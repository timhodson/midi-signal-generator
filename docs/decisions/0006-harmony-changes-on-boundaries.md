# 0006 — Harmony changes on boundaries, with smoothing and hysteresis

- **Status:** accepted
- **Date:** 2026-11-12

## Context

If chords followed packet types directly they would change every few hundred milliseconds. Network
traffic is bursty: the first live test showed the mood stuck on "quiet" even at ~20 kB/s,
because every dip below the threshold reset the hysteresis timer.

## Decision

The `Conductor`:

1. **Smooths** total and per-app rates (`conductor.smoothing`, one-pole, seconds).
2. **Classifies** a mood: `quiet` (< `conductor.quietBelow`), `busy` (> `conductor.busyAbove`),
   `focused` (busy, and one app ≥ `conductor.focusRatio` of traffic), otherwise `calm`.
3. Switches progression only once a new mood has lasted `harmony.hysteresis` seconds, and,
   if `harmony.changeOnPhrase` is on, only when the current progression wraps around.
4. Changes chord only on bar lines, every `harmony.barsPerChord` bars.
5. **Combinations → gestures:** ≥ `conductor.flurryApps` activations within
   `conductor.flurryWindow` s (at most once per `conductor.flurryCooldown` s) queue the scene's `flurry` gesture (default v → i), which plays
   ahead of the progression. A finished gesture ends the phrase, so the progression restarts
   and a pending mood change can happen there.

Progressions are per mood, as scale-degree lists in the scene. Chords are stacked thirds of
`harmony.chordSize` notes, so changing scale or mode re-colours every progression automatically.

## Consequences

- Harmony moves at musical speed whatever the data rate.
- More gestures (e.g. a key change when a new device joins the LAN, or a cadence when traffic goes
  quiet) fit the same queue.
- Mode, key and tempo are not yet state-driven. Sensors are the natural driver (temperature →
  mode); this will need "switch at a boundary" handling for choice params (ADR 0002).
