# Roadmap

## Done: spike (2026-11-12)

- [x] Package with Params / SignalBus / Music / Router / MIDIOut / Sources / Engine
- [x] Per-app traffic from `nettop` (no root), plus a synthetic source
- [x] Conductor (moods, progressions, hysteresis, flurry gesture), Drone / Motif / Pulse generators
- [x] Continuous quantisers, mod matrix, faithfulness macro, JSON scenes
- [x] CoreMIDI out: virtual port, network session, named destinations; scheduler with note ledger
- [x] Hosted Audio Unit instruments, one per voice, with plugin params as mod targets (ADR 0010). Heard on the Mac
- [x] Record / replay signals (`--record`, `--source replay:`, ADR 0011)
- [ ] **Listen to it on the iPad** and tune the default and hosted scenes by ear

## Next

2. **OSC in** (ADR 0008), for both signals and param control (`/param/quant.pitch.strength 0.4`).
3. **pcap helper** (privileged, separate process). Packet-level features: protocol mix, DNS
   → pickup notes, SYN/FIN → phrase start/end, TLS hello, mDNS/SSDP chatter → texture.
4. **SwiftUI app** on top of `Engine`:
   - parameter panels generated from `ParamSpec` (AudioKit Controls)
   - voice/range mapper using AudioKit Keyboard, showing sounding notes
   - mod-matrix grid, macro knobs, scene save/load/A–B
   - live signal scopes (Swift Charts)
5. **MIDI clock** out (and in, to follow a DAW). CoreMIDI timestamped sends.
6. More generators: arpeggiator over the chord, flow-voice (one voice per live connection with voice stealing), percussion.

## Later

- Whole-LAN capture: mirror port / router NetFlow / Pi-hole DNS log. Per-**device** leitmotifs (ADR 0009).
- MQTT bridge (Home Assistant / Zigbee2MQTT) for temperature, humidity and motion. Mostly the
  state layer: mode, key and tempo drift.
- Scene morphing, including choice params switching on boundaries.
- Effects on the hosted mix (reverb/delay sends), and the plugins' own editor windows in the app.
