import Foundation
import Music

/// Plain-language introductions for each group of parameters, shown above them in the app.
/// Keys are id prefixes; the longest matching prefix wins.
public enum ParamDocs {
    public static let groups: [String: String] = [
        "clock": "Tempo of the grid that notes snap to and chords are counted in.",
        "harmony": "The key, scale and chords. Everything melodic is bent towards these, so changing scale re-colours the whole piece at once.",
        "conductor": """
            The conductor turns overall traffic into a MOOD, and each mood plays its own chord progression \
            (shown below). Smoothed total traffic is compared with two thresholds: below 'quiet below' it's \
            QUIET, above 'busy above' it's BUSY, or FOCUSED if one app has most of the traffic, otherwise CALM. \
            A mood must last for the 'hysteresis' time before the music follows. Moods only choose the progression; \
            the other layers react to traffic directly.
            """,
        "quant": "How tidy the music is. Each control runs from 'faithful to the data' (raw timing and pitch) to 'musical' (in key, on the beat). The Faithfulness macro moves them together.",
        "macro": "One knob that moves several settings together.",
        "activity": "When an app counts as 'waking up'. Each wake-up plays that app's motif on the lead.",
        "gen.drone": "PAD (pad voice): the current chord, sustained. The harmonic bed.",
        "gen.motif": "LEAD (lead voice): every app has its own short tune, played when it wakes up, so you can hear who's talking.",
        "gen.pulse": "PULSE (pulse voice): sparse random notes on the grid. Their density and height follow total traffic.",
        "gen.bass": "BASS (bass voice): the chord root, low, in a pattern. Heavy traffic adds fills and dynamics.",
        "gen.sub": "SUB (sub voice): a deep, long drone under everything, either holding the home note or following the chords.",
        "voice": "Where each role's notes go (MIDI channel), and the register it may use. Notes outside a voice's range are moved by octaves, so the melody keeps its shape.",
        "au": "Hosted synths. Every control here is the synth's own, and each can be driven by traffic in Modulation.",
        "mod": "Routes that let a signal (e.g. total traffic) push a parameter up or down as it changes.",
    ]

    public static func description(for prefix: String) -> String? {
        groups.keys.filter { prefix.hasPrefix($0) }.max(by: { $0.count < $1.count }).flatMap { groups[$0] }
    }
}

/// One mood's progression, named in the current key (for the app's mood table).
public struct MoodProgression: Sendable, Hashable {
    public var mood: String
    public var degrees: [Int]
    public var chords: [String]
    public var numerals: [String]
}

extension Conductor {
    public func describedProgressions(in harmony: HarmonyContext) -> [MoodProgression] {
        Mood.allCases.map { mood in
            let degrees = progressions[mood] ?? []
            return MoodProgression(mood: mood.rawValue, degrees: degrees,
                                   chords: degrees.map { harmony.chordName(degree: $0) },
                                   numerals: degrees.map { harmony.romanNumeral(degree: $0) })
        }
    }

    public func describedGestures(in harmony: HarmonyContext) -> [MoodProgression] {
        gestures.keys.sorted().map { name in
            let degrees = gestures[name] ?? []
            return MoodProgression(mood: name, degrees: degrees,
                                   chords: degrees.map { harmony.chordName(degree: $0) },
                                   numerals: degrees.map { harmony.romanNumeral(degree: $0) })
        }
    }
}
