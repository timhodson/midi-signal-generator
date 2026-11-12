# MIDI Signal Generator

Turns data signals into ambient MIDI streams: 90s modem handshake sounds, re-imagined for
today's networks. It starts with **this Mac's network traffic**. The whole LAN and
sensors (temperature, humidity, motion) come later.

Each app on the Mac gets its own motif when it wakes up. Overall traffic drives pulse density
and pad brightness. The network's "mood" (quiet / calm / busy / focused) picks the chord
progression, and a flurry of apps waking at once triggers a cadence. **Every musical decision
is a tunable parameter**, from raw sonification to tidy ambient music.

## Quick start

```sh
swift build    # see docs/development.md if this fails with a PackageDescription error
.build/debug/msg-spike --source synthetic --dry-run   # hear nothing, see the notes
.build/debug/msg-spike --verbose                      # real traffic → virtual MIDI port "MIDI Signal Generator"
.build/debug/msg-spike --dest network                 # → iPad via network MIDI (docs/midi-setup.md)
.build/debug/msg-spike --list-params                  # all ~80 parameters
.build/debug/msg-spike --set macro.faithfulness=0.9   # closer to raw data
```

Voices: `pad` = ch 1, `lead` = ch 2, `pulse` = ch 3 (all tunable).

## Docs

- [Architecture](docs/architecture.md)
- [Decisions (ADRs)](docs/README.md#decisions-adrs)
- [MIDI setup (iPad, DAW, Bluetooth)](docs/midi-setup.md)
- [Development](docs/development.md) · [Roadmap](docs/roadmap.md)
