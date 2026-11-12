import Foundation
import Params

/// "App X just started talking": the event-timescale signal derived from per-app byte rates.
public struct Activation: Sendable, Equatable {
    public var key: String
    public var bytesPerSecond: Double
    public var time: Double
}

/// Detects idle -> active transitions per key with a tunable threshold and cooldown.
public struct ActivityTracker: Sendable {
    public static let params: [ParamSpec] = [
        ParamSpec("activity.threshold", kind: .continuous, range: 100...5_000_000, default: 4_000, unit: "B/s",
                  help: "Per-app rate above which an app counts as active."),
        ParamSpec("activity.cooldown", kind: .continuous, range: 0...120, default: 6, unit: "s",
                  help: "Minimum time between two activations of the same app."),
        ParamSpec("activity.ignore", kind: .toggle, default: 1,
                  help: "Ignore always-on system daemons listed in the scene's ignoreApps."),
    ]

    private var active: Set<String> = []
    private var lastFired: [String: Double] = [:]

    public init() {}

    public mutating func update(rates: [String: Double], now: Double, params p: ParamStore,
                                ignore: Set<String>) -> [Activation] {
        let threshold = p.value("activity.threshold")
        let cooldown = p.value("activity.cooldown")
        let skip = p.bool("activity.ignore") ? ignore : []
        var out: [Activation] = []
        for (key, rate) in rates where !skip.contains(key) {
            if rate >= threshold {
                if !active.contains(key), now - (lastFired[key] ?? -.infinity) >= cooldown {
                    out.append(Activation(key: key, bytesPerSecond: rate, time: now))
                    lastFired[key] = now
                }
                active.insert(key)
            } else {
                active.remove(key)
            }
        }
        return out.sorted { $0.bytesPerSecond > $1.bytesPerSecond }
    }
}
