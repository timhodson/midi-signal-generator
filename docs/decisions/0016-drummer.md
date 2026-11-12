# 0016 — The drummer: steady grooves whose feel follows the data

- **Status:** accepted
- **Date:** 2026-11-12

## Context

Percussion was the missing layer. The obvious mapping, one hit per network event, sounds
random rather than rhythmic: traffic is bursty and has no pulse. Drums also differ from the
other voices: their notes are drum sounds, not pitches, so the pitch quantiser and chords must
leave them alone, and their timing is the groove itself, so time quantising mustn't move them.
Presence matters too: the same piece can want a faint shaker texture or a groove that drives it.

## Decision

- **Pattern drummer, data-driven feel.** `DrumGenerator` (`gen.drums.*`, role `drums`) plays a
  one-bar, 16-step groove per mood (`gen.drums.groove.<mood>`: Shaker, Heartbeat, Brushes,
  Halftime, Broken, Euclidean, or Off). The data decides how busy it is, when it fills, and
  when it rests, not where each hit goes.
- **Grooves are text.** One string per lane (kick, rim, snare, closed/open hat, shaker, high/low
  tom, crash): `X` accent and `x` hit always play; `o` optional, `g` ghost and `-` rare extra
  each have a complexity threshold and play with a chance that ramps ±0.1 around it.
- **Two feel controls, both parameters:**
  - **presence** (0–1): which lanes play at all. Light sounds come first (shaker, rim, then hats,
    kick, toms, snare, crash), so low presence is a texture and high presence a full kit. Below
    the snare's level its backbeat survives as a rim click.
  - **complexity** (0–1) plus **response** × traffic level (log scale, smoothed): how many optional
    steps play.
- **Structure from the conductor.** The generator context now carries mood, progression position,
  pending gestures and flurries. The last bar of a progression may get a fill (`fills` chance;
  style Auto / Soft / Toms / Snare roll; `fillBeats` long), followed by a crash when presence
  allows. A flurry fills the rest of the bar. A mood change crashes on its downbeat. An idle
  network (`idleBelow`) drops to the always-on hits, then rests after `restAfter` bars.
- **Locked intents.** `NoteIntent.locked` skips time quantising and the density limiter; the drummer
  applies its own swing, timing and velocity humanising. Pitches are `.exact` kit-map notes
  (`gen.drums.note.<lane>`, General MIDI by default).
- **Euclidean grooves** come from per-lane hits/rotation params, so the mod matrix can grow a
  rhythm from a signal.
- **Network accents** (off by default): a DNS lookup is a rim click, a reset a choked open hat, a
  LAN announcement a shaker, on the next 16th, rate-limited.
- **Sound with no setup.** Scenes gain a `drums` voice on channel 10 when they lack one: on Apple's
  built-in General MIDI synth (`DLSMusicDevice`, hosted in-process) when every voice is a hosted
  synth, otherwise on the pad's destination. Edited grooves are saved in the scene (`grooves`),
  replacing the built-in of the same name.

## Consequences

- Drums stay musical at any traffic level: the worst case is a busier version of the same groove.
- The tempo now matters audibly, which makes MIDI clock (roadmap) more valuable.
- iPad and external scenes send drums on channel 10; a synth listening on all channels will play
  them as pitches. Turn `voice.drums.enabled` off, or set its channel, for those setups.
- The app shows the groove as an editable grid with each step's chance at the current complexity,
  draggable presence and complexity bars, and every hit's reason.
