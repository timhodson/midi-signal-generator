import Foundation
import Music
import Params
import Router

/// Everything that defines a sound, as one JSON file: parameter values, mod routes, macros,
/// voice routing, progressions. See scenes/default.json.
public struct Scene: Codable, Sendable {
    public var name: String
    public var seed: UInt64
    /// Base values for any registered param. Missing ids use the param's default.
    public var params: [String: Double]
    public var routes: [ModRoute]
    public var macros: [Macro]
    public var voices: [VoiceConfig]
    /// Audio Unit instruments hosted in-app; voices reach them with destination "au:<id>".
    public var instruments: [InstrumentConfig] = []
    /// Hand-designed motifs for matching apps (see MotifDesign).
    public var motifs: [MotifDesign] = []
    /// Drum grooves edited in the app; they replace the built-in groove of the same name.
    public var grooves: [DrumGroove] = []
    public var progressions: [String: [Int]]
    public var gestures: [String: [Int]]
    /// Apps that never trigger motifs (always-on daemons) while `activity.ignore` is on.
    public var ignoreApps: [String]
    /// The style whose settings are already in `params` (saved with the scene), so loading it
    /// doesn't apply the style again over later tweaks. A scene that sets `style.name` without
    /// this (written by hand, or `--set style.name=…`) gets the style applied when it starts.
    public var appliedStyle: String?

    public static let `default` = Scene(
        name: "Default — network ambient",
        seed: 2026,
        params: [:],
        routes: [
            // More traffic -> pulse fires more often.
            ModRoute(source: "net.total.bytesPerSec", target: "gen.pulse.density", amount: 0.45,
                     inputMin: 5_000, inputMax: 5_000_000, scale: .log, curve: 1.5, smoothing: 2),
            // More traffic -> brighter pad (CC74) and a bit louder.
            ModRoute(source: "net.total.bytesPerSec", target: "gen.drone.ccValue", amount: 0.5,
                     inputMin: 1_000, inputMax: 10_000_000, scale: .log, curve: 1, smoothing: 4),
            ModRoute(source: "net.total.bytesPerSec", target: "gen.drone.intensity", amount: 0.25,
                     inputMin: 1_000, inputMax: 10_000_000, scale: .log, curve: 1, smoothing: 6),
        ],
        macros: [
            Macro(id: "macro.faithfulness",
                  help: "0 = tidy and musical, 1 = raw sonification. Moves the quantise strengths and density.",
                  targets: [
                      .init(param: "quant.pitch.strength", at0: 1, at1: 0),
                      .init(param: "quant.time.strength", at0: 1, at1: 0),
                      .init(param: "quant.density.probability", at0: 0.7, at1: 1),
                      .init(param: "quant.density.maxPerSecond", at0: 4, at1: 40),
                      .init(param: "harmony.hysteresis", at0: 30, at1: 0),
                  ]),
        ],
        voices: [
            VoiceConfig(role: "pad", destination: "virtual", channel: 1, low: 36, high: 72, maxPolyphony: 8),
            VoiceConfig(role: "lead", destination: "virtual", channel: 2, low: 60, high: 96, maxPolyphony: 4),
            VoiceConfig(role: "pulse", destination: "virtual", channel: 3, low: 48, high: 84, maxPolyphony: 3),
            VoiceConfig(role: "bass", destination: "virtual", channel: 4, low: 28, high: 55, maxPolyphony: 2),
            VoiceConfig(role: "sub", destination: "virtual", channel: 5, low: 21, high: 45, maxPolyphony: 2),
            Scene.drumVoice(destination: "virtual"),
        ],
        progressions: Dictionary(uniqueKeysWithValues: Conductor.defaultProgressions.map { ($0.key.rawValue, $0.value) }),
        gestures: Conductor.defaultGestures,
        ignoreApps: ["mDNSResponder", "apsd", "netbiosd", "syslogd", "symptomsd", "rapportd", "identityservice"]
    )

    private enum CodingKeys: String, CodingKey {
        case name, seed, params, routes, macros, voices, instruments, motifs, grooves, progressions, gestures, ignoreApps, appliedStyle
    }

    public init(name: String, seed: UInt64, params: [String: Double], routes: [ModRoute], macros: [Macro],
                voices: [VoiceConfig], instruments: [InstrumentConfig] = [], progressions: [String: [Int]],
                gestures: [String: [Int]], ignoreApps: [String]) {
        self.name = name
        self.seed = seed
        self.params = params
        self.routes = routes
        self.macros = macros
        self.voices = voices
        self.instruments = instruments
        self.progressions = progressions
        self.gestures = gestures
        self.ignoreApps = ignoreApps
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        seed = try c.decode(UInt64.self, forKey: .seed)
        params = try c.decode([String: Double].self, forKey: .params)
        routes = try c.decode([ModRoute].self, forKey: .routes)
        macros = try c.decode([Macro].self, forKey: .macros)
        voices = try c.decode([VoiceConfig].self, forKey: .voices)
        instruments = try c.decodeIfPresent([InstrumentConfig].self, forKey: .instruments) ?? []
        motifs = try c.decodeIfPresent([MotifDesign].self, forKey: .motifs) ?? []
        grooves = try c.decodeIfPresent([DrumGroove].self, forKey: .grooves) ?? []
        progressions = try c.decode([String: [Int]].self, forKey: .progressions)
        gestures = try c.decode([String: [Int]].self, forKey: .gestures)
        ignoreApps = try c.decode([String].self, forKey: .ignoreApps)
        appliedStyle = try c.decodeIfPresent(String.self, forKey: .appliedStyle)
        addDrumsIfMissing()
    }

    /// The drums voice: General MIDI channel 10, every note allowed (the kit map picks them).
    public static func drumVoice(destination: String) -> VoiceConfig {
        VoiceConfig(role: DrumGenerator.role, destination: destination, channel: 10, low: 0, high: 127, maxPolyphony: 16)
    }

    /// Apple's built-in General MIDI synth, which plays drums on channel 10: drums with no setup.
    public static let builtInDrumKit = InstrumentConfig(id: "drums", component: "DLSMusicDevice", volume: 0.7, outOfProcess: false)

    /// Scenes from before the drummer get a drums voice: on Apple's built-in GM kit when every
    /// voice is a hosted synth, otherwise on the pad's destination, channel 10.
    public mutating func addDrumsIfMissing() {
        guard !voices.contains(where: { $0.role == DrumGenerator.role }) else { return }
        let hosted = !voices.isEmpty && voices.allSatisfy { $0.destination.hasPrefix(InstrumentConfig.destinationPrefix) }
        if hosted {
            if !instruments.contains(where: { $0.id == Self.builtInDrumKit.id }) { instruments.append(Self.builtInDrumKit) }
            voices.append(Self.drumVoice(destination: Self.builtInDrumKit.destination))
        } else {
            voices.append(Self.drumVoice(destination: voices.first(where: { $0.role == "pad" })?.destination ?? voices.first?.destination ?? "virtual"))
        }
    }

    public static func load(_ url: URL) throws -> Scene {
        try JSONDecoder().decode(Scene.self, from: Data(contentsOf: url))
    }

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(self)
    }
}
