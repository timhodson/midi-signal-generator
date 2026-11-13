import Foundation
import Music
import Params

/// MIDI clock out (docs/decisions/0018-midi-clock.md): 24 pulses per beat to every external MIDI
/// destination a voice plays on, so a synth's arpeggiator, LFOs, sequencer and tempo-synced delays
/// follow the piece's tempo, including tempo that traffic modulates. Each destination gets Start
/// on a bar line (the first time it's heard of, or after a restart), so sequencers and arps begin
/// on beat 1 with us, and Stop when it's dropped or the engine stops.
///
/// Pure bookkeeping: `advance` returns the messages with the engine time they're due, and the
/// engine sends them ahead with CoreMIDI timestamps, so pulses land exactly on time.
struct ClockOut {
    static let pulsesPerBeat = 24
    static let timingClock: UInt8 = 0xF8, start: UInt8 = 0xFA, stop: UInt8 = 0xFC

    static let params: [ParamSpec] = [
        ParamSpec("clock.midiOut", kind: .toggle, default: 1, modulatable: false,
                  help: "Send MIDI clock (24 pulses a beat) to every external MIDI destination a voice plays on (iPad, Bluetooth, the virtual port), so synth arpeggiators, LFOs and tempo-synced delays follow the tempo. Set the synth to sync to external MIDI clock. Hosted synths follow the tempo without it."),
        ParamSpec("clock.transport", kind: .toggle, default: 1, modulatable: false,
                  help: "Also send Start on the next bar line to each destination that's new to the clock (and Stop when it's dropped or playback stops), so sequencers and arps begin on beat 1 with the piece. Off = clock pulses only, for synths that would otherwise start their own sequencer."),
    ]

    struct Message: Equatable {
        var destination: String
        var bytes: [UInt8]
        /// Engine time it's due; nil = now.
        var time: Double?
    }

    /// Destinations receiving clock now.
    private(set) var targets: Set<String> = []
    /// Destinations that have been sent Start (running in step with us).
    private(set) var started: Set<String> = []
    /// Index of the next pulse to send (pulse k is at beat k / 24).
    private var nextPulse: Int?

    /// The messages for the beats that just elapsed (start exclusive; the very first call also
    /// covers its first beat). Pulses due before `notBefore` (engine time) are dropped: after a
    /// stall (the Mac asleep, the queue blocked) the missed ones would only arrive as a burst.
    mutating func advance(beats: Range<Double>, clock: MusicalClock, destinations: Set<String>,
                          enabled: Bool, transport: Bool, notBefore: Double = -.infinity) -> [Message] {
        var out: [Message] = []
        let want = enabled ? destinations : []
        for d in targets.subtracting(want).sorted() where started.contains(d) {
            out.append(Message(destination: d, bytes: [Self.stop], time: nil))
        }
        targets = want
        started.formIntersection(want)
        if !transport {
            for d in started.sorted() { out.append(Message(destination: d, bytes: [Self.stop], time: nil)) }
            started = []
        }
        guard !want.isEmpty else { nextPulse = nil; return out }

        let ppb = Double(Self.pulsesPerBeat)
        let first = Int((beats.lowerBound * ppb).rounded(.up))
        var k = nextPulse ?? first
        if Double(k) / ppb < beats.lowerBound - 0.25 { k = first }
        let pulsesPerBar = Self.pulsesPerBeat * max(clock.beatsPerBar, 1)
        let order = want.sorted()
        while Double(k) / ppb <= beats.upperBound {
            let t = clock.time(ofBeat: Double(k) / ppb)
            if t < notBefore { k += 1; continue }
            if transport, k % pulsesPerBar == 0 {
                for d in order where !started.contains(d) {
                    out.append(Message(destination: d, bytes: [Self.start], time: t))
                    started.insert(d)
                }
            }
            for d in order { out.append(Message(destination: d, bytes: [Self.timingClock], time: t)) }
            k += 1
        }
        nextPulse = k
        return out
    }

    /// Stop everything that's running (the engine is stopping).
    mutating func stopAll() -> [Message] {
        defer { started = []; targets = []; nextPulse = nil }
        return started.sorted().map { Message(destination: $0, bytes: [Self.stop], time: nil) }
    }

    /// Stop now and start again on the next bar line: brings a synth that lost its place (it
    /// reconnected, or its sequencer was stopped by hand) back in step.
    mutating func restart() -> [Message] {
        defer { started = [] }
        return started.sorted().map { Message(destination: $0, bytes: [Self.stop], time: nil) }
    }
}
