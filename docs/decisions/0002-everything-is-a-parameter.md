# 0002 — Every musical decision is a parameter

- **Status:** accepted
- **Date:** 2026-11-12

## Context

Whether the output is *faithful* (you can hear what the network is doing) or *pleasant*
(the data only colours an ambient piece) is the user's choice, and it may change from moment to moment.
So no quantisation, scale, threshold or other musical decision may be hard-coded.

## Decision

- Every tunable value is a `ParamSpec`: id, kind (normalised / continuous / integer / choice
  / toggle), range, default, unit, help text, and whether it can be modulated. They live in one `ParamStore`.
- Components *declare* their params (`Quantiser.params`, `Conductor.params`, each generator's
  `params`, each voice's `voice.<role>.*`). Nothing reads a magic number.
- `ParamStore` keeps **base** values (set by the user or scene) and **offsets** (from the mod
  matrix). The engine always reads `value(id)`, which is base + offset, clamped and rounded.
- **ModMatrix**: rows of `source signal → target param` with input range, linear/log scale,
  curve, smoothing and depth. Each row's depth is itself a param (`mod.<n>.amount`).
- **Macros** move several base values together (e.g. `macro.faithfulness`). A macro writes only
  when it is moved, so individual tweaks afterwards still work.
- Unknown ids are errors (typos in scenes or `--set` fail loudly).
- A **Scene** (JSON) is the full state: param values, routes, macros, voices, progressions,
  gestures and the ignore list. `--dump-scene` output reloads to the same scene.

## Consequences

- The UI can be generated from specs: one knob type per kind, with the help text as tooltip.
- OSC and MIDI-learn control later need only a param id.
- The cost is some ceremony: a new behaviour means declaring its params first.
- Choice and toggle params are never modulatable, because a CC wobbling a scale index would be chaos.
  A future "scene morph" can switch them at boundaries instead.
