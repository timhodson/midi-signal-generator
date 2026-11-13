# 0017 — Variation: randomising the melodic presentation by a deviation, now or on a schedule

- **Status:** accepted
- **Date:** 2026-11-13

## Context

A piece that runs for hours needs to change character now and then, beyond what traffic does
moment to moment: a new key, a different scale, other progressions, new motifs. Doing that by hand
means touching dozens of settings, and fully random settings sound broken (chromatic "scales",
diminished chords as phrase centres, a lead three octaves up).

## Decision

- **A Variation engine** (`Engine/Variation.swift`, `variation.*` params) changes a curated set of
  settings in groups that can be switched on and off:
  harmony (root, scale, chord size, bars per chord, every mood's progression), motifs (a motif
  seed, length, range, step, octave, the network-event note seed), generators (pad octave and
  spread, pulse octave/span/grid, bass pattern and register, sub mode), tempo, drums (groove per
  mood, swing, fill style). Tempo and drums are off by default.
- **Deviation** (`variation.amount`, 0–1, modulatable) is both the chance that each setting changes
  and how far it moves. Rules keep it musical: the key moves around the circle of fifths (one step
  at low deviation); scales come from everyday modes, adding Phrygian/harmonic/melodic minor from 0.5
  and Locrian/whole tone from 0.85, never chromatic; progressions usually keep the tonic first, avoid
  diminished chords and repeated neighbours, and may gain or lose a chord at higher deviation; numbers
  stay within ranges that suit each voice.
- **Home.** Variations start from a remembered home (the scene as loaded, or "Make this home"), so
  the piece never wanders far; "from: where it is now" makes them drift. "Return home" restores it.
- **Seeds.** Generated motifs and network-event notes take a seed (`gen.motif.seed`,
  `gen.packets.seed`; 0 = the original), so a variation can give every app a new tune while each app
  still keeps one tune within a set.
- **When.** `variation.every` (off, 5 min … 4 h). Scheduled variations wait for the end of the chord
  progression; "Randomise now" and "Return home" use the next chord change. On applying, the phrase
  restarts and the pad, bass and sub re-strike in the new key, so no old-key chord hangs over.
- **Explained.** Each variation is logged in words ("key D → F", "calm: Dm C G Am → Dm Em F Am"),
  shown in the app and the engine log.

## Consequences

- Saving a scene saves what's playing (a variation, not the home). The app no longer overwrites a
  loaded scene silently: ⌘S offers Save as New… (default) or Replace.
- Motif designs (hand-made motifs) are untouched; only generated motifs reshuffle.
