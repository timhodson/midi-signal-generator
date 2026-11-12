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
    public var progressions: [String: [Int]]
    public var gestures: [String: [Int]]
    /// Apps that never trigger motifs (always-on daemons) while `activity.ignore` is on.
    public var ignoreApps: [String]

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
        ],
        progressions: Dictionary(uniqueKeysWithValues: Conductor.defaultProgressions.map { ($0.key.rawValue, $0.value) }),
        gestures: Conductor.defaultGestures,
        ignoreApps: ["mDNSResponder", "apsd", "netbiosd", "syslogd", "symptomsd", "rapportd", "identityservice"]
    )

    private enum CodingKeys: String, CodingKey {
        case name, seed, params, routes, macros, voices, instruments, progressions, gestures, ignoreApps
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
        progressions = try c.decode([String: [Int]].self, forKey: .progressions)
        gestures = try c.decode([String: [Int]].self, forKey: .gestures)
        ignoreApps = try c.decode([String].self, forKey: .ignoreApps)
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
