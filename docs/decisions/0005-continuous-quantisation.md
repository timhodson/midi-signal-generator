# 0005 — Quantisation is a continuum, not a switch

- **Status:** accepted
- **Date:** 2026-11-12

## Context

"Faithful or pleasant" is a matter of degree. Each musical tidy-up step needs a control running from
"raw data" to "fully musical".

## Decision

Generators emit **intents** with *raw* values. The `Quantiser` then applies each step with its own strength:

| Step | Params | Behaviour |
|---|---|---|
| Density | `quant.density.probability`, `quant.density.maxPerSecond` | probability gate, then token bucket. Notes marked *essential* (pad chords) are exempt |
| Pitch | `quant.pitch.strength` | per note: P(chord tone) = max(0, 2s−1), P(in scale) = min(1, 2s), otherwise raw chromatic. 0 = raw, 0.5 = always in scale, 1 = always a chord tone |
| Time | `quant.time.strength`, `.grid`, `.swing`, `.humanise` | interpolates from the raw time towards the **next** grid line (we can't play the past), plus swing on odd steps and random spread |
| Velocity | `quant.velocity.curve`, `.floor`, `.ceiling` | `floor + (ceiling−floor)·intensity^curve` |

Pitch can also be `.chordTone(i, octave)` for generators that *are* the harmony (the drone).
Those notes skip pitch quantising.

`macro.faithfulness` moves all of these together (plus `harmony.hysteresis`).

## Consequences

- At in-between strengths the pitch output is **probabilistic**. That's deliberate: a
  half-quantised melody sounds like it's "trying" to be in key. The RNG is seeded (ADR 0009).
- Snapping time only ever delays notes, so with strength 1 and a coarse grid, events can be heard up to one grid step late.
