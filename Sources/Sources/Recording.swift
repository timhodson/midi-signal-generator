import Foundation
import SignalBus

/// One line of a recording: a batch of samples as a source emitted them, `t` seconds after
/// recording started.
public struct RecordedBatch: Codable, Sendable, Equatable {
    public var t: Double
    public var samples: [SignalSample]
}

/// First line of a recording.
public struct RecordingHeader: Codable, Sendable, Equatable {
    public static let formatName = "msg-signals"
    public var format: String = formatName
    public var version: Int = 1
    public var recorded: Date
    public var sources: [String]
}

/// Writes incoming signal batches to a JSON Lines file, so a session can be replayed exactly
/// (docs/decisions/0011-record-and-replay-signals.md). Called on the engine queue.
public final class SignalRecorder: @unchecked Sendable {
    private let handle: FileHandle
    private let encoder = JSONEncoder()
    private var start: Double?
    public private(set) var batches = 0
    public let url: URL

    public init(url: URL, sources: [String]) throws {
        self.url = url
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw SourceError.failed("cannot create \(url.path)")
        }
        handle = try FileHandle(forWritingTo: url)
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try write(RecordingHeader(recorded: Date(), sources: sources))
    }

    private func write<T: Encodable>(_ value: T) throws {
        var data = try encoder.encode(value)
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }

    public func record(_ samples: [SignalSample], at time: Double) {
        if start == nil { start = time }
        let stripped = samples.map { var s = $0; s.time = 0; return s }
        try? write(RecordedBatch(t: time - (start ?? time), samples: stripped))
        batches += 1
    }

    public func close() { try? handle.close() }
}

/// Plays a recording back with its original timing (optionally faster, optionally looping).
/// Emits the same signal ids as the source that was recorded, so the engine can't tell.
public final class ReplaySource: SignalSource, @unchecked Sendable {
    public let name: String
    public let header: RecordingHeader
    public let batches: [RecordedBatch]
    public let speed: Double
    public let loop: Bool
    private let queue = DispatchQueue(label: "replay-source")
    private var running = false

    public init(url: URL, speed: Double = 1, loop: Bool = false) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).makeIterator()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let first = lines.next(),
              let header = try? decoder.decode(RecordingHeader.self, from: Data(first.utf8)),
              header.format == RecordingHeader.formatName
        else { throw SourceError.failed("\(url.lastPathComponent) is not a signal recording") }
        var batches: [RecordedBatch] = []
        while let line = lines.next() {
            batches.append(try decoder.decode(RecordedBatch.self, from: Data(line.utf8)))
        }
        guard !batches.isEmpty else { throw SourceError.failed("\(url.lastPathComponent) has no data") }
        self.header = header
        self.batches = batches
        self.speed = max(speed, 0.01)
        self.loop = loop
        name = "replay(\(url.lastPathComponent)\(speed != 1 ? " ×\(speed)" : "")\(loop ? ", loop" : ""))"
    }

    /// Recording length in seconds (at 1×).
    public var duration: Double { batches.last?.t ?? 0 }

    public func start(emit: @escaping @Sendable ([SignalSample]) -> Void) throws {
        queue.sync { running = true }
        schedule(index: 0, origin: DispatchTime.now(), emit: emit)
    }

    private func schedule(index: Int, origin: DispatchTime, emit: @escaping @Sendable ([SignalSample]) -> Void) {
        guard index < batches.count || loop else { return }
        // Past the end of a loop: restart one second after the last batch so it has a breath.
        let wrapped = index >= batches.count
        let index = wrapped ? 0 : index
        let origin = wrapped ? origin + (duration + 1) / speed : origin
        let batch = batches[index]
        queue.asyncAfter(deadline: origin + batch.t / speed) { [weak self] in
            guard let self, self.running else { return }
            emit(batch.samples)
            self.schedule(index: index + 1, origin: origin, emit: emit)
        }
    }

    public func stop() { queue.sync { running = false } }
}
