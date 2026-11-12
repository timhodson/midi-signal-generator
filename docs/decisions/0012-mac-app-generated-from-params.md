# 0012 — The Mac app: SwiftUI, panels generated from ParamSpecs, shared Runtime

- **Status:** accepted (first version)
- **Date:** 2026-11-12

## Context

With hosted synths there are 470+ parameters. Tweaking them through `--set` was the
bottleneck. The CLI and the app also had to build sessions the same way (hosted synths,
MIDI outputs, source, recorder).

## Decision

- **`Runtime` target** with `Session`: builds the hosted synths, the `CompositeSink`, the `Engine`, the source
  and the recorder from a `Scene` + `SessionOptions`. The CLI (`msg-spike`) and the app (`msg-app`) both use it.
- **Engine → UI:** `Engine.onStatus` publishes an `EngineStatus` about 10× a second from the engine
  queue: mood, chord, key, tempo, rates, top apps, every param's base and effective value,
  signal values and recent notes. UI → engine: `Session.set(id, value)` hops onto the engine queue.
  The UI updates its copy of the base value straight away so sliders don't jump back.
- **SwiftUI app (`msg-app`)**, a SwiftPM executable (no Xcode project). Sidebar sections:
  Overview, Harmony, Quantise, Generators, Voices, Instruments, Modulation.
  - Parameter panels are **generated** from `ParamSpec`: toggle → switch, choice → picker,
    integer → slider + stepper, continuous → slider (log scale for `B/s` thresholds). Help
    text becomes tooltips. When modulation moves a value, an orange marker and `~value` show the
    current value next to the user's base value. Each section can be filtered.
  - The Overview has a transport (start/stop, live / synthetic / replay source, record), status
    cards (mood, chord, tempo, traffic, sounding notes, output peak), the faithfulness macro, a
    traffic chart on a log axis with the quiet/busy thresholds, busiest apps and recent notes (Swift Charts).
  - Instruments: preset picker, volume, pan, every synth parameter, and **Open Editor**,
    which shows the plugin's own UI (`requestViewController`) in a window.
  - Modulation: routes with live input values, depth, add/remove. Structural edits (adding or
    removing routes, opening a scene) rebuild the session. Stopping keeps every tweak in the scene.
  - Scenes: Open / Save / Save As (⌘O, ⌘S, ⇧⌘S).
- **Headless UI check:** `msg-app --snapshot <dir> [--seconds N]` starts the session, renders
  every section offscreen to PNG, and exits. It paints the window background itself, because an
  offscreen capture doesn't draw it.

## Consequences

- New params appear in the UI with no UI work.
- The AudioKit Controls and Keyboard packages (ADR 0001) aren't used yet: built-in sliders are
  more practical for long lists. A Keyboard-based range editor for voices is a natural follow-up.
- Voice destinations and instrument lists are still edited in the scene JSON (not yet in the UI).
- Without an app bundle, `swift run msg-app` sets itself to a regular Dock app at launch. A
  signed `.app` bundle comes when distribution matters.
