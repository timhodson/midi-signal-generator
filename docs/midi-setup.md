# MIDI setup

Run `msg-spike --list-destinations` to see what this Mac can send to, and
`msg-spike --list-instruments` for Audio Unit synths it can host itself.

## Hosted Audio Unit synths on the Mac (Synth One J6, King of FM 2…)

No other app is needed: the synths run inside `msg-spike` and play through the Mac's audio output.

```sh
msg-spike --scene scenes/audiokit-hosted.json --verbose
# or pick per role on the command line (role=synth[@preset]):
msg-spike --au pad="Synth One J6@Intersteller Pad" --au lead="King of FM 2@DX Tub Bells"
msg-spike --au pad="Synth One J6" --list-options au.pad.preset   # browse presets
msg-spike --au pad="Synth One J6" --list-params | grep '^au\.pad'  # all synth controls
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
   msg-spike --scene scenes/ipad-network.json
   # or, with any scene:
   msg-spike --dest network
   ```

   `network` always means the Mac's network session, whatever it is called.
5. On the iPad, set each synth's MIDI input to the session and its channel to match the voices:
   `pad` = ch 1, `lead` = ch 2, `pulse` = ch 3 (change with `--set voice.lead.channel=5`).

If the destination warning says the session is disabled, step 2 hasn't taken effect yet.
Restart `msg-spike` after enabling it.

## USB cable to the iPad

This has lower latency than Wi-Fi. In Audio MIDI Setup → MIDI Studio, the iPad appears once it's plugged in and
trusted. Use its name with `--dest "<name from --list-destinations>"`.

## Bluetooth MIDI

Pair it under Audio MIDI Setup → MIDI Studio → Bluetooth (the "Configure Bluetooth" button). Bluetooth has the
most latency, so delay the *other* voices to line up, e.g. `--set voice.lead.latencyMs=25`.

## A DAW or AUM on the Mac

The default scene sends to `virtual`, a virtual source called **MIDI Signal Generator**.
Pick it as a MIDI input in Logic, Ableton or any software synth.
