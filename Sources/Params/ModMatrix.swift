import Foundation

/// How a raw signal value is mapped onto 0...1 before it modulates a parameter.
public enum InputScale: String, Codable, Sendable {
    case linear
    /// Logarithmic between inputMin and inputMax. Right for byte rates, which span decades.
    case log
}

/// One row of the modulation matrix: signal -> parameter.
public struct ModRoute: Codable, Sendable, Equatable {
    /// Signal id on the bus, optionally with a key: "net.total.bytesPerSec" or "net.app.bytesPerSec#Spotify".
    public var source: String
    public var target: String
    /// -1...1, as a fraction of the target's full range.
    public var amount: Double
    public var inputMin: Double
    public var inputMax: Double
    public var scale: InputScale
    /// Exponent applied after normalising (1 = straight line, >1 = gentle start, <1 = fast start).
    public var curve: Double
    /// One-pole smoothing time constant in seconds (0 = none).
    public var smoothing: Double

    public init(
        source: String, target: String, amount: Double,
        inputMin: Double = 0, inputMax: Double = 1,
        scale: InputScale = .linear, curve: Double = 1, smoothing: Double = 0.5
    ) {
        self.source = source
        self.target = target
        self.amount = amount
        self.inputMin = inputMin
        self.inputMax = inputMax
        self.scale = scale
        self.curve = curve
        self.smoothing = smoothing
    }

    /// Map a raw input to 0...1 using this route's scale and curve.
    public func normalise(_ raw: Double) -> Double {
        let n: Double
        switch scale {
        case .linear:
            n = (raw - inputMin) / max(inputMax - inputMin, .ulpOfOne)
        case .log:
            let lo = log10(max(inputMin, 1e-9))
            let hi = log10(max(inputMax, inputMin * 10, 1e-8))
            n = (log10(max(raw, 1e-9)) - lo) / max(hi - lo, .ulpOfOne)
        }
        return pow(min(max(n, 0), 1), max(curve, 0.01))
    }
}

/// Evaluates all routes each tick and pushes offsets into the store.
public final class ModMatrix: @unchecked Sendable {
    public var routes: [ModRoute]
    private var smoothed: [Int: Double] = [:]

    public init(routes: [ModRoute] = []) { self.routes = routes }

    /// Each route's amount is itself a parameter ("mod.<index>.amount") so it can be tweaked live.
    public func registerParams(in store: ParamStore) {
        for (i, route) in routes.enumerated() {
            store.register(ParamSpec(
                "mod.\(i).amount", label: "\(route.source) → \(route.target)",
                kind: .continuous, range: -1...1, default: route.amount, modulatable: false,
                help: "How strongly \(route.source) moves \(route.target). 0 = no effect; 0.5 = up to half the target's range; negative = inverted (more signal pushes it down)."
            ))
        }
    }

    /// - Parameters:
    ///   - lookup: returns the latest raw value for a signal id, or nil if not seen yet.
    ///   - dt: seconds since the previous call.
    public func apply(to store: ParamStore, dt: Double, lookup: (String) -> Double?) {
        var offsets: [String: Double] = [:]
        for (i, route) in routes.enumerated() {
            guard let spec = store.specs[route.target], spec.modulatable else { continue }
            let target = route.normalise(lookup(route.source) ?? route.inputMin)
            let previous = smoothed[i] ?? target
            let alpha = route.smoothing <= 0 ? 1 : 1 - exp(-dt / route.smoothing)
            let value = previous + (target - previous) * alpha
            smoothed[i] = value
            let amount = store.value("mod.\(i).amount")
            offsets[route.target, default: 0] += value * amount * spec.span
        }
        store.setOffsets(offsets)
    }
}

/// One knob that moves several parameters' base values together (e.g. "faithfulness").
/// Moving a target by hand afterwards is allowed; the macro only writes when it changes.
public struct Macro: Codable, Sendable, Equatable {
    public struct Target: Codable, Sendable, Equatable {
        public var param: String
        /// Target value when the macro is at 0.
        public var at0: Double
        /// Target value when the macro is at 1.
        public var at1: Double

        public init(param: String, at0: Double, at1: Double) {
            self.param = param
            self.at0 = at0
            self.at1 = at1
        }
    }

    public var id: String
    public var help: String
    public var targets: [Target]

    public init(id: String, help: String, targets: [Target]) {
        self.id = id
        self.help = help
        self.targets = targets
    }

    public func apply(_ position: Double, to store: ParamStore) throws {
        for t in targets {
            try store.set(t.param, t.at0 + (t.at1 - t.at0) * position)
        }
    }
}
