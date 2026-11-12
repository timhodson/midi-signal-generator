# Documentation

- [Architecture](architecture.md): pipeline, modules, signals, threading
- [MIDI setup](midi-setup.md): hosted AU synths on the Mac, an iPad over network MIDI, a DAW or Bluetooth
- [Development](development.md): building and testing (including the Command Line Tools workaround)
- [Roadmap](roadmap.md): what comes after the spike

## Decisions (ADRs)

Short records of *why* things are the way they are. Add a new numbered file when a decision
is made or reversed; don't rewrite history. Mark superseded ones in their status line.

| # | Decision |
|---|---|
| [0001](decisions/0001-swift-and-audiokit-ecosystem.md) | Swift, the AudioKit ecosystem (Tonic now; Controls and Keyboard for the UI) and swift-midi-io |
| [0002](decisions/0002-everything-is-a-parameter.md) | Every musical decision is a parameter; mod matrix; macros; scenes |
| [0003](decisions/0003-three-signal-timescales.md) | Events, streams, states |
| [0004](decisions/0004-local-traffic-via-nettop.md) | Local traffic via `nettop` on a pseudo-terminal; pcap later |
| [0005](decisions/0005-continuous-quantisation.md) | Quantisation is a continuum (pitch, time, velocity, density) |
| [0006](decisions/0006-harmony-changes-on-boundaries.md) | Harmony on bar boundaries, smoothing, hysteresis, gestures |
| [0007](decisions/0007-midi-output.md) | Roles, voice routing, app-side scheduler, destinations |
| [0008](decisions/0008-sources-behind-a-protocol-osc-later.md) | Sources behind a protocol; OSC and out-of-process later |
| [0009](decisions/0009-seeded-randomness-and-leitmotifs.md) | Seeded randomness and per-app leitmotifs |
| [0010](decisions/0010-hosted-audio-unit-instruments.md) | Host Audio Unit instruments (Synth One J6, King of FM) in-app, one per voice |
| [0011](decisions/0011-record-and-replay-signals.md) | Record and replay signals for repeatable tuning |
| [0012](decisions/0012-mac-app-generated-from-params.md) | The Mac app: SwiftUI panels generated from ParamSpecs, shared Runtime |
| [0013](decisions/0013-ui-and-engine-performance.md) | Performance: fine-grained UI updates, visuals only when visible, change-driven synth sync |
| [0014](decisions/0014-motif-designs-and-explaining-triggers.md) | Motif designs in scale steps; explaining why each note plays |
| [0015](decisions/0015-packet-capture-helper.md) | Packet capture helper: features over OSC, heard as network negotiation |
