import Foundation
import Testing
@testable import PacketFeatures
import SignalBus

/// Builds packets byte by byte (Ethernet / IPv4 / IPv6 / UDP / TCP), like a tiny scapy.
enum Craft {
    static func be16(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
    static func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }

    static func eth(_ payload: [UInt8], v6: Bool = false) -> [UInt8] {
        [UInt8](repeating: 0x11, count: 6) + [UInt8](repeating: 0x22, count: 6) + be16(v6 ? 0x86DD : 0x0800) + payload
    }
    static func ip4(_ src: String, _ dst: String, _ proto: UInt8, _ payload: [UInt8]) -> [UInt8] {
        let s = IPAddress(src)!.octets, d = IPAddress(dst)!.octets
        return [0x45, 0] + be16(20 + payload.count) + [0, 0, 0, 0, 64, proto, 0, 0] + s + d + payload
    }
    static func ip6(_ src: String, _ dst: String, _ next: UInt8, _ payload: [UInt8]) -> [UInt8] {
        [0x60, 0, 0, 0] + be16(payload.count) + [next, 64] + IPAddress(src)!.octets + IPAddress(dst)!.octets + payload
    }
    static func udp(_ sp: Int, _ dp: Int, _ payload: [UInt8]) -> [UInt8] { be16(sp) + be16(dp) + be16(8 + payload.count) + [0, 0] + payload }
    static func tcp(_ sp: Int, _ dp: Int, _ flags: UInt8, _ payload: [UInt8] = []) -> [UInt8] {
        be16(sp) + be16(dp) + be32(1) + be32(0) + [5 << 4, flags] + be16(65535) + [0, 0, 0, 0] + payload
    }
    static func name(_ n: String) -> [UInt8] {
        n.split(separator: ".").flatMap { [UInt8($0.utf8.count)] + Array($0.utf8) } + [0]
    }
    static func dnsQuery(_ n: String, type: Int = 1, id: Int = 1) -> [UInt8] {
        be16(id) + be16(0x0100) + be16(1) + be16(0) + be16(0) + be16(0) + name(n) + be16(type) + be16(1)
    }
    /// A response with a compressed answer name pointing back at the question (offset 12).
    static func dnsAnswer(_ n: String, _ addr: String) -> [UInt8] {
        be16(1) + be16(0x8180) + be16(1) + be16(1) + be16(0) + be16(0) + name(n) + be16(1) + be16(1)
            + [0xC0, 0x0C] + be16(1) + be16(1) + be32(60) + be16(4) + IPAddress(addr)!.octets
    }
    static func clientHello(sni: String) -> [UInt8] {
        let host = Array(sni.utf8)
        let sniExt = be16(0) + be16(host.count + 5) + be16(host.count + 3) + [0] + be16(host.count) + host
        let other = be16(0x000A) + be16(4) + [0, 2, 0, 0x1D]
        let exts = other + sniExt
        let body = [3, 3] + [UInt8](repeating: 0, count: 32) + [0] + be16(2) + [0x13, 0x01] + [1, 0] + be16(exts.count) + exts
        let hs = [1] + Array(be32(UInt32(body.count)).dropFirst()) + body
        return [0x16, 3, 1] + be16(hs.count) + hs
    }
}

extension FeatureExtractor {
    func feed(_ packet: [UInt8], at time: Double) -> [SignalSample] {
        packet.withUnsafeBytes { process(Bytes($0), wireLength: packet.count, linkType: 1, time: time) }
    }
}

@Suite struct PacketFeatureTests {
    let me = "192.168.1.20", router = "192.168.1.1", github = "140.82.121.4"

    @Test func lookupIsOneEventEvenForAAndAAAA() {
        let f = FeatureExtractor()
        let a = f.feed(Craft.eth(Craft.ip4(me, router, 17, Craft.udp(50000, 53, Craft.dnsQuery("GitHub.com")))), at: 0)
        let aaaa = f.feed(Craft.eth(Craft.ip4(me, router, 17, Craft.udp(50001, 53, Craft.dnsQuery("github.com", type: 28)))), at: 0.01)
        #expect(a == [.event("net.dns.query", key: "github.com")])
        #expect(aaaa.isEmpty)
        // After the dedupe window it counts again.
        #expect(f.feed(Craft.eth(Craft.ip4(me, router, 17, Craft.udp(50002, 53, Craft.dnsQuery("github.com")))), at: 3).count == 1)
    }

    @Test func handshakeIsNamedFromTheDNSAnswerAndCarriesTheRoundTrip() throws {
        let f = FeatureExtractor()
        _ = f.feed(Craft.eth(Craft.ip4(router, me, 17, Craft.udp(53, 50000, Craft.dnsAnswer("github.com", github)))), at: 0)
        #expect(f.feed(Craft.eth(Craft.ip4(me, github, 6, Craft.tcp(51000, 443, 0x02))), at: 1).isEmpty)
        let open = f.feed(Craft.eth(Craft.ip4(github, me, 6, Craft.tcp(443, 51000, 0x12))), at: 1.025)
        let e = try #require(open.first)
        #expect(e.id == "net.tcp.open" && e.key == "github.com")
        #expect(abs(e.value - 0.025) < 1e-9)
        // A SYN-ACK nobody asked for (we missed the SYN) is ignored.
        #expect(f.feed(Craft.eth(Craft.ip4(github, me, 6, Craft.tcp(443, 51001, 0x12))), at: 1.1).isEmpty)
    }

    @Test func closeIsReportedOnceForBothFINs() {
        let f = FeatureExtractor()
        _ = f.feed(Craft.eth(Craft.ip4(me, github, 6, Craft.tcp(51000, 443, 0x02))), at: 0)
        _ = f.feed(Craft.eth(Craft.ip4(github, me, 6, Craft.tcp(443, 51000, 0x12))), at: 0.02)
        let first = f.feed(Craft.eth(Craft.ip4(me, github, 6, Craft.tcp(51000, 443, 0x11))), at: 5)
        let second = f.feed(Craft.eth(Craft.ip4(github, me, 6, Craft.tcp(443, 51000, 0x11))), at: 5.01)
        #expect(first == [.event("net.tcp.close", key: github, 0)])
        #expect(second.isEmpty)
    }

    @Test func resetIsACloseWithValueOne() {
        let f = FeatureExtractor()
        _ = f.feed(Craft.eth(Craft.ip4(me, github, 6, Craft.tcp(51000, 443, 0x02))), at: 0)
        _ = f.feed(Craft.eth(Craft.ip4(github, me, 6, Craft.tcp(443, 51000, 0x12))), at: 0.02)
        #expect(f.feed(Craft.eth(Craft.ip4(github, me, 6, Craft.tcp(443, 51000, 0x04))), at: 1).first?.value == 1)
    }

    @Test func tlsServerNameNamesTheServer() {
        let f = FeatureExtractor()
        let out = f.feed(Craft.eth(Craft.ip4(me, github, 6, Craft.tcp(51000, 443, 0x18, Craft.clientHello(sni: "api.github.com")))), at: 0)
        #expect(out == [.event("net.tls.hello", key: "api.github.com")])
        #expect(f.name(for: IPAddress(github)!) == "api.github.com")
    }

    @Test func quicRoundTripFromFirstInitialToReply() throws {
        let f = FeatureExtractor()
        let initial: [UInt8] = [0xC3, 0, 0, 0, 1] + [UInt8](repeating: 0, count: 20)
        let reply: [UInt8] = [0xC1, 0, 0, 0, 1] + [UInt8](repeating: 0, count: 20)
        _ = f.feed(Craft.eth(Craft.ip4(me, "142.250.1.1", 17, Craft.udp(52000, 443, initial))), at: 0)
        _ = f.feed(Craft.eth(Craft.ip4(me, "142.250.1.1", 17, Craft.udp(52000, 443, initial))), at: 0.005) // retransmit keeps the first time
        let e = try #require(f.feed(Craft.eth(Craft.ip4("142.250.1.1", me, 17, Craft.udp(443, 52000, reply))), at: 0.018).first)
        #expect(e.id == "net.quic.open")
        #expect(abs(e.value - 0.018) < 1e-9)
        // Later long-header packets on the same connection don't reopen it.
        _ = f.feed(Craft.eth(Craft.ip4(me, "142.250.1.1", 17, Craft.udp(52000, 443, initial))), at: 0.1)
        #expect(f.feed(Craft.eth(Craft.ip4("142.250.1.1", me, 17, Craft.udp(443, 52000, reply))), at: 0.12).isEmpty)
    }

    @Test func ipv6HandshakeWorks() {
        let f = FeatureExtractor()
        let a = "2001:db8::20", b = "2606:50c0:8000::153"
        _ = f.feed(Craft.eth(Craft.ip6(a, b, 6, Craft.tcp(51000, 443, 0x02)), v6: true), at: 0)
        let out = f.feed(Craft.eth(Craft.ip6(b, a, 6, Craft.tcp(443, 51000, 0x12)), v6: true), at: 0.03)
        #expect(out.first?.key == "2606:50c0:8000::153")
    }

    @Test func lanAnnouncementsAreNamed() {
        let f = FeatureExtractor()
        let mdns = f.feed(Craft.eth(Craft.ip4(me, "224.0.0.251", 17, Craft.udp(5353, 5353, Craft.dnsQuery("_airplay._tcp.local", type: 12, id: 0)))), at: 0)
        #expect(mdns == [.event("net.lan.announce", key: "_airplay._tcp")])
        let ssdp = Array("NOTIFY * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nNT: upnp:rootdevice\r\n\r\n".utf8)
        let s = f.feed(Craft.eth(Craft.ip4("192.168.1.30", "239.255.255.250", 17, Craft.udp(1900, 1900, ssdp))), at: 0.1)
        #expect(s == [.event("net.lan.announce", key: "upnp:rootdevice")])
    }

    @Test func streamsReportRatesPerCategory() {
        let f = FeatureExtractor()
        #expect(f.streams(at: 0).isEmpty) // starts the clock
        let p = Craft.eth(Craft.ip4(me, github, 6, Craft.tcp(51000, 443, 0x10)))
        for i in 0..<10 { _ = f.feed(p, at: Double(i) / 10) }
        #expect(f.streams(at: 0.5).isEmpty) // not a second yet
        let s = f.streams(at: 2)
        #expect(s.first == .stream("net.pkt.perSec", 5))
        #expect(s.contains(.stream("net.proto.bytesPerSec", key: "tcp", Double(p.count * 10) / 2)))
        #expect(s.contains(.stream("net.proto.bytesPerSec", key: "quic", 0)))
    }

    @Test func truncatedAndForeignPacketsAreHarmless() {
        let f = FeatureExtractor()
        let full = Craft.eth(Craft.ip4(me, router, 17, Craft.udp(50000, 53, Craft.dnsQuery("example.org"))))
        for n in 0..<full.count { _ = f.feed(Array(full.prefix(n)), at: 0) } // every truncation
        _ = f.feed([UInt8](repeating: 0xFF, count: 200), at: 0)
        _ = f.feed(Craft.eth([0x45] + [UInt8](repeating: 0, count: 10)), at: 0)
        // A self-referencing compression pointer must not loop forever.
        let loop = Craft.be16(1) + Craft.be16(0x0100) + Craft.be16(1) + [0, 0, 0, 0, 0, 0] + [0xC0, 0x0C]
        _ = f.feed(Craft.eth(Craft.ip4(me, router, 17, Craft.udp(50000, 53, loop))), at: 0)
    }
}
