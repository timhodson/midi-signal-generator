import Foundation
import Music

/// A read-only picture of the engine, published ~10× a second for UIs and scopes.
public struct EngineStatus: Sendable {
    public struct AppRate: Sendable, Hashable {
        public var app: String
        public var bytesPerSecond: Double
    }

    public struct PlayedNote: Sendable, Hashable, Identifiable {
        public var id: Int
        /// When it sounds (after quantise, routing latency).
        public var time: Double
        public var role: String
        public var note: Int
        public var velocity: Int
        public var why: String
        public var duration: Double = 0
        /// When the generator asked for it, before time quantising.
        public var rawTime: Double = 0
        /// The data-derived pitch before pitch quantising (nil for chord tones / exact notes).
        public var rawPitch: Double?
        /// Generator intensity (0...1) before the velocity curve.
        public var intensity: Double = 0
        /// For motif notes: the app, step and design (nil = generated motif).
        public var motif: NoteIntent.MotifTag?
    }

    /// An app the engine has seen, for the motif editor.
    public struct AppInfo: Sendable, Hashable {
        public var name: String
        public var bytesPerSecond: Double
        public var wakes: Int
        /// Engine time of the last wake-up, if any.
        public var lastWake: Double?
        public var ignored: Bool
    }

    public struct ChordEvent: Sendable, Hashable {
        public var time: Double
        public var name: String
        public var numeral: String
        public var mood: String
    }

    /// A chord the scale offers, for the progression editor.
    public struct ChordChoice: Sendable, Hashable {
        public var degree: Int
        public var name: String
        public var numeral: String
        /// Note names, root first: ["D", "F", "A"].
        public var notes: [String]
        /// Which scale steps it's built from, 1-based: [1, 3, 5].
        public var steps: [Int]
        public var pitchClasses: [Int]
    }

    /// The music is paused (the session stays loaded).
    public var paused = false
    /// [bar, of] while the intro builds up, nil once the piece is going.
    public var intro: [Int]?
    public var time: Double
    public var beat: Double
    public var bpm: Double
    public var mood: String
    public var chordDegree: Int
    /// Pitch-class names of the current chord, e.g. ["D", "F", "A"].
    public var chord: [String]
    public var key: String
    public var totalRate: Double
    public var smoothedRate: Double
    public var topApps: [AppRate]
    public var sounding: Int
    /// Effective (base + modulation) value of every param.
    public var values: [String: Double]
    /// Base (user-set) value of every param.
    public var bases: [String: Double]
    /// Latest signal values, by address ("id" or "id#key").
    public var signals: [String: Double]
    /// Most recent notes, newest last.
    public var recentNotes: [PlayedNote]
    /// Every mood's progression in the current key, and which step is playing.
    public var progressions: [MoodProgression]
    public var progressionIndex: Int
    /// Gesture sequences (e.g. "flurry"), named in the current key.
    public var gestures: [MoodProgression]
    /// The chord on each scale degree, in the current key.
    public var chordChoices: [ChordChoice]
    /// Recent chord changes, oldest first.
    public var chordHistory: [ChordEvent]
    /// Pitch classes (0 = C) of the scale and of the current chord.
    public var scalePitchClasses: [Int]
    public var chordPitchClasses: [Int]
    /// Enough to rebuild the HarmonyContext in a UI (e.g. to resolve motif steps to notes).
    public var root: Int
    public var scaleSteps: [Int]
    public var chordSize: Int
    public var apps: [AppInfo]
    public var motifs: [MotifDesign]
    /// Recent network events from the packet capture helper, newest last, and what they played.
    public var netEvents: [NetEvent] = []
    /// The capture helper's interface and when it last reported (nil = never heard from it).
    public var capture: Capture?
    /// The drummer: groove, complexity, fills and recent hits.
    public var drums: DrumStatus?
    /// Variations made so far, and when the next scheduled one is due.
    public var variation: VariationInfo?
    /// MIDI clock out: who gets it, and who has been sent Start.
    public var clock: ClockInfo?
    /// The genre style applied (index into `Style.choices`), and whether a change is waiting for the next chord.
    public var style: StyleInfo?

    public struct StyleInfo: Sendable, Equatable {
        public var applied: Int
        public var pending: Bool
    }

    public struct ClockInfo: Sendable, Equatable {
        public var destinations: [String]
        public var started: [String]
    }

    public struct VariationInfo: Sendable {
        public var log: [Variation.Applied]
        /// Seconds until the next scheduled variation (nil = no schedule).
        public var nextIn: Double?
        /// A variation waiting for its chord change / phrase end, and why.
        public var pending: String?
    }

    public struct NetEvent: Sendable, Hashable, Identifiable {
        public var id: Int
        public var time: Double
        /// Signal id, e.g. "net.dns.query".
        public var kind: String
        /// Host / service name.
        public var name: String
        /// Round trip in seconds for handshakes; 1 = reset for closes.
        public var value: Double
        public var played: Bool
        /// What it played, or why it didn't.
        public var reason: String
    }

    public struct Capture: Sendable, Hashable {
        public var interface: String
        public var lastSeen: Double
        public var packetsPerSecond: Double
    }
}
