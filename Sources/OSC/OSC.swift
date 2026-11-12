import Foundation
import SignalBus

/// A minimal Open Sound Control 1.0 codec: messages with string / float32 / int32 / float64
/// arguments, and bundles (flattened, time tags ignored). Enough for sources to send signal
/// features to the engine (docs/decisions/0008-sources-behind-a-protocol-osc-later.md).
public struct OSCMessage: Sendable, Equatable {
    public enum Argument: Sendable, Equatable {
        case string(String)
        case float(Float)
        case int(Int32)
        case double(Double)

        public var number: Double? {
            switch self {
            case .float(let f): Double(f)
            case .int(let i): Double(i)
            case .double(let d): d
            case .string: nil
            }
        }
    }

    public var address: String
    public var arguments: [Argument]

    public init(_ address: String, _ arguments: [Argument] = []) {
        self.address = address
        self.arguments = arguments
    }

    public func encoded() -> Data {
        var data = Data()
        Self.appendString(address, to: &data)
        var tags = ","
        for a in arguments {
            switch a {
            case .string: tags += "s"
            case .float: tags += "f"
            case .int: tags += "i"
            case .double: tags += "d"
            }
        }
        Self.appendString(tags, to: &data)
        for a in arguments {
            switch a {
            case .string(let s): Self.appendString(s, to: &data)
            case .float(let f): Self.appendBigEndian(f.bitPattern, to: &data)
            case .int(let i): Self.appendBigEndian(UInt32(bitPattern: i), to: &data)
            case .double(let d): Self.appendBigEndian(d.bitPattern, to: &data)
            }
        }
        return data
    }

    /// Decode a packet: one message, or a bundle of messages (possibly nested).
    public static func decode(_ data: Data) -> [OSCMessage] {
        var reader = Reader(bytes: [UInt8](data))
        return reader.packet(length: data.count)
    }

    private static func appendString(_ s: String, to data: inout Data) {
        data.append(contentsOf: Array(s.utf8))
        data.append(0)
        while data.count % 4 != 0 { data.append(0) }
    }

    private static func appendBigEndian<T: FixedWidthInteger>(_ v: T, to data: inout Data) {
        withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) }
    }

    private struct Reader {
        let bytes: [UInt8]
        var pos = 0

        mutating func packet(length: Int) -> [OSCMessage] {
            let end = pos + length
            guard end <= bytes.count, length >= 4 else { return [] }
            if bytes[pos] == UInt8(ascii: "#") {
                guard string() == "#bundle", pos + 8 <= end else { return [] }
                pos += 8 // time tag
                var out: [OSCMessage] = []
                while pos + 4 <= end {
                    guard let size = int32().map(Int.init), size > 0, pos + size <= end else { break }
                    let next = pos + size
                    out += packet(length: size)
                    pos = next
                }
                return out
            }
            guard let address = string(), address.hasPrefix("/") else { return [] }
            guard pos < end, let tags = string(), tags.hasPrefix(",") else { return [OSCMessage(address)] }
            var args: [Argument] = []
            for tag in tags.dropFirst() {
                switch tag {
                case "s", "S": guard let s = string() else { return [] }; args.append(.string(s))
                case "f": guard let v = int32() else { return [] }; args.append(.float(Float(bitPattern: UInt32(bitPattern: v))))
                case "i": guard let v = int32() else { return [] }; args.append(.int(v))
                case "d":
                    guard let hi = int32(), let lo = int32() else { return [] }
                    let bits = UInt64(UInt32(bitPattern: hi)) << 32 | UInt64(UInt32(bitPattern: lo))
                    args.append(.double(Double(bitPattern: bits)))
                case "T": args.append(.int(1))
                case "F", "N", "I": args.append(.int(0))
                default: return [OSCMessage(address, args)] // unknown type: stop, keep what we have
                }
            }
            return [OSCMessage(address, args)]
        }

        mutating func string() -> String? {
            guard let zero = bytes[pos...].firstIndex(of: 0) else { return nil }
            let s = String(decoding: bytes[pos..<zero], as: UTF8.self)
            pos = (zero + 4) & ~3
            return s
        }

        mutating func int32() -> Int32? {
            guard pos + 4 <= bytes.count else { return nil }
            let v = UInt32(bytes[pos]) << 24 | UInt32(bytes[pos + 1]) << 16 | UInt32(bytes[pos + 2]) << 8 | UInt32(bytes[pos + 3])
            pos += 4
            return Int32(bitPattern: v)
        }
    }
}

// MARK: - Signals over OSC

/// How signal samples travel as OSC:
///
///   /stream/<id> [key] value      e.g. /stream/net.pkt.perSec 230.0
///   /event/<id>  [key] value      e.g. /event/net.dns.query "github.com" 1.0
///
/// Any other address is read as a stream whose id is the path with slashes turned into dots,
/// so a hand-made controller can send `/net/app/bytesPerSec "Spotify" 1234.0`.
extension SignalSample {
    public var oscMessage: OSCMessage {
        let prefix = kind == .event ? "/event/" : "/stream/"
        var args: [OSCMessage.Argument] = []
        if let key { args.append(.string(key)) }
        args.append(.double(value))
        return OSCMessage(prefix + id, args)
    }

    public init?(osc message: OSCMessage) {
        let address = message.address
        let kind: Kind
        let id: String
        if address.hasPrefix("/event/") {
            kind = .event
            id = String(address.dropFirst("/event/".count))
        } else if address.hasPrefix("/stream/") {
            kind = .stream
            id = String(address.dropFirst("/stream/".count))
        } else {
            kind = .stream
            id = address.split(separator: "/").joined(separator: ".")
        }
        guard !id.isEmpty else { return nil }
        let key = message.arguments.first.flatMap { if case .string(let s) = $0 { s } else { nil } }
        let value = message.arguments.lazy.compactMap(\.number).first ?? (kind == .event ? 1 : 0)
        self.init(kind, id, key: key, value: value)
    }
}

// MARK: - UDP sending

/// Sends OSC messages over UDP (fire and forget). Used by the packet capture helper.
public final class OSCSender: @unchecked Sendable {
    private let fd: Int32
    private var address: sockaddr_storage
    private let length: socklen_t

    /// `host` is an IPv4 or IPv6 literal or a name ("127.0.0.1", "localhost").
    public init(host: String, port: UInt16) throws {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_DGRAM
        hints.ai_protocol = IPPROTO_UDP
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &result) == 0, let info = result else {
            throw OSCError.failed("cannot resolve \(host)")
        }
        defer { freeaddrinfo(result) }
        fd = socket(info.pointee.ai_family, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw OSCError.failed("socket: \(String(cString: strerror(errno)))") }
        address = sockaddr_storage()
        length = info.pointee.ai_addrlen
        withUnsafeMutableBytes(of: &address) { dst in
            dst.copyMemory(from: UnsafeRawBufferPointer(start: info.pointee.ai_addr, count: Int(info.pointee.ai_addrlen)))
        }
    }

    deinit { close(fd) }

    /// Send one datagram. Returns false if the OS refused (nobody listening is not an error for UDP).
    @discardableResult
    public func send(_ message: OSCMessage) -> Bool {
        let data = message.encoded()
        return data.withUnsafeBytes { buf in
            withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, buf.baseAddress, buf.count, 0, $0, length) == buf.count
                }
            }
        }
    }
}

public enum OSCError: Error, CustomStringConvertible {
    case failed(String)
    public var description: String {
        switch self { case .failed(let s): s }
    }
}
