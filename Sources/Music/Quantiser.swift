import Foundation
import Params

/// Turns intents into concrete notes. Every decision is a continuum between "faithful to the
/// data" (0) and "musically tidy" (1); see docs/decisions/0005-continuous-quantisation.md.
public struct Quantiser {
    public static let gridOptions: [(label: String, beats: Double)] = [
        ("1/4", 1), ("1/8", 0.5), ("1/8T", 1.0 / 3), ("1/16", 0.25), ("1/32", 0.125),
    ]

    public static let params: [ParamSpec] = [
        ParamSpec("quant.pitch.strength", default: 0.75,
                  help: "0 = raw chromatic data pitch, 0.5 = always in scale, 1 = always a chord tone. In between is probabilistic."),
        ParamSpec("quant.time.strength", default: 0.9,
                  help: "0 = notes fire the moment data arrives, 1 = snapped to the grid."),
        ParamSpec("quant.time.grid", kind: .choice, default: 3, options: gridOptions.map(\.label),
                  help: "Grid used by time quantise."),
        ParamSpec("quant.time.swing", kind: .continuous, range: 0...0.5, default: 0,
                  help: "Delay of every second grid step, as a fraction of the step."),
        ParamSpec("quant.time.humanise", kind: .continuous, range: 0...60, default: 6, unit: "ms",
                  help: "Random timing spread added after quantising."),
        ParamSpec("quant.velocity.curve", kind: .continuous, range: 0.25...4, default: 1,
                  help: "Exponent on intensity: <1 lifts quiet data, >1 makes only peaks loud."),
        ParamSpec("quant.velocity.floor", kind: .integer, range: 1...127, default: 28,
                  help: "Velocity at zero intensity."),
        ParamSpec("quant.velocity.ceiling", kind: .integer, range: 1...127, default: 108,
                  help: "Velocity at full intensity."),
        ParamSpec("quant.density.probability", default: 1,
                  help: "Chance each non-essential note survives (thins busy data)."),
        ParamSpec("quant.density.maxPerSecond", kind: .continuous, range: 0.25...40, default: 6, unit: "notes/s",
                  help: "Hard ceiling on non-essential notes per second (token bucket)."),
    ]

    private var tokens: Double = 0
    private var lastRefill: Double?

    public init() {}

    public mutating func resolve(
        _ intent: NoteIntent, harmony: HarmonyContext, clock: MusicalClock,
        params p: ParamStore, rng: inout SeededRandom
    ) -> ResolvedNote? {
        // Density: probability gate then token bucket.
        if !intent.essential {
            guard rng.chance(p.value("quant.density.probability")) else { return nil }
            let rate = p.value("quant.density.maxPerSecond")
            if let last = lastRefill {
                tokens = min(tokens + (intent.time - last) * rate, max(rate, 1))
            } else {
                tokens = max(rate, 1)
            }
            lastRefill = intent.time
            guard tokens >= 1 else { return nil }
            tokens -= 1
        }

        let note: Int
        switch intent.pitch {
        case .chordTone(let i, let octave):
            note = harmony.chordTone(i, octave: octave)
        case .raw(let pitch):
            note = Self.quantisePitch(pitch, strength: p.value("quant.pitch.strength"),
                                      harmony: harmony, roll: rng.unit())
        }

        let start = Self.quantiseTime(
            intent.time, clock: clock,
            grid: Self.gridOptions[p.int("quant.time.grid")].beats,
            strength: p.value("quant.time.strength"),
            swing: p.value("quant.time.swing")
        ) + (rng.unit() * 2 - 1) * p.value("quant.time.humanise") / 1000

        let velocity = Self.velocity(intent.intensity, curve: p.value("quant.velocity.curve"),
                                     floor: p.value("quant.velocity.floor"),
                                     ceiling: p.value("quant.velocity.ceiling"))

        return ResolvedNote(role: intent.role, note: note, velocity: velocity,
                            start: start,
                            duration: max(intent.beats * clock.secondsPerBeat, 0.02),
                            why: intent.why)
    }

    /// `roll` is a uniform 0..<1 random number, injected so tests are deterministic.
    public static func quantisePitch(_ pitch: Double, strength s: Double, harmony: HarmonyContext, roll: Double) -> Int {
        let pChord = max(0, 2 * s - 1)
        let pScale = min(1, 2 * s)
        if roll < pChord { return HarmonyContext.nearest(pitch, in: harmony.chordPitchClasses) }
        if roll < pScale { return HarmonyContext.nearest(pitch, in: harmony.scalePitchClasses) }
        return Int(pitch.rounded())
    }

    /// Moves `time` towards the next grid point by `strength`. Never moves a note earlier than
    /// requested (we can't play the past), so "snap" means "wait for the next grid line".
    public static func quantiseTime(_ time: Double, clock: MusicalClock, grid: Double, strength: Double, swing: Double) -> Double {
        guard strength > 0, grid > 0 else { return time }
        let b = clock.beat(atTime: time)
        let index = (b / grid).rounded(.up)
        let target = index * grid + (Int(index) % 2 != 0 ? swing * grid : 0)
        let gridTime = clock.time(ofBeat: target)
        return time + (gridTime - time) * strength
    }

    public static func velocity(_ intensity: Double, curve: Double, floor: Double, ceiling: Double) -> Int {
        let shaped = pow(min(max(intensity, 0), 1), curve)
        return Int((floor + (ceiling - floor) * shaped).rounded()).clamped(to: 1...127)
    }
}

extension Comparable {
    func clamped(to r: ClosedRange<Self>) -> Self { min(max(self, r.lowerBound), r.upperBound) }
}
