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
    ]
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
              ]),
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
              ]),
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
        for mood in Conductor.Mood.allCases {
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
