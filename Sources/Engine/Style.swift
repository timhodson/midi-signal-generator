import Foundation
import Music
import Params

/// A genre style (docs/decisions/0020-styles.md): the choices that make the piece sound like
/// synthwave, house, funk… expressed as ordinary settings, so everything stays tunable afterwards.
/// The network keeps driving it, and the moods map onto the shape of the genre: a quiet network is
/// the breakdown, a busy one the drop.
///
/// Applying a style picks a tempo from its range, a scale from its list and, for every mood, a
/// progression from its pool or from a real song of a matching genre (the Billboard library).
public struct Style: Sendable {
    public enum Value: Sendable {
        case number(Double)
        /// A choice param's option, by name ("Four on the floor").
        case option(String)
    }

    public let name: String
    public let summary: String
    public let bpm: ClosedRange<Double>
    /// `ScaleCatalogue.scales` indices.
    public let scales: [Int]
    /// Progressions as scale degrees, written for the first scale's family (degree 6 = ♭VII in
    /// minor and Mixolydian, vii° in major).
    public let progressions: [[Int]]
    /// Billboard library genres whose songs may lend a progression.
    public let songGenres: [String]
    public let settings: [(String, Value)]

    /// Drum grooves for quiet / calm / busy / focused.
    static func grooves(_ quiet: String, _ calm: String, _ busy: String, _ focused: String) -> [(String, Value)] {
        [("gen.drums.groove.quiet", .option(quiet)), ("gen.drums.groove.calm", .option(calm)),
         ("gen.drums.groove.busy", .option(busy)), ("gen.drums.groove.focused", .option(focused))]
    }

    /// Settings every style shares: steady drums with the full kit, a grid that suits beat music.
    static let base: [(String, Value)] = [
        ("gen.drums.enabled", .number(1)), ("gen.drums.presence", .number(0.8)), ("gen.drums.response", .number(0.35)),
        ("gen.drums.humanise", .number(3)), ("gen.drums.restAfter", .number(16)),
        ("gen.bass.enabled", .number(1)), ("gen.bass.fills", .number(0)), ("gen.pulse.enabled", .number(1)),
        ("quant.time.grid", .option("1/16")), ("quant.time.strength", .number(0.95)),
        ("harmony.changeOnPhrase", .number(0)),
        ("lfo.1.enabled", .number(0)), ("lfo.2.enabled", .number(0)), ("quant.time.swing", .number(0)),
        ("gen.drums.swing", .number(0)), ("gen.pulse.arpOctaves", .number(2)), ("gen.sub.enabled", .number(1)),
    ]

    /// A tempo-synced LFO sending a CC to a voice: the wobble, the pump.
    static func lfo(_ n: Int, role: String, cc: Int, rate: String, shape: String, low: Double, high: Double) -> [(String, Value)] {
        [("lfo.\(n).enabled", .number(1)), ("lfo.\(n).role", .option(role)), ("lfo.\(n).cc", .number(Double(cc))),
         ("lfo.\(n).rate", .option(rate)), ("lfo.\(n).shape", .option(shape)),
         ("lfo.\(n).low", .number(low)), ("lfo.\(n).high", .number(high)), ("lfo.\(n).phase", .number(0))]
    }
}

extension Style {
    public static let all: [Style] = [
        Style(name: "Synthwave",
              summary: "Neon 80s: driving 8th-note bass, 16th arpeggios, gated snare on 2 and 4, minor keys.",
              bpm: 84...104, scales: [1, 2], progressions: [[0, 5, 2, 6], [0, 5, 6, 4], [0, 3, 5, 6], [5, 6, 0, 0], [0, 6, 5, 6]],
              songGenres: ["New wave & synth"],
              settings: base + grooves("Breakdown", "Synthwave", "Synthwave", "Backbeat") + [
                ("harmony.chordSize", .number(3)), ("harmony.barsPerChord", .number(1)),
                ("gen.drums.complexity", .number(0.3)), ("gen.drums.swing", .number(0)),
                ("gen.bass.pattern", .option("Eighths")), ("gen.bass.octave", .number(2)), ("gen.bass.length", .number(0.8)),
                ("gen.bass.inQuiet", .number(0)), ("gen.bass.intensity", .number(0.65)),
                ("gen.pulse.mode", .option("Arp up")), ("gen.pulse.step", .option("1/16")), ("gen.pulse.density", .number(0.9)),
                ("gen.pulse.octave", .number(4)), ("gen.pulse.arpOctaves", .number(2)), ("gen.pulse.noteBeats", .number(0.2)),
                ("gen.pulse.intensity", .number(0.4)),
                ("gen.drone.octave", .number(3)), ("gen.drone.intensity", .number(0.35)), ("gen.sub.mode", .option("Chord root")),
              ]),
        Style(name: "House",
              summary: "Four on the floor at 120-something, off-beat bass and chord stabs, seventh chords, a breakdown when it's quiet.",
              bpm: 120...126, scales: [1, 2], progressions: [[0, 0, 3, 3], [0, 6], [0, 5, 3, 6], [0, 3], [3, 4, 0, 0]],
              songGenres: ["Electronic & dance", "Disco"],
              settings: base + grooves("Breakdown", "Four on the floor", "Four on the floor", "Four on the floor") + [
                ("harmony.chordSize", .number(4)), ("harmony.barsPerChord", .number(2)),
                ("gen.drums.complexity", .number(0.35)), ("gen.drums.swing", .number(0.05)),
                ("gen.bass.pattern", .option("Off-beat")), ("gen.bass.octave", .number(2)), ("gen.bass.length", .number(0.7)),
                ("gen.bass.inQuiet", .number(0)), ("gen.bass.intensity", .number(0.7)),
                ("gen.pulse.mode", .option("Off-beat stabs")), ("gen.pulse.step", .option("1/8")), ("gen.pulse.density", .number(0.85)),
                ("gen.pulse.octave", .number(4)), ("gen.pulse.noteBeats", .number(0.3)), ("gen.pulse.intensity", .number(0.45)),
                ("gen.drone.intensity", .number(0.25)), ("gen.sub.mode", .option("Chord root")),
              ] + lfo(2, role: "pad", cc: 11, rate: "1/4", shape: "Pump", low: 0.35, high: 1)),
        Style(name: "Disco",
              summary: "Four on the floor with open hats on the off-beats, octave-jumping bass, lush seventh chords.",
              bpm: 112...122, scales: [1, 0, 2], progressions: [[0, 3], [0, 3, 0, 4], [1, 4], [0, 5, 1, 4], [0, 6, 5, 6]],
              songGenres: ["Disco", "Funk", "Soul & R&B"],
              settings: base + grooves("Breakdown", "Disco", "Disco", "Disco") + [
                ("harmony.chordSize", .number(4)), ("harmony.barsPerChord", .number(2)),
                ("gen.drums.complexity", .number(0.4)), ("gen.drums.swing", .number(0.04)),
                ("gen.bass.pattern", .option("Octaves")), ("gen.bass.octave", .number(2)), ("gen.bass.length", .number(0.6)),
                ("gen.bass.inQuiet", .number(0)), ("gen.bass.intensity", .number(0.7)),
                ("gen.pulse.mode", .option("Off-beat stabs")), ("gen.pulse.step", .option("1/8")), ("gen.pulse.density", .number(0.7)),
                ("gen.pulse.octave", .number(4)), ("gen.pulse.noteBeats", .number(0.25)), ("gen.pulse.intensity", .number(0.4)),
                ("gen.drone.intensity", .number(0.4)), ("gen.drone.octave", .number(4)), ("gen.sub.mode", .option("Chord root")),
              ]),
        Style(name: "Funk",
              summary: "Syncopated 16ths and ghost notes, a busy bass line, one- and two-chord vamps in Dorian and Mixolydian.",
              bpm: 96...112, scales: [2, 5], progressions: [[0, 0, 3, 3], [0, 3], [0, 0, 0, 3], [0, 6, 0, 3], [0]],
              songGenres: ["Funk", "Soul & R&B"],
              settings: base + grooves("Breakdown", "Funk", "Funk", "Funk") + [
                ("harmony.chordSize", .number(4)), ("harmony.barsPerChord", .number(2)),
                ("gen.drums.complexity", .number(0.5)), ("gen.drums.swing", .number(0.1)), ("gen.drums.humanise", .number(5)),
                ("gen.bass.pattern", .option("Funk")), ("gen.bass.octave", .number(2)), ("gen.bass.length", .number(0.7)),
                ("gen.bass.inQuiet", .number(1)), ("gen.bass.intensity", .number(0.75)),
                ("gen.pulse.mode", .option("Off-beat stabs")), ("gen.pulse.step", .option("1/16")), ("gen.pulse.density", .number(0.75)),
                ("gen.pulse.octave", .number(4)), ("gen.pulse.noteBeats", .number(0.12)), ("gen.pulse.intensity", .number(0.45)),
                ("gen.drone.intensity", .number(0.2)), ("gen.sub.enabled", .number(0)),
              ]),
        Style(name: "Hip hop",
              summary: "Boom bap: a swung kick and snare at 90 bpm, a sparse sub-heavy bass, minor-key loops.",
              bpm: 84...94, scales: [1, 2], progressions: [[0, 5], [0, 3], [0, 5, 3, 4], [0, 0, 5, 5], [3, 2, 0, 0]],
              songGenres: ["Hip hop", "Soul & R&B", "Funk"],
              settings: base + grooves("Breakdown", "Boom bap", "Boom bap", "Boom bap") + [
                ("harmony.chordSize", .number(4)), ("harmony.barsPerChord", .number(2)),
                ("gen.drums.complexity", .number(0.35)), ("gen.drums.swing", .number(0.22)), ("gen.drums.humanise", .number(6)),
                ("gen.bass.pattern", .option("Boom bap")), ("gen.bass.octave", .number(1)), ("gen.bass.length", .number(0.9)),
                ("gen.bass.inQuiet", .number(1)), ("gen.bass.intensity", .number(0.75)),
                ("gen.pulse.mode", .option("Sparkle")), ("gen.pulse.step", .option("1/8")), ("gen.pulse.density", .number(0.06)),
                ("gen.pulse.octave", .number(5)), ("gen.pulse.span", .number(5)), ("gen.pulse.noteBeats", .number(0.5)),
                ("quant.time.swing", .number(0.2)),
                ("gen.drone.intensity", .number(0.3)), ("gen.sub.enabled", .number(0)),
              ]),
        Style(name: "Dubstep",
              summary: "Half-time at 140: the snare on beat 3, long low roots to wobble, dark minor and Phrygian keys, a drop when busy.",
              bpm: 138...142, scales: [1, 3], progressions: [[0, 0, 5, 5], [0, 3], [0, 1], [0, 5, 6, 6], [0, 0, 0, 5]],
              songGenres: [],
              settings: base + grooves("Breakdown", "Halftime", "Dubstep", "Dubstep") + [
                ("harmony.chordSize", .number(3)), ("harmony.barsPerChord", .number(2)),
                ("gen.drums.complexity", .number(0.4)), ("gen.drums.swing", .number(0.03)),
                ("gen.bass.pattern", .option("Wobble")), ("gen.bass.octave", .number(1)), ("gen.bass.length", .number(0.95)),
                ("gen.bass.inQuiet", .number(0)), ("gen.bass.intensity", .number(0.85)),
                ("gen.pulse.mode", .option("Sparkle")), ("gen.pulse.step", .option("1/16")), ("gen.pulse.density", .number(0.05)),
                ("gen.pulse.octave", .number(5)), ("gen.pulse.noteBeats", .number(0.15)),
                ("gen.drone.intensity", .number(0.3)), ("gen.sub.mode", .option("Tonic pedal")),
              ] + lfo(1, role: "bass", cc: 74, rate: "1/8", shape: "Sine", low: 0.1, high: 0.9)),
        Style(name: "Rock",
              summary: "Backbeat drums and driving 8th-note bass, power-chord pulses, I–IV–V and Mixolydian ♭VII.",
              bpm: 100...136, scales: [5, 0], progressions: [[0, 6, 3, 0], [0, 3, 4, 3], [0, 3, 0, 4], [0, 4, 5, 3], [0, 6, 3, 3]],
              songGenres: ["Rock", "Rock 'n' roll", "Blues"],
              settings: base + grooves("Breakdown", "Backbeat", "Backbeat", "Backbeat") + [
                ("harmony.chordSize", .number(3)), ("harmony.barsPerChord", .number(1)),
                ("gen.drums.complexity", .number(0.4)), ("gen.drums.swing", .number(0)), ("gen.drums.humanise", .number(6)),
                ("gen.bass.pattern", .option("Eighths")), ("gen.bass.octave", .number(2)), ("gen.bass.length", .number(0.85)),
                ("gen.bass.inQuiet", .number(1)), ("gen.bass.intensity", .number(0.7)),
                ("gen.pulse.mode", .option("Chord pulse")), ("gen.pulse.step", .option("1/8")), ("gen.pulse.density", .number(0.6)),
                ("gen.pulse.octave", .number(3)), ("gen.pulse.noteBeats", .number(0.4)), ("gen.pulse.intensity", .number(0.35)),
                ("gen.drone.intensity", .number(0.25)), ("gen.sub.enabled", .number(0)),
              ]),
        Style(name: "Pop",
              summary: "Bright major keys and the classic four-chord loops, backbeat drums, root–fifth bass and an 8th-note arp.",
              bpm: 96...118, scales: [0], progressions: [[0, 4, 5, 3], [5, 3, 0, 4], [0, 5, 3, 4], [3, 0, 4, 5], [0, 3, 5, 4]],
              songGenres: ["Pop"],
              settings: base + grooves("Breakdown", "Backbeat", "Backbeat", "Disco") + [
                ("harmony.chordSize", .number(3)), ("harmony.barsPerChord", .number(1)),
                ("gen.drums.complexity", .number(0.3)), ("gen.drums.swing", .number(0)),
                ("gen.bass.pattern", .option("Root–fifth")), ("gen.bass.stepBeats", .number(1)), ("gen.bass.octave", .number(2)),
                ("gen.bass.length", .number(0.8)), ("gen.bass.inQuiet", .number(1)), ("gen.bass.intensity", .number(0.65)),
                ("gen.pulse.mode", .option("Arp up-down")), ("gen.pulse.step", .option("1/8")), ("gen.pulse.density", .number(0.8)),
                ("gen.pulse.octave", .number(4)), ("gen.pulse.arpOctaves", .number(2)), ("gen.pulse.noteBeats", .number(0.35)),
                ("gen.pulse.intensity", .number(0.4)),
                ("gen.drone.intensity", .number(0.3)), ("gen.sub.enabled", .number(0)),
              ]),

        // MARK: Second pass
        Style(name: "Techno",
              summary: "Relentless four on the floor at 130, rolling 16th bass, one-chord minor grooves, a pumping pad.",
              bpm: 124...134, scales: [1, 3], progressions: [[0], [0, 0, 0, 6], [0, 3], [0, 0, 5, 5]],
              songGenres: [],
              settings: base + grooves("Breakdown", "Techno", "Techno", "Techno") + [
                ("harmony.chordSize", .number(3)), ("harmony.barsPerChord", .number(4)),
                ("gen.drums.complexity", .number(0.45)),
                ("gen.bass.pattern", .option("Rolling")), ("gen.bass.octave", .number(1)), ("gen.bass.length", .number(0.6)),
                ("gen.bass.inQuiet", .number(0)), ("gen.bass.intensity", .number(0.7)),
                ("gen.pulse.mode", .option("Off-beat stabs")), ("gen.pulse.step", .option("1/16")), ("gen.pulse.density", .number(0.4)),
                ("gen.pulse.octave", .number(4)), ("gen.pulse.noteBeats", .number(0.12)), ("gen.pulse.intensity", .number(0.4)),
                ("gen.drone.intensity", .number(0.25)), ("gen.sub.mode", .option("Tonic pedal")),
              ] + lfo(2, role: "pad", cc: 11, rate: "1/4", shape: "Pump", low: 0.3, high: 1)),
        Style(name: "Trance",
              summary: "138 bpm euphoria: four on the floor, rolling bass, a three-octave 16th arpeggio, big minor progressions.",
              bpm: 134...140, scales: [1], progressions: [[0, 5, 2, 6], [5, 6, 0, 0], [0, 6, 5, 6], [0, 3, 5, 6], [5, 3, 0, 6]],
              songGenres: [],
              settings: base + grooves("Breakdown", "Four on the floor", "Four on the floor", "Techno") + [
                ("harmony.chordSize", .number(3)), ("harmony.barsPerChord", .number(2)),
                ("gen.drums.complexity", .number(0.35)),
                ("gen.bass.pattern", .option("Rolling")), ("gen.bass.octave", .number(1)), ("gen.bass.length", .number(0.6)),
                ("gen.bass.inQuiet", .number(0)), ("gen.bass.intensity", .number(0.7)),
                ("gen.pulse.mode", .option("Arp up")), ("gen.pulse.step", .option("1/16")), ("gen.pulse.density", .number(1)),
                ("gen.pulse.octave", .number(4)), ("gen.pulse.arpOctaves", .number(3)), ("gen.pulse.noteBeats", .number(0.18)),
                ("gen.pulse.intensity", .number(0.4)),
                ("gen.drone.intensity", .number(0.4)), ("gen.drone.octave", .number(4)), ("gen.sub.mode", .option("Chord root")),
              ] + lfo(2, role: "pad", cc: 11, rate: "1/4", shape: "Pump", low: 0.4, high: 1)),
        Style(name: "Drum & bass",
              summary: "Two-step breaks at 174 over long, deep bass notes and wide minor pads.",
              bpm: 170...176, scales: [1, 2], progressions: [[0, 5], [0, 6, 5, 6], [0, 3], [0, 0, 5, 6]],
              songGenres: [],
              settings: base + grooves("Breakdown", "Drum & bass", "Drum & bass", "Drum & bass") + [
                ("harmony.chordSize", .number(4)), ("harmony.barsPerChord", .number(4)),
                ("gen.drums.complexity", .number(0.45)), ("gen.drums.humanise", .number(2)),
                ("gen.bass.pattern", .option("Hold")), ("gen.bass.octave", .number(1)), ("gen.bass.length", .number(0.9)),
                ("gen.bass.inQuiet", .number(0)), ("gen.bass.intensity", .number(0.8)),
                ("gen.pulse.mode", .option("Sparkle")), ("gen.pulse.step", .option("1/8")), ("gen.pulse.density", .number(0.08)),
                ("gen.pulse.octave", .number(5)), ("gen.pulse.noteBeats", .number(1)),
                ("gen.drone.intensity", .number(0.4)), ("gen.drone.spread", .number(2)), ("gen.sub.mode", .option("Chord root")),
              ] + lfo(1, role: "bass", cc: 74, rate: "1 bar", shape: "Triangle", low: 0.2, high: 0.7)),
        Style(name: "Lo-fi",
              summary: "Dusty, lazy and warm: heavily swung boom bap at 80, jazzy seventh chords, a soft bass and sparse keys.",
              bpm: 72...86, scales: [0, 2], progressions: [[1, 4, 0, 5], [3, 2, 1, 0], [1, 4, 0, 0], [0, 5, 1, 4], [3, 4, 2, 5]],
              songGenres: ["Jazz", "Soul & R&B"],
              settings: base + grooves("Shaker", "Boom bap", "Boom bap", "Brushes") + [
                ("harmony.chordSize", .number(4)), ("harmony.barsPerChord", .number(2)),
                ("gen.drums.presence", .number(0.65)), ("gen.drums.complexity", .number(0.3)), ("gen.drums.swing", .number(0.28)),
                ("gen.drums.humanise", .number(12)), ("gen.drums.intensity", .number(0.45)),
                ("gen.bass.pattern", .option("Boom bap")), ("gen.bass.octave", .number(2)), ("gen.bass.length", .number(0.8)),
                ("gen.bass.inQuiet", .number(1)), ("gen.bass.intensity", .number(0.55)),
                ("gen.pulse.mode", .option("Sparkle")), ("gen.pulse.step", .option("1/8")), ("gen.pulse.density", .number(0.1)),
                ("gen.pulse.octave", .number(5)), ("gen.pulse.span", .number(4)), ("gen.pulse.noteBeats", .number(0.6)),
                ("quant.time.swing", .number(0.25)),
                ("gen.drone.intensity", .number(0.35)), ("gen.sub.enabled", .number(0)),
              ]),
        Style(name: "Trap",
              summary: "Half-time at 140 with rolling hi-hats, long 808 bass, dark minor and harmonic-minor loops.",
              bpm: 130...150, scales: [1, 7, 3], progressions: [[0, 5], [0, 0, 5, 6], [0, 1], [0, 3], [0, 5, 3, 4]],
              songGenres: ["Hip hop"],
              settings: base + grooves("Breakdown", "Trap", "Trap", "Trap") + [
                ("harmony.chordSize", .number(3)), ("harmony.barsPerChord", .number(2)),
                ("gen.drums.complexity", .number(0.45)), ("gen.drums.humanise", .number(1)),
                ("gen.bass.pattern", .option("808")), ("gen.bass.octave", .number(1)), ("gen.bass.length", .number(0.95)),
                ("gen.bass.inQuiet", .number(0)), ("gen.bass.intensity", .number(0.85)),
                ("gen.pulse.mode", .option("Arp up")), ("gen.pulse.step", .option("1/8T")), ("gen.pulse.density", .number(0.35)),
                ("gen.pulse.octave", .number(5)), ("gen.pulse.arpOctaves", .number(1)), ("gen.pulse.noteBeats", .number(0.3)),
                ("gen.drone.intensity", .number(0.3)), ("gen.sub.enabled", .number(0)),
              ]),
        Style(name: "R&B",
              summary: "A slow jam: laid-back drums, rich sevenths and ninths, a smooth bass and runs on the keys.",
              bpm: 64...80, scales: [0, 2, 1], progressions: [[0, 3], [3, 4, 2, 5], [1, 4, 0, 0], [0, 5, 3, 4], [5, 3, 0, 4]],
              songGenres: ["Soul & R&B"],
              settings: base + grooves("Shaker", "Boom bap", "Boom bap", "Heartbeat") + [
                ("harmony.chordSize", .number(5)), ("harmony.barsPerChord", .number(2)),
                ("gen.drums.presence", .number(0.7)), ("gen.drums.complexity", .number(0.3)), ("gen.drums.swing", .number(0.15)),
                ("gen.drums.humanise", .number(8)),
                ("gen.bass.pattern", .option("Boom bap")), ("gen.bass.octave", .number(2)), ("gen.bass.length", .number(0.95)),
                ("gen.bass.inQuiet", .number(1)), ("gen.bass.intensity", .number(0.6)),
                ("gen.pulse.mode", .option("Arp up-down")), ("gen.pulse.step", .option("1/16")), ("gen.pulse.density", .number(0.25)),
                ("gen.pulse.octave", .number(5)), ("gen.pulse.noteBeats", .number(0.2)), ("gen.pulse.intensity", .number(0.35)),
                ("gen.drone.intensity", .number(0.4)), ("gen.sub.enabled", .number(0)),
              ]),
        Style(name: "Reggae & dub",
              summary: "One drop: the kick and rim on beat three, off-beat skanks, a melodic bass that rests on the one.",
              bpm: 66...84, scales: [0, 1], progressions: [[0, 3], [0, 4], [0, 3, 4, 3], [0, 5, 3, 4], [0, 0, 6, 6]],
              songGenres: ["Reggae & Caribbean", "Soul & R&B"],
              settings: base + grooves("One drop", "One drop", "One drop", "One drop") + [
                ("harmony.chordSize", .number(3)), ("harmony.barsPerChord", .number(2)),
                ("gen.drums.presence", .number(0.6)), ("gen.drums.complexity", .number(0.35)), ("gen.drums.swing", .number(0.12)),
                ("gen.bass.pattern", .option("Reggae")), ("gen.bass.octave", .number(1)), ("gen.bass.length", .number(0.9)),
                ("gen.bass.inQuiet", .number(1)), ("gen.bass.intensity", .number(0.8)),
                ("gen.pulse.mode", .option("Off-beat stabs")), ("gen.pulse.step", .option("1/8")), ("gen.pulse.density", .number(0.95)),
                ("gen.pulse.octave", .number(4)), ("gen.pulse.noteBeats", .number(0.2)), ("gen.pulse.intensity", .number(0.4)),
                ("mix.delay.return", .number(0.6)), ("mix.delay.feedback", .number(0.55)),
                ("gen.drone.intensity", .number(0.2)), ("gen.sub.enabled", .number(0)),
              ]),
        Style(name: "Jazz",
              summary: "Swing: a ride cymbal pattern, a walking bass, ii–V–I changes with seventh chords.",
              bpm: 100...160, scales: [0, 2], progressions: [[1, 4, 0, 0], [0, 5, 1, 4], [2, 5, 1, 4], [1, 4, 0, 5], [3, 6, 2, 5]],
              songGenres: ["Jazz"],
              settings: base + grooves("Brushes", "Jazz swing", "Jazz swing", "Jazz swing") + [
                ("harmony.chordSize", .number(4)), ("harmony.barsPerChord", .number(1)),
                ("gen.drums.presence", .number(0.6)), ("gen.drums.complexity", .number(0.35)), ("gen.drums.swing", .number(0.33)),
                ("gen.drums.humanise", .number(9)), ("gen.drums.intensity", .number(0.45)),
                ("gen.bass.pattern", .option("Walk")), ("gen.bass.stepBeats", .number(1)), ("gen.bass.octave", .number(2)),
                ("gen.bass.length", .number(0.9)), ("gen.bass.inQuiet", .number(1)), ("gen.bass.intensity", .number(0.6)),
                ("gen.pulse.mode", .option("Sparkle")), ("gen.pulse.step", .option("1/8")), ("gen.pulse.density", .number(0.12)),
                ("gen.pulse.octave", .number(4)), ("gen.pulse.span", .number(7)), ("gen.pulse.noteBeats", .number(0.5)),
                ("quant.time.swing", .number(0.33)),
                ("gen.drone.intensity", .number(0.3)), ("gen.sub.enabled", .number(0)),
              ]),
        Style(name: "Blues",
              summary: "A twelve-bar shuffle in dominant sevenths, a boogie bass and a lazy backbeat.",
              bpm: 70...110, scales: [5], progressions: [[0, 0, 0, 0, 3, 3, 0, 0, 4, 3, 0, 4], [0, 3, 0, 0, 3, 3, 0, 0, 4, 3, 0, 4]],
              songGenres: ["Blues"],
              settings: base + grooves("Shuffle", "Shuffle", "Shuffle", "Shuffle") + [
                ("harmony.chordSize", .number(4)), ("harmony.barsPerChord", .number(1)),
                ("gen.drums.presence", .number(0.7)), ("gen.drums.complexity", .number(0.3)), ("gen.drums.swing", .number(0.33)),
                ("gen.drums.humanise", .number(8)),
                ("gen.bass.pattern", .option("Boogie")), ("gen.bass.octave", .number(2)), ("gen.bass.length", .number(0.85)),
                ("gen.bass.inQuiet", .number(1)), ("gen.bass.intensity", .number(0.65)),
                ("gen.pulse.mode", .option("Sparkle")), ("gen.pulse.step", .option("1/8")), ("gen.pulse.density", .number(0.1)),
                ("gen.pulse.octave", .number(5)), ("gen.pulse.noteBeats", .number(0.4)),
                ("quant.time.swing", .number(0.33)),
                ("gen.drone.intensity", .number(0.25)), ("gen.sub.enabled", .number(0)),
              ]),
        Style(name: "Country",
              summary: "A train beat on the snare, root–fifth bass on one and three, picked arpeggios, I–IV–V.",
              bpm: 96...128, scales: [0], progressions: [[0, 3, 4, 0], [0, 3, 0, 4], [0, 0, 3, 4], [0, 4, 5, 3]],
              songGenres: ["Country", "Folk"],
              settings: base + grooves("Shaker", "Train", "Train", "Backbeat") + [
                ("harmony.chordSize", .number(3)), ("harmony.barsPerChord", .number(1)),
                ("gen.drums.presence", .number(0.7)), ("gen.drums.complexity", .number(0.3)),
                ("gen.bass.pattern", .option("Root–fifth")), ("gen.bass.stepBeats", .number(2)), ("gen.bass.octave", .number(2)),
                ("gen.bass.length", .number(0.6)), ("gen.bass.inQuiet", .number(1)), ("gen.bass.intensity", .number(0.6)),
                ("gen.pulse.mode", .option("Arp up-down")), ("gen.pulse.step", .option("1/8")), ("gen.pulse.density", .number(0.75)),
                ("gen.pulse.octave", .number(4)), ("gen.pulse.arpOctaves", .number(1)), ("gen.pulse.noteBeats", .number(0.3)),
                ("gen.drone.intensity", .number(0.2)), ("gen.sub.enabled", .number(0)),
              ]),
        Style(name: "Bossa nova",
              summary: "Brazilian: a clave on the rim, a gentle bass pulse on the root and fifth, syncopated seventh chords.",
              bpm: 120...140, scales: [0, 2], progressions: [[0, 0, 1, 4], [1, 4, 0, 0], [0, 5, 1, 4], [0, 3, 1, 4]],
              songGenres: ["Jazz", "Latin"],
              settings: base + grooves("Bossa nova", "Bossa nova", "Bossa nova", "Bossa nova") + [
                ("harmony.chordSize", .number(4)), ("harmony.barsPerChord", .number(2)),
                ("gen.drums.presence", .number(0.5)), ("gen.drums.complexity", .number(0.3)), ("gen.drums.intensity", .number(0.4)),
                ("gen.bass.pattern", .option("Bossa")), ("gen.bass.octave", .number(2)), ("gen.bass.length", .number(0.9)),
                ("gen.bass.inQuiet", .number(1)), ("gen.bass.intensity", .number(0.55)),
                ("gen.pulse.mode", .option("Chord pulse")), ("gen.pulse.step", .option("1/8")), ("gen.pulse.density", .number(0.45)),
                ("gen.pulse.octave", .number(4)), ("gen.pulse.noteBeats", .number(0.35)), ("gen.pulse.intensity", .number(0.35)),
                ("gen.drone.intensity", .number(0.2)), ("gen.sub.enabled", .number(0)),
              ]),
        Style(name: "Reggaeton",
              summary: "The dembow riddim at 95, 808 bass and off-beat chord stabs over a minor four-chord loop.",
              bpm: 88...100, scales: [1], progressions: [[0, 5, 2, 6], [0, 5, 6, 6], [0, 3, 6, 2], [5, 6, 0, 0]],
              songGenres: ["Latin"],
              settings: base + grooves("Breakdown", "Dembow", "Dembow", "Dembow") + [
                ("harmony.chordSize", .number(3)), ("harmony.barsPerChord", .number(1)),
                ("gen.drums.complexity", .number(0.35)),
                ("gen.bass.pattern", .option("808")), ("gen.bass.octave", .number(1)), ("gen.bass.length", .number(0.9)),
                ("gen.bass.inQuiet", .number(0)), ("gen.bass.intensity", .number(0.8)),
                ("gen.pulse.mode", .option("Off-beat stabs")), ("gen.pulse.step", .option("1/8")), ("gen.pulse.density", .number(0.6)),
                ("gen.pulse.octave", .number(4)), ("gen.pulse.noteBeats", .number(0.2)), ("gen.pulse.intensity", .number(0.4)),
                ("gen.drone.intensity", .number(0.25)), ("gen.sub.enabled", .number(0)),
              ]),
        Style(name: "Afrobeat",
              summary: "Fela-style: interlocking 16th hats and percussion, a syncopated bass, guitar-like stabs on a one-chord vamp.",
              bpm: 100...116, scales: [2, 5], progressions: [[0], [0, 3], [0, 0, 6, 6], [0, 0, 0, 3]],
              songGenres: ["Funk", "Soul & R&B"],
              settings: base + grooves("Shaker", "Afrobeat", "Afrobeat", "Afrobeat") + [
                ("harmony.chordSize", .number(4)), ("harmony.barsPerChord", .number(4)),
                ("gen.drums.complexity", .number(0.5)), ("gen.drums.swing", .number(0.06)), ("gen.drums.humanise", .number(6)),
                ("gen.bass.pattern", .option("Funk")), ("gen.bass.octave", .number(2)), ("gen.bass.length", .number(0.7)),
                ("gen.bass.inQuiet", .number(1)), ("gen.bass.intensity", .number(0.7)),
                ("gen.pulse.mode", .option("Off-beat stabs")), ("gen.pulse.step", .option("1/16")), ("gen.pulse.density", .number(0.6)),
                ("gen.pulse.octave", .number(4)), ("gen.pulse.noteBeats", .number(0.1)), ("gen.pulse.intensity", .number(0.4)),
                ("gen.drone.intensity", .number(0.2)), ("gen.sub.enabled", .number(0)),
              ]),
        Style(name: "UK garage",
              summary: "Two-step at 132: a skippy shuffled kick and snare, a bouncing bass and organ-like chord stabs.",
              bpm: 128...136, scales: [1, 2], progressions: [[0, 5], [0, 3, 6, 5], [0, 6], [0, 0, 3, 6]],
              songGenres: ["Electronic & dance", "Soul & R&B"],
              settings: base + grooves("Breakdown", "Two-step", "Two-step", "Two-step") + [
                ("harmony.chordSize", .number(4)), ("harmony.barsPerChord", .number(2)),
                ("gen.drums.complexity", .number(0.4)), ("gen.drums.swing", .number(0.3)),
                ("gen.bass.pattern", .option("Two-step")), ("gen.bass.octave", .number(1)), ("gen.bass.length", .number(0.8)),
                ("gen.bass.inQuiet", .number(0)), ("gen.bass.intensity", .number(0.75)),
                ("gen.pulse.mode", .option("Off-beat stabs")), ("gen.pulse.step", .option("1/8")), ("gen.pulse.density", .number(0.7)),
                ("gen.pulse.octave", .number(4)), ("gen.pulse.noteBeats", .number(0.25)), ("gen.pulse.intensity", .number(0.4)),
                ("quant.time.swing", .number(0.2)),
                ("gen.drone.intensity", .number(0.25)), ("gen.sub.mode", .option("Chord root")),
              ]),
        Style(name: "Synth-pop",
              summary: "80s synth-pop: a motorik pulse, 8th-note bass, bright arpeggios, pop progressions in major and minor.",
              bpm: 110...128, scales: [0, 1], progressions: [[0, 4, 5, 3], [5, 3, 0, 4], [0, 5, 3, 4], [0, 3, 4, 4]],
              songGenres: ["New wave & synth", "Pop"],
              settings: base + grooves("Breakdown", "Synthwave", "Backbeat", "Disco") + [
                ("harmony.chordSize", .number(3)), ("harmony.barsPerChord", .number(1)),
                ("gen.drums.complexity", .number(0.3)),
                ("gen.bass.pattern", .option("Eighths")), ("gen.bass.octave", .number(2)), ("gen.bass.length", .number(0.7)),
                ("gen.bass.inQuiet", .number(0)), ("gen.bass.intensity", .number(0.65)),
                ("gen.pulse.mode", .option("Arp up")), ("gen.pulse.step", .option("1/16")), ("gen.pulse.density", .number(0.85)),
                ("gen.pulse.octave", .number(4)), ("gen.pulse.arpOctaves", .number(2)), ("gen.pulse.noteBeats", .number(0.18)),
                ("gen.pulse.intensity", .number(0.4)),
                ("gen.drone.intensity", .number(0.3)), ("gen.sub.enabled", .number(0)),
              ]),
    ]

    /// Options for the `style.name` choice param: index 0 = no style (the scene as written).
    public static let choices = ["None"] + all.map(\.name)

    static let params: [ParamSpec] = [
        ParamSpec("style.name", kind: .choice, default: 0, options: choices, modulatable: false,
                  help: "A genre style: tempo, scales, chord progressions (some from real songs of that genre), drum grooves, bass figures and arpeggios that make the piece synthwave, house, funk… Applied at the next chord change; every setting stays tunable afterwards. Quiet network = the breakdown, busy = the drop. None = leave the scene as it is."),
    ]
}

// MARK: - Applying

extension Style {
    /// Apply to the params and the conductor's progressions. Returns what changed, in words.
    func apply(_ p: ParamStore, _ conductor: Conductor, rng: inout SeededRandom) -> [String] {
        var changes: [String] = []
        for (id, value) in settings {
            guard let spec = p.specs[id] else { continue }
            let v: Double
            switch value {
            case .number(let n): v = n
            case .option(let name):
                guard let i = spec.options.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == name }) else { continue }
                v = Double(i)
            }
            try? p.set(id, v)
        }
        let bpm = (bpm.lowerBound + rng.unit() * (bpm.upperBound - bpm.lowerBound)).rounded()
        try? p.set("clock.bpm", bpm)
        changes.append("tempo \(Int(bpm)) bpm")
        let scale = scales[Int(rng.next() % UInt64(scales.count))]
        try? p.set("harmony.scale", Double(scale))
        changes.append("scale \(ScaleCatalogue.names[scale])")
        changes += pickProgressions(p, conductor, scale: scale, rng: &rng)
        return changes
    }

    /// A progression for every mood: mostly from the style's pool, sometimes a section of a real
    /// song in one of its genres that fits the chosen scale without bending a chord.
    func pickProgressions(_ p: ParamStore, _ conductor: Conductor, scale: Int, rng: inout SeededRandom) -> [String] {
        let harmony = conductor.harmony(p)
        let candidates = songSections(scale: scale)
        var out: [String] = []
        var used: Set<[Int]> = []
        // Progressions picked by hand stay.
        for mood in Conductor.Mood.allCases where !conductor.pinned.contains(mood) {
            var pick: [Int]?
            var from = ""
            if !candidates.isEmpty, rng.chance(0.5) {
                let c = candidates[Int(rng.next() % UInt64(candidates.count))]
                if !used.contains(c.degrees) { pick = c.degrees; from = " (\(c.section) of \(c.song.title), \(c.song.artist))" }
            }
            if pick == nil {
                // Progressions are written for the main scale: skip any that land on a diminished
                // chord in the one picked (♭VII in Mixolydian is vii° in major).
                let playable = progressions.filter { !$0.contains { Variation.isDiminished($0, harmony) } }
                let all = playable.isEmpty ? progressions : playable
                let pool = all.filter { !used.contains($0) }
                let source = pool.isEmpty ? all : pool
                pick = source[Int(rng.next() % UInt64(source.count))]
            }
            guard let degrees = pick else { continue }
            used.insert(degrees)
            conductor.progressions[mood] = degrees
            out.append("\(mood.rawValue): " + degrees.map { harmony.chordName(degree: $0) }.joined(separator: " ") + from)
        }
        return out
    }

    struct SongSection { let song: SongLibrary.Song; let section: String; let degrees: [Int] }

    /// Verses and choruses of songs in the style's genres that fit `scale` exactly enough (no bent
    /// chords), trimmed to at most 8 chords.
    func songSections(scale: Int) -> [SongSection] {
        guard !songGenres.isEmpty else { return [] }
        let harmony = HarmonyContext(root: 0, scale: ScaleCatalogue.scales[scale])
        var out: [SongSection] = []
        for song in SongLibrary.billboard.songs where song.genres.contains(where: songGenres.contains) {
            for section in song.sections where ["verse", "chorus"].contains(section.name) && section.chords.count >= 2 {
                let chords = Array(section.chords.prefix(8))
                let fit = SongLibrary.fit(chords, into: harmony)
                guard fit.bentCount == 0, fit.exactCount >= chords.count - 1 else { continue }
                out.append(SongSection(song: song, section: section.name, degrees: fit.degrees))
            }
        }
        return out
    }
}

// MARK: - Sound suggestions

extension Style {
    /// Words to look for in hosted synths' preset names, per role, most telling first. Matched
    /// case-insensitively; the role's general words come after the style's own.
    public static let soundHints: [String: [String: [String]]] = [
        "Synthwave": ["pad": ["80s", "juno", "brass", "synthwave", "retro"], "bass": ["saw", "synth bass", "analog"], "pulse": ["arp", "pluck", "seq"], "lead": ["lead", "saw"]],
        "House": ["pad": ["organ", "chord", "warm"], "bass": ["deep", "house", "sub"], "pulse": ["stab", "chord", "piano", "organ"]],
        "Disco": ["pad": ["string", "orchestra", "brass"], "bass": ["slap", "funk", "finger"], "pulse": ["clav", "string", "stab", "guitar"]],
        "Funk": ["pad": ["organ", "rhodes"], "bass": ["slap", "funk", "finger", "synth bass"], "pulse": ["clav", "wah", "funk", "guitar"]],
        "Hip hop": ["pad": ["rhodes", "ep", "soul"], "bass": ["sub", "808", "deep"], "pulse": ["piano", "rhodes", "keys", "bell"]],
        "Dubstep": ["pad": ["dark", "atmos"], "bass": ["wobble", "growl", "dub", "reese"], "pulse": ["pluck", "bell"]],
        "Rock": ["pad": ["organ", "string"], "bass": ["pick", "rock", "bass"], "pulse": ["guitar", "power", "distort", "overdrive"]],
        "Pop": ["pad": ["warm", "string", "bright"], "bass": ["synth bass", "pop"], "pulse": ["piano", "pluck", "bright", "bell"]],
        "Techno": ["pad": ["dark", "drone"], "bass": ["acid", "303", "rubber"], "pulse": ["stab", "acid", "chord"]],
        "Trance": ["pad": ["supersaw", "trance", "lush"], "bass": ["rolling", "pluck bass"], "pulse": ["arp", "trance", "pluck", "gate"]],
        "Drum & bass": ["pad": ["atmos", "lush", "dark"], "bass": ["reese", "sub", "growl"], "pulse": ["bell", "pluck"]],
        "Lo-fi": ["pad": ["tape", "dust", "lofi", "warm"], "bass": ["upright", "warm", "soft"], "pulse": ["rhodes", "ep", "keys", "piano"]],
        "Trap": ["pad": ["dark", "choir"], "bass": ["808", "sub", "boom"], "pulse": ["bell", "pluck", "flute"]],
        "R&B": ["pad": ["rhodes", "ep", "silk", "warm"], "bass": ["sub", "smooth", "fretless"], "pulse": ["rhodes", "ep", "keys"]],
        "Reggae & dub": ["pad": ["organ", "bubble"], "bass": ["dub", "sub", "deep"], "pulse": ["organ", "skank", "guitar", "piano"]],
        "Jazz": ["pad": ["organ", "rhodes", "vibes"], "bass": ["upright", "acoustic", "jazz"], "pulse": ["piano", "rhodes", "vibe", "ep"]],
        "Blues": ["pad": ["organ", "hammond"], "bass": ["upright", "finger"], "pulse": ["piano", "guitar", "harmonica"]],
        "Country": ["pad": ["string", "steel"], "bass": ["finger", "acoustic"], "pulse": ["guitar", "banjo", "pluck", "piano"]],
        "Bossa nova": ["pad": ["string", "soft"], "bass": ["upright", "acoustic"], "pulse": ["nylon", "guitar", "rhodes", "ep"]],
        "Reggaeton": ["pad": ["pad", "warm"], "bass": ["808", "sub"], "pulse": ["pluck", "piano", "marimba"]],
        "Afrobeat": ["pad": ["organ", "brass"], "bass": ["finger", "funk"], "pulse": ["guitar", "clav", "organ"]],
        "UK garage": ["pad": ["organ", "warm"], "bass": ["sub", "garage", "wobble"], "pulse": ["organ", "stab", "chord"]],
        "Synth-pop": ["pad": ["brass", "80s", "string"], "bass": ["synth bass", "saw"], "pulse": ["arp", "pluck", "synth"]],
    ]

    public static let roleHints: [String: [String]] = [
        "pad": ["pad", "string", "choir", "ambient"], "bass": ["bass"], "sub": ["sub", "bass"],
        "pulse": ["arp", "pluck", "key", "bell"], "lead": ["lead", "solo"], "drums": ["drum", "kit"],
    ]

    /// Presets (index, name) for `role` whose names match this style's words, best first.
    public func suggestedPresets(role: String, presets: [String], limit: Int = 6) -> [(index: Int, name: String)] {
        let words = (Self.soundHints[name]?[role] ?? []) + (Self.roleHints[role] ?? [])
        guard !words.isEmpty else { return [] }
        var scored: [(score: Int, index: Int, name: String)] = []
        for (i, preset) in presets.enumerated() {
            let n = preset.lowercased()
            var score = 0
            for (rank, w) in words.enumerated() where n.contains(w) { score += words.count - rank }
            if score > 0 { scored.append((score, i, preset.trimmingCharacters(in: .whitespaces))) }
        }
        return scored.sorted { ($0.score, -$0.index) > ($1.score, -$1.index) }.prefix(limit).map { ($0.index, $0.name) }
    }
}
