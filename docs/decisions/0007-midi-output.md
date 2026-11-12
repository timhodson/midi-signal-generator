# 0007 — MIDI output: roles, app-side scheduler, three kinds of destination

- **Status:** accepted
- **Date:** 2026-11-12

## Context

The targets are AudioKit synths on an iPad (network MIDI over Wi-Fi, Bluetooth MIDI or
USB) plus software synths on the Mac. Each link has different latency. Stuck notes are the
classic failure of generative MIDI tools.

## Decision

- **Generators speak in roles** (`pad`, `lead`, `pulse`), never devices. A scene's `voices`
  map each role to a destination and channel. Range, transpose, latency, polyphony and
  velocity trim are `voice.<role>.*` params. Out-of-range notes **fold by octaves**, and are
  clamped to the nearest edge only when the range is narrower than an octave.
- **Destinations:**
  - `virtual`: our own virtual source "MIDI Signal Generator" (DAWs, AUM, IAC-free).
  - `network`: Apple's network MIDI session, resolved by the unique ID of its destination
    endpoint, so the session's display name doesn't matter. iPad apps join this.
  - any other string: an existing destination by name (`--list-destinations`).
- **App-side scheduler** (`NoteScheduler`): the engine runs 50 ms ahead and the scheduler fires
  on a 5 ms strict timer. It keeps a ledger of sounding notes keyed by (destination, channel, note)
  with a token per note-on, so a re-triggered note isn't cut short by the earlier note's
  note-off. It also handles per-role polyphony (oldest released) and panic (note-offs + CC 123) on exit.
- **Per-voice latency offset** (`voice.<role>.latencyMs`) delays faster links so a Bluetooth
  pad and a USB lead line up.

## Consequences

- Timing jitter is around the timer resolution (≤ ~5 ms), which is fine for ambient music. A later step can hand
  CoreMIDI timestamped packets (swift-midi-io supports event lists) for tighter timing.
- The network session must be enabled by the user (Audio MIDI Setup → Network). Our
  `--network-session` flag sets the connection policy but can't be relied on to enable it
  in every context.
- MIDI clock out/in and MIDI 2.0 are not done yet.
