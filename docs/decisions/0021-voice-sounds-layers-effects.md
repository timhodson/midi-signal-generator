# 0021 — A voice's sound in one place: layers, hosted synths, effects, pause

- **Status:** accepted
- **Date:** 2026-11-16

## Context

Voices (where a role's notes go) and Instruments (the hosted synths) were separate pages, so
setting up a sound meant choosing the synth on one page and its preset on another. Hosted synths
were named by their scene id, so "bells" stayed "bells" after its preset became Rock Organ. A
voice could reach only one destination, there was no way to add a synth or an effect from the
app, and Stop unloaded everything, so there was no way to hold the music for a moment.

## Decision

- **Layers** (`VoiceConfig.layers`): a voice can send its notes to several outputs. Each layer
  has its own destination and channel, and a transpose, level and delay on top of the voice's
  (`voice.<role>.layerN.*`). The voice's range and polyphony apply to all layers; polyphony is
  counted per output so layers don't steal each other's notes. Controllers (LFO CCs) reach every
  layer. Saved only when present, so older scenes are unchanged.
- **One Sound panel per voice:** where it plays, then for a hosted synth its preset, volume, pan,
  editor, synth parameters and effects; one card per layer; then range and channel. The
  Instruments page left the sidebar (a synth's own panel still exists for the tabletop, windows
  and Signal flow).
- **Hosted synths are named by what they are now** ("King of FM 2 · DX Tub Bells"); the id stays
  internal because params, routes and mixer settings are filed under it.
- **New hosted synth / unload unused** from a voice's destination menu. **Effects**
  (`InstrumentConfig.effects`): AU effects (`aufx`, `aumf`) chained synth → effects → EQ →
  fader, each with bypass, a factory-preset menu, its editor and every parameter as
  `au.<synth>.fxN.*`. These are structural changes: the scene is updated and the session
  reloaded (every setting carries over; hosted synths take a moment). Removing or moving a
  numbered item (layer, effect) renumbers its params and modulation routes (`Scene.renumber`,
  `Scene.swapPrefixes`).
- **Pause** (`Engine.setPaused`): notes are released, the clock stands still and MIDI clock
  sends Stop, while params, signals, the mixer and hosted synths keep running. Play carries on
  from the same beat and strikes the chord again. Play/pause, randomise and stop sit in the
  middle of the toolbar.

## Consequences

- Adding a synth or an effect reloads the sound briefly rather than patching the audio graph
  live; that's simpler and robust, and can become live later if the gap is a nuisance.
- One hosted synth can be shared by several voices; its panel warns that changing its sound
  changes theirs too.
