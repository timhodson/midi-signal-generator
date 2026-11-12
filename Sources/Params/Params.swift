import Foundation

/// How a parameter's value should be interpreted and displayed.
public enum ParamKind: String, Codable, Sendable {
    /// Continuous value, typically 0...1.
    case normalised
    /// Continuous value in its own unit (bpm, seconds, bytes/s...).
    case continuous
    /// Whole numbers only (octaves, MIDI notes, counts).
    case integer
    /// An index into `options`.
    case choice
    /// 0 = off, 1 = on.
    case toggle
}

/// The definition of one tunable value. Every musical decision in the app is one of these
/// (see docs/decisions/0002-everything-is-a-parameter.md).
public struct ParamSpec: Sendable, Codable, Equatable {
    public let id: String
    public let label: String
    public let kind: ParamKind
    public let range: ClosedRange<Double>
    public let defaultValue: Double
    public let unit: String
    /// Labels for `.choice` params.
    public let options: [String]
    /// May the modulation matrix drive this param from a signal?
    public let modulatable: Bool
    /// One-line explanation shown in UI / `--list-params`.
    public let help: String

    public init(
        _ id: String,
        label: String? = nil,
        kind: ParamKind = .normalised,
        range: ClosedRange<Double> = 0...1,
        default defaultValue: Double,
        unit: String = "",
        options: [String] = [],
        modulatable: Bool = true,
        help: String = ""
    ) {
        self.id = id
        self.label = label ?? id
        self.kind = kind
        self.range = kind == .choice ? 0...Double(max(options.count - 1, 0)) : range
        self.defaultValue = defaultValue
        self.unit = unit
        self.options = options
        self.modulatable = kind == .choice || kind == .toggle ? false : modulatable
        self.help = help
    }

    /// Clamp and, for discrete kinds, round.
    public func sanitise(_ value: Double) -> Double {
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        switch kind {
        case .integer, .choice, .toggle: return clamped.rounded()
        case .normalised, .continuous: return clamped
        }
    }

    public var span: Double { range.upperBound - range.lowerBound }
}

/// Holds base values (what the user set) and effective values (base + modulation).
///
/// Not thread-safe by design: the engine owns it on its serial queue.
public final class ParamStore: @unchecked Sendable {
    public private(set) var specs: [String: ParamSpec] = [:]
    /// Insertion order, so listings and UIs are stable.
    public private(set) var order: [String] = []
    private var base: [String: Double] = [:]
    private var offsets: [String: Double] = [:]

    public init() {}

    public func register(_ spec: ParamSpec) {
        if specs[spec.id] == nil { order.append(spec.id) }
        specs[spec.id] = spec
        if base[spec.id] == nil { base[spec.id] = spec.sanitise(spec.defaultValue) }
    }

    public func register(_ list: [ParamSpec]) { list.forEach(register) }

    /// Set a base value. Unknown ids throw so typos in scenes / `--set` are caught.
    public func set(_ id: String, _ value: Double) throws {
        guard let spec = specs[id] else { throw ParamError.unknown(id) }
        base[id] = spec.sanitise(value)
    }

    public func baseValue(_ id: String) -> Double {
        base[id] ?? specs[id]?.defaultValue ?? 0
    }

    /// The value the music engine should use right now.
    public func value(_ id: String) -> Double {
        guard let spec = specs[id] else {
            assertionFailure("Unregistered param \(id)")
            return 0
        }
        return spec.sanitise(baseValue(id) + (offsets[id] ?? 0))
    }

    public func int(_ id: String) -> Int { Int(value(id)) }
    public func bool(_ id: String) -> Bool { value(id) >= 0.5 }

    /// Replace all modulation offsets (called once per engine tick by the mod matrix).
    public func setOffsets(_ new: [String: Double]) { offsets = new }

    public var baseValues: [String: Double] { base }
}

public enum ParamError: Error, CustomStringConvertible {
    case unknown(String)
    case malformed(String)

    public var description: String {
        switch self {
        case .unknown(let id): "Unknown parameter '\(id)'. Run with --list-params to see them all."
        case .malformed(let s): "Could not parse '\(s)'; expected id=value."
        }
    }
}
