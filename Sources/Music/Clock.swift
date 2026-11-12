import Foundation

/// Musical time. Integrates tempo so `clock.bpm` can change (or be modulated) without jumps.
public struct MusicalClock: Sendable {
    public private(set) var beat: Double = 0
    public private(set) var time: Double = 0
    public private(set) var bpm: Double = 72
    public let beatsPerBar: Int

    public init(beatsPerBar: Int = 4) { self.beatsPerBar = beatsPerBar }

    public var secondsPerBeat: Double { 60 / bpm }

    /// Advance to `now`. Returns the beat range that elapsed.
    public mutating func advance(to now: Double, bpm newBpm: Double) -> Range<Double> {
        let from = beat
        if time == 0 { time = now }
        beat += (now - time) / secondsPerBeat
        time = now
        bpm = max(newBpm, 1)
        return from..<beat
    }

    /// Engine time at which a (future or recent) beat position occurs, assuming current tempo.
    public func time(ofBeat b: Double) -> Double {
        time + (b - beat) * secondsPerBeat
    }

    public func beat(atTime t: Double) -> Double {
        beat + (t - time) / secondsPerBeat
    }

    /// Multiples of `step` beats crossed within `range` (start exclusive, end inclusive).
    public static func crossings(of step: Double, in range: Range<Double>) -> [Double] {
        guard step > 0, range.upperBound > range.lowerBound else { return [] }
        var out: [Double] = []
        var k = (range.lowerBound / step).rounded(.down) + 1
        while k * step <= range.upperBound {
            out.append(k * step)
            k += 1
        }
        return out
    }
}
