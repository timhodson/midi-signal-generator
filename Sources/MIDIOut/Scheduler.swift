import Foundation
import Router

/// Anything that can receive MIDI channel messages. Channels are 0...15.
public protocol MIDISink: AnyObject {
    func noteOn(destination: String, channel: Int, note: Int, velocity: Int)
    func noteOff(destination: String, channel: Int, note: Int)
    func controlChange(destination: String, channel: Int, controller: Int, value: Int)
    /// CC 123 on every channel of every destination this sink knows about.
    func allNotesOff()
    /// Raw bytes (MIDI clock, Start, Stop, song position), delivered at `uptimeNanos` (the
    /// `DispatchTime` uptime clock) or as soon as possible when nil. Sinks without real MIDI
    /// ports ignore it.
    func sendRaw(destination: String, _ bytes: [UInt8], atUptimeNanos: UInt64?)
    /// Where the music is: tempo, beat and whether it's playing. Hosted instruments read this
    /// as the host's musical context, so their arpeggiators and tempo-synced effects follow.
    func transport(_ state: TransportState)
}

extension MIDISink {
    public func sendRaw(destination: String, _ bytes: [UInt8], atUptimeNanos: UInt64?) {}
    public func transport(_ state: TransportState) {}
}

/// The engine's beat clock at one instant, for hosted instruments.
public struct TransportState: Sendable, Equatable {
    public var bpm: Double
    /// Beat position at `uptimeNanos`.
    public var beat: Double
    public var uptimeNanos: UInt64
    public var beatsPerBar: Int
    public var playing: Bool

    public init(bpm: Double, beat: Double, uptimeNanos: UInt64, beatsPerBar: Int, playing: Bool) {
        self.bpm = bpm
        self.beat = beat
        self.uptimeNanos = uptimeNanos
        self.beatsPerBar = beatsPerBar
        self.playing = playing
    }

    /// The beat at another instant, at this tempo.
    public func beat(atUptimeNanos t: UInt64) -> Double {
        beat + (Double(Int64(bitPattern: t &- uptimeNanos)) / 1e9) * bpm / 60
    }
}

/// Holds future note-ons, note-offs and CCs, and fires them when due. Keeps a ledger of
/// sounding notes so nothing gets stuck (docs/decisions/0007-midi-output.md).
///
/// Not thread-safe: driven from the engine's serial queue.
public final class NoteScheduler: @unchecked Sendable {
    private enum Action {
        case on(RoutedNote)
        case off(destination: String, channel: Int, note: Int, token: Int)
        case cc(RoutedControl)
    }

    private struct Item {
        var time: Double
        var seq: Int
        var action: Action
    }

    private struct Sounding: Hashable {
        var destination: String
        var channel: Int
        var note: Int
    }

    private let sink: MIDISink
    private var queue: [Item] = []
    private var seq = 0
    /// Sounding note -> token of the note-on that started it (so a stale note-off for a
    /// retriggered note doesn't cut the newer one short).
    private var sounding: [Sounding: Int] = [:]
    /// Per role, sounding notes in start order, for polyphony limits.
    private var byRole: [String: [Sounding]] = [:]

    public init(sink: MIDISink) { self.sink = sink }

    public var soundingCount: Int { sounding.count }

    public func schedule(_ note: RoutedNote) {
        push(note.start, .on(note))
    }

    public func schedule(_ control: RoutedControl) {
        push(control.time, .cc(control))
    }

    private func push(_ time: Double, _ action: Action) {
        seq += 1
        queue.append(Item(time: time, seq: seq, action: action))
    }

    /// Fire everything due at or before `now`, in time order.
    public func fire(now: Double) {
        guard !queue.isEmpty else { return }
        queue.sort { ($0.time, $0.seq) < ($1.time, $1.seq) }
        while let first = queue.first, first.time <= now {
            queue.removeFirst()
            perform(first)
        }
    }

    private func perform(_ item: Item) {
        switch item.action {
        case .on(let n):
            let key = Sounding(destination: n.destination, channel: n.channel, note: n.note)
            if sounding[key] != nil { release(key, role: n.role) } // retrigger cleanly
            var active = byRole[n.role, default: []]
            while active.count >= max(n.maxPolyphony, 1), let oldest = active.first {
                active.removeFirst()
                release(oldest, role: nil)
            }
            byRole[n.role] = active + [key]
            sounding[key] = item.seq
            sink.noteOn(destination: n.destination, channel: n.channel, note: n.note, velocity: n.velocity)
            push(item.time + n.duration, .off(destination: n.destination, channel: n.channel, note: n.note, token: item.seq))
        case .off(let d, let c, let note, let token):
            let key = Sounding(destination: d, channel: c, note: note)
            guard sounding[key] == token else { return } // already released or retriggered
            release(key, role: nil)
        case .cc(let c):
            sink.controlChange(destination: c.destination, channel: c.channel, controller: c.controller, value: c.value)
        }
    }

    private func release(_ key: Sounding, role: String?) {
        guard sounding.removeValue(forKey: key) != nil else { return }
        if let role {
            byRole[role]?.removeAll { $0 == key }
        } else {
            for r in byRole.keys { byRole[r]?.removeAll { $0 == key } }
        }
        sink.noteOff(destination: key.destination, channel: key.channel, note: key.note)
    }

    /// Release everything now and drop pending events.
    public func panic() {
        for key in sounding.keys { sink.noteOff(destination: key.destination, channel: key.channel, note: key.note) }
        sounding.removeAll()
        byRole.removeAll()
        queue.removeAll()
        sink.allNotesOff()
    }
}
