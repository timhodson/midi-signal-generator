# 0019 — Chord progressions from real songs (McGill Billboard library)

- **Status:** accepted
- **Date:** 2026-11-13

## Context

A mood's progression is a list of scale degrees, edited chord by chord. A quicker way in is to borrow
the chords of a song you like: "the chorus of Stand By Me for the calm mood".

Libraries considered: **McGill Billboard** (~740 Hot 100 songs 1958–1991, hand-annotated keys,
sections and bar-by-bar chords, **CC0**); **Chordonomicon** (666k songs from user-submitted charts;
its dataset card says CC BY-NC 4.0; songs identified by Spotify IDs; 237 MB); **ChoCo** (~20k pieces,
mostly CC BY 4.0, some CC BY-NC-SA); **Hooktheory** (no song-level API; terms forbid bulk use).
Chord progressions themselves aren't generally protected by copyright; the annotations are the
datasets' work, hence the licence matters.

## Decision

- **Bundle McGill Billboard**, built once by `tools/songs/build_song_library.py` (standard library
  Python) into `Sources/Music/Songs/billboard.json` (~320 KB, 734 songs): per song title, artist,
  chart year, genres, key, best-fitting mode and up to 8 distinct sections ("verse", "chorus",
  "bridge"…), each up to 16 chords with repeats collapsed. Chords are stored as semitones above the
  key (in force at that point: key changes are followed) plus triad quality; sevenths and extensions
  reduce to their triad (chord size adds notes back in the engine).
- **Genres from Wikidata** (CC0), per artist (`P136`), mapped to 15 broad genres, cached in
  `tools/songs/artist-genres.json` so a rebuild needs no network. ~70 songs have no genre ("Unknown").
  Decade comes from the chart date.
- **Fitting** (`SongLibrary.fit`): a chord whose root is in the target scale keeps that degree (exact,
  or "the scale's own chord on that root" if its quality differs, e.g. a secondary dominant); a root
  outside the scale bends to the scale chord sharing the most notes. The picker can switch the
  piece to the song's best-fit mode (on by default: ♭VII rock songs come through in Mixolydian) and
  optionally its key, and shows per chord how it will play.
- **Typed chords** ("Am F C G", "Bb7 Ebmaj7") go through the same fit.
- UI: "From a song…" on each mood in Harmony → Chord progressions: search title/artist, filter by
  decade and genre, pick a section, "Use for <mood>".

## Consequences

- Songs are a sample of chart positions, not a greatest-hits list: many famous titles aren't there.
  Chordonomicon could be an optional, user-downloaded import later (non-commercial licence).
- Progressions store degrees, so a song's progression follows later key/scale changes and Variation.
