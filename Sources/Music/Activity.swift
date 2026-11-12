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
                  help: "How much traffic an app needs before it counts as 'waking up' and plays its motif. Lower = more apps get heard (busier); higher = only significant activity."),
        ParamSpec("activity.cooldown", kind: .continuous, range: 0...120, default: 6, unit: "s",
                  help: "Minimum time before the same app can play its motif again. Longer stops one chatty app from dominating."),
        ParamSpec("activity.ignore", kind: .toggle, default: 1,
                  help: "Skip always-on background services (listed in the scene's ignoreApps) so their constant chatter doesn't trigger motifs."),
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
