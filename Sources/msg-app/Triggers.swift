import Music
import SwiftUI

/// Plain-language explanation of what makes a voice play, built from the *current* settings
/// and traffic, so it changes as you tweak.
struct TriggerCard: View {
    @Environment(AppModel.self) private var model
    let role: String

    var body: some View {
        VisualCard(title: "What makes the \(role) play") {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: line.icon).foregroundStyle(RoleStyle.color(role)).frame(width: 16)
                    Text(line.text).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let last = model.status?.recentNotes.last(where: { $0.role == role }) {
                Text("Last note: \(Format.note(last.note)), because \(last.why)")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private struct Line { let icon: String; let text: String }

    private var lines: [Line] {
        let m = model
        let bpm = m.effective("clock.bpm")
        let barSeconds = 4 * 60 / max(bpm, 1)
        let total = m.status?.totalRate ?? 0
        let level = min(max((log10(max(total, 1)) - 3) / 4, 0), 1)
        func on(_ id: String) -> Bool { m.base(id) >= 0.5 }
        func pct(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }
        let pitchNote = Line(icon: "tuningfork", text: "Its pitches are pulled into key by Quantise → pitch strength (\(m.base("quant.pitch.strength").formatted(.number.precision(.fractionLength(2))))), and it can be thinned by the density limit (\(m.base("quant.density.maxPerSecond").formatted()) notes/s).")

        switch role {
        case "pad":
            guard on("gen.drone.enabled") else { return [Line(icon: "speaker.slash", text: "Switched off (Generators → Pad → Enabled).")] }
            let bars = Int(m.base("harmony.barsPerChord"))
            return [
                Line(icon: "clock", text: "Plays the whole chord each time the chord changes: every \(bars) bar\(bars == 1 ? "" : "s"), about every \(Int((Double(bars) * barSeconds).rounded())) s at \(Int(bpm)) bpm (Harmony → Bars per chord, Tempo)."),
                Line(icon: "music.note.list", text: "Which chord comes from the mood's progression (Harmony → Chord progressions); a flurry of apps waking inserts a cadence."),
                Line(icon: "speaker.wave.2", text: "Loudness \(pct(m.effective("gen.drone.intensity"))) now; traffic swells it through a Modulation route."),
            ]
        case "lead":
            guard on("gen.motif.enabled") else { return [Line(icon: "speaker.slash", text: "Switched off (Generators → Lead → Enabled).")] }
            let woke = (m.status?.apps ?? []).filter { $0.lastWake != nil }.sorted { ($0.lastWake ?? 0) > ($1.lastWake ?? 0) }.first
            let ago = woke.flatMap { a in a.lastWake.map { (m.status?.time ?? $0) - $0 } }
            return [
                Line(icon: "bolt.horizontal", text: "Plays an app's motif when that app's traffic jumps above \(Format.rate(m.base("activity.threshold"))) after being quiet (App activity → Threshold)."),
                Line(icon: "hourglass", text: "The same app can't retrigger for \(Int(m.base("activity.cooldown"))) s; at most \(Int(m.base("gen.motif.maxPerTick"))) apps start at once\(on("activity.ignore") ? "; background services are ignored" : "")."),
                Line(icon: "music.quarternote.3", text: "Each app has its own motif: generated from its name, or your design (Motifs page)."),
                Line(icon: "waveform", text: woke.map { "Most recently: \($0.name), \(Int((ago ?? 0).rounded())) s ago." } ?? "No app has woken yet."),
                pitchNote,
            ]
        case "pulse":
            guard on("gen.pulse.enabled") else { return [Line(icon: "speaker.slash", text: "Switched off (Generators → Pulse → Enabled).")] }
            let stepBeats = Quantiser.gridOptions[min(max(Int(m.base("gen.pulse.step")), 0), Quantiser.gridOptions.count - 1)].beats
            let stepsPerSecond = bpm / 60 / stepBeats
            let chance = min(max(m.effective("gen.pulse.density"), 0), 1)
            return [
                Line(icon: "dice", text: "On every \(Quantiser.gridOptions[Int(m.base("gen.pulse.step"))].label) step it rolls a dice: \(pct(chance)) chance of a note right now (\(pct(m.base("gen.pulse.density"))) set + traffic via Modulation)."),
                Line(icon: "speedometer", text: String(format: "That's about %.1f notes a second at the current traffic (%@).", stepsPerSecond * chance, Format.rate(total))),
                Line(icon: "arrow.up.right", text: "Its pitch rises with traffic: about +\(Int((level * m.base("gen.pulse.span")).rounded())) semitones now, ± \(Int(m.base("gen.pulse.jitter"))) random."),
                pitchNote,
            ]
        case "bass":
            guard on("gen.bass.enabled") else { return [Line(icon: "speaker.slash", text: "Switched off (Generators → Bass → Enabled).")] }
            let pattern = BassGenerator.patterns[min(max(Int(m.base("gen.bass.pattern")), 0), 3)]
            var out = [Line(icon: "metronome", text: pattern == "Hold"
                            ? "Holds the chord's root for the whole chord, struck at each chord change."
                            : "Plays the \(pattern.lowercased()) pattern on the chord's notes every \(m.base("gen.bass.stepBeats").formatted()) beats (Bass → Pattern, Step).")]
            if pattern != "Hold" {
                out.append(Line(icon: "plus.circle", text: "Extra fill notes between steps: \(pct(m.base("gen.bass.fills") * level)) chance each at the current traffic (more traffic, more fills)."))
            }
            out.append(Line(icon: "speaker.wave.2", text: "Louder when the network is busier (Bass → Dynamics \(m.base("gen.bass.dynamics").formatted(.number.precision(.fractionLength(2)))))."))
            return out
        case "sub":
            guard on("gen.sub.enabled") else { return [Line(icon: "speaker.slash", text: "Switched off (Generators → Sub drone → Enabled).")] }
            let pedal = Int(m.base("gen.sub.mode")) == 0
            let hold = Int(m.base("gen.sub.holdBars"))
            return [
                Line(icon: "infinity", text: pedal
                     ? "Holds the key's home note, struck again every \(hold) bars (about every \(Int((Double(hold) * barSeconds).rounded())) s), whatever the chords do."
                     : "Plays the root of each chord, struck at every chord change."),
                Line(icon: "waveform.path", text: "Not driven by traffic directly; route traffic to Sub → Intensity in Modulation to make it swell."),
            ]
        default:
            return []
        }
    }
}
