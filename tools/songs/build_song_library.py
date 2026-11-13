#!/usr/bin/env python3
"""Build the app's song library from the McGill Billboard chord annotations.

The McGill Billboard Project (https://ddmal.music.mcgill.ca/research/The_McGill_Billboard_Project_(Chord_Analysis_Dataset))
is released under CC0: ~740 Billboard Hot 100 songs (1958-1991), annotated by hand with keys,
labelled sections and the chord in every bar. Genres come from Wikidata (also CC0), looked up per
artist and cached in artist-genres.json, so a rebuild needs no network unless artists change.

Usage (standard library only):
    python3 -I tools/songs/build_song_library.py INDEX.csv SALAMI_DIR [--refresh-genres]

    INDEX.csv   billboard-2.0-index.csv
    SALAMI_DIR  the extracted billboard-2.0-salami_chords.tar.gz (contains McGill-Billboard/NNNN/)

Writes Sources/Music/Songs/billboard.json. Each song:
    {"t": title, "a": artist, "y": year, "g": [genres], "k": key (0 = C), "m": scale index,
     "s": [{"n": section name, "c": ["0", "9m", "5", "7"]}]}
Chords are semitones above the song's key, plus "" major, "m" minor, "o" diminished, "+" augmented.
"m" indexes Music.ScaleCatalogue.scales (0 major, 1 minor, 2 dorian, 3 phrygian, 4 lydian,
5 mixolydian, 7 harmonic minor): the mode that fits the song's chords best.
"""

import csv
import json
import re
import sys
import time
import urllib.parse
import urllib.request
from collections import Counter, OrderedDict
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
OUT = REPO / "Sources" / "Music" / "Songs" / "billboard.json"
GENRE_CACHE = HERE / "artist-genres.json"

NOTE = {"C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11}
CHORD = re.compile(r"^([A-G])([b#]*):?([^/\s]*)")

# Same order and steps as Music.ScaleCatalogue.scales (checked by a Swift test).
MODES = [
    ("major", [0, 2, 4, 5, 7, 9, 11]),
    ("minor", [0, 2, 3, 5, 7, 8, 10]),
    ("dorian", [0, 2, 3, 5, 7, 9, 10]),
    ("phrygian", [0, 1, 3, 5, 7, 8, 10]),
    ("lydian", [0, 2, 4, 6, 7, 9, 11]),
    ("mixolydian", [0, 2, 4, 5, 7, 9, 10]),
    ("locrian", [0, 1, 3, 5, 6, 8, 10]),
    ("harmonic minor", [0, 2, 3, 5, 7, 8, 11]),
]
# Modes a song may be fitted to, most usual first (ties go to the earlier one). Locrian is left out.
CANDIDATES = [0, 1, 5, 2, 7, 4, 3]

SECTION_NAMES = {
    "intro": "intro", "verse": "verse", "chorus": "chorus", "refrain": "chorus", "pre-chorus": "pre-chorus",
    "prechorus": "pre-chorus", "pre-verse": "pre-chorus", "bridge": "bridge", "solo": "solo",
    "instrumental": "instrumental", "interlude": "interlude", "outro": "outro", "coda": "outro",
    "fadeout": "outro", "trans": "transition", "transition": "transition", "theme": "theme", "main theme": "theme",
    "secondary theme": "theme", "vamp": "vamp", "head": "theme", "breakdown": "breakdown",
}
SKIP_SECTIONS = {"silence", "end", "applause", "noise", "talking", "spoken", "fade-in", "fadein"}
MAX_CHORDS = 16

# Wikidata genre labels → the app's broad genres, first match wins.
GENRE_RULES = [
    ("Hip hop", r"hip hop|rap\b|\brap"),
    ("Disco", r"disco"),
    ("Funk", r"funk"),
    ("Soul & R&B", r"soul|rhythm and blues|r&b|motown|doo-wop|gospel|new jack|quiet storm"),
    ("Country", r"country|bluegrass|honky|western|nashville"),
    ("Folk", r"folk|singer-songwriter"),
    ("Jazz", r"jazz|swing|big band|bossa|bebop"),
    ("Blues", r"blues"),
    ("Rock 'n' roll", r"rock and roll|rock 'n' roll|rockabilly|rock & roll"),
    ("Rock", r"rock|metal|punk|grunge|psychedelic|garage|heartland|aor\b"),
    ("New wave & synth", r"new wave|synth|post-punk|new romantic"),
    ("Electronic & dance", r"electronic|dance|house|techno|freestyle|hi-nrg|eurobeat"),
    ("Reggae & Caribbean", r"reggae|ska|calypso|dancehall"),
    ("Latin", r"latin|salsa|mambo|bolero|tejano"),
    ("Pop", r"pop|bubblegum|teen|adult contemporary|easy listening|traditional pop|vocal|crooner|exotica|novelty|schlager"),
]


def section_name(label):
    """'pre chorus', 'chorus b', 'verse two', 'intro-a' -> the app's section name (None if not a section)."""
    label = re.sub(r"[\s-]+(a|b|c|one|two|three|four|five|\d)$", "", label.strip())
    if label in SECTION_NAMES:
        return SECTION_NAMES[label]
    if label.startswith("pre") and ("chorus" in label or "verse" in label):
        return "pre-chorus"
    for word in ["chorus", "verse", "intro", "bridge", "solo", "outro", "interlude", "instrumental", "theme"]:
        if label.endswith(word):
            return SECTION_NAMES[word]
    return None


def parse_chord(token):
    """'C#:min7/5' -> (1, 'm'); None for N, X, & and other non-chords."""
    m = CHORD.match(token)
    if not m:
        return None
    root = NOTE[m.group(1)] + m.group(2).count("#") - m.group(2).count("b")
    q = m.group(3)
    if q.startswith("hdim") or q.startswith("dim"):
        quality = "o"
    elif q.startswith("aug"):
        quality = "+"
    elif q.startswith("min") and not q.startswith("minmaj"):
        quality = "m"
    else:
        quality = ""  # maj, 7, sus, power chords, 9, 11, 13…
    return root % 12, quality


def parse_song(path):
    """Sections of one salami_chords.txt, in order: [(name, [(semitones above key, quality)])]."""
    tonic = None
    sections = []
    current = None
    for raw in path.read_text(errors="replace").splitlines():
        line = raw.strip()
        if line.startswith("#"):
            m = re.match(r"#\s*tonic:\s*([A-G][b#]*)", line)
            if m:
                tonic = (NOTE[m.group(1)[0]] + m.group(1).count("#") - m.group(1).count("b")) % 12
            continue
        parts = line.split("\t", 1)
        if len(parts) < 2:
            continue
        body = parts[1]
        fields = [f.strip() for f in body.split(",")]
        # Section starts look like "A, verse, | ... |" (letter, then a name).
        name = None
        for f in fields:
            if "|" in f:
                break
            low = f.lower().strip("'")
            if re.fullmatch(r"[A-Z]'*", f) or not low:
                continue
            if low in SKIP_SECTIONS:
                name = "skip"
            elif section_name(low):
                name = section_name(low)
        if name == "skip":
            current = None
            continue
        if name is not None:
            current = (name, [])
            sections.append(current)
        if current is None or tonic is None or "|" not in body:
            continue
        bars = body[body.index("|"):body.rindex("|") + 1]
        repeat = re.search(r"\|\s*x(\d+)", body)
        chords = []
        for bar in bars.split("|"):
            for token in bar.split():
                c = parse_chord(token)
                if c:
                    chords.append(((c[0] - tonic) % 12, c[1]))
        if repeat:
            chords = chords * min(int(repeat.group(1)), 4)
        current[1].extend(chords)
    return sections


def collapse(chords):
    out = []
    for c in chords:
        if not out or out[-1] != c:
            out.append(c)
    return out


def triad(c):
    root, q = c
    third = {"m": 3, "o": 3, "+": 4}.get(q, 4)
    fifth = {"o": 6, "+": 8}.get(q, 7)
    return [root, (root + third) % 12, (root + fifth) % 12]


def best_mode(chords):
    tones = Counter(t for c in chords for t in triad(c))
    total = sum(tones.values()) or 1
    def score(i):
        steps = set(MODES[i][1])
        return sum(n for t, n in tones.items() if t in steps) / total
    best = max(CANDIDATES, key=lambda i: (round(score(i), 3), -CANDIDATES.index(i)))
    # A tonic chord that's minor points at a minor-family mode when the fit is close.
    return best


def encode(c):
    return f"{c[0]}{c[1]}"


def wikidata_genres(artists):
    """artist name -> [Wikidata genre labels], via the public SPARQL endpoint (CC0 data)."""
    out = {}
    names = sorted(artists)
    for i in range(0, len(names), 40):
        batch = names[i:i + 40]
        values = " ".join(json.dumps(n) + "@en" for n in batch)
        query = f"""
        SELECT ?name ?genreLabel WHERE {{
          VALUES ?name {{ {values} }}
          ?a rdfs:label ?name .
          VALUES ?type {{ wd:Q5 wd:Q215380 wd:Q5741069 wd:Q2088357 wd:Q9212979 wd:Q216337 }}
          ?a wdt:P31 ?type ; wdt:P136 ?genre .
          ?genre rdfs:label ?genreLabel . FILTER(lang(?genreLabel) = "en")
        }}"""
        url = "https://query.wikidata.org/sparql?format=json&query=" + urllib.parse.quote(query)
        req = urllib.request.Request(url, headers={
            "User-Agent": "midi-signal-generator-song-library/1.0 (https://github.com/timhodson/midi-signal-generator)",
            "Accept": "application/sparql-results+json"})
        for attempt in range(3):
            try:
                with urllib.request.urlopen(req, timeout=60) as r:
                    data = json.load(r)
                break
            except Exception as e:  # noqa: BLE001 (retry anything, then give up on this batch)
                print(f"  wikidata batch {i // 40}: {e}", file=sys.stderr)
                time.sleep(5 * (attempt + 1))
        else:
            continue
        for row in data["results"]["bindings"]:
            out.setdefault(row["name"]["value"], set()).add(row["genreLabel"]["value"])
        for n in batch:
            out.setdefault(n, set())
        time.sleep(1)
        print(f"  wikidata: {min(i + 40, len(names))}/{len(names)} artists", file=sys.stderr)
    return {k: sorted(v) for k, v in out.items()}


def lookup_names(artist):
    """'Roberta Flack,Donny Hathaway' -> ['Roberta Flack,Donny Hathaway', 'Roberta Flack', 'Donny Hathaway']."""
    names = [artist]
    for sep in [",", " & ", " and ", " With ", " with ", " Featuring ", " featuring "]:
        if sep in artist:
            names += [p.strip() for p in artist.split(sep) if p.strip()]
    # Wikidata often names a group with "The" when the chart didn't, or the other way round.
    names += [n[4:] if n.startswith("The ") else "The " + n for n in list(names)]
    return list(OrderedDict.fromkeys(names))


def broad_genres(labels):
    counts = Counter()
    for label in labels:
        low = label.lower()
        for name, pattern in GENRE_RULES:
            if re.search(pattern, low):
                counts[name] += 1
                break
    return [g for g, _ in counts.most_common(2)]


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if len(args) != 2:
        sys.exit(__doc__)
    index_csv, salami_dir = Path(args[0]), Path(args[1])
    root = salami_dir / "McGill-Billboard" if (salami_dir / "McGill-Billboard").is_dir() else salami_dir

    rows = {}
    with index_csv.open(newline="") as f:
        for r in csv.DictReader(f):
            if r["title"] and r["artist"]:
                rows[int(r["id"])] = r

    songs = OrderedDict()
    for sid, r in sorted(rows.items()):
        path = root / f"{sid:04d}" / "salami_chords.txt"
        if not path.exists():
            continue
        key = (r["title"].strip().lower(), r["artist"].strip().lower())
        if key in songs:
            continue  # charted more than once: keep the first annotation
        sections = parse_song(path)
        tonic_line = next((l for l in path.read_text(errors="replace").splitlines() if l.startswith("# tonic:")), "")
        m = re.match(r"#\s*tonic:\s*([A-G][b#]*)", tonic_line)
        if not m or not sections:
            continue
        tonic = (NOTE[m.group(1)[0]] + m.group(1).count("#") - m.group(1).count("b")) % 12
        seen, out_sections, all_chords = set(), [], []
        for name, chords in sections:
            prog = collapse(chords)[:MAX_CHORDS]
            if len(prog) < 2:
                continue
            sig = (name, tuple(prog))
            if sig in seen:
                continue
            seen.add(sig)
            all_chords += prog
            out_sections.append({"n": name, "c": [encode(c) for c in prog]})
        if not out_sections:
            continue
        songs[key] = {
            "t": r["title"].strip(), "a": r["artist"].strip(), "y": int(r["chart_date"][:4]),
            "k": tonic, "m": best_mode(all_chords), "s": out_sections[:8],
        }

    # Genres: cached per lookup name; fetch the missing ones (or all, with --refresh-genres).
    cache = json.loads(GENRE_CACHE.read_text()) if GENRE_CACHE.exists() and "--refresh-genres" not in sys.argv else {}
    wanted = {n for s in songs.values() for n in lookup_names(s["a"])}
    missing = wanted - cache.keys()
    if missing:
        print(f"looking up {len(missing)} artists on Wikidata…", file=sys.stderr)
        cache.update(wikidata_genres(missing))
        GENRE_CACHE.write_text(json.dumps(dict(sorted(cache.items())), indent=1, ensure_ascii=False) + "\n")
    for s in songs.values():
        labels = []
        for n in lookup_names(s["a"]):
            labels += cache.get(n, [])
            if labels:
                break
        s["g"] = broad_genres(labels)

    library = {
        "source": "McGill Billboard Project v2.0 (CC0), https://ddmal.music.mcgill.ca/research/The_McGill_Billboard_Project_(Chord_Analysis_Dataset); genres from Wikidata (CC0)",
        "songs": sorted(songs.values(), key=lambda s: (s["a"].lower(), s["t"].lower())),
    }
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(library, separators=(",", ":"), ensure_ascii=False) + "\n")
    genres = Counter(g for s in songs.values() for g in s["g"])
    print(f"wrote {OUT.relative_to(REPO)}: {len(songs)} songs, {OUT.stat().st_size // 1024} KB; "
          f"without a genre: {sum(1 for s in songs.values() if not s['g'])}; genres: {dict(genres.most_common())}")


if __name__ == "__main__":
    main()
