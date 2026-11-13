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
- [x] Tile pages for Generators and Voices (live tile per group, click to expand one), pop-out windows, a Tabletop of pinned panels
- [x] Mixer page: channel strips (EQ, reverb/delay sends, pan, mute/solo, fader, meter) for hosted synths, FX returns, master; MIDI voices get a velocity-trim strip
- [x] Instruments as tiles; Studio skin batch 1 (generated panel, knob cap and LCD textures) on the Mixer, switchable in the toolbar
- [x] Signal flow page (patchbay of signals → generators → voices → outputs, live cables, path highlighting); Studio skin on tiles, Tabletop, panel windows and Signal flow
- [x] Studio skin on every page: Overview (LCD readouts), Modulation (a depth knob per route), Harmony and Quantise (engraved panel sections), Motifs
- [x] Studio controls: bevelled keys for buttons and menus, sliders with a fader cap (AudioKit Controls, like the knobs), LED switches, − / + steppers, recessed LCD-green text fields
- [x] Variation: randomise key, scale, progressions, motifs, registers (and optionally tempo, drums) by a deviation, by hand or every 5 min … 4 h, from home or drifting (ADR 0017); Save asks before overwriting a loaded scene
- [x] Listened to on the iPad and tuned by ear (2026-11-13)
- [x] Overview: a legend for the traffic chart; drag the quiet / busy lines to move the thresholds
- [x] Public repo, CI (build + test) and tagged releases (an Apple-silicon zip); v0.1.0
- [x] MIDI clock out: 24 PPQN, CoreMIDI-timestamped, Start on a bar line and Stop, to every external voice destination; hosted synths get the host's tempo and beat (ADR 0018)

## Next

1. **App, layout (feedback 2026-11-12), first pass done 2026-11-13; still to come: free-form
   placement and sizing on the tabletop, tiles for the other pages.** Voices and Generators take a lot of scrolling to find
   anything. Instead:
   - an overview of small **tiles**, one per voice / generator, each showing at a glance what it's
     doing now (live mini-visual, key numbers, on/off)
   - **click to expand just that one** (the others stay as tiles)
   - **open several in their own windows**, or **pin them to a "tabletop"**: a free-form, tiled
     workspace where the chosen panels sit side by side for tweaking together
   (saved per scene or per user).
2. **Mixer page (feedback 2026-11-12), first pass done 2026-11-13; still to come: group buses
   (e.g. a drums sub-group), MIDI CC7/CC10 strips for external voices, a per-scene default mix.** styled like a hardware mixer: a channel strip per voice
   with a fader, pan, mute/solo, a meter and EQ knobs (low / mid with frequency / high), plus
   **buses** for grouping and shared FX (e.g. a reverb bus and a delay bus with per-channel send
   knobs, a drums bus), and a master strip. Notes:
   - Only voices on **hosted synths** have audio in the app; strips for voices sent out over MIDI
     can offer MIDI volume/pan (CC7/CC10) and say so.
   - Audio: the hosted graph already gives each synth its own mixer node, so EQ and sends slot in
     there. Apple's built-in units (`AVAudioUnitEQ`, `AVAudioUnitReverb`, `AVAudioUnitDelay`) need
     no new dependencies; AudioKit's effect packages (SoundpipeAudioKit and friends) offer more
     if those aren't enough.
   - Controls: AudioKit Controls (already used for the knobs) has knobs, sliders and wheels but no
     fader, so the fader is built on its `Control` base to match.
   - Every fader, knob and send is a param, so traffic can ride them in Modulation.
   (Replaces "effects on the hosted mix" under Later.)
3. **A hardware-style skin (feedback 2026-11-12)**, in the spirit of AudioKit's apps (King of FM 2
   as the reference): an original look, not their artwork. What makes that style:
   - dark charcoal panels with a fine grain, divided into labelled sections by inset/bevel lines
   - big 3D knobs (soft radial shading, drop shadow, a single light pointer line), labels in small
     caps underneath, value arcs and scale labels around the important ones
   - one typeface for everything: an all-caps, slightly technical / LCD-like font
   - a green-tinted **LCD screen** for the preset name and a short text blurb: a natural home for our
     "why did that play" explanations and live status
   - square LED toggles ("ON", "LO-FI"), segmented tab buttons (MAIN / PCM / FX / SEQ), arrow
     steppers for numbers (BPM, octave), a transport/footer bar, and a keyboard strip
   How to build it:
   - a `Skin` in the SwiftUI environment (colours, fonts, panel and LCD styles), so the system look
     stays available as a choice and every page picks the skin up without rewriting controls
   - draw knobs, LEDs, faders and panels in code (Canvas / gradients, procedural grain) so they're
     sharp at any size and need no image assets; build on AudioKit Controls' `Control` base, as the
     current knobs do
   - bundle an open-licensed font (e.g. an OFL dot-matrix or technical mono) for labels and the LCD
   - apply it first to the new tiles, mixer and tabletop (items 1–2) rather than restyling the long
     pages that those replace
   - our own art, generated on Tim's local ComfyUI (Z-Image Turbo and FLUX.2 klein 4B are installed,
     the same setup as the video skill): Claude writes the texture specs and prompts.
     - textures, not finished controls: panel surfaces (charcoal grain, light wear), knob-cap
       materials (radially symmetric, so they can rotate), LCD glass, section bevel strips, an app icon
     - lighting, shadows, pointers and value arcs stay in code, so a knob can turn without its
       highlight turning with it
     - panel textures must tile: generate, then make seamless (offset and blend), and check at 1× and 2×
     - keep source prompts and settings in the repo (e.g. `art/`) so the look can be regenerated
   - no reuse of AudioKit's artwork
4. **App, next round:** adding
   and removing hosted instruments, scene A/B comparison, MIDI-learn for params, an app bundle.
5. **MIDI clock**: out done (ADR 0018). Still to come: clock **in**, to follow a DAW; timestamped notes.
6. More generators: arpeggiator over the chord, flow-voice (one voice per live connection with voice stealing).
7. Drums, next: more grooves and odd meters, per-lane timing feel (laid-back snare), groove morphing between moods.
8. **Chord progressions from songs**: done (ADR 0019), McGill Billboard with decade / genre search and typed chords. Later: an optional Chordonomicon import (666k songs, non-commercial licence).
9. **Signal flow, editable**: drag cables to rewire voices and create mod routes; route long cables along the gutters.
10. **Styles** (ADR 0020): 23 genres, genre grooves and bass figures, arp / stab pulse modes, tempo-synced LFOs (wobble,
   pumping), preset suggestions, flat chord spelling. Later: grooves longer than a bar or on a triplet grid (trap rolls,
   jazz swing), style-aware motif rhythms, per-style mixer settings (reverb / delay sends).

## Later

- OSC param control (`/param/quant.pitch.strength 0.4`) and OSC from the LAN (parked 2026-11-13).
- Packets: per-process attribution via PKTAP (link events to app motifs), a whole-LAN capture source on a Pi (parked 2026-11-13).

- Whole-LAN capture: mirror port / router NetFlow / Pi-hole DNS log. Per-**device** leitmotifs (ADR 0009).
- MQTT bridge (Home Assistant / Zigbee2MQTT) for temperature, humidity and motion. Mostly the
  state layer: mode, key and tempo drift.
- Scene morphing, including choice params switching on boundaries.
- The plugins' own editor windows docked in the app (effects moved to the Mixer page, Next).
