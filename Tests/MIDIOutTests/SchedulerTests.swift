import Testing
@testable import MIDIOut
import Router

private final class Recorder: MIDISink {
    var log: [String] = []
    func noteOn(destination: String, channel: Int, note: Int, velocity: Int) { log.append("on \(note)") }
    func noteOff(destination: String, channel: Int, note: Int) { log.append("off \(note)") }
    func controlChange(destination: String, channel: Int, controller: Int, value: Int) { log.append("cc \(controller)=\(value)") }
    func allNotesOff() { log.append("panic") }
}

private func note(_ n: Int, at start: Double, for duration: Double, poly: Int = 8) -> RoutedNote {
    RoutedNote(destination: "d", channel: 0, note: n, velocity: 100, start: start, duration: duration,
               role: "r", maxPolyphony: poly, why: "")
}

@Suite struct SchedulerTests {
    @Test func firesOnAndOffInTimeOrder() {
        let r = Recorder()
        let s = NoteScheduler(sink: r)
        s.schedule(note(62, at: 0.2, for: 0.1))
        s.schedule(note(60, at: 0.1, for: 1))
        s.fire(now: 0.05)
        #expect(r.log.isEmpty)
        s.fire(now: 0.25)
        #expect(r.log == ["on 60", "on 62"])
        s.fire(now: 0.35)
        #expect(r.log == ["on 60", "on 62", "off 62"])
    }

    @Test func retriggerIsNotCutShortByStaleNoteOff() {
        let r = Recorder()
        let s = NoteScheduler(sink: r)
        s.schedule(note(60, at: 0, for: 1))
        s.schedule(note(60, at: 0.5, for: 1))
        s.fire(now: 0.6)
        #expect(r.log == ["on 60", "off 60", "on 60"])
        s.fire(now: 1.2)                // the first note's off is stale and must be ignored
        #expect(r.log.count == 3)
        s.fire(now: 1.6)
        #expect(r.log.last == "off 60")
        #expect(s.soundingCount == 0)
    }

    @Test func polyphonyLimitReleasesOldest() {
        let r = Recorder()
        let s = NoteScheduler(sink: r)
        s.schedule(note(60, at: 0, for: 5, poly: 2))
        s.schedule(note(62, at: 0.1, for: 5, poly: 2))
        s.schedule(note(64, at: 0.2, for: 5, poly: 2))
        s.fire(now: 0.3)
        #expect(r.log == ["on 60", "on 62", "off 60", "on 64"])
    }

    @Test func panicReleasesEverything() {
        let r = Recorder()
        let s = NoteScheduler(sink: r)
        s.schedule(note(60, at: 0, for: 5))
        s.fire(now: 0.1)
        s.panic()
        #expect(r.log == ["on 60", "off 60", "panic"])
        #expect(s.soundingCount == 0)
    }
}

@Suite struct CompositeSinkTests {
    @Test func routesByDestinationWithFallback() {
        let au = Recorder(), midi = Recorder()
        let sink = CompositeSink(routes: [.init(claims: { $0.hasPrefix("au:") }, sink: au)], fallback: midi)
        sink.noteOn(destination: "au:j6", channel: 0, note: 60, velocity: 1)
        sink.noteOn(destination: "network", channel: 0, note: 62, velocity: 1)
        sink.allNotesOff()
        #expect(au.log == ["on 60", "panic"])
        #expect(midi.log == ["on 62", "panic"])
    }
}
