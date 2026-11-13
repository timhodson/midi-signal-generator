# 0020 — Genre styles

- **Status:** accepted
- **Date:** 2026-11-13

## Context

The piece is ambient by default. A genre (synthwave, house, funk…) is mostly a set of choices the
engine already makes (tempo, scale, progressions, drum groove, bass and pulse behaviour), plus some
rhythmic figures it didn't have: four-on-the-floor and half-time grooves, octave and off-beat bass,
arpeggios and chord stabs.

## Decision

- **New building blocks**, each an ordinary option, usable without styles:
  - drum grooves (appended to the choices so saved scenes keep theirs): Four on the floor, Disco,
    Synthwave, Backbeat, Boom bap, Dubstep, Funk, Breakdown
  - bass figures, one bar on the 16th grid: Eighths, Octaves, Off-beat, Funk, Boom bap, Wobble;
    `gen.bass.inQuiet` lets the bass sit out the quiet mood
  - pulse modes (`gen.pulse.mode`): Sparkle (the original), Arp up, Arp up-down, Off-beat stabs,
    Chord pulse, with `gen.pulse.arpOctaves`; density stays each step's chance, so traffic can thin
    or fill an arp
- **A style is data** (`Engine/Style.swift`): a tempo range, scales, a pool of progressions (scale
  degrees), Billboard genres to borrow progressions from (ADR 0019), and settings by param id, with
  choice params named by option ("Four on the floor") and checked by a test.
- **Applying** (`style.name`, at the next chord change, phrase restarted): settings, a tempo from the
  range, a scale from the list, and per mood a progression from the pool or, half the time, a verse
  or chorus of a song in the style's genres that fits the scale without bending a chord ("calm: verse
  of Rebel Yell, Billy Idol"). Progressions that would land on a diminished chord in the chosen
  scale are skipped. What changed goes in the Variation log; the result becomes Variation's home.
- **Moods as song structure:** quiet = the breakdown (hats and shaker; dance styles drop the bass),
  calm and busy = the groove and the drop, so traffic builds and releases the track.
- **Variation inside a style:** scales from the style's list, tempo within its range, fresh
  progressions from its pool and songs; bass figure, pulse grid, chord size and grooves are left as
  the style set them. Without a style, Variation no longer picks the genre bass figures.
- **New take** re-applies the style (new tempo, scale, progressions). **None** restores the scene as
  it was before the first style. Saved scenes record the applied style (`appliedStyle`), so loading
  doesn't re-apply it over later tweaks; a scene that only sets `style.name` gets it at the first chord.
- First pass: Synthwave, House, Disco, Funk, Hip hop, Dubstep, Rock, Pop.

## Consequences

- The sound is still the synths': a style can't make a hosted pad a TR-909. Next pass: patch
  suggestions per style for the hosted synths, and a tempo-synced LFO mod source (dubstep wobble,
  sidechain-style pumping).
- More styles are data only: techno, trance, drum & bass, lo-fi, trap, R&B, reggae/dub, ambient,
  jazz, blues, country, bossa nova, reggaeton, afrobeat, UK garage, synth-pop.
- Chord names are spelled with sharps (A♯ in D minor); flat spelling for flat keys is a follow-up.
