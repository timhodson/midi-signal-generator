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
- [x] Drummer: a groove per mood with presence and complexity, fills at phrase ends and flurries, idle rests, Euclidean grooves, network accents; built-in GM kit; editable step grid (ADR 0016)
- [x] Destination picker per voice in the app: virtual, network, hosted, Bluetooth / USB / network / IAC / app destinations (incl. offline), live switching, Bluetooth MIDI pairing panel
- [ ] **Listen to it on the iPad** and tune the default and hosted scenes by ear

## Next

1. **OSC in, the rest**: signals already arrive over OSC (ADR 0015); still to do: param control
   (`/param/quant.pitch.strength 0.4`) and accepting from the LAN.
2. **Packets, next:** per-process attribution via PKTAP (link events to app motifs), a packet
   source for whole-LAN capture on a Pi.
3. **App, layout (feedback 2026-11-12):** Voices and Generators take a lot of scrolling to find
   anything. Instead:
   - an overview of small **tiles**, one per voice / generator, each showing at a glance what it's
     doing now (live mini-visual, key numbers, on/off)
   - **click to expand just that one** (the others stay as tiles)
   - **open several in their own windows**, or **pin them to a "tabletop"**: a free-form, tiled
     workspace where the chosen panels sit side by side for tweaking together
   (saved per scene or per user).
4. **App, next round:** adding
   and removing hosted instruments, scene A/B comparison, MIDI-learn for params, an app bundle.
5. **MIDI clock** out (and in, to follow a DAW). CoreMIDI timestamped sends.
6. More generators: arpeggiator over the chord, flow-voice (one voice per live connection with voice stealing).
7. Drums, next: more grooves and odd meters, per-lane timing feel (laid-back snare), groove morphing between moods.

## Later

- Whole-LAN capture: mirror port / router NetFlow / Pi-hole DNS log. Per-**device** leitmotifs (ADR 0009).
- MQTT bridge (Home Assistant / Zigbee2MQTT) for temperature, humidity and motion. Mostly the
  state layer: mode, key and tempo drift.
- Scene morphing, including choice params switching on boundaries.
- Effects on the hosted mix (reverb/delay sends), and the plugins' own editor windows in the app.
