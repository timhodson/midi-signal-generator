import Darwin
import Foundation
import OSC
import SignalBus

/// Receives signal samples as OSC over UDP (see `SignalSample.init(osc:)` for the addresses).
/// The packet capture helper sends here; so can a Raspberry Pi, a sensor bridge or TouchOSC.
public final class OSCSource: SignalSource, @unchecked Sendable {
    public static let defaultPort: UInt16 = 57121

    public let name: String
    public let port: UInt16
    /// Bind address: "127.0.0.1" (this Mac only) or "0.0.0.0" (accept from the LAN).
    public let bindAddress: String
    private var fd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "msg.osc")

    /// Binds the port straight away, so a clash (another copy running) is reported here.
    public init(port: UInt16 = OSCSource.defaultPort, bindAddress: String = "127.0.0.1") throws {
        self.port = port
        self.bindAddress = bindAddress
        name = "osc:\(port)"
        fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw SourceError.failed("OSC socket: \(String(cString: strerror(errno)))") }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr(bindAddress)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard ok == 0 else {
            let reason = String(cString: strerror(errno))
            close(fd)
            fd = -1
            throw SourceError.failed("cannot listen for OSC on \(bindAddress):\(port): \(reason) (is another copy running?)")
        }
    }

    deinit { if readSource == nil, fd >= 0 { close(fd) } }

    public func start(emit: @escaping @Sendable ([SignalSample]) -> Void) throws {
        guard fd >= 0 else { throw SourceError.failed("OSC source already stopped") }
        let fd = self.fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler {
            var buffer = [UInt8](repeating: 0, count: 65_536)
            var batch: [SignalSample] = []
            // Drain everything waiting, so a burst becomes one batch.
            while true {
                let n = recv(fd, &buffer, buffer.count, MSG_DONTWAIT)
                guard n > 0 else { break }
                for message in OSCMessage.decode(Data(buffer[0..<n])) {
                    if let s = SignalSample(osc: message) { batch.append(s) }
                }
            }
            if !batch.isEmpty { emit(batch) }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        readSource = source
    }

    public func stop() {
        readSource?.cancel()
        readSource = nil
        fd = -1
    }
}
