import Foundation
import Params

// MARK: - Bass

/// The "bass" role: the chord root (and friends) in a low register, in one of four patterns.
/// Traffic adds fills between the main notes and pushes the dynamics.
public final class BassGenerator: Generator {
    public let id = "bass"
    /// New patterns go on the end: scenes store the index.
    public static let patterns = ["Hold", "Beats", "Root–fifth", "Walk",
                                  "Eighths", "Octaves", "Off-beat", "Funk", "Boom bap", "Wobble",
                                  "Rolling", "808", "Reggae", "Boogie", "Bossa", "Two-step"]

    /// A one-bar bass figure on the 16th grid: (step, chord tone, octave up?, length in 16ths, level).
    struct Hit { let step: Int; let tone: Int; let up: Bool; let length: Double; let level: Double }

    /// Genre figures (styles, ADR 0020), by pattern index.
    static let figures: [Int: [Hit]] = [
        // Eighths: straight driving 8ths on the root (synthwave, rock).
        4: stride(from: 0, to: 16, by: 2).map { Hit(step: $0, tone: 0, up: false, length: 1.6, level: $0 % 4 == 0 ? 1 : 0.8) },
        // Octaves: disco, root and the octave above in 8ths.
        5: stride(from: 0, to: 16, by: 2).map { Hit(step: $0, tone: 0, up: $0 % 4 == 2, length: 1.4, level: $0 % 4 == 0 ? 1 : 0.85) },
        // Off-beat: house, on every "and".
        6: [2, 6, 10, 14].map { Hit(step: $0, tone: 0, up: false, length: 1.8, level: 0.95) },
        // Funk: syncopated 16ths around the root, octave and fifth.
        7: [Hit(step: 0, tone: 0, up: false, length: 1.5, level: 1), Hit(step: 3, tone: 0, up: false, length: 0.8, level: 0.6),
            Hit(step: 6, tone: 0, up: true, length: 0.8, level: 0.85), Hit(step: 7, tone: 0, up: false, length: 0.8, level: 0.7),
            Hit(step: 10, tone: 2, up: false, length: 1.5, level: 0.85), Hit(step: 12, tone: 0, up: false, length: 0.8, level: 0.75),
            Hit(step: 14, tone: 0, up: true, length: 0.8, level: 0.8), Hit(step: 15, tone: 2, up: false, length: 0.8, level: 0.6)],
        // Boom bap: sparse, with the kick.
        8: [Hit(step: 0, tone: 0, up: false, length: 3, level: 1), Hit(step: 7, tone: 0, up: false, length: 1.5, level: 0.8),
            Hit(step: 10, tone: 2, up: false, length: 2.5, level: 0.85)],
        // Wobble: dubstep, long low roots (a tempo-synced filter LFO on the synth gives the wobble).
        9: [Hit(step: 0, tone: 0, up: false, length: 7.5, level: 1), Hit(step: 8, tone: 0, up: false, length: 5.5, level: 0.95),
            Hit(step: 14, tone: 0, up: true, length: 1.5, level: 0.8)],
        // Rolling: techno and trance, every 16th between the kicks.
        10: (0..<16).filter { $0 % 4 != 0 }.map { Hit(step: $0, tone: 0, up: false, length: 0.8, level: $0 % 4 == 2 ? 0.9 : 0.7) },
        // 808: trap and reggaeton, long low notes that follow the kick.
        11: [Hit(step: 0, tone: 0, up: false, length: 5, level: 1), Hit(step: 7, tone: 0, up: false, length: 2.5, level: 0.85),
             Hit(step: 10, tone: 0, up: false, length: 5.5, level: 0.9)],
        // Reggae: rests on the one, melodic roots and fifths around the drop.
        12: [Hit(step: 2, tone: 0, up: false, length: 3, level: 0.95), Hit(step: 6, tone: 2, up: false, length: 1.5, level: 0.8),
             Hit(step: 8, tone: 0, up: false, length: 2, level: 1), Hit(step: 11, tone: 1, up: false, length: 1.5, level: 0.75),
             Hit(step: 14, tone: 0, up: false, length: 1.5, level: 0.8)],
        // Boogie: blues and rock 'n' roll, up the chord and back in 8ths.
        13: zip(stride(from: 0, to: 16, by: 2), [0, 0, 1, 1, 2, 2, 1, 1]).map { Hit(step: $0, tone: $1, up: false, length: 1.6, level: $0 % 4 == 0 ? 1 : 0.8) },
        // Bossa: root on one, the fifth anticipating three.
        14: [Hit(step: 0, tone: 0, up: false, length: 3, level: 1), Hit(step: 6, tone: 2, up: false, length: 2, level: 0.8),
             Hit(step: 8, tone: 2, up: false, length: 3, level: 0.9), Hit(step: 14, tone: 0, up: false, length: 2, level: 0.8)],
        // Two-step: UK garage, syncopated with an octave pop.
        15: [Hit(step: 0, tone: 0, up: false, length: 2, level: 1), Hit(step: 7, tone: 0, up: false, length: 1, level: 0.8),
             Hit(step: 10, tone: 0, up: false, length: 2.5, level: 0.9), Hit(step: 13, tone: 0, up: true, length: 1, level: 0.75)],
    ]
    public init() {}

    public var params: [ParamSpec] {
        [
            ParamSpec("gen.bass.enabled", kind: .toggle, default: 1,
                      help: "Play the bass line: the root of each chord, low down."),
            ParamSpec("gen.bass.pattern", kind: .choice, default: 2, options: Self.patterns,
                      help: "Hold = one long note per chord. Beats = the root repeated every step. Root–fifth = alternates root and fifth. Walk = climbs root, third, fifth, octave. Genre figures (one bar on the 16th grid, ignore Step): Eighths = driving 8ths; Octaves = disco root and octave; Off-beat = house, on every 'and'; Funk = syncopated 16ths; Boom bap = sparse, with the kick; Wobble = long dubstep roots."),
            ParamSpec("gen.bass.octave", kind: .integer, range: 0...4, default: 2,
                      help: "Register of the bass. 2 is a typical bass guitar range; 1 is deep, 3 sits in the low mids. The voice's range still folds notes into place."),
            ParamSpec("gen.bass.stepBeats", kind: .continuous, range: 0.5...8, default: 2, unit: "beats",
                      help: "Time between bass notes (not used by Hold). 4 = once a bar at 4/4, 1 = every beat. Smaller is busier."),
            ParamSpec("gen.bass.length", kind: .continuous, range: 0.1...1.5, default: 0.9,
                      help: "Note length as a share of the step. Low values give a plucked, staccato bass; above 1 the notes overlap."),
            ParamSpec("gen.bass.intensity", default: 0.6,
                      help: "Base loudness of the bass."),
            ParamSpec("gen.bass.dynamics", default: 0.4,
                      help: "How much traffic volume changes bass loudness. 0 = steady, 1 = quiet network is soft, busy network is loud."),
            ParamSpec("gen.bass.inQuiet", kind: .toggle, default: 1,
                      help: "Play in the quiet mood. Off = the bass drops out when the network is quiet (a breakdown) and comes back with the traffic: the drop. Styles for dance music turn this off."),
            ParamSpec("gen.bass.fills", default: 0.35,
                      help: "Chance of an extra note halfway between steps when traffic is heavy. Scales with traffic, so a quiet network never fills. 0 = no fills."),
        ]
    }

    public func tick(_ ctx: GeneratorContext, rng: inout SeededRandom) -> GeneratorOutput {
        var out = GeneratorOutput()
        let p = ctx.params
        guard p.bool("gen.bass.enabled") else { return out }
        if !p.bool("gen.bass.inQuiet"), ctx.mood == "quiet" { return out }
        let octave = p.int("gen.bass.octave")
        let level = trafficLevel(ctx.totalRate)
        let d = p.value("gen.bass.dynamics")
        let intensity = p.value("gen.bass.intensity") * ((1 - d) + d * (0.35 + 0.65 * level))
        let pattern = p.int("gen.bass.pattern")

        if pattern == 0 {
            if ctx.chordChanged {
                let beats = Double(p.int("harmony.barsPerChord") * ctx.clock.beatsPerBar) * max(p.value("gen.bass.length"), 0.25)
                out.notes.append(NoteIntent(role: "bass", pitch: .chordTone(0, octave: octave), intensity: intensity,
                                            time: ctx.now, beats: beats, essential: true, why: "chord changed → hold root"))
            }
            return out
        }

        if let figure = Self.figures[pattern] {
            // One-bar figures on the 16th grid; "length" scales their note lengths.
            for beat in MusicalClock.crossings(of: 0.25, in: ctx.beats) {
                let i = Int((beat / 0.25).rounded()), step = ((i % 16) + 16) % 16
                for h in figure where h.step == step {
                    out.notes.append(NoteIntent(role: "bass", pitch: .chordTone(h.tone, octave: octave + (h.up ? 1 : 0)),
                                                intensity: intensity * h.level, time: ctx.clock.time(ofBeat: beat),
                                                beats: 0.25 * h.length * max(p.value("gen.bass.length"), 0.1) / 0.9, essential: true,
                                                why: "\(Self.patterns[pattern].lowercased()) figure · 16th \(step + 1)"))
                }
            }
            return out
        }

        let step = p.value("gen.bass.stepBeats")
        let length = step * p.value("gen.bass.length")
        for beat in MusicalClock.crossings(of: step, in: ctx.beats) {
            let i = Int((beat / step).rounded())
            let tone: Int
            switch pattern {
            case 1: tone = 0
            case 2: tone = i % 2 == 0 ? 0 : 2
            default: tone = [0, 1, 2, 3][i % 4] // index 3 = root an octave up (chord wraps)
            }
            out.notes.append(NoteIntent(role: "bass", pitch: .chordTone(tone, octave: octave), intensity: intensity,
                                        time: ctx.clock.time(ofBeat: beat), beats: length, essential: true,
                                        why: "\(Self.patterns[pattern].lowercased()) step \(i % (pattern == 3 ? 4 : 2) + 1) · every \(step.formatted()) beats"))
        }
        // Fills on the half-steps, only when traffic is up.
        for beat in MusicalClock.crossings(of: step / 2, in: ctx.beats)
        where Int((beat / (step / 2)).rounded()) % 2 == 1 && rng.chance(p.value("gen.bass.fills") * level) {
            out.notes.append(NoteIntent(role: "bass", pitch: .chordTone(rng.chance(0.5) ? 0 : 2, octave: octave),
                                        intensity: intensity * 0.8, time: ctx.clock.time(ofBeat: beat),
                                        beats: length / 2, why: String(format: "fill · %.0f%% chance at traffic %@", p.value("gen.bass.fills") * level * 100, formatRate(ctx.totalRate))))
        }
        return out
    }
}

// MARK: - Sub drone

/// The "sub" role: a very low, long note under everything. Either a pedal on the key's tonic
/// (stays put while chords change above it) or following each chord's root.
public final class SubDroneGenerator: Generator {
    public let id = "sub"
    public static let modes = ["Tonic pedal", "Chord root"]
    public init() {}

    private var lastStart: Double = -.infinity

    public var params: [ParamSpec] {
        [
            ParamSpec("gen.sub.enabled", kind: .toggle, default: 1,
                      help: "Play the sub drone: a deep sustained note that you feel more than hear."),
            ParamSpec("gen.sub.mode", kind: .choice, default: 0, options: Self.modes,
                      help: "Tonic pedal = holds the key's home note while chords change above it (tension and release). Chord root = moves with every chord, reinforcing the bass."),
            ParamSpec("gen.sub.octave", kind: .integer, range: 0...3, default: 1,
                      help: "Register. 1 is sub-bass (around 30–60 Hz); small speakers may barely play it. 2 is easier to hear."),
            ParamSpec("gen.sub.holdBars", kind: .integer, range: 1...32, default: 8, unit: "bars",
                      help: "In Tonic pedal mode, how long each drone note lasts before it is struck again. Longer = smoother, fewer re-attacks."),
            ParamSpec("gen.sub.fifth", kind: .toggle, default: 0,
                      help: "Add the fifth above the drone note: a fuller, more 'power chord' bed."),
            ParamSpec("gen.sub.intensity", default: 0.5,
                      help: "Loudness of the drone. A good modulation target: route traffic here and the floor swells as the network gets busy."),
        ]
    }

    public func tick(_ ctx: GeneratorContext, rng: inout SeededRandom) -> GeneratorOutput {
        var out = GeneratorOutput()
        let p = ctx.params
        guard p.bool("gen.sub.enabled") else { return out }
        let octave = p.int("gen.sub.octave")
        let spb = ctx.clock.secondsPerBeat
        let root: Int
        let beats: Double
        if p.int("gen.sub.mode") == 0 {
            let hold = Double(p.int("gen.sub.holdBars") * ctx.clock.beatsPerBar)
            let due = ctx.now - lastStart >= hold * spb - 0.01
            guard ctx.chordChanged && lastStart == -.infinity || (due && !MusicalClock.crossings(of: Double(ctx.clock.beatsPerBar), in: ctx.beats).isEmpty)
            else { return out }
            root = ctx.harmony.note(degree: 0, octave: octave)
            beats = hold * 1.02
        } else {
            guard ctx.chordChanged else { return out }
            root = ctx.harmony.chordTone(0, octave: octave)
            beats = Double(p.int("harmony.barsPerChord") * ctx.clock.beatsPerBar) * 1.02
        }
        lastStart = ctx.now
        let why = p.int("gen.sub.mode") == 0 ? "tonic pedal · re-struck every \(p.int("gen.sub.holdBars")) bars" : "chord changed → root"
        out.notes.append(NoteIntent(role: "sub", pitch: .exact(root), intensity: p.value("gen.sub.intensity"),
                                    time: ctx.now, beats: beats, essential: true, why: why))
        if p.bool("gen.sub.fifth") {
            out.notes.append(NoteIntent(role: "sub", pitch: .exact(root + 7), intensity: p.value("gen.sub.intensity") * 0.8,
                                        time: ctx.now, beats: beats, essential: true, why: why + " fifth"))
        }
        return out
    }
}

/// Total traffic mapped to 0...1 on a log scale (1 kB/s → 0, 10 MB/s → 1).
func trafficLevel(_ bytesPerSecond: Double) -> Double {
    min(max((log10(max(bytesPerSecond, 1)) - 3) / 4, 0), 1)
}
