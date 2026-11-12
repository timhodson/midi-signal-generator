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
swift run -c release msg-app --scene scenes/audiokit-hosted.json   # the Mac app (release: much lighter)
swift build
.build/debug/msg-spike --source synthetic --dry-run   # hear nothing, see the notes
.build/debug/msg-spike --verbose                      # real traffic → virtual MIDI port "MIDI Signal Generator"
.build/debug/msg-spike --scene scenes/audiokit-hosted.json   # Synth One J6 + King of FM, hosted in-app
.build/debug/msg-spike --au pad="Synth One J6@Intersteller Pad"  # any AU synth per role
.build/debug/msg-spike --dest network                 # → iPad via network MIDI (docs/midi-setup.md)
.build/debug/msg-spike --list-params                  # all ~80 parameters (hundreds more with hosted synths)
.build/debug/msg-spike --set macro.faithfulness=0.9   # closer to raw data
.build/debug/msg-spike --packets                      # + DNS lookups, handshakes, LAN chatter (msg-pcap, ADR 0015)
.build/debug/msg-pcap --print                         # see packet features (needs sudo or ChmodBPF)
.build/debug/msg-spike --record recordings/evening.jsonl          # capture the traffic…
.build/debug/msg-spike --source replay:recordings/evening.jsonl  # …and replay it while tuning
```

Voices: `pad` = ch 1, `lead` = ch 2, `pulse` = ch 3, `bass` = ch 4, `sub` = ch 5, `drums` = ch 10 (all tunable).
The drummer (ADR 0016) plays General MIDI drums; hosted scenes get Apple's built-in kit automatically.

## Docs

- [Architecture](docs/architecture.md)
- [The app](docs/decisions/0012-mac-app-generated-from-params.md)
- [Decisions (ADRs)](docs/README.md#decisions-adrs)
- [MIDI setup (hosted AU synths, iPad, DAW, Bluetooth)](docs/midi-setup.md)
- [Development](docs/development.md) · [Roadmap](docs/roadmap.md)
