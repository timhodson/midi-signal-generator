import Foundation
import OSC
import SignalBus
import Testing
@testable import Sources

@Suite struct OSCTests {
    @Test func messageRoundTrips() {
        let m = OSCMessage("/event/net.dns.query", [.string("github.com"), .double(1), .float(0.5), .int(-3)])
        let data = m.encoded()
        #expect(data.count % 4 == 0)
        #expect(OSCMessage.decode(data) == [m])
    }

    @Test func bundlesAreFlattened() {
        let a = OSCMessage("/a", [.float(1)]).encoded(), b = OSCMessage("/b", [.string("x")]).encoded()
        var bundle = Data("#bundle".utf8) + Data([0])
        bundle += Data(repeating: 0, count: 8) // time tag
        for part in [a, b] {
            withUnsafeBytes(of: UInt32(part.count).bigEndian) { bundle.append(contentsOf: $0) }
            bundle += part
        }
        #expect(OSCMessage.decode(bundle).map(\.address) == ["/a", "/b"])
    }

    @Test func garbageDecodesToNothing() {
        #expect(OSCMessage.decode(Data([1, 2, 3])).isEmpty)
        #expect(OSCMessage.decode(Data("hello world!".utf8)).isEmpty)
    }

    @Test func signalsMapBothWays() {
        let e = SignalSample.event("net.tcp.open", key: "github.com", 0.025)
        #expect(SignalSample(osc: e.oscMessage) == e)
        let s = SignalSample.stream("net.pkt.perSec", 230)
        #expect(SignalSample(osc: s.oscMessage) == s)
        // Plain paths are streams, slashes become dots (hand-made controllers, ADR 0008).
        let plain = OSCMessage("/net/app/bytesPerSec", [.string("Spotify"), .float(1234)])
        #expect(SignalSample(osc: plain) == .stream("net.app.bytesPerSec", key: "Spotify", 1234))
    }

    @Test func sourceReceivesOverUDP() async throws {
        let port = UInt16.random(in: 40_000...60_000)
        let source = try OSCSource(port: port)
        let received = Received()
        try source.start { received.add($0) }
        defer { source.stop() }
        let sender = try OSCSender(host: "127.0.0.1", port: port)
        sender.send(SignalSample.event("net.dns.query", key: "example.org").oscMessage)
        for _ in 0..<50 where received.samples.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(received.samples == [.event("net.dns.query", key: "example.org")])
        // A second listener on the same port is refused up front.
        #expect(throws: SourceError.self) { try OSCSource(port: port) }
    }
}

final class Received: @unchecked Sendable {
    private let lock = NSLock()
    private var _samples: [SignalSample] = []
    var samples: [SignalSample] { lock.withLock { _samples } }
    func add(_ s: [SignalSample]) { lock.withLock { _samples += s } }
}
