# 0010 — Host Audio Unit instruments in-app, one per voice

- **Status:** accepted
- **Date:** 2026-11-12

## Context

AudioKit's **Synth One J6** and **King of FM 2** are installed on the Mac as AUv3 instruments
(`aumu j6ct AuPr`, `aumu kfm2 AkPr`). We want a different synth per voice. GarageBand can
host them, but it plays live MIDI into the selected track only, so one synth per channel isn't possible there.

## Decision

- New target **`AUHost`** with `AUHostSink`: an `AVAudioEngine` with one plugin instance per
  `InstrumentConfig`, each through its own mixer (volume, pan) into the main output.
- A scene's `instruments` list names a component (`--list-instruments`) and an optional factory
  preset. Voices reach an instrument with destination **`au:<id>`**. A `CompositeSink` sends
  `au:` destinations to the host and everything else to CoreMIDI, so one scene can mix hosted
  synths with the iPad. CLI shortcut: `--au pad="Synth One J6@Intersteller Pad"`.
- MIDI goes straight into the plugin via `scheduleMIDIEventBlock`, with no CoreMIDI hop.
- **Every plugin parameter becomes a param.** `au.<id>.volume`, `.pan`, `.preset` (a choice of
  factory presets, `--list-options au.<id>.preset`), plus the whole parameter tree
  (J6: 170, King of FM: 105), with a shared id prefix stripped (`neoncutoffLayer1` → `au.j6.cutoffLayer1`).
  The mod matrix can therefore drive a synth's own controls from data, with no CC mapping.
  Values are pushed only when *our* value changes, so a preset's own settings aren't
  overwritten. After a preset change our base values are re-read from the plugin.
- `engine` registers sink params through the `ParameterisedSink` protocol and calls
  `applyParams` every tick. In `--dry-run` instruments aren't loaded, and their `au.*` scene values are kept as they are.

## Findings

- **Plugins load out of process by default** (`outOfProcess: true`). Loaded in-process from
  the CLI, King of FM 2 crashed the app.
- **A hosting process needs AppKit.** Even with no UI, plugins use ViewBridge (remote views) over
  XPC and hop onto the main thread. Without an `NSApplication` this throws
  "already on an AppKit thread" and aborts. The CLI sets up `NSApplication` with a `.prohibited`
  activation policy (no Dock icon) and runs `NSApplication.shared.run()` instead of `dispatchMain()`.
- `AVAudioUnit.instantiate` delivers its result on the main queue, so the CLI waits for it by
  running the main run loop rather than blocking it.
- **Presets only apply to a running plugin.** Synth One J6 accepts `currentPreset` before the
  engine starts and even reports it back as current, but keeps its default sound ("2025: Space
  Trip"). Its parameter values then update **asynchronously**. The host therefore selects presets
  after `engine.start()` and waits until the values have changed and held still for 200 ms (2 s
  timeout) before reading them as param defaults. It warns if nothing changed. A preset changed at
  runtime is re-read after 0.6 s.
- Factory preset names can have trailing spaces and curly apostrophes ("Heaven’s Gate Pad "), so
  lookup is trimmed, case-insensitive and apostrophe-agnostic. A number selects by index.
- Fixing a plugin param in a scene (as the hosted scene first did with the J6 cutoff) overrides
  every preset's own value. Prefer mod routes, which offset the preset's value.
- A peak meter on the main mix (`takePeak()`, printed with `--verbose`) confirms rendering
  headlessly. Three synths at default levels peaked around −4 dBFS, so the hosted scene uses lower volumes.

## Consequences

- No external host needed, and the sound runs on the Mac alongside network MIDI to the iPad.
- The plugins' own editor windows need the SwiftUI app (`requestViewController`). Until then: presets and params only.
- Out-of-process plugins cost a little CPU and latency per render cycle. That's acceptable for ambient music, and
  any instrument can switch to `outOfProcess: false`.
- Built-in effects (reverb or delay sends on the mix) are a natural next step for the same engine.
