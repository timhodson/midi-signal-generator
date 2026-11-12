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

## Live visuals (second round)

Settings pages open with a picture of what their controls change, drawn from the same params
the sliders edit, so moving a control changes the picture immediately:

- **Harmony:** a mood bar (log traffic axis, quiet/calm/busy bands, draggable thresholds,
  smoothed and raw markers), a keyboard of the scale, the current chord and the sounding notes,
  and a piano roll with a chord band. Above Root/Scale/Chord size: **Chords in this key**, every
  chord the scale offers, with its scale steps (1·3·5…), notes and a mini keyboard. Click one to
  audition it (`Engine.auditionChord`). Then **Chord progressions by mood**, an editor with a popover for
  each chord (pick any scale chord, move, duplicate, remove), add, reset to default. Edits go live
  through `Engine.setProgression` and are saved in the scene.
- **Quantise:** pitch asked→played, timing asked→played against the grid and swing, the velocity curve
  with recent notes, and a density meter against the limit. Needs `PlayedNote.rawPitch/rawTime/intensity`.
- **Generators:** an all-voices piano roll, and a lane per generator.
- **Voices:** a keyboard per voice with draggable range handles, plus its piano roll.
- **Instruments:** a lane for each voice the synth plays. **Modulation:** live sparklines for each route's
  input and the target's value.

Visuals scroll smoothly by extrapolating engine time between the 10 Hz status updates.
(Menus with custom labels lose their styling on macOS, so editable chips are buttons with popovers.)

## Visual-first controls (third round)

- A setting that a visual can set directly is moved out of the slider list into an **Advanced** drawer
  at the end of its group, with sliders and typed exact values (`VisualControls`). Direct controls:
  mood thresholds (mood bar), pitch strength (strength bar), density limit (red line, fixed log scale),
  velocity floor/ceiling/bend (handles on the curve), voice ranges (keyboard handles). Searching still shows everything.
- Drag areas built from offset children must be pinned to their full size (`.frame(width:height:)`
  before `.contentShape`). Otherwise only part of the control accepts drags (this was the busy-threshold bug).
- Piano rolls: hovering pauses the roll. Details appear in a fixed panel at the left (never over the
  note); all notes of a hovered motif's wake-up are outlined (`MotifTag.instance`). There's no system tooltip.
- The Motifs page lists apps in first-heard order, so it doesn't reshuffle as traffic changes.

## Knobs and LED buttons (fourth round)

- Continuous settings default to **AudioKit-style arc knobs** (`ParamKnob`), built on AudioKit Controls'
  `Control` primitive with a vertical drag. The ring fills from the left, or from the centre for bipolar
  params (pan, route depth); an orange dot shows the live modulated value; the value in the middle uses
  our formatting. AudioKit's own `ArcKnob` shows `Int(value)` while dragging, which can't show 0–1 values.
- Toggles are **LED buttons** (lit in the group's colour); pickers stay rows. Knobs and LEDs take the
  voice colour in generator and voice groups.
- With explanations on, a knob grid shows the hovered knob's explanation above it.
- A toolbar switch flips between **Knobs** and **Sliders** (sliders keep inline explanations).
- Instruments: volume and pan knobs; the synth's own parameters as a knob grid.
- `Circle().trim` doesn't wrap past 1, so arcs are drawn from 0 and rotated to their start angle.

## Consequences

- New params appear in the UI with no UI work.
- The AudioKit Controls and Keyboard packages (ADR 0001) aren't used yet: built-in sliders are
  more practical for long lists. A Keyboard-based range editor for voices is a natural follow-up.
- Voice destinations and instrument lists are still edited in the scene JSON (not yet in the UI).
- Without an app bundle, `swift run msg-app` sets itself to a regular Dock app at launch. A
  signed `.app` bundle comes when distribution matters.
