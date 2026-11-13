import AUHost
import Params
import Router
import SwiftUI

/// A mixing desk for the hosted synths: a channel strip per synth (EQ, sends, pan, mute/solo,
/// fader and meter), the reverb and delay returns, and the master. Voices sent out over MIDI get a
/// simpler strip: their mix happens on the device, so here it's a velocity trim and a mute.
struct MixerView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if !model.isRunning {
                NotRunningHint()
            } else {
                let hosted = model.hostedInstruments
                let external = model.scene.voices.filter { !$0.destination.hasPrefix(InstrumentConfig.destinationPrefix) }
                let explanation = hosted.isEmpty
                    ? "This scene has no hosted synths, so there's no audio to mix in the app. Voices sent out over MIDI are mixed where they play; their strips trim velocity instead."
                    : "Sends are after the fader, so pulling a fader down also quietens its reverb and echoes. Every knob and fader is a setting you can route traffic to in Modulation."
                ScrollView([.horizontal, .vertical]) {
                    VStack(alignment: .leading, spacing: 10) {
                        if model.skin == .studio {
                            LCDScreen(lines: lcdLines).frame(maxWidth: 760).help(explanation)
                        } else {
                            Text(explanation)
                                .font(.callout).foregroundStyle(.secondary)
                                .frame(maxWidth: 900, alignment: .leading)
                        }
                        HStack(alignment: .top, spacing: 8) {
                            ForEach(hosted, id: \.id) { ChannelStrip(instrument: $0) }
                            if !external.isEmpty {
                                if !hosted.isEmpty { Divider() }
                                ForEach(external, id: \.role) { MIDIStrip(voice: $0) }
                            }
                            if !hosted.isEmpty {
                                Divider()
                                BusStrip(bus: "reverb")
                                BusStrip(bus: "delay")
                                MasterStrip()
                            }
                        }
                    }
                    .padding(16)
                }
                .defaultScrollAnchor(.topLeading)
                .skinnedPage(model.skin, shade: 0.45)
            }
        }
        .navigationTitle("Mixer")
    }

    /// What the LCD shows: the scene, the musical state, and the latest reason a note played.
    private var lcdLines: [String] {
        guard let s = model.status else { return [model.scene.name] }
        let chord = s.chordHistory.last?.name ?? s.chord.joined(separator: " ")
        let why = s.recentNotes.last { $0.time <= s.time }.map { "\($0.role): \($0.why)" } ?? "waiting for notes"
        return [model.session?.scene.name ?? model.scene.name,
                "mood \(s.mood) · \(s.key) · chord \(chord) · \(Int(s.bpm.rounded())) bpm",
                why]
    }
}

// MARK: - Strips

private struct StripFrame<Content: View>: View {
    @Environment(\.skin) private var skin
    let title: String
    var subtitle: String = ""
    var color: Color = .accentColor
    var width: CGFloat = 116
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 8) {
            VStack(spacing: 2) {
                Text(title.uppercased()).font(skin == .studio ? Studio.legend(12, weight: .bold) : .caption.weight(.bold))
                    .tracking(skin == .studio ? 1 : 0).lineLimit(1)
                Text(subtitle).font(skin == .studio ? Studio.legend(8, weight: .regular) : .caption2)
                    .foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.center)
                    .frame(height: 24, alignment: .top)
            }
            Rectangle().fill(color).frame(height: 3).clipShape(Capsule())
            content
        }
        .padding(10)
        .frame(width: width)
        .background {
            if skin == .studio { PanelBackground(cornerRadius: 8) } else { RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06)) }
        }
    }
}

private struct Knob: View {
    @Environment(AppModel.self) private var model
    let id: String
    let label: String
    var color: Color = .accentColor

    var body: some View {
        if let spec = model.specsByID[id] {
            ParamKnob(spec: spec, label: label, color: color, size: 40)
        }
    }
}

struct ChannelStrip: View {
    @Environment(AppModel.self) private var model
    let instrument: InstrumentConfig

    var body: some View {
        let p = "au.\(instrument.id)"
        let roles = model.scene.voices.filter { $0.destination == instrument.destination }.map(\.role)
        let color = roles.first.map { RoleStyle.color($0) } ?? .accentColor
        StripFrame(title: instrument.id, subtitle: "\(instrument.component)\(roles.isEmpty ? "" : " · " + roles.joined(separator: ", "))", color: color) {
            SectionLegend(text: "EQ")
            Knob(id: "\(p).eqHigh", label: "High", color: color)
            HStack(spacing: 2) {
                Knob(id: "\(p).eqMid", label: "Mid", color: color)
                Knob(id: "\(p).eqMidFreq", label: "Freq", color: color)
            }
            Knob(id: "\(p).eqLow", label: "Low", color: color)
            Divider()
            SectionLegend(text: "SENDS")
            HStack(spacing: 2) {
                Knob(id: "\(p).sendReverb", label: "Reverb", color: color)
                Knob(id: "\(p).sendDelay", label: "Delay", color: color)
            }
            Divider()
            Knob(id: "\(p).pan", label: "Pan", color: color)
            HStack(spacing: 6) {
                ToggleChip(id: "\(p).mute", label: "M", on: .orange)
                ToggleChip(id: "\(p).solo", label: "S", on: .yellow)
            }
            HStack(alignment: .bottom, spacing: 6) {
                Fader(id: "\(p).volume", color: color)
                LevelMeter(key: instrument.id)
            }
        }
    }
}

/// A voice sent out over MIDI: velocity trim and mute; its audio is mixed where it plays.
struct MIDIStrip: View {
    @Environment(AppModel.self) private var model
    let voice: VoiceConfig

    var body: some View {
        let color = RoleStyle.color(voice.role)
        StripFrame(title: voice.role, subtitle: "MIDI → \(DestinationPicker.label(voice.destination, model: model))", color: color) {
            Text("Mixed on the device it plays on. This fader trims velocity.")
                .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(height: 64, alignment: .top)
            ToggleChip(id: "voice.\(voice.role).enabled", label: "ON", on: color)
            Fader(id: "voice.\(voice.role).velocityScale", color: color, height: 220)
        }
    }
}

struct BusStrip: View {
    @Environment(AppModel.self) private var model
    let bus: String

    var body: some View {
        StripFrame(title: bus, subtitle: bus == "reverb" ? "FX return" : "FX return · tempo-synced", color: .gray) {
            if bus == "reverb" {
                if let room = model.specsByID["mix.reverb.room"] {
                    SkinPicker(selection: Binding(get: { Int(model.base(room.id)) }, set: { model.set(room.id, Double($0)) }),
                               options: room.options.enumerated().map { ($0.offset, $0.element) })
                        .controlSize(.small)
                }
                Spacer().frame(height: 120)
            } else {
                Knob(id: "mix.delay.beats", label: "Beats")
                Knob(id: "mix.delay.feedback", label: "Feedback")
                Knob(id: "mix.delay.tone", label: "Tone")
            }
            Spacer(minLength: 0)
            Fader(id: "mix.\(bus).return", color: .gray)
        }
    }
}

struct MasterStrip: View {
    var body: some View {
        StripFrame(title: "Master", subtitle: "hosted synths", color: .primary) {
            Spacer().frame(height: 190)
            HStack(alignment: .bottom, spacing: 6) {
                Fader(id: "mix.master", color: .primary)
                LevelMeter(key: "master")
            }
        }
    }
}

// MARK: - Controls

/// A small latching button bound to a toggle param.
struct ToggleChip: View {
    @Environment(AppModel.self) private var model
    @Environment(\.skin) private var skin
    let id: String
    let label: String
    let on: Color

    var body: some View {
        let isOn = model.effective(id) >= 0.5
        if skin == .studio {
            StudioLEDButton(label: label, on: isOn, color: on) { model.set(id, isOn ? 0 : 1) }
                .help(model.specsByID[id]?.help ?? "")
        } else {
            chip(isOn)
        }
    }

    private func chip(_ isOn: Bool) -> some View {
        Button { model.set(id, isOn ? 0 : 1) } label: {
            Text(label).font(.caption.weight(.bold)).frame(width: 30, height: 20)
                .background(isOn ? on.opacity(0.85) : Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                .foregroundStyle(isOn ? Color.black : .secondary)
        }
        .buttonStyle(.plain)
        .help(model.specsByID[id]?.help ?? "")
    }
}

/// A vertical fader. Levels use a cube law (more travel near the top, like a desk), shown in dB;
/// other params move linearly.
struct Fader: View {
    @Environment(AppModel.self) private var model
    @Environment(\.skin) private var skin
    let id: String
    var color: Color = .accentColor
    var height: CGFloat = 200

    private var isGain: Bool { !id.hasSuffix("velocityScale") }

    private func position(_ v: Double, _ spec: ParamSpec) -> Double {
        isGain ? cbrt(max(v, 0) / spec.range.upperBound) : (v - spec.range.lowerBound) / spec.span
    }

    private func value(_ pos: Double, _ spec: ParamSpec) -> Double {
        let p = min(max(pos, 0), 1)
        return isGain ? pow(p, 3) * spec.range.upperBound : spec.range.lowerBound + p * spec.span
    }

    private func label(_ v: Double) -> String {
        guard isGain else { return "×\(v.formatted(.number.precision(.fractionLength(2))))" }
        return v <= 0.0001 ? "−∞" : String(format: "%+.1f dB", 20 * log10(v))
    }

    var body: some View {
        if let spec = model.specsByID[id] {
            let v = model.effective(id)
            VStack(spacing: 4) {
                GeometryReader { geo in
                    let h = geo.size.height, travel = h - 22
                    let y = (1 - position(v, spec)) * travel
                    ZStack(alignment: .top) {
                        Capsule().fill(skin == .studio ? Color.black.opacity(0.8) : Color.primary.opacity(0.18))
                            .frame(width: skin == .studio ? 5 : 4)
                            .overlay(Capsule().stroke(Color.white.opacity(skin == .studio ? 0.08 : 0), lineWidth: 1))
                            .frame(maxHeight: .infinity).padding(.vertical, 11)
                        if isGain {
                            ForEach([0.0, -6, -12, -24, -48], id: \.self) { db in
                                let ty = (1 - cbrt(pow(10, db / 20))) * travel + 11
                                Rectangle().fill(Color.secondary.opacity(0.5)).frame(width: 14, height: 1).offset(y: ty)
                            }
                        }
                        RoundedRectangle(cornerRadius: 3)
                            .fill(LinearGradient(colors: [Color(white: 0.75), Color(white: 0.45)], startPoint: .top, endPoint: .bottom))
                            .overlay(Rectangle().fill(color).frame(height: 2))
                            .frame(width: 30, height: 22)
                            .shadow(radius: 2, y: 1)
                            .offset(y: y)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                        model.set(id, value(1 - (g.location.y - 11) / travel, spec))
                    })
                    .onTapGesture(count: 2) { model.set(id, spec.defaultValue) }
                }
                .frame(width: 40, height: height)
                Text(label(v)).font(skin == .studio ? Studio.legend(9) : .caption2.monospacedDigit()).foregroundStyle(.secondary)
                    .lineLimit(1).fixedSize().frame(width: 56)
            }
            .help("\(spec.help) Double-click to reset.")
        }
    }
}

/// Peak level of a channel (or "master"), in dB from −60 to 0, with a decaying hold.
struct LevelMeter: View {
    @Environment(AppModel.self) private var model
    let key: String
    var height: CGFloat = 200

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: !model.visualsActive)) { _ in
            let peak = Double(model.mixLevels()[key] ?? 0)
            let db = peak > 0 ? 20 * log10(peak) : -100
            let fill = min(max((db + 60) / 60, 0), 1)
            VStack(spacing: 4) {
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.1))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(LinearGradient(stops: [.init(color: .green, location: 0), .init(color: .green, location: 0.7),
                                                     .init(color: .yellow, location: 0.85), .init(color: .red, location: 1)],
                                             startPoint: .bottom, endPoint: .top))
                        .mask(alignment: .bottom) { Rectangle().frame(height: height * fill) }
                }
                .frame(width: 8, height: height)
                .frame(width: 26)
                // Fixed width: the number changing from "-41" to "-6" mustn't shift the fader beside it.
                Text(db > -60 ? String(format: "%.0f", db) : "").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 26, height: 14)
            }
        }
    }
}

/// "EQ", "SENDS": plain caption, or an engraved legend with rules in the studio skin.
private struct SectionLegend: View {
    @Environment(\.skin) private var skin
    let text: String

    var body: some View {
        if skin == .studio {
            HStack(spacing: 4) {
                Rectangle().fill(Studio.label.opacity(0.3)).frame(height: 1)
                Text(text).font(Studio.legend(9, weight: .bold)).tracking(1).foregroundStyle(Studio.label).fixedSize()
                Rectangle().fill(Studio.label.opacity(0.3)).frame(height: 1)
            }
        } else {
            Text(text).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
        }
    }
}
