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
}
