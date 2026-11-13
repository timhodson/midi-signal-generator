import AudioToolbox
import Foundation
import MIDIOut
import Synchronization

/// The host's musical context for hosted Audio Units: tempo, beat position, bar and whether the
/// transport is playing. Plugins read it from the render thread through `musicalContextBlock`
/// and `transportStateBlock`, so arpeggiators, LFOs and tempo-synced delays follow the engine's
/// clock (MIDI clock does the same for external synths).
///
/// The engine queue writes; render threads read. A sequence lock keeps a read consistent (tempo
/// and anchor from the same update) without blocking the audio thread.
final class HostTransport: Sendable {
    private let sequence = Atomic<UInt64>(0)
    private let bpmBits = Atomic<UInt64>(120.0.bitPattern)
    private let beatBits = Atomic<UInt64>(0.0.bitPattern)
    private let anchorNanos = Atomic<UInt64>(0)
    private let barBeats = Atomic<Int>(4)
    private let playing = Atomic<Bool>(false)
    private let changed = Atomic<Bool>(false)
    let sampleRateBits = Atomic<UInt64>(48_000.0.bitPattern)

    func update(_ s: TransportState) {
        let wasPlaying = playing.load(ordering: .relaxed)
        sequence.add(1, ordering: .acquiringAndReleasing) // odd: writing
        bpmBits.store(s.bpm.bitPattern, ordering: .relaxed)
        beatBits.store(s.beat.bitPattern, ordering: .relaxed)
        anchorNanos.store(s.uptimeNanos, ordering: .relaxed)
        barBeats.store(s.beatsPerBar, ordering: .relaxed)
        playing.store(s.playing, ordering: .relaxed)
        if wasPlaying != s.playing { changed.store(true, ordering: .relaxed) }
        sequence.add(1, ordering: .acquiringAndReleasing) // even: done
    }

    /// A consistent snapshot: tempo, beat now, beats per bar, playing.
    private func read() -> (bpm: Double, beat: Double, bar: Int, playing: Bool) {
        while true {
            let before = sequence.load(ordering: .acquiring)
            if before & 1 == 1 { continue }
            let bpm = Double(bitPattern: bpmBits.load(ordering: .relaxed))
            let beat = Double(bitPattern: beatBits.load(ordering: .relaxed))
            let anchor = anchorNanos.load(ordering: .relaxed)
            let bar = barBeats.load(ordering: .relaxed)
            let isPlaying = playing.load(ordering: .relaxed)
            if sequence.load(ordering: .acquiring) == before {
                let now = DispatchTime.now().uptimeNanoseconds
                let elapsed = Double(Int64(bitPattern: now &- anchor)) / 1e9
                return (bpm, isPlaying ? beat + elapsed * bpm / 60 : beat, max(bar, 1), isPlaying)
            }
        }
    }

    var musicalContextBlock: AUHostMusicalContextBlock {
        { [self] tempo, numerator, denominator, beatPosition, sampleOffsetToNextBeat, downbeat in
            let s = read()
            tempo?.pointee = s.bpm
            numerator?.pointee = Double(s.bar)
            denominator?.pointee = 4
            beatPosition?.pointee = s.beat
            if let sampleOffsetToNextBeat {
                let rate = Double(bitPattern: sampleRateBits.load(ordering: .relaxed))
                sampleOffsetToNextBeat.pointee = Int(((s.beat.rounded(.up) - s.beat) * 60 / s.bpm * rate).rounded())
            }
            downbeat?.pointee = (s.beat / Double(s.bar)).rounded(.down) * Double(s.bar)
            return true
        }
    }

    var transportStateBlock: AUHostTransportStateBlock {
        { [self] flags, samplePosition, cycleStart, cycleEnd in
            let s = read()
            if let flags {
                var f: AUHostTransportStateFlags = []
                if s.playing { f.insert(.moving) }
                if changed.exchange(false, ordering: .relaxed) { f.insert(.changed) }
                flags.pointee = f
            }
            let rate = Double(bitPattern: sampleRateBits.load(ordering: .relaxed))
            samplePosition?.pointee = s.beat * 60 / s.bpm * rate
            cycleStart?.pointee = 0
            cycleEnd?.pointee = 0
            return true
        }
    }
}
