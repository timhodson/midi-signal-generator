import Foundation

/// What a generator wants to play, before quantising and routing.
/// Generators never pick MIDI channels or devices; they speak in roles.
public struct NoteIntent: Sendable, Equatable {
    public enum Pitch: Sendable, Equatable {
        /// A data-derived pitch (fractional MIDI note). The pitch quantiser decides how far to
        /// pull it towards the scale or chord.
        case raw(Double)
        /// An exact chord tone (index 0 = chord root) at an octave. Not pitch-quantised.
        case chordTone(Int, octave: Int)
        /// An exact MIDI note (e.g. a tonic pedal). Not pitch-quantised.
        case exact(Int)
    }

    /// Voice role, e.g. "pad", "lead", "pulse". The router maps roles to devices.
    public var role: String
    public var pitch: Pitch
    /// 0...1 loudness before the velocity curve.
    public var intensity: Double
    /// Desired start, engine seconds, before time quantising.
    public var time: Double
    /// Duration in beats (converted with the current tempo).
    public var beats: Double
    /// Exempt from the density limiter (e.g. pad chords that define the harmony).
    public var essential: Bool
    /// Already musical (a drummer's hits): skip time quantising and the density limiter. The
    /// generator has placed, swung and humanised it itself.
    public var locked: Bool
    /// Human-readable reason, shown in dry-run logs.
    public var why: String
    /// For motif notes: which app, which step, and which design (nil = generated).
    public var motif: MotifTag?

    public struct MotifTag: Sendable, Equatable, Hashable {
        public var app: String
        public var step: Int
        public var designID: String?
        /// Which wake-up this note belongs to, so all notes of one motif can be grouped.
        public var instance: Int
        public init(app: String, step: Int, designID: String?, instance: Int = 0) {
            self.app = app
            self.step = step
            self.designID = designID
            self.instance = instance
        }
    }

    public init(role: String, pitch: Pitch, intensity: Double, time: Double, beats: Double,
                essential: Bool = false, locked: Bool = false, why: String = "", motif: MotifTag? = nil) {
        self.motif = motif
        self.locked = locked
        self.role = role
        self.pitch = pitch
        self.intensity = intensity
        self.time = time
        self.beats = beats
        self.essential = essential
        self.why = why
    }
}

/// A fully musical note: concrete pitch, velocity and timing, still addressed by role.
public struct ResolvedNote: Sendable, Equatable {
    public var role: String
    public var note: Int
    public var velocity: Int
    public var start: Double
    public var duration: Double
    public var why: String

    public init(role: String, note: Int, velocity: Int, start: Double, duration: Double, why: String) {
        self.role = role
        self.note = note
        self.velocity = velocity
        self.start = start
        self.duration = duration
        self.why = why
    }
}

/// A non-note control message a generator wants to send (e.g. a filter CC on the pad).
public struct ControlIntent: Sendable, Equatable {
    public var role: String
    public var controller: Int
    public var value: Int
    public var time: Double

    public init(role: String, controller: Int, value: Int, time: Double) {
        self.role = role
        self.controller = controller
        self.value = value
        self.time = time
    }
}
