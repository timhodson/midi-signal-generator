# 0009 — Seeded randomness and per-app leitmotifs

- **Status:** accepted
- **Date:** 2026-11-12

## Context

Data should *shape* the music without fixing every note. Similar traffic should give a
recognisably similar mood, and you should be able to tell *who* is talking.

## Decision

- All randomness comes from one `SeededRandom` (SplitMix64) seeded by the scene's `seed`.
- Each app's motif comes from a **stable hash** (FNV-1a) of its name: its starting pitch
  class and a random walk of chromatic steps limited to `gen.motif.range`. Swift's `Hasher`
  is randomised per process, so it would give a new motif every launch.
- Motif pitches are *raw*, so `quant.pitch.strength` decides whether you hear the app's
  "true" chromatic shape or a version bent into the key.

## Consequences

- Safari always sounds like Safari (in a given key and scale). On the LAN the same scheme keys off device MAC addresses or hostnames.
- Runs aren't bit-identical, because real data and timer jitter change the order of RNG draws, but they keep the same character.
