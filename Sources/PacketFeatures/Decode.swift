import Darwin
import Foundation

/// An IPv4 or IPv6 address, stored without allocating (hot path: every packet).
public struct IPAddress: Hashable, Sendable, CustomStringConvertible {
    public var hi: UInt64
    public var lo: UInt64
    public var isV6: Bool

    public init(v4 bytes: Bytes, at offset: Int) {
        hi = 0
        lo = UInt64(bytes.u32(offset) ?? 0)
        isV6 = false
    }

    public init(v6 bytes: Bytes, at offset: Int) {
        hi = (UInt64(bytes.u32(offset) ?? 0) << 32) | UInt64(bytes.u32(offset + 4) ?? 0)
        lo = (UInt64(bytes.u32(offset + 8) ?? 0) << 32) | UInt64(bytes.u32(offset + 12) ?? 0)
        isV6 = true
    }

    /// From text, for tests ("192.168.1.2", "2001:db8::1").
    public init?(_ text: String) {
        var a4 = in_addr()
        var a6 = in6_addr()
        if inet_pton(AF_INET, text, &a4) == 1 {
            hi = 0
            lo = UInt64(UInt32(bigEndian: a4.s_addr))
            isV6 = false
        } else if inet_pton(AF_INET6, text, &a6) == 1 {
            let b = withUnsafeBytes(of: &a6) { [UInt8]($0) }
            hi = b[0..<8].reduce(0) { $0 << 8 | UInt64($1) }
            lo = b[8..<16].reduce(0) { $0 << 8 | UInt64($1) }
            isV6 = true
        } else {
            return nil
        }
    }

    public var octets: [UInt8] {
        if isV6 {
            return (0..<8).map { UInt8(truncatingIfNeeded: hi >> (56 - 8 * $0)) }
                + (0..<8).map { UInt8(truncatingIfNeeded: lo >> (56 - 8 * $0)) }
        }
        return (0..<4).map { UInt8(truncatingIfNeeded: lo >> (24 - 8 * $0)) }
    }

    public var isMulticastOrBroadcast: Bool {
        isV6 ? (hi >> 56) == 0xFF : (lo >> 28) == 0xE || lo == 0xFFFF_FFFF
    }

    public var description: String {
        if !isV6 { return octets.map(String.init).joined(separator: ".") }
        var a6 = in6_addr()
        withUnsafeMutableBytes(of: &a6) { $0.copyBytes(from: octets) }
        var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        inet_ntop(AF_INET6, &a6, &buf, socklen_t(buf.count))
        return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

/// Bounds-checked big-endian reads over captured bytes. A view: only valid while the
/// underlying buffer is (one pcap callback, or inside `withUnsafeBytes`).
public struct Bytes {
    public let raw: UnsafeRawBufferPointer

    public init(_ raw: UnsafeRawBufferPointer) { self.raw = raw }

    public var count: Int { raw.count }
    public func u8(_ i: Int) -> UInt8? { i >= 0 && i < raw.count ? raw[i] : nil }
    public func u16(_ i: Int) -> UInt16? {
        guard i >= 0, i + 2 <= raw.count else { return nil }
        return UInt16(raw[i]) << 8 | UInt16(raw[i + 1])
    }
    public func u32(_ i: Int) -> UInt32? {
        guard i >= 0, i + 4 <= raw.count else { return nil }
        return UInt32(raw[i]) << 24 | UInt32(raw[i + 1]) << 16 | UInt32(raw[i + 2]) << 8 | UInt32(raw[i + 3])
    }
    public func slice(_ from: Int, _ to: Int? = nil) -> Bytes {
        let end = min(to ?? raw.count, raw.count)
        let start = min(max(from, 0), end)
        return Bytes(UnsafeRawBufferPointer(rebasing: raw[start..<end]))
    }
    public func string(_ from: Int, _ length: Int) -> String? {
        guard from >= 0, length >= 0, from + length <= raw.count else { return nil }
        return String(decoding: raw[from..<(from + length)], as: UTF8.self)
    }
}

/// The parts of a packet the features need.
public struct PacketInfo {
    public enum Transport { case tcp(flags: UInt8), udp, other }

    public var src: IPAddress
    public var dst: IPAddress
    public var srcPort: UInt16
    public var dstPort: UInt16
    public var transport: Transport
    /// Transport payload (TCP/UDP data), as captured (may be truncated by the snap length).
    public var payload: Bytes
}

/// pcap link-layer types we can decode.
public enum LinkType: Int32, Sendable {
    case null = 0       // BSD loopback: 4-byte host-order address family
    case ethernet = 1
    case raw = 12       // raw IP (12 on macOS; 101 on others)
    case rawAlt = 101
    case loop = 108     // OpenBSD loopback: 4-byte network-order family
}

public enum PacketDecoder {
    public static func decode(_ bytes: Bytes, linkType: Int32) -> PacketInfo? {
        switch LinkType(rawValue: linkType) {
        case .ethernet:
            guard var type = bytes.u16(12) else { return nil }
            var offset = 14
            while type == 0x8100 || type == 0x88A8 { // VLAN tags
                guard let inner = bytes.u16(offset + 2) else { return nil }
                type = inner
                offset += 4
            }
            switch type {
            case 0x0800: return ipv4(bytes.slice(offset))
            case 0x86DD: return ipv6(bytes.slice(offset))
            default: return nil
            }
        case .null, .loop:
            return ip(bytes.slice(4))
        case .raw, .rawAlt:
            return ip(bytes)
        case nil:
            return nil
        }
    }

    /// IPv4 or IPv6, by version nibble.
    static func ip(_ b: Bytes) -> PacketInfo? {
        switch (b.u8(0) ?? 0) >> 4 {
        case 4: ipv4(b)
        case 6: ipv6(b)
        default: nil
        }
    }

    static func ipv4(_ b: Bytes) -> PacketInfo? {
        guard let vihl = b.u8(0), vihl >> 4 == 4, let proto = b.u8(9), let frag = b.u16(6) else { return nil }
        let headerLength = Int(vihl & 0x0F) * 4
        guard headerLength >= 20 else { return nil }
        let src = IPAddress(v4: b, at: 12), dst = IPAddress(v4: b, at: 16)
        // Later fragments carry no transport header.
        if frag & 0x1FFF != 0 { return PacketInfo(src: src, dst: dst, srcPort: 0, dstPort: 0, transport: .other, payload: b.slice(b.count)) }
        let total = Int(b.u16(2) ?? 0)
        let end = total >= headerLength ? total : b.count
        return transport(proto, b.slice(headerLength, end), src: src, dst: dst)
    }

    static func ipv6(_ b: Bytes) -> PacketInfo? {
        guard (b.u8(0) ?? 0) >> 4 == 6, var next = b.u8(6), let payloadLength = b.u16(4) else { return nil }
        let src = IPAddress(v6: b, at: 8), dst = IPAddress(v6: b, at: 24)
        var offset = 40
        let end = 40 + Int(payloadLength)
        // Skip extension headers: hop-by-hop, routing, destination options; stop at fragments.
        while [0, 43, 60].contains(next) {
            guard let n = b.u8(offset), let len = b.u8(offset + 1) else { return nil }
            next = n
            offset += 8 + Int(len) * 8
        }
        return transport(next, b.slice(offset, end), src: src, dst: dst)
    }

    static func transport(_ proto: UInt8, _ b: Bytes, src: IPAddress, dst: IPAddress) -> PacketInfo? {
        switch proto {
        case 6:
            guard let sp = b.u16(0), let dp = b.u16(2), let off = b.u8(12), let flags = b.u8(13) else { return nil }
            return PacketInfo(src: src, dst: dst, srcPort: sp, dstPort: dp, transport: .tcp(flags: flags),
                              payload: b.slice(Int(off >> 4) * 4))
        case 17:
            guard let sp = b.u16(0), let dp = b.u16(2) else { return nil }
            return PacketInfo(src: src, dst: dst, srcPort: sp, dstPort: dp, transport: .udp, payload: b.slice(8))
        default:
            return PacketInfo(src: src, dst: dst, srcPort: 0, dstPort: 0, transport: .other, payload: b.slice(b.count))
        }
    }
}

// MARK: - DNS

public struct DNSMessage: Equatable {
    public var isResponse: Bool
    public var questions: [(name: String, type: UInt16)]
    /// A / AAAA answers.
    public var addresses: [IPAddress]
    /// Every answer's owner name (mDNS announcements put the interesting name here).
    public var answerNames: [String]

    public static func == (a: DNSMessage, b: DNSMessage) -> Bool {
        a.isResponse == b.isResponse && a.questions.map(\.name) == b.questions.map(\.name)
            && a.questions.map(\.type) == b.questions.map(\.type) && a.addresses == b.addresses && a.answerNames == b.answerNames
    }

    public static func parse(_ b: Bytes) -> DNSMessage? {
        guard let flags = b.u16(2), let qd = b.u16(4), let an = b.u16(6) else { return nil }
        var msg = DNSMessage(isResponse: flags & 0x8000 != 0, questions: [], addresses: [], answerNames: [])
        var offset = 12
        for _ in 0..<min(Int(qd), 16) {
            guard let (name, next) = readName(b, offset), let type = b.u16(next) else { return msg }
            msg.questions.append((name, type))
            offset = next + 4
        }
        for _ in 0..<min(Int(an), 64) {
            guard let (name, next) = readName(b, offset), let type = b.u16(next), let rdLength = b.u16(next + 8) else { return msg }
            let rdata = next + 10
            msg.answerNames.append(name)
            if type == 1, rdLength == 4, rdata + 4 <= b.count { msg.addresses.append(IPAddress(v4: b, at: rdata)) }
            if type == 28, rdLength == 16, rdata + 16 <= b.count { msg.addresses.append(IPAddress(v6: b, at: rdata)) }
            offset = rdata + Int(rdLength)
        }
        return msg
    }

    /// A possibly-compressed name; returns it and the offset just past it (in the original position).
    static func readName(_ b: Bytes, _ start: Int) -> (String, Int)? {
        var labels: [String] = []
        var offset = start
        var resume: Int?
        var hops = 0
        while true {
            guard let len = b.u8(offset) else { return nil }
            if len == 0 { offset += 1; break }
            if len & 0xC0 == 0xC0 {
                guard let ptr = b.u16(offset), hops < 16 else { return nil }
                if resume == nil { resume = offset + 2 }
                offset = Int(ptr & 0x3FFF)
                hops += 1
                continue
            }
            guard let label = b.string(offset + 1, Int(len)) else { return nil }
            labels.append(label)
            offset += 1 + Int(len)
        }
        return (labels.joined(separator: "."), resume ?? offset)
    }
}

// MARK: - TLS

public enum TLSClientHello {
    /// The server name (SNI) from a TLS ClientHello at the start of a TCP payload, if present
    /// in the captured bytes.
    public static func serverName(_ b: Bytes) -> String? {
        // Record: type 22 (handshake), version 3.x; handshake type 1 (ClientHello).
        guard b.u8(0) == 0x16, b.u8(1) == 0x03, b.u8(5) == 0x01 else { return nil }
        var o = 5 + 4 + 2 + 32 // record hdr, handshake hdr, client version, random
        guard let sid = b.u8(o) else { return nil }
        o += 1 + Int(sid)
        guard let suites = b.u16(o) else { return nil }
        o += 2 + Int(suites)
        guard let comp = b.u8(o) else { return nil }
        o += 1 + Int(comp)
        guard let extLength = b.u16(o) else { return nil }
        o += 2
        let end = min(o + Int(extLength), b.count)
        while o + 4 <= end {
            guard let type = b.u16(o), let len = b.u16(o + 2) else { return nil }
            if type == 0 { // server_name: list length, name type (0 = host), name length, name
                guard b.u8(o + 6) == 0, let nameLength = b.u16(o + 7) else { return nil }
                return b.string(o + 9, Int(nameLength))
            }
            o += 4 + Int(len)
        }
        return nil
    }
}
