import Foundation
import Params
import SignalBus

/// Everything a generator may look at during one engine tick.
public struct GeneratorContext {
    public var now: Double
    public var clock: MusicalClock
    /// Beats elapsed since the previous tick.
    public var beats: Range<Double>
    public var harmony: HarmonyContext
    public var params: ParamStore
    /// True on the tick where the Conductor moved to a new chord.
    public var chordChanged: Bool
    public var activations: [Activation]
    /// Total bytes/s, latest.
    public var totalRate: Double
    /// Events received since the previous tick (DNS lookups, handshakes…).
    public var events: [SignalSample]
    /// The conductor's mood ("quiet", "calm", "busy", "focused").
    public var mood: String
    /// Which chord of the mood's progression is playing, and how many it has: the phrase.
    public var progressionIndex: Int
    public var progressionLength: Int
    /// A gesture (e.g. the flurry cadence) is queued and will take over the next chord(s).
    public var gesturePending: Bool
    /// True on the tick a flurry of apps waking was detected.
    public var flurry: Bool

    public init(now: Double, clock: MusicalClock, beats: Range<Double>, harmony: HarmonyContext,
                params: ParamStore, chordChanged: Bool, activations: [Activation], totalRate: Double,
                events: [SignalSample] = [], mood: String = "quiet", progressionIndex: Int = 0,
                progressionLength: Int = 1, gesturePending: Bool = false, flurry: Bool = false) {
        self.events = events
        self.mood = mood
        self.progressionIndex = progressionIndex
        self.progressionLength = progressionLength
        self.gesturePending = gesturePending
        self.flurry = flurry
        self.now = now
        self.clock = clock
        self.beats = beats
        self.harmony = harmony
        self.params = params
        self.chordChanged = chordChanged
        self.activations = activations
        self.totalRate = totalRate
    }
}

public struct GeneratorOutput {
    public var notes: [NoteIntent] = []
    public var controls: [ControlIntent] = []
    public init() {}
}

/// A musical behaviour. Generators speak in roles and intents; they never touch MIDI.
public protocol Generator: AnyObject {
    var id: String { get }
    var params: [ParamSpec] { get }
    func tick(_ ctx: GeneratorContext, rng: inout SeededRandom) -> GeneratorOutput
}

// MARK: - Drone

/// Holds the current chord on the "pad" role, re-voiced on every chord change. Optionally
/// streams a CC (e.g. filter cutoff) whose value is meant to be driven by the mod matrix.
public final class DroneGenerator: Generator {
    public let id = "drone"
    public init() {}

    public var params: [ParamSpec] {
        [
            ParamSpec("gen.drone.enabled", kind: .toggle, default: 1, help: "The pad: the current chord, held. The harmonic bed everything else sits on."),
            ParamSpec("gen.drone.octave", kind: .integer, range: 1...6, default: 3, help: "Register of the pad chord. 3 = warm middle; 4 = brighter and thinner; 2 = darker and muddier."),
            ParamSpec("gen.drone.intensity", default: 0.35, help: "Pad loudness. Traffic modulates it by default, so the bed swells with network activity."),
            ParamSpec("gen.drone.legato", kind: .continuous, range: 0.25...1.5, default: 1.02,
                      help: "Chord length relative to its slot. Just over 1 = chords overlap smoothly; below 1 leaves gaps (a breathing, pulsing pad)."),
            ParamSpec("gen.drone.spread", kind: .integer, range: 0...2, default: 1,
                      help: "Open voicing: lifts every other chord note up an octave for a wider, airier pad. 0 = close, compact chords."),
            ParamSpec("gen.drone.ccNumber", kind: .integer, range: 0...127, default: 74,
                      help: "MIDI CC the pad sends once a beat (74 = filter cutoff on most synths). 0 = off. For hosted synths it's usually better to route traffic straight to a synth parameter in Modulation."),
            ParamSpec("gen.drone.ccValue", default: 0.4, help: "Value of that CC (0–1). Modulated by traffic by default: busier network = brighter pad."),
        ]
    }

    private var lastCC: Int?

    public func tick(_ ctx: GeneratorContext, rng: inout SeededRandom) -> GeneratorOutput {
        var out = GeneratorOutput()
        let p = ctx.params
        guard p.bool("gen.drone.enabled") else { return out }

        if ctx.chordChanged {
            let size = ctx.harmony.chordDegrees.count
            let beats = Double(p.int("harmony.barsPerChord") * ctx.clock.beatsPerBar) * p.value("gen.drone.legato")
            for i in 0..<size {
                let lift = i % 2 == 1 ? p.int("gen.drone.spread") : 0
                out.notes.append(NoteIntent(
                    role: "pad", pitch: .chordTone(i, octave: p.int("gen.drone.octave") + lift),
                    intensity: p.value("gen.drone.intensity"), time: ctx.now, beats: beats,
                    essential: true, why: "chord changed → \(ctx.harmony.chordName(degree: ctx.harmony.chordDegree))"
                ))
            }
        }

        let cc = p.int("gen.drone.ccNumber")
        if cc > 0, !MusicalClock.crossings(of: 1, in: ctx.beats).isEmpty {
            let value = Int((p.value("gen.drone.ccValue") * 127).rounded())
            if value != lastCC {
                out.controls.append(ControlIntent(role: "pad", controller: cc, value: value, time: ctx.now))
                lastCC = value
            }
        }
        return out
    }
}

// MARK: - Motif

/// Each app gets its own short motif, derived from a stable hash of its name, played on the
/// "lead" role when that app wakes up. Like hearing who is talking.
public final class MotifGenerator: Generator {
    public let id = "motif"
    /// Hand-made motifs that replace the generated one for matching apps.
    public var designs: [MotifDesign] = []
    private var instances = 0
    public init() {}

    public var params: [ParamSpec] {
        [
            ParamSpec("gen.motif.enabled", kind: .toggle, default: 1, help: "Per-app motifs: each app has its own little tune, played on the lead when it wakes up. This is how you hear who is talking."),
            ParamSpec("gen.motif.length", kind: .integer, range: 1...12, default: 4, help: "Notes per motif. Short (2–3) = blips and chirps; long (6–12) = little melodies."),
            ParamSpec("gen.motif.stepBeats", kind: .continuous, range: 0.125...4, default: 0.5, unit: "beats",
                      help: "Gap between motif notes in beats. 0.25 = quick flourish, 1 = slow and spacious."),
            ParamSpec("gen.motif.noteBeats", kind: .continuous, range: 0.05...8, default: 0.75, unit: "beats",
                      help: "Length of each motif note. Short = plucked; long = notes ring into each other."),
            ParamSpec("gen.motif.octave", kind: .integer, range: 2...7, default: 5, help: "Register of the motifs. 5 sits above the pad; 6 is bell-like and sparkly."),
            ParamSpec("gen.motif.range", kind: .integer, range: 1...24, default: 7, unit: "semitones",
                      help: "How far a motif can wander from its first note, in semitones. Small = tight, repetitive figures; large = leaping melodies."),
            ParamSpec("gen.motif.intensity", default: 0.7, help: "Overall loudness of motifs."),
            ParamSpec("gen.motif.dynamics", default: 0.6,
                      help: "How much an app's traffic changes its motif's loudness. 0 = all motifs equal; 1 = big downloads are loud, small pings are soft."),
            ParamSpec("gen.motif.maxPerTick", kind: .integer, range: 1...8, default: 2,
                      help: "How many apps can start motifs at the same instant. Keeps simultaneous wake-ups from piling up."),
            ParamSpec("gen.motif.seed", kind: .integer, range: 0...9999, default: 0, modulatable: false,
                      help: "Which set of generated motifs plays. Every app keeps its own tune within a set; a new number gives every app a new tune. 0 = the original set. Variation changes this when it reshuffles motifs."),
        ]
    }

    /// Chromatic offsets for an app's motif. Deterministic per name (and seed; 0 = the original set).
    public static func shape(for key: String, length: Int, range: Int, seed: Int = 0) -> (start: Int, offsets: [Int]) {
        var rng = SeededRandom(seed: stableHash(seed == 0 ? key : "\(key)#\(seed)"))
        let start = Int(rng.next() % 12)
        var offsets: [Int] = [0]
        var current = 0
        while offsets.count < length {
            let step = Int(rng.next() % 5) + 1
            let up = rng.chance(0.5)
            current = min(max(current + (up ? step : -step), -range), range)
            offsets.append(current)
        }
        return (start, offsets)
    }

    public func tick(_ ctx: GeneratorContext, rng: inout SeededRandom) -> GeneratorOutput {
        var out = GeneratorOutput()
        let p = ctx.params
        guard p.bool("gen.motif.enabled") else { return out }

        for activation in ctx.activations.prefix(p.int("gen.motif.maxPerTick")) {
            instances += 1
            if let design = MotifDesign.best(for: activation.key, in: designs) {
                out.notes += play(design, for: activation, ctx)
                continue
            }
            let shape = Self.shape(for: activation.key, length: p.int("gen.motif.length"),
                                   range: p.int("gen.motif.range"), seed: p.int("gen.motif.seed"))
            let centre = Double(12 * (p.int("gen.motif.octave") + 1) + ctx.harmony.root + shape.start)
            // Loudness: log of the rate between 1 kB/s and 10 MB/s, blended by `dynamics`.
            let level = min(max((log10(max(activation.bytesPerSecond, 1)) - 3) / 4, 0), 1)
            let d = p.value("gen.motif.dynamics")
            let intensity = p.value("gen.motif.intensity") * ((1 - d) + d * level)
            let step = p.value("gen.motif.stepBeats") * ctx.clock.secondsPerBeat
            for (i, offset) in shape.offsets.enumerated() {
                out.notes.append(NoteIntent(
                    role: "lead", pitch: .raw(centre + Double(offset)), intensity: intensity,
                    time: ctx.now + Double(i) * step, beats: p.value("gen.motif.noteBeats"),
                    why: "\(activation.key) woke (\(formatRate(activation.bytesPerSecond))) · generated motif",
                    motif: .init(app: activation.key, step: i, designID: nil, instance: instances)
                ))
            }
        }
        return out
    }

    private func play(_ design: MotifDesign, for activation: Activation, _ ctx: GeneratorContext) -> [NoteIntent] {
        let p = ctx.params
        let level = min(max((log10(max(activation.bytesPerSecond, 1)) - 3) / 4, 0), 1)
        let d = p.value("gen.motif.dynamics")
        let intensity = p.value("gen.motif.intensity") * ((1 - d) + d * level)
        let step = (design.stepBeats ?? p.value("gen.motif.stepBeats")) * ctx.clock.secondsPerBeat
        let anchor = design.anchor == .chord ? ctx.harmony.chordDegree : 0
        let octave = design.octave ?? p.int("gen.motif.octave")
        let label = design.match == "*" ? "default design" : "design “\(design.match)”"
        return design.steps.enumerated().compactMap { i, s in
            guard let s else { return nil }
            return NoteIntent(role: "lead", pitch: .exact(ctx.harmony.note(degree: anchor + s, octave: octave)),
                              intensity: intensity, time: ctx.now + Double(i) * step,
                              beats: p.value("gen.motif.noteBeats"),
                              why: "\(activation.key) woke (\(formatRate(activation.bytesPerSecond))) · \(label)",
                              motif: .init(app: activation.key, step: i, designID: design.id, instance: instances))
        }
    }
}

// MARK: - Pulse

/// A sparse rhythmic layer on the "pulse" role: on each grid step it fires with probability
/// `gen.pulse.density` (route total traffic to it), pitch rising with traffic volume.
public final class PulseGenerator: Generator {
    public let id = "pulse"
    public init() {}

    public var params: [ParamSpec] {
        [
            ParamSpec("gen.pulse.enabled", kind: .toggle, default: 1, help: "A sparse rhythmic sparkle: random notes on the grid whose density follows total traffic."),
            ParamSpec("gen.pulse.step", kind: .choice, default: 1, options: Quantiser.gridOptions.map(\.label),
                      help: "Grid the pulse fires on. 1/8 = gentle; 1/16 = busier, more glitchy."),
            ParamSpec("gen.pulse.density", default: 0.05, help: "Chance of a note on each step. Traffic adds to this by default, so a busy network sparkles more."),
            ParamSpec("gen.pulse.octave", kind: .integer, range: 1...7, default: 4, help: "Lowest register of the pulse."),
            ParamSpec("gen.pulse.span", kind: .integer, range: 0...36, default: 14, unit: "semitones",
                      help: "How far pitch rises with traffic, in semitones. Higher = busy network sounds higher and more excited."),
            ParamSpec("gen.pulse.jitter", kind: .continuous, range: 0...12, default: 3, unit: "semitones",
                      help: "Random pitch spread on each pulse. 0 = repetitive; higher = more varied."),
            ParamSpec("gen.pulse.intensity", default: 0.45, help: "Loudness of the pulse."),
            ParamSpec("gen.pulse.noteBeats", kind: .continuous, range: 0.05...4, default: 0.25, unit: "beats",
                      help: "Length of pulse notes. Short = ticks and plinks; long = shimmering overlaps."),
        ]
    }

    public func tick(_ ctx: GeneratorContext, rng: inout SeededRandom) -> GeneratorOutput {
        var out = GeneratorOutput()
        let p = ctx.params
        guard p.bool("gen.pulse.enabled") else { return out }
        let step = Quantiser.gridOptions[p.int("gen.pulse.step")].beats
        let level = min(max((log10(max(ctx.totalRate, 1)) - 3) / 4, 0), 1)
        for beat in MusicalClock.crossings(of: step, in: ctx.beats) where rng.chance(p.value("gen.pulse.density")) {
            let base = Double(12 * (p.int("gen.pulse.octave") + 1) + ctx.harmony.root)
            let pitch = base + level * p.value("gen.pulse.span") + (rng.unit() * 2 - 1) * p.value("gen.pulse.jitter")
            out.notes.append(NoteIntent(
                role: "pulse", pitch: .raw(pitch), intensity: p.value("gen.pulse.intensity"),
                time: ctx.clock.time(ofBeat: beat), beats: p.value("gen.pulse.noteBeats"),
                why: String(format: "%.0f%% chance on this step · traffic %@", p.value("gen.pulse.density") * 100, formatRate(ctx.totalRate))
            ))
        }
        return out
    }
}

public func formatRate(_ bytesPerSecond: Double) -> String {
    switch bytesPerSecond {
    case ..<1_000: String(format: "%.0f B/s", bytesPerSecond)
    case ..<1_000_000: String(format: "%.1f kB/s", bytesPerSecond / 1_000)
    default: String(format: "%.1f MB/s", bytesPerSecond / 1_000_000)
    }
}
