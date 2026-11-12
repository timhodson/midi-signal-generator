import Darwin
import Foundation
import SignalBus

/// Parses `nettop -P -d -L 0 -s N -J bytes_in,bytes_out -x` output.
///
/// The output is a series of CSV blocks, each starting with the header ",bytes_in,bytes_out,".
/// The first block holds cumulative totals since boot and is skipped; every later block holds
/// per-process byte deltas for the last interval. Rows look like "Brave Browser H.10275,1234,56,".
/// Names are truncated by nettop (~15 chars) and may contain spaces and dots, so the pid is
/// split off at the *last* dot. Helper processes with the same name are summed.
public struct NettopParser: Sendable {
    public struct Snapshot: Sendable, Equatable {
        /// App name -> bytes in + out during the interval.
        public var bytesByApp: [String: Double]
        public var total: Double { bytesByApp.values.reduce(0, +) }
    }

    private var current: [String: Double]?
    private var blocksSeen = 0

    public init() {}

    /// Feed one line; returns a completed snapshot when a new block header closes the previous one.
    public mutating func feed(line raw: String) -> Snapshot? {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }

        if line.hasPrefix(",bytes_in") {
            defer {
                blocksSeen += 1
                current = [:]
            }
            // Block 1 is totals-since-boot; only emit deltas (block 2 onwards).
            guard blocksSeen >= 2, let finished = current else { return nil }
            return Snapshot(bytesByApp: finished)
        }

        guard current != nil else { return nil }
        let fields = line.split(separator: ",", omittingEmptySubsequences: false)
        guard fields.count >= 3,
              let bytesIn = Double(fields[fields.count - 3]),
              let bytesOut = Double(fields[fields.count - 2])
        else { return nil }
        let nameAndPid = fields[0..<(fields.count - 3)].joined(separator: ",")
        let name: String
        if let dot = nameAndPid.lastIndex(of: "."), Int(nameAndPid[nameAndPid.index(after: dot)...]) != nil {
            name = String(nameAndPid[..<dot]).trimmingCharacters(in: .whitespaces)
        } else {
            name = nameAndPid
        }
        let bytes = bytesIn + bytesOut
        if bytes > 0 { current?[name, default: 0] += bytes }
        return nil
    }
}

/// Per-app network traffic for this Mac, without root, by running `nettop`.
///
/// nettop block-buffers when its stdout is a pipe, so it is run on a pseudo-terminal to get
/// one block per interval (docs/decisions/0004-local-traffic-via-nettop.md).
///
/// Emits streams:
/// - `net.total.bytesPerSec`
/// - `net.app.bytesPerSec` keyed by app name (apps that go quiet are sent as 0 once)
public final class NettopSource: SignalSource, @unchecked Sendable {
    public let name = "nettop"
    public let interval: Int
    private var process: Process?
    private var master: FileHandle?
    private let lock = NSLock()

    public init(interval: Int = 1) { self.interval = max(interval, 1) }

    public func start(emit: @escaping @Sendable ([SignalSample]) -> Void) throws {
        var masterFD: Int32 = -1
        var slaveFD: Int32 = -1
        guard openpty(&masterFD, &slaveFD, nil, nil, nil) == 0 else {
            throw SourceError.failed("openpty: \(String(cString: strerror(errno)))")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        p.arguments = ["-P", "-d", "-L", "0", "-s", String(interval), "-J", "bytes_in,bytes_out", "-x"]
        let slave = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: true)
        p.standardOutput = slave
        p.standardError = slave
        p.standardInput = FileHandle.nullDevice
        try p.run()
        try? slave.close() // the child holds its own copy

        let master = FileHandle(fileDescriptor: masterFD, closeOnDealloc: true)
        let state = ReaderState(interval: Double(interval))
        master.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            let samples = state.consume(data)
            if !samples.isEmpty { emit(samples) }
        }
        lock.withLock {
            process = p
            self.master = master
        }
    }

    public func stop() {
        lock.withLock {
            master?.readabilityHandler = nil
            if process?.isRunning == true { process?.terminate() }
            process = nil
            master = nil
        }
    }
}

/// Line assembly + parsing, confined to the FileHandle's reader callback.
private final class ReaderState: @unchecked Sendable {
    private var buffer = Data()
    private var parser = NettopParser()
    private var known: Set<String> = []
    private let interval: Double

    init(interval: Double) { self.interval = interval }

    func consume(_ data: Data) -> [SignalSample] {
        buffer.append(data)
        var out: [SignalSample] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let line = String(data: lineData, encoding: .utf8),
                  let snap = parser.feed(line: line) else { continue }
            out.append(.stream("net.total.bytesPerSec", snap.total / interval))
            for (app, bytes) in snap.bytesByApp {
                out.append(.stream("net.app.bytesPerSec", key: app, bytes / interval))
            }
            // Zero out apps that went silent so they can re-activate later.
            for gone in known.subtracting(snap.bytesByApp.keys) {
                out.append(.stream("net.app.bytesPerSec", key: gone, 0))
            }
            known = Set(snap.bytesByApp.keys)
        }
        return out
    }
}

public enum SourceError: Error, CustomStringConvertible {
    case failed(String)
    public var description: String {
        switch self { case .failed(let s): s }
    }
}
