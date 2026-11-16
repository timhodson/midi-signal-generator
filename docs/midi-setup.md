# MIDI setup

Run `msg-cli --list-destinations` to see what this Mac can send to, and
`msg-cli --list-instruments` for Audio Unit synths it can host itself.

## In the app

**Voices → each voice → "plays on"** picks the destination from a menu, live:

- **This Mac:** the virtual port "MIDI Signal Generator" (for DAWs, AUM…) and the network session.
- **Hosted synths** loaded by the scene.
- Every destination macOS knows, grouped as **Bluetooth, USB, Network, IAC buses, other apps**,
  including devices that are paired or known but not connected now. Those still work: notes
  reach them once they appear.

**Bluetooth MIDI…** opens macOS's Bluetooth MIDI panel to find and connect a device (e.g. an
iPad advertising Bluetooth MIDI from AUM or a synth's settings); it then shows up in the menu.
**Audio MIDI Setup** opens the system app for the network session and IAC buses. The choice is
saved with the scene (⌘S). Destinations are stored by display name, e.g. `"Tim's iPad Bluetooth"`,
which tells several Bluetooth devices apart (their endpoints are all called "Bluetooth").

## Hosted Audio Unit synths on the Mac (Synth One J6, King of FM 2…)

No other app is needed: the synths run inside `msg-cli` and play through the Mac's audio output.

```sh
msg-cli --scene scenes/audiokit-hosted.json --verbose
# or pick per role on the command line (role=synth[@preset]):
msg-cli --au pad="Synth One J6@Intersteller Pad" --au lead="King of FM 2@DX Tub Bells"
msg-cli --au pad="Synth One J6" --list-options au.pad.preset   # browse presets
msg-cli --au pad="Synth One J6" --list-params | grep '^au\.pad'  # all synth controls
```

Every synth control is a param, so it can be a mod-matrix target. The hosted scene routes
total traffic to `au.j6.cutoffLayer1`. `--verbose` also prints the output peak level every 5 s.
See [ADR 0010](decisions/0010-hosted-audio-unit-instruments.md).

## iPad synths over network MIDI (Wi-Fi)

1. On the Mac, open **Audio MIDI Setup → Window → Show MIDI Studio**, then double-click
   **Network**.
2. Under **My Sessions** add a session (the `+` button) and tick it to enable it. Set *Who may
   connect to me* to **Anyone**.
3. On the iPad, the AudioKit synth (or AUM, or any app with network MIDI) should see the Mac's
   session. Connect from the iPad, or select the iPad under **Directory** on the Mac and press **Connect**.
4. Run:

   ```sh
   msg-cli --scene scenes/ipad-network.json
   # or, with any scene:
   msg-cli --dest network
   ```

   `network` always means the Mac's network session, whatever it is called.
5. On the iPad, set each synth's MIDI input to the session and its channel to match the voices:
   `pad` = ch 1, `lead` = ch 2, `pulse` = ch 3 (change with `--set voice.lead.channel=5`).

If the destination warning says the session is disabled, step 2 hasn't taken effect yet.
Restart `msg-cli` after enabling it.

## Syncing arps, LFOs and delays (MIDI clock)

The app sends MIDI clock (24 pulses a beat) to every external destination a voice plays on, with
Start on a bar line and Stop when playback stops (Harmony → Clock; ADR 0018). In the iPad synth, set
its clock / sync source to **external MIDI** (in AudioKit's apps: Settings → MIDI → sync to MIDI
clock, or the arpeggiator's sync option); its arpeggiator and tempo-synced delay then follow the
piece's tempo, including tempo that traffic or a variation moves. If it lost its place (it
reconnected, or you stopped it), press **Restart on the next bar**. Hosted synths on the Mac follow
the tempo without any setting.

## USB cable to the iPad

This has lower latency than Wi-Fi. In Audio MIDI Setup → MIDI Studio, the iPad appears once it's plugged in and
trusted. Use its name with `--dest "<name from --list-destinations>"`.

## Bluetooth MIDI

In the app, use Voices → **Bluetooth MIDI…**; or pair it under Audio MIDI Setup → MIDI Studio → Bluetooth (the "Configure Bluetooth" button). Bluetooth has the
most latency, so delay the *other* voices to line up, e.g. `--set voice.lead.latencyMs=25`.

## A DAW or AUM on the Mac

The default scene sends to `virtual`, a virtual source called **MIDI Signal Generator**.
Pick it as a MIDI input in Logic, Ableton or any software synth.
