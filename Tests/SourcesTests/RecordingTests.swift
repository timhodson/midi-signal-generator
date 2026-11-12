import Foundation
import Testing
@testable import Sources
import SignalBus

@Suite struct RecordingTests {
    @Test func recordThenReplayRoundTrips() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("msg-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let rec = try SignalRecorder(url: url, sources: ["test"])
        rec.record([.stream("net.total.bytesPerSec", 100)], at: 10)
        rec.record([.stream("net.app.bytesPerSec", key: "Safari", 42), .event("x")], at: 11.5)
        rec.close()

        let replay = try ReplaySource(url: url, speed: 2)
        #expect(replay.header.sources == ["test"])
        #expect(replay.batches.map(\.t) == [0, 1.5])
        #expect(replay.batches[1].samples == [.stream("net.app.bytesPerSec", key: "Safari", 42), .event("x")])
        #expect(replay.duration == 1.5)
    }

    @Test func rejectsNonRecordings() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("msg-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("{\"hello\": 1}\n".utf8).write(to: url)
        #expect(throws: SourceError.self) { try ReplaySource(url: url) }
    }
}
