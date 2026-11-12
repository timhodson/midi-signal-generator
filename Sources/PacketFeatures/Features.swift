import Foundation
import SignalBus

/// Turns captured packets into musical *features* (ADR 0008: features, not packets, leave the
/// capture process). Payloads are only looked at for names: DNS questions/answers, the TLS
/// server name, mDNS/SSDP announcements.
///
/// Events (one per occurrence):
/// - `net.dns.query`      key = name looked up
/// - `net.tcp.open`       key = server name, value = handshake round trip (s), SYN → SYN-ACK
/// - `net.quic.open`      key = server name, value = round trip (s), first Initial → reply
/// - `net.tcp.close`      key = server name, value 0 = FIN, 1 = RST
/// - `net.tls.hello`      key = server name from the ClientHello
/// - `net.lan.announce`   key = mDNS / SSDP / LLMNR name ("_airplay._tcp", "upnp:rootdevice")
///
/// Streams (every `streamInterval` seconds):
/// - `net.pkt.perSec`, `net.flows.tcp` (open TCP connections seen opening),
/// - `net.proto.bytesPerSec` keyed tcp / quic / dns / lan / udp / other.
public final class FeatureExtractor {
    public static let categories = ["tcp", "quic", "dns", "lan", "udp", "other"]
    public var streamInterval: Double = 1

    struct Flow: Hashable {
        var client: IPAddress
        var clientPort: UInt16
        var server: IPAddress
        var serverPort: UInt16
        var reversed: Flow { Flow(client: server, clientPort: serverPort, server: client, serverPort: clientPort) }
    }

    /// Address → name, learned from DNS answers and TLS server names.
    private(set) var names: [IPAddress: String] = [:]
    private var pendingSyn: [Flow: Double] = [:]
    private var openTCP: [Flow: Double] = [:] // flow -> last seen
    private var pendingQuic: [Flow: Double] = [:]
    private var answeredQuic: [Flow: Double] = [:]
    /// Same name + kind within this many seconds counts once (A + AAAA + HTTPS lookups, repeated announcements).
    public var dedupeWindow: Double = 2
    private var recent: [String: Double] = [:]

    private var packets = 0
    private var bytes: [String: Double] = [:]
    private var lastStreams: Double?
    private var lastPrune: Double = 0

    public init() {}

    public func name(for ip: IPAddress) -> String { names[ip] ?? ip.description }

    /// Process one captured packet. `wireLength` is its length on the wire (may exceed `bytes.count`).
    public func process(_ bytes: Bytes, wireLength: Int, linkType: Int32, time: Double) -> [SignalSample] {
        packets += 1
        guard let p = PacketDecoder.decode(bytes, linkType: linkType) else {
            self.bytes["other", default: 0] += Double(wireLength)
            return []
        }
        var out: [SignalSample] = []
        let lanPorts: Set<UInt16> = [5353, 1900, 5355, 137, 138]

        switch p.transport {
        case .tcp(let flags):
            self.bytes[p.srcPort == 53 || p.dstPort == 53 ? "dns" : "tcp", default: 0] += Double(wireLength)
            tcp(p, flags: flags, time: time, into: &out)
        case .udp:
            let category: String
            if p.srcPort == 53 || p.dstPort == 53 {
                category = "dns"
                dns(p, time: time, into: &out)
            } else if lanPorts.contains(p.dstPort) || p.dst.isMulticastOrBroadcast {
                category = "lan"
                lan(p, time: time, into: &out)
            } else if p.dstPort == 443 || p.srcPort == 443 {
                category = "quic"
                quic(p, time: time, into: &out)
            } else {
                category = "udp"
            }
            self.bytes[category, default: 0] += Double(wireLength)
        case .other:
            self.bytes[p.dst.isMulticastOrBroadcast ? "lan" : "other", default: 0] += Double(wireLength)
        }
        if time - lastPrune > 10 { prune(time) }
        return out.map { var s = $0; s.time = 0; return s }
    }

    /// Rate streams, if `streamInterval` has passed since the last ones. Call often (e.g. per batch).
    public func streams(at time: Double) -> [SignalSample] {
        guard let last = lastStreams else { lastStreams = time; return [] }
        let dt = time - last
        guard dt >= streamInterval else { return [] }
        lastStreams = time
        var out: [SignalSample] = [
            .stream("net.pkt.perSec", Double(packets) / dt),
            .stream("net.flows.tcp", Double(openTCP.count)),
        ]
        for c in Self.categories { out.append(.stream("net.proto.bytesPerSec", key: c, (bytes[c] ?? 0) / dt)) }
        packets = 0
        bytes.removeAll(keepingCapacity: true)
        return out
    }

    // MARK: - Protocols

    private func tcp(_ p: PacketInfo, flags: UInt8, time: Double, into out: inout [SignalSample]) {
        let syn = flags & 0x02 != 0, ack = flags & 0x10 != 0, fin = flags & 0x01 != 0, rst = flags & 0x04 != 0
        let flow = Flow(client: p.src, clientPort: p.srcPort, server: p.dst, serverPort: p.dstPort)
        if syn, !ack {
            pendingSyn[flow] = time
            return
        }
        if syn, ack {
            let client = flow.reversed
            if let sent = pendingSyn.removeValue(forKey: client) {
                openTCP[client] = time
                out.append(.event("net.tcp.open", key: name(for: client.server), max(time - sent, 0)))
            }
            return
        }
        let known = openTCP[flow] != nil ? flow : openTCP[flow.reversed] != nil ? flow.reversed : nil
        if fin || rst {
            if let f = known {
                openTCP[f] = nil
                out.append(.event("net.tcp.close", key: name(for: f.server), rst ? 1 : 0))
            }
            return
        }
        if let f = known { openTCP[f] = time }
        // The first data from the client to an HTTPS port: the TLS server name.
        if p.payload.count > 0, [443, 8443, 853].contains(p.dstPort), p.payload.u8(0) == 0x16,
           let sni = TLSClientHello.serverName(p.payload), !sni.isEmpty {
            names[p.dst] = sni
            if fresh("tls:" + sni, time) { out.append(.event("net.tls.hello", key: sni)) }
        }
    }

    private func dns(_ p: PacketInfo, time: Double, into out: inout [SignalSample]) {
        guard let m = DNSMessage.parse(p.payload), let q = m.questions.first else { return }
        let name = q.name.lowercased()
        if m.isResponse {
            for a in m.addresses { names[a] = name }
        } else if p.dstPort == 53, fresh("dns:" + name, time) {
            out.append(.event("net.dns.query", key: name))
        }
    }

    private func lan(_ p: PacketInfo, time: Double, into out: inout [SignalSample]) {
        var label: String?
        switch p.dstPort {
        case 5353, 5355:
            if let m = DNSMessage.parse(p.payload) {
                label = (m.questions.first?.name ?? m.answerNames.first).map(Self.trimLocal)
            }
        case 1900:
            label = Self.ssdpTarget(p.payload) ?? "SSDP"
        case 137, 138:
            label = "NetBIOS"
        default:
            label = nil
        }
        if let label, !label.isEmpty, fresh("lan:" + label, time) {
            out.append(.event("net.lan.announce", key: label))
        }
    }

    private func quic(_ p: PacketInfo, time: Double, into out: inout [SignalSample]) {
        guard let first = p.payload.u8(0), first & 0x80 != 0, let version = p.payload.u32(1), version != 0 else { return }
        let isInitial = (first >> 4) & 0x03 == 0
        if p.dstPort == 443 {
            let flow = Flow(client: p.src, clientPort: p.srcPort, server: p.dst, serverPort: p.dstPort)
            if isInitial, pendingQuic[flow] == nil, answeredQuic[flow] == nil { pendingQuic[flow] = time }
        } else if p.srcPort == 443 {
            let flow = Flow(client: p.dst, clientPort: p.dstPort, server: p.src, serverPort: p.srcPort)
            if let sent = pendingQuic.removeValue(forKey: flow) {
                answeredQuic[flow] = time
                out.append(.event("net.quic.open", key: name(for: flow.server), max(time - sent, 0)))
            }
        }
    }

    // MARK: - Helpers

    private func fresh(_ key: String, _ time: Double) -> Bool {
        if let last = recent[key], time - last < dedupeWindow { return false }
        recent[key] = time
        return true
    }

    private func prune(_ time: Double) {
        lastPrune = time
        pendingSyn = pendingSyn.filter { time - $0.value < 10 }
        pendingQuic = pendingQuic.filter { time - $0.value < 10 }
        answeredQuic = answeredQuic.filter { time - $0.value < 600 }
        openTCP = openTCP.filter { time - $0.value < 900 }
        recent = recent.filter { time - $0.value < dedupeWindow }
        if names.count > 20_000 { names.removeAll(keepingCapacity: true) }
    }

    static func trimLocal(_ name: String) -> String {
        name.hasSuffix(".local") ? String(name.dropLast(".local".count)) : name
    }

    /// The ST (search target) or NT (notification type) header of an SSDP message.
    static func ssdpTarget(_ b: Bytes) -> String? {
        guard let text = b.string(0, min(b.count, 1500)) else { return nil }
        for line in text.split(whereSeparator: \.isNewline) {
            let lower = line.lowercased()
            if lower.hasPrefix("st:") || lower.hasPrefix("nt:") {
                return line.dropFirst(3).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}
