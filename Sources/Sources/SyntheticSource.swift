import Foundation
import SignalBus

/// Fake per-app traffic with the same signal ids as `NettopSource`, for working on the music
/// without a busy network (and for reproducible demos). Apps idle, wake, burst and stream.
public final class SyntheticSource: SignalSource, @unchecked Sendable {
    public let name = "synthetic"
    private let apps = ["Safari", "Mail", "Spotify", "Slack", "Music", "Dropbox", "Messages"]
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "synthetic-source")
    private var seed: UInt64

    public init(seed: UInt64 = 1) { self.seed = seed }

    private func random() -> Double {
        seed &+= 0x9E37_79B9_7F4A_7C15
        var z = seed
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
    }

    public func start(emit: @escaping @Sendable ([SignalSample]) -> Void) throws {
        var rates = Dictionary(uniqueKeysWithValues: apps.map { ($0, 0.0) })
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            for app in self.apps {
                let r = self.random()
                switch rates[app]! {
                case 0 where r < 0.08: rates[app] = 2_000 + self.random() * 200_000 // wake
                case let x where x > 0 && r < 0.15: rates[app] = 0 // sleep
                case let x where x > 0: rates[app] = max(x * (0.6 + self.random() * 0.9), 500)
                default: break
                }
            }
            if self.random() < 0.02 { rates["Spotify"] = 3_000_000 } // start "streaming"
            var samples = rates.map { SignalSample.stream("net.app.bytesPerSec", key: $0.key, $0.value) }
            samples.append(.stream("net.total.bytesPerSec", rates.values.reduce(0, +)))
            emit(samples)
        }
        t.resume()
        timer = t
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }
}
