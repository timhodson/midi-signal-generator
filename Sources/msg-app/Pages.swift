import SwiftUI

/// The live visuals at the top of each settings page, and per-group extras.
enum Pages {
    // MARK: Harmony

    @MainActor static var harmonyHero: AnyView {
        AnyView(VStack(spacing: 12) {
            VisualCard(title: "Mood", caption: "Smoothed traffic picks the mood, and the mood picks the chord progression. Drag the white handles to move the thresholds.") {
                MoodLadder()
            }
            VisualCard(title: "Harmony now",
                       caption: "Dots: notes in the scale · accent dots: notes of the current chord · lit keys: notes sounding now, in their voice's colour.") {
                HarmonyKeyboard().frame(height: 74)
                PianoRoll(window: 20, ahead: 2).frame(height: 150)
                RoleLegend()
            }
        })
    }

    @MainActor static func harmonyAccessory(_ group: String) -> AnyView? {
        guard group == "harmony" else { return nil }
        return AnyView(VStack(spacing: 12) {
            VisualCard(title: "Chords in this key",
                       caption: "Chords aren't stored as notes but as positions in the scale: the chord on step 1 stacks scale notes 1·3·5, step 2 stacks 2·4·6, and so on. Change Root, Scale or Chord size below and watch every chord (and every progression) change. Click a chord to hear it now.") {
                ChordPalette()
            }
            VisualCard(title: "Chord progressions by mood",
                       caption: "What each mood plays. Click a chord to change, move, duplicate or remove it; + adds one (or use + on a chord above). The outlined chord is playing now.") {
                ProgressionEditor()
            }
        })
    }

    // MARK: Quantise

    @MainActor static var quantiseHero: AnyView {
        AnyView(VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VisualCard(title: "Pitch: asked → played",
                           caption: "Hollow = the pitch the data asked for; filled = the note that played. Long lines = strong pull into key. Shaded rows: scale; highlighted rows: current chord.") {
                    PitchPullView().frame(height: 200)
                }
                VisualCard(title: "Velocity curve",
                           caption: "How data intensity becomes loudness, as set now. Dots are recent notes.") {
                    VelocityCurveView().frame(height: 200)
                }
                .frame(width: 380)
            }
            VisualCard(title: "Timing: asked → played",
                       caption: "Top: when the data asked for a note. Bottom: when it sounded, on the grid (lines; swing shifts every second one). Slanted lines = snapping.") {
                TimingView().frame(height: 110)
            }
            VisualCard(title: "Density") { DensityMeter() }
        })
    }

    // MARK: Generators

    @MainActor static var generatorsHero: AnyView {
        AnyView(VisualCard(title: "All voices", caption: "Every note from every generator. Outlined notes are scheduled but not played yet; brighter = louder. The band on top shows the chords.") {
            PianoRoll(window: 16, ahead: 2).frame(height: 240)
            RoleLegend()
        })
    }

    static let generatorRoles = ["drone": "pad", "motif": "lead", "pulse": "pulse", "bass": "bass", "sub": "sub", "drums": "drums"]

    /// Knob colour: a voice's colour for its generator / voice group, accent otherwise.
    static func color(forGroup group: String) -> Color {
        if group == "packets" { return RoleStyle.color("pulse") }
        if let role = generatorRoles[group] { return RoleStyle.color(role) }
        if RoleStyle.order.contains(group) { return RoleStyle.color(group) }
        return .accentColor
    }

    @MainActor static func generatorAccessory(_ group: String) -> AnyView? {
        if group == "packets" { return AnyView(NetworkEventsCard()) }
        if group == "drums" { return AnyView(DrumsCard()) }
        guard let role = generatorRoles[group] else { return nil }
        return AnyView(VStack(spacing: 10) {
            TriggerCard(role: role)
            RoleLane(role: role)
        })
    }

    // MARK: Voices

    @MainActor static func voiceAccessory(_ role: String) -> AnyView? {
        AnyView(VStack(spacing: 10) {
            DestinationPicker(role: role)
            VoiceRangeEditor(role: role)
        })
    }
}

/// Keyboard showing the scale, current chord and every sounding note.
struct HarmonyKeyboard: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 12, paused: !model.visualsActive)) { _ in
            KeyboardView(low: 24, high: 96, scale: Set(model.status?.scalePitchClasses ?? []),
                         chord: Set(model.status?.chordPitchClasses ?? []), sounding: model.soundingNotes())
        }
    }
}

/// One voice's recent notes, in its own range.
struct RoleLane: View {
    @Environment(AppModel.self) private var model
    let role: String
    var body: some View {
        let lo = Int(model.base("voice.\(role).low")), hi = Int(model.base("voice.\(role).high"))
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2).fill(RoleStyle.color(role)).frame(width: 12, height: 8)
                Text("\(role) voice · \(Format.note(lo))–\(Format.note(hi))").font(.caption).foregroundStyle(.secondary)
            }
            PianoRoll(roles: [role], window: 16, ahead: 2, pitchRange: lo...max(hi, lo + 12), showChords: role != "lead", fps: 12)
                .frame(height: 110)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

/// Drag the handles on the keyboard to set a voice's range; lit keys are its sounding notes.
struct VoiceRangeEditor: View {
    @Environment(AppModel.self) private var model
    let role: String
    var body: some View {
        let lo = Int(model.base("voice.\(role).low")), hi = Int(model.base("voice.\(role).high"))
        VisualCard(title: "\(role.capitalized) range: \(Format.note(lo)) – \(Format.note(hi))",
                   caption: "Drag the handles to set the lowest and highest notes. Notes outside are moved by octaves into this range. Lit keys: notes this voice is playing now.") {
            TimelineView(.animation(minimumInterval: 1 / 12, paused: !model.visualsActive)) { _ in
                KeyboardView(low: 21, high: 108, scale: Set(model.status?.scalePitchClasses ?? []),
                             chord: Set(model.status?.chordPitchClasses ?? []),
                             sounding: model.soundingNotes(roles: [role]), range: lo...hi,
                             rangeColor: RoleStyle.color(role)) { newLo, newHi in
                    model.set("voice.\(role).low", Double(newLo))
                    model.set("voice.\(role).high", Double(newHi))
                }
            }
            .frame(height: 70)
            PianoRoll(roles: [role], window: 12, ahead: 2, pitchRange: lo...max(hi, lo + 12), showChords: false, fps: 12)
                .frame(height: 80)
        }
    }
}
