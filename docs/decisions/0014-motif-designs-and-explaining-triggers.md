# 0014 — Motif designs in scale steps, and explaining why notes play

- **Status:** accepted
- **Date:** 2026-11-12

## Context

Two questions came up while listening: *what makes each voice play?*, and *why do some motifs
clash?* Generated motifs are chromatic shapes derived from the app's name. The pitch quantiser pulls them
towards the scale or chord, so at most strengths a note can land in the scale but off the chord,
or (below strength 0.5) out of key.

## Decision

**Motif designs** (`MotifDesign`, saved in the scene's `motifs`):
- Steps are **scale steps above an anchor**, either the current chord's root (the motif follows the
  harmony) or the key's tonic (same notes on every chord). `nil` steps are rests. Designed notes are played
  as exact notes (`Pitch.exact`), so the quantiser doesn't move them: a design always stays in key, and
  steps on chord rows always fit the chord.
- `match` picks the apps a design applies to: an exact name beats "name contains", which beats `*` (all
  other apps). The same mechanism will cover traffic types and devices once those signals exist.
- Optional step length and octave; otherwise the motif generator's settings apply.
- "Customise" turns what an app's generated motif *plays now* into the nearest scale steps, to tweak a
  clashing note while keeping the app's character.
- `Engine.previewMotif(for:)` injects a pretend wake-up, so motifs can be heard on demand.

**Motifs page:** apps heard (wake-ups, rate, ignored or custom), the generated motif (raw vs played pitch,
with chord/scale rows), a step-grid editor (rows highlighted when their note is in the current chord),
and a strip showing how the design sounds over the current chord (orange = chord note,
yellow = scale note, red = out of key).

**Explaining triggers:**
- Every note carries a reason, now worded for people: "chord changed → Dm", "23% chance on this step ·
  traffic 41 kB/s", "Safari woke (32 kB/s) · design “Safari”", "fill · 12% chance at traffic…",
  "tonic pedal · re-struck every 8 bars".
- **Hover any note in a piano roll** to see its reason.
- Each generator group starts with a **"What makes the … play"** card built from the current settings
  and traffic (e.g. how often a pulse fires right now and why).

**Follow-ups:**
- Motif notes carry a tag (app, step, design) through to `PlayedNote.motif`. The app lights the sounding step
  in the step grid, the strips, the list thumbnails and the **All motifs** gallery (designs and every app heard).
- Piano rolls **pause while the pointer is over them**, with a "paused" badge, holding a snapshot of the notes
  so the inspected note can't scroll away. They ease back to live over 0.5 s when the pointer leaves.

## Consequences

- Discord can be fixed per app without losing the "who's talking" mapping.
- Designs ignore `quant.pitch.strength`: they are deliberate choices.
