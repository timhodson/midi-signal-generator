import Foundation
import Music
import Params

/// Where a role's notes go. The static parts (destination, role) live in the scene; the
/// numbers become `voice.<role>.*` parameters so they're tunable like everything else.
public struct VoiceConfig: Codable, Sendable, Equatable {
    public var role: String
    /// "virtual" = this app's own virtual MIDI source, otherwise the name of a MIDI
    /// destination (e.g. "Network Session 1", "IAC Driver Bus 1").
    public var destination: String
    /// 1...16, as written on synths.
    public var channel: Int
    public var low: Int
    public var high: Int
    public var transpose: Int = 0
    public var latencyMs: Double = 0
    public var maxPolyphony: Int = 8

    public init(role: String, destination: String, channel: Int, low: Int, high: Int,
                transpose: Int = 0, latencyMs: Double = 0, maxPolyphony: Int = 8) {
        self.role = role
        self.destination = destination
        self.channel = channel
        self.low = low
        self.high = high
        self.transpose = transpose
        self.latencyMs = latencyMs
        self.maxPolyphony = maxPolyphony
    }

    public func params() -> [ParamSpec] {
        let r = "voice.\(role)"
        return [
            ParamSpec("\(r).enabled", kind: .toggle, default: 1, help: "Send the \(role) role."),
            ParamSpec("\(r).channel", kind: .integer, range: 1...16, default: Double(channel), modulatable: false,
                      help: "MIDI channel for \(role)."),
            ParamSpec("\(r).low", kind: .integer, range: 0...127, default: Double(low), modulatable: false,
                      help: "Lowest note \(role) may play; lower notes fold up by octaves."),
            ParamSpec("\(r).high", kind: .integer, range: 0...127, default: Double(high), modulatable: false,
                      help: "Highest note \(role) may play; higher notes fold down by octaves."),
            ParamSpec("\(r).transpose", kind: .integer, range: -48...48, default: Double(transpose), modulatable: false,
                      help: "Semitones added before range folding."),
            ParamSpec("\(r).latencyMs", kind: .continuous, range: 0...500, default: latencyMs, unit: "ms", modulatable: false,
                      help: "Delay added to \(role) so slower links (e.g. Bluetooth) line up with the others."),
            ParamSpec("\(r).maxPolyphony", kind: .integer, range: 1...32, default: Double(maxPolyphony), modulatable: false,
                      help: "Max simultaneous notes; the oldest is released when exceeded."),
            ParamSpec("\(r).velocityScale", kind: .continuous, range: 0...2, default: 1,
                      help: "Per-voice velocity trim."),
        ]
    }
}

/// A note addressed to a concrete MIDI destination and channel.
public struct RoutedNote: Sendable, Equatable {
    public var destination: String
    /// 0...15 (wire value).
    public var channel: Int
    public var note: Int
    public var velocity: Int
    public var start: Double
    public var duration: Double
    public var role: String
    public var maxPolyphony: Int
    public var why: String

    public init(destination: String, channel: Int, note: Int, velocity: Int, start: Double,
                duration: Double, role: String, maxPolyphony: Int, why: String) {
        self.destination = destination
        self.channel = channel
        self.note = note
        self.velocity = velocity
        self.start = start
        self.duration = duration
        self.role = role
        self.maxPolyphony = maxPolyphony
        self.why = why
    }
}

public struct RoutedControl: Sendable, Equatable {
    public var destination: String
    public var channel: Int
    public var controller: Int
    public var value: Int
    public var time: Double

    public init(destination: String, channel: Int, controller: Int, value: Int, time: Double) {
        self.destination = destination
        self.channel = channel
        self.controller = controller
        self.value = value
        self.time = time
    }
}

public struct VoiceRouter: Sendable {
    public var voices: [String: VoiceConfig]

    public init(voices: [VoiceConfig]) {
        self.voices = Dictionary(voices.map { ($0.role, $0) }, uniquingKeysWith: { a, _ in a })
    }

    public func registerParams(in store: ParamStore) {
        for v in voices.values.sorted(by: { $0.role < $1.role }) { store.register(v.params()) }
    }

    /// Move `note` by octaves until it sits in low...high. If the range is narrower than an
    /// octave and the pitch class doesn't fit, clamp to the nearest edge.
    public static func fold(_ note: Int, low: Int, high: Int) -> Int {
        let lo = min(low, high), hi = max(low, high)
        var n = note
        while n > hi { n -= 12 }
        while n < lo { n += 12 }
        return n > hi ? (abs(n - hi) < abs(n - 12 - lo) ? hi : lo) : n
    }

    public func route(_ note: ResolvedNote, params p: ParamStore) -> RoutedNote? {
        guard let v = voices[note.role] else { return nil }
        let r = "voice.\(v.role)"
        guard p.bool("\(r).enabled") else { return nil }
        let pitch = Self.fold(note.note + p.int("\(r).transpose"), low: p.int("\(r).low"), high: p.int("\(r).high"))
        let velocity = min(max(Int((Double(note.velocity) * p.value("\(r).velocityScale")).rounded()), 1), 127)
        return RoutedNote(
            destination: v.destination, channel: p.int("\(r).channel") - 1,
            note: min(max(pitch, 0), 127), velocity: velocity,
            start: note.start + p.value("\(r).latencyMs") / 1000, duration: note.duration,
            role: v.role, maxPolyphony: p.int("\(r).maxPolyphony"), why: note.why
        )
    }

    public func route(_ control: ControlIntent, params p: ParamStore) -> RoutedControl? {
        guard let v = voices[control.role], p.bool("voice.\(v.role).enabled") else { return nil }
        return RoutedControl(destination: v.destination, channel: p.int("voice.\(v.role).channel") - 1,
                             controller: control.controller, value: min(max(control.value, 0), 127),
                             time: control.time + p.value("voice.\(v.role).latencyMs") / 1000)
    }
}
