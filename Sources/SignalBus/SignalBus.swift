import Foundation

/// A single observation from a data source.
///
/// Three timescales (docs/decisions/0003-three-signal-timescales.md):
/// - `.stream`: a continuous quantity, latest value wins (bytes/s, temperature).
/// - `.event`: something happened (flow opened, motion detected).
/// States are *derived* from streams/events by the Conductor, not sent by sources.
public struct SignalSample: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case stream, event }

    public var kind: Kind
    /// Dotted id, e.g. "net.app.bytesPerSec".
    public var id: String
    /// Optional sub-key, e.g. the app name. Streams are stored per (id, key).
    public var key: String?
    public var value: Double
    /// Engine time in seconds (set by the bus on receipt if the source doesn't know it).
    public var time: Double

    public init(_ kind: Kind, _ id: String, key: String? = nil, value: Double, time: Double = 0) {
        self.kind = kind
        self.id = id
        self.key = key
        self.value = value
        self.time = time
    }

    public static func stream(_ id: String, key: String? = nil, _ value: Double) -> Self {
        .init(.stream, id, key: key, value: value)
    }

    public static func event(_ id: String, key: String? = nil, _ value: Double = 1) -> Self {
        .init(.event, id, key: key, value: value)
    }
}

/// Anything that produces signals: nettop, pcap helper, MQTT bridge, OSC listener, synthetic.
public protocol SignalSource: AnyObject, Sendable {
    var name: String { get }
    /// Start producing. `emit` may be called from any thread.
    func start(emit: @escaping @Sendable ([SignalSample]) -> Void) throws
    func stop()
}

/// Latest stream values plus the events received since the last drain.
///
/// Not thread-safe: the engine posts to it on its own serial queue.
public final class SignalBus: @unchecked Sendable {
    /// id -> key ("" for none) -> value
    public private(set) var streams: [String: [String: Double]] = [:]
    /// Incremented each time a stream with this id is updated, so consumers can detect fresh data.
    public private(set) var streamVersion: [String: Int] = [:]
    private var pendingEvents: [SignalSample] = []

    public init() {}

    public func post(_ samples: [SignalSample], at time: Double) {
        var touched = Set<String>()
        for var s in samples {
            if s.time == 0 { s.time = time }
            switch s.kind {
            case .stream:
                streams[s.id, default: [:]][s.key ?? ""] = s.value
                touched.insert(s.id)
            case .event:
                pendingEvents.append(s)
            }
        }
        for id in touched { streamVersion[id, default: 0] += 1 }
    }

    /// Lookup by "id" or "id#key".
    public func value(_ address: String) -> Double? {
        let parts = address.split(separator: "#", maxSplits: 1).map(String.init)
        return streams[parts[0]]?[parts.count > 1 ? parts[1] : ""]
    }

    public func drainEvents() -> [SignalSample] {
        defer { pendingEvents.removeAll(keepingCapacity: true) }
        return pendingEvents
    }
}
