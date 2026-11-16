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
    /// More sounds playing the same notes ("pad on the J6 *and* on the iPad"). Each layer has
    /// its own destination and channel, and can be shifted, trimmed and delayed; the voice's
    /// range and polyphony apply to all of them. Params `voice.<role>.layer<N>.*`, N from 1.
    public var layers: [VoiceLayer] = []

    public init(role: String, destination: String, channel: Int, low: Int, high: Int,
                transpose: Int = 0, latencyMs: Double = 0, maxPolyphony: Int = 8, layers: [VoiceLayer] = []) {
        self.role = role
        self.destination = destination
        self.channel = channel
        self.low = low
        self.high = high
        self.transpose = transpose
        self.latencyMs = latencyMs
        self.maxPolyphony = maxPolyphony
        self.layers = layers
    }

    private enum CodingKeys: String, CodingKey { case role, destination, channel, low, high, transpose, latencyMs, maxPolyphony, layers }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        role = try c.decode(String.self, forKey: .role)
        destination = try c.decode(String.self, forKey: .destination)
        channel = try c.decode(Int.self, forKey: .channel)
        low = try c.decode(Int.self, forKey: .low)
        high = try c.decode(Int.self, forKey: .high)
        transpose = try c.decodeIfPresent(Int.self, forKey: .transpose) ?? 0
        latencyMs = try c.decodeIfPresent(Double.self, forKey: .latencyMs) ?? 0
        maxPolyphony = try c.decodeIfPresent(Int.self, forKey: .maxPolyphony) ?? 8
        layers = try c.decodeIfPresent([VoiceLayer].self, forKey: .layers) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(role, forKey: .role)
        try c.encode(destination, forKey: .destination)
        try c.encode(channel, forKey: .channel)
        try c.encode(low, forKey: .low)
        try c.encode(high, forKey: .high)
        try c.encode(transpose, forKey: .transpose)
        try c.encode(latencyMs, forKey: .latencyMs)
        try c.encode(maxPolyphony, forKey: .maxPolyphony)
        if !layers.isEmpty { try c.encode(layers, forKey: .layers) }
    }

    /// Every destination this voice plays on: its own, then its layers'.
    public var destinations: [String] { [destination] + layers.map(\.destination) }

    public func params() -> [ParamSpec] {
        let r = "voice.\(role)"
        return [
            ParamSpec("\(r).enabled", kind: .toggle, default: 1, help: "Mute or unmute the \(role) voice entirely."),
            ParamSpec("\(r).channel", kind: .integer, range: 1...16, default: Double(channel), modulatable: false,
                      help: "MIDI channel the \(role) voice sends on. Match it to the synth listening for it (hosted synths listen on all channels)."),
            ParamSpec("\(r).low", kind: .integer, range: 0...127, default: Double(low), modulatable: false,
                      help: "Lowest note the \(role) voice may play. Lower notes are moved up by octaves, so this shapes the register without changing the melody."),
            ParamSpec("\(r).high", kind: .integer, range: 0...127, default: Double(high), modulatable: false,
                      help: "Highest note the \(role) voice may play. Higher notes are moved down by octaves."),
            ParamSpec("\(r).transpose", kind: .integer, range: -48...48, default: Double(transpose), modulatable: false,
                      help: "Shift the \(role) voice up or down in semitones (12 = an octave) before the range is applied."),
            ParamSpec("\(r).latencyMs", kind: .continuous, range: 0...500, default: latencyMs, unit: "ms", modulatable: false,
                      help: "Delay the \(role) voice to line up with slower links. E.g. if a Bluetooth synth lags, delay the other voices by the same amount."),
            ParamSpec("\(r).maxPolyphony", kind: .integer, range: 1...32, default: Double(maxPolyphony), modulatable: false,
                      help: "Max notes the \(role) voice holds at once. When exceeded, the oldest note is released. Lower = cleaner, less smeared."),
            ParamSpec("\(r).velocityScale", kind: .continuous, range: 0...2, default: 1,
                      help: "Loudness trim for the \(role) voice: 1 = as played, 0.5 = half velocity, 2 = double (capped)."),
        ] + layers.enumerated().flatMap { i, layer in layer.params(role: role, number: i + 1) }
    }
}

/// An extra sound on a voice: the same notes, sent somewhere else too.
public struct VoiceLayer: Codable, Sendable, Equatable {
    public var destination: String
    /// 1...16.
    public var channel: Int
    /// Semitones on top of the voice's own notes, after its range: 12 doubles an octave up.
    public var transpose: Int = 0
    public var latencyMs: Double = 0

    public init(destination: String, channel: Int, transpose: Int = 0, latencyMs: Double = 0) {
        self.destination = destination
        self.channel = channel
        self.transpose = transpose
        self.latencyMs = latencyMs
    }

    private enum CodingKeys: String, CodingKey { case destination, channel, transpose, latencyMs }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        destination = try c.decode(String.self, forKey: .destination)
        channel = try c.decodeIfPresent(Int.self, forKey: .channel) ?? 1
        transpose = try c.decodeIfPresent(Int.self, forKey: .transpose) ?? 0
        latencyMs = try c.decodeIfPresent(Double.self, forKey: .latencyMs) ?? 0
    }

    public static func prefix(role: String, number: Int) -> String { "voice.\(role).layer\(number)" }

    public func params(role: String, number: Int) -> [ParamSpec] {
        let r = Self.prefix(role: role, number: number), name = "layer \(number) of the \(role) voice"
        return [
            ParamSpec("\(r).enabled", kind: .toggle, default: 1, help: "Mute or unmute \(name); the voice's main sound keeps playing."),
            ParamSpec("\(r).channel", kind: .integer, range: 1...16, default: Double(channel), modulatable: false,
                      help: "MIDI channel \(name) sends on."),
            ParamSpec("\(r).transpose", kind: .integer, range: -36...36, default: Double(transpose), modulatable: false,
                      help: "Shift \(name) in semitones against the main sound: 12 doubles it an octave up, -12 an octave down, 7 a fifth above."),
            ParamSpec("\(r).velocityScale", kind: .continuous, range: 0...2, default: 1,
                      help: "Loudness of \(name) against the main sound: 0.5 = a quieter layer underneath, 1 = as played."),
            ParamSpec("\(r).latencyMs", kind: .continuous, range: 0...500, default: latencyMs, unit: "ms", modulatable: false,
                      help: "Delay \(name) on its own. A few ms thickens it; more makes an echo. Also lines up a slower link."),
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

    /// The voice's outputs that are switched on: where they go, and their param prefix.
    private func outputs(_ v: VoiceConfig, _ p: ParamStore) -> [(destination: String, prefix: String, layer: Bool)] {
        let r = "voice.\(v.role)"
        guard p.bool("\(r).enabled") else { return [] }
        return [(v.destination, r, false)] + v.layers.enumerated().compactMap { i, layer in
            let lp = VoiceLayer.prefix(role: v.role, number: i + 1)
            return p.bool("\(lp).enabled") ? (layer.destination, lp, true) : nil
        }
    }

    /// The note on every output of its voice: the main sound first, then each layer that's on.
    /// Empty when the voice is off (or there's no voice for the role).
    public func route(_ note: ResolvedNote, params p: ParamStore) -> [RoutedNote] {
        guard let v = voices[note.role] else { return [] }
        let r = "voice.\(v.role)"
        let pitch = Self.fold(note.note + p.int("\(r).transpose"), low: p.int("\(r).low"), high: p.int("\(r).high"))
        let baseLatency = p.value("\(r).latencyMs")
        let poly = p.int("\(r).maxPolyphony")
        return outputs(v, p).map { out in
            let shift = out.layer ? p.int("\(out.prefix).transpose") : 0
            let scale = p.value("\(r).velocityScale") * (out.layer ? p.value("\(out.prefix).velocityScale") : 1)
            let velocity = min(max(Int((Double(note.velocity) * scale).rounded()), 1), 127)
            let latency = baseLatency + (out.layer ? p.value("\(out.prefix).latencyMs") : 0)
            return RoutedNote(
                destination: out.destination, channel: p.int("\(out.prefix).channel") - 1,
                note: min(max(pitch + shift, 0), 127), velocity: velocity,
                start: note.start + latency / 1000, duration: note.duration,
                role: v.role, maxPolyphony: poly, why: note.why
            )
        }
    }

    /// A controller change on every output of its voice (an LFO wobbles every layer).
    public func route(_ control: ControlIntent, params p: ParamStore) -> [RoutedControl] {
        guard let v = voices[control.role] else { return [] }
        let base = p.value("voice.\(v.role).latencyMs")
        return outputs(v, p).map { out in
            RoutedControl(destination: out.destination, channel: p.int("\(out.prefix).channel") - 1,
                          controller: control.controller, value: min(max(control.value, 0), 127),
                          time: control.time + (base + (out.layer ? p.value("\(out.prefix).latencyMs") : 0)) / 1000)
        }
    }
}

/// An Audio Unit instrument hosted inside the app. Voices reach it with destination
/// "au:<id>" (docs/decisions/0010-hosted-audio-unit-instruments.md).
public struct InstrumentConfig: Codable, Sendable, Equatable {
    /// Short id used in destinations and param ids: "j6" -> "au:j6", "au.j6.volume".
    public var id: String
    /// Component name as listed by `--list-instruments`, e.g. "Synth One J6" or
    /// "AudioKit Pro: Synth One J6".
    public var component: String
    /// Factory preset name to load (nil = the plugin's default sound).
    public var preset: String?
    public var volume: Double
    public var pan: Double
    /// Run the plugin in a separate process (the default). A crashing plugin can't take the
    /// app down, and some plugins (King of FM 2) only load this way from a command-line host.
    public var outOfProcess: Bool
    /// Audio Unit effects after the synth, in order, before its mixer channel. Params
    /// `au.<id>.fx<N>.*`, N from 1.
    public var effects: [EffectConfig] = []

    public init(id: String, component: String, preset: String? = nil, volume: Double = 0.8,
                pan: Double = 0, outOfProcess: Bool = true, effects: [EffectConfig] = []) {
        self.id = id
        self.component = component
        self.preset = preset
        self.volume = volume
        self.pan = pan
        self.outOfProcess = outOfProcess
        self.effects = effects
    }

    public static let destinationPrefix = "au:"
    public var destination: String { Self.destinationPrefix + id }

    private enum CodingKeys: String, CodingKey { case id, component, preset, volume, pan, outOfProcess, effects }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        component = try c.decode(String.self, forKey: .component)
        preset = try c.decodeIfPresent(String.self, forKey: .preset)
        volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? 0.8
        pan = try c.decodeIfPresent(Double.self, forKey: .pan) ?? 0
        outOfProcess = try c.decodeIfPresent(Bool.self, forKey: .outOfProcess) ?? true
        effects = try c.decodeIfPresent([EffectConfig].self, forKey: .effects) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(component, forKey: .component)
        try c.encodeIfPresent(preset, forKey: .preset)
        try c.encode(volume, forKey: .volume)
        try c.encode(pan, forKey: .pan)
        try c.encode(outOfProcess, forKey: .outOfProcess)
        if !effects.isEmpty { try c.encode(effects, forKey: .effects) }
    }

    /// The id an effect of this synth is known by: "j6.fx1" (params "au.j6.fx1.*").
    public func effectID(_ number: Int) -> String { "\(id).fx\(number)" }
}

/// An Audio Unit effect on a hosted synth: a delay, a chorus, a filter…
public struct EffectConfig: Codable, Sendable, Equatable {
    /// Component name as listed by `--list-effects`, e.g. "AUDelay" or "Apple: AUDelay".
    public var component: String
    /// Factory preset to load (nil = the plugin's default).
    public var preset: String?
    public var outOfProcess: Bool

    public init(component: String, preset: String? = nil, outOfProcess: Bool = true) {
        self.component = component
        self.preset = preset
        self.outOfProcess = outOfProcess
    }

    private enum CodingKeys: String, CodingKey { case component, preset, outOfProcess }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        component = try c.decode(String.self, forKey: .component)
        preset = try c.decodeIfPresent(String.self, forKey: .preset)
        outOfProcess = try c.decodeIfPresent(Bool.self, forKey: .outOfProcess) ?? true
    }
}
