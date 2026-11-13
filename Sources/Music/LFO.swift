import Foundation
import Params

/// A tempo-synced LFO (ADR 0020, styles next pass): a shape that repeats every bar, beat or note
/// value, locked to the musical clock. It sends a MIDI CC to one voice (CC74, filter cutoff on most
/// synths, gives a dubstep wobble; CC11 expression with the Pump shape gives house-style ducking)
/// and publishes its value as the signal `lfo.<n>` (0–1), so Modulation routes can ride any setting
/// with it, hosted-synth and mixer params included.
public final class LFOGenerator: Generator {
    public let index: Int
    public var id: String { "lfo\(index)" }
    public static let rates: [(label: String, beats: Double)] = [
        ("4 bars", 16), ("2 bars", 8), ("1 bar", 4), ("1/2", 2), ("1/4", 1), ("1/8", 0.5), ("1/16", 0.25),
        ("1/2T", 4.0 / 3), ("1/4T", 2.0 / 3), ("1/8T", 1.0 / 3),
    ]
    public static let shapes = ["Sine", "Triangle", "Saw up", "Saw down", "Square", "Pump"]
    public static let roles = ["pad", "lead", "pulse", "bass", "sub", "none"]

    /// The latest value, 0–1 (the engine publishes it as `lfo.<n>`).
    public private(set) var value: Double = 0
    private var lastCC: Int?
    private var lastSent: Double = -.infinity

    public init(index: Int) { self.index = index }

    private var prefix: String { "lfo.\(index)" }

    public var params: [ParamSpec] {
        let defaultRole = index == 1 ? 3 : 0
        return [
            ParamSpec("\(prefix).enabled", kind: .toggle, default: 0,
                      help: "Send this LFO to a voice as a MIDI CC. Its value is always available as the signal lfo.\(index) for Modulation routes, on or off."),
            ParamSpec("\(prefix).rate", kind: .choice, default: 5, options: Self.rates.map(\.label),
                      help: "How long one cycle lasts, locked to the tempo: 1/8 = twice a beat (a classic wobble), 1/4 = every beat (pumping), 1 bar or longer for slow sweeps. T = triplets."),
            ParamSpec("\(prefix).shape", kind: .choice, default: 0, options: Self.shapes,
                      help: "Sine and Triangle sweep smoothly; Saw up / down ramp and jump; Square switches between low and high; Pump drops to the bottom on the beat and swells back, like sidechain compression."),
            ParamSpec("\(prefix).role", kind: .choice, default: Double(defaultRole), options: Self.roles,
                      help: "Which voice gets the CC (on its MIDI channel and destination). none = signal only."),
            ParamSpec("\(prefix).cc", kind: .integer, range: 0...127, default: 74,
                      help: "The CC number: 74 = filter cutoff (brightness) on most synths, 1 = mod wheel, 11 = expression (volume), 7 = volume. Map it in the synth if it doesn't respond."),
            ParamSpec("\(prefix).low", default: 0.15, help: "The CC value at the bottom of the cycle (0–1 = 0–127)."),
            ParamSpec("\(prefix).high", default: 0.85, help: "The CC value at the top of the cycle."),
            ParamSpec("\(prefix).phase", default: 0, help: "Shifts the cycle against the beat: 0.5 = half a cycle later."),
        ]
    }

    /// The shape at position x (0..<1) of its cycle, 0–1.
    public static func shape(_ i: Int, _ x: Double) -> Double {
        switch i {
        case 0: return 0.5 - 0.5 * cos(2 * .pi * x)
        case 1: return x < 0.5 ? x * 2 : 2 - x * 2
        case 2: return x
        case 3: return 1 - x
        case 4: return x < 0.5 ? 1 : 0
        default: return 1 - pow(1 - min(x * 1.6, 1), 3) // pump: ducked on the beat, back up by ~60%
        }
    }

    public func tick(_ ctx: GeneratorContext, rng: inout SeededRandom) -> GeneratorOutput {
        var out = GeneratorOutput()
        let p = ctx.params
        let rate = Self.rates[min(max(p.int("\(prefix).rate"), 0), Self.rates.count - 1)].beats
        // The value now (not at the look-ahead horizon): CCs are sent on the tick.
        let beat = ctx.clock.beat(atTime: ctx.now - 0.05)
        var x = (beat / rate + p.value("\(prefix).phase")).truncatingRemainder(dividingBy: 1)
        if x < 0 { x += 1 }
        value = Self.shape(p.int("\(prefix).shape"), x)
        guard p.bool("\(prefix).enabled") else { lastCC = nil; return out }
        let role = Self.roles[min(max(p.int("\(prefix).role"), 0), Self.roles.count - 1)]
        let cc = p.int("\(prefix).cc")
        guard role != "none", cc > 0 else { return out }
        let low = p.value("\(prefix).low"), high = p.value("\(prefix).high")
        let v = Int(((low + (high - low) * value) * 127).rounded())
        // Every change, but no faster than every 8 ms (Bluetooth MIDI copes; a wobble needs ~50/s).
        if v != lastCC, ctx.now - lastSent >= 0.008 {
            out.controls.append(ControlIntent(role: role, controller: cc, value: min(max(v, 0), 127), time: ctx.now - 0.05))
            lastCC = v
            lastSent = ctx.now
        }
        return out
    }
}
