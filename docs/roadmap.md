# Roadmap

## Done: spike (2026-11-12)

- [x] Package with Params / SignalBus / Music / Router / MIDIOut / Sources / Engine
- [x] Per-app traffic from `nettop` (no root), plus a synthetic source
- [x] Conductor (moods, progressions, hysteresis, flurry gesture), Drone / Motif / Pulse generators
- [x] Continuous quantisers, mod matrix, faithfulness macro, JSON scenes
- [x] CoreMIDI out: virtual port, network session, named destinations; scheduler with note ledger
- [x] Hosted Audio Unit instruments, one per voice, with plugin params as mod targets (ADR 0010). Heard on the Mac
- [x] Record / replay signals (`--record`, `--source replay:`, ADR 0011)
- [x] Mac app v1: generated param panels, overview scopes, instruments with editors, mod matrix, scenes (ADR 0012)
- [x] Bass and sub-drone voices; plain-language help on every param, group intros and a mood table in the app; two-way sync with synth editor windows
- [x] Live visuals on every settings page; chord palette with audition; per-mood progression editor
- [x] Motif designer (scale-step grid, per app / pattern / default) and trigger explanations (ADR 0014)
- [x] Packet capture helper `msg-pcap`: DNS lookups, handshakes with round trips, closes and LAN chatter as figures; features over OSC (ADR 0015)
- [ ] **Listen to it on the iPad** and tune the default and hosted scenes by ear

## Next

1. **OSC in, the rest**: signals already arrive over OSC (ADR 0015); still to do: param control
   (`/param/quant.pitch.strength 0.4`) and accepting from the LAN.
2. **Packets, next:** per-process attribution via PKTAP (link events to app motifs), a packet
   source for whole-LAN capture on a Pi.
3. **App, next round:** voice routing and range editing in the UI (AudioKit Keyboard), adding
   and removing hosted instruments, scene A/B comparison, MIDI-learn for params, an app bundle.
4. **MIDI clock** out (and in, to follow a DAW). CoreMIDI timestamped sends.
5. More generators: arpeggiator over the chord, flow-voice (one voice per live connection with voice stealing), percussion.

## Later

- Whole-LAN capture: mirror port / router NetFlow / Pi-hole DNS log. Per-**device** leitmotifs (ADR 0009).
- MQTT bridge (Home Assistant / Zigbee2MQTT) for temperature, humidity and motion. Mostly the
  state layer: mode, key and tempo drift.
- Scene morphing, including choice params switching on boundaries.
- Effects on the hosted mix (reverb/delay sends), and the plugins' own editor windows in the app.
