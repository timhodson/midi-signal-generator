import Foundation

/// A read-only picture of the engine, published ~10× a second for UIs and scopes.
public struct EngineStatus: Sendable {
    public struct AppRate: Sendable, Hashable {
        public var app: String
        public var bytesPerSecond: Double
    }

    public struct PlayedNote: Sendable, Hashable, Identifiable {
        public var id: Int
        public var time: Double
        public var role: String
        public var note: Int
        public var velocity: Int
        public var why: String
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
}
