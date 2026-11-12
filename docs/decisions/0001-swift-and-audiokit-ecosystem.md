# 0001 — Swift, the AudioKit ecosystem and swift-midi-io

- **Status:** accepted
- **Date:** 2026-11-12

## Context

The app targets macOS first. MIDI timing matters, and the UI is mostly knobs, matrices and
scopes. The target synths are iPad apps built with AudioKit, reached over network MIDI or
Bluetooth. A Rust core (`midir`, `pcap`) with a Tauri UI was considered for possible Linux or Raspberry Pi reuse.

## Decision

- **Swift 6 + SwiftPM**, macOS 15+. SwiftUI app later, CLI spike now.
- **[Tonic](https://github.com/AudioKit/Tonic)** (AudioKit) supplies the scale catalogue. Chord
  arithmetic is our own: stacked thirds over any scale, so it works for pentatonic and whole-tone too.
- **[swift-midi-io](https://github.com/orchetect/swift-midi-io)** for CoreMIDI. This is the
  MIDIKit I/O layer, which became a separate package in its 1.x releases ("SwiftMIDI"). It gives
  virtual ports, connections by name or unique ID, and the network session policy.
- **AudioKit Controls** is used for knob interaction (ADR 0012). Planned: **Keyboard** (range display),
  plus Swift Charts for data scopes. AudioKitUI's scopes expect audio buffers, so they are only
  useful if we add a built-in preview synth.

## Consequences

- CoreMIDI and the AudioKit packages are first-class and the code is shared with iOS.
- Linux/Pi support would need a separate source process. Sources will move out of process
  anyway (ADR 0008), so a Pi only ever needs to run a *source*, not the engine.
