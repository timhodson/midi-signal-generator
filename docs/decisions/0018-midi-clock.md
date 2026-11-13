# 0018 — MIDI clock out, and the host's tempo for hosted synths

- **Status:** accepted
- **Date:** 2026-11-13

## Context

The iPad synths (and Synth One J6 hosted on the Mac) have arpeggiators, LFOs, step sequencers and
tempo-synced delays. Left on their own tempo they drift against the piece, and the piece's tempo
moves: Variation can change it and traffic can modulate it.

The engine ticks every 5 ms and sends notes when they're due. Clock pulses are 20.8 ms apart at
120 bpm, so a pulse sent on the next tick would wobble by up to a quarter of its interval, and a
synth deriving its tempo from them would hear that.

## Decision

- **24 pulses per quarter note** (`0xF8`) to every **external MIDI destination an enabled voice
  plays on** (virtual port, network session, Bluetooth / USB devices), worked out each tick from the
  same look-ahead beat range the generators use (`Engine/ClockOut.swift`).
- **Timestamped.** Each pulse is sent up to 50 ms ahead with a CoreMIDI timestamp for the exact
  moment of its beat position, so the system delivers it on time whatever the tick. swift-midi-io's
  send has no timestamp, so `CoreMIDISink.sendRaw` builds the packet list itself and sends it through
  the library's own port and endpoint refs. Measured on the virtual port: pulses 20.833 ms apart at
  120 bpm, arrival jitter under 0.4 ms.
- **Transport** (`clock.transport`, on by default): each destination gets **Start on a bar line**
  (beat 0 when the engine starts; the next bar line when a voice is moved to a new destination), so
  sequencers begin on beat 1 with the piece; it gets clock straight away, so it can lock its tempo
  first. **Stop** when a destination is dropped, clock is switched off, or the engine stops.
  "Restart on the next bar" (Stop now, Start on the next bar) brings back a synth that lost its
  place: it reconnected, or something listening on the virtual port connected after the Start.
  Off = pulses only, for synths that would otherwise start their own sequencer.
- **No burst after a stall.** Pulses already in the past when they're worked out (the Mac slept, the
  queue was blocked) are dropped rather than sent late in a lump.
- **Hosted synths** don't need MIDI clock: the host gives every Audio Unit a `musicalContextBlock`
  (tempo, beat position, 4/4 bar, samples to the next beat) and a `transportStateBlock` (playing),
  read on the render thread from a lock-free snapshot (`AUHost/HostTransport.swift`, a sequence lock
  over atomics) that the engine updates every tick.
- Params: `clock.midiOut` (on), `clock.transport` (on). The Harmony page's Clock section shows who
  gets clock and who has started.

## Consequences

- A synth set to external sync follows tempo changes, including modulated ones, within a beat.
- Notes are still sent on the tick (up to 5 ms late) while pulses are exact. Fine by ear; notes could
  be timestamped the same way later.
- Clock **in** (following a DAW) is still to come: it would drive `MusicalClock` from incoming pulses.
- No song position pointer yet: a synth always starts from the bar it's told to, which is what an
  ambient piece without a song position wants.
