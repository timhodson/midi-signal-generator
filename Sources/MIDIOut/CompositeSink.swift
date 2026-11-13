import Foundation
import Params

/// A sink that also owns tunable parameters (e.g. a hosted synth's volume and controls).
/// The engine registers them at start-up and calls `applyParams` every tick.
public protocol ParameterisedSink: MIDISink {
    func registerParams(in store: ParamStore)
    func applyParams(_ store: ParamStore)
}

/// Sends each destination to the first sink that claims it, so one scene can mix hosted
/// Audio Units ("au:…") with external MIDI (virtual port, network session, devices).
public final class CompositeSink: ParameterisedSink {
    public struct Route {
        public var claims: (String) -> Bool
        public var sink: MIDISink
        public init(claims: @escaping (String) -> Bool, sink: MIDISink) {
            self.claims = claims
            self.sink = sink
        }
    }

    private let routes: [Route]
    private let fallback: MIDISink

    public init(routes: [Route], fallback: MIDISink) {
        self.routes = routes
        self.fallback = fallback
    }

    private func sink(for destination: String) -> MIDISink {
        routes.first { $0.claims(destination) }?.sink ?? fallback
    }

    private var all: [MIDISink] { routes.map(\.sink) + [fallback] }

    public func noteOn(destination: String, channel: Int, note: Int, velocity: Int) {
        sink(for: destination).noteOn(destination: destination, channel: channel, note: note, velocity: velocity)
    }

    public func noteOff(destination: String, channel: Int, note: Int) {
        sink(for: destination).noteOff(destination: destination, channel: channel, note: note)
    }

    public func controlChange(destination: String, channel: Int, controller: Int, value: Int) {
        sink(for: destination).controlChange(destination: destination, channel: channel, controller: controller, value: value)
    }

    public func allNotesOff() { all.forEach { $0.allNotesOff() } }

    public func sendRaw(destination: String, _ bytes: [UInt8], atUptimeNanos: UInt64?) {
        sink(for: destination).sendRaw(destination: destination, bytes, atUptimeNanos: atUptimeNanos)
    }

    public func transport(_ state: TransportState) { all.forEach { $0.transport(state) } }

    public func registerParams(in store: ParamStore) {
        for case let s as ParameterisedSink in all { s.registerParams(in: store) }
    }

    public func applyParams(_ store: ParamStore) {
        for case let s as ParameterisedSink in all { s.applyParams(store) }
    }
}
