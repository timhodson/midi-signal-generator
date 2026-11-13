import Foundation

/// Chord progressions from real songs: the McGill Billboard Project's hand-annotated chords for
/// ~730 Billboard Hot 100 songs (1958–1991, CC0), with genres from Wikidata (CC0). Built by
/// `tools/songs/build_song_library.py` into `Songs/billboard.json` (ADR 0019).
///
/// Chords are stored relative to the song's key, so a section can be played in the piece's own
/// key: `fit(_:into:)` turns it into the scale degrees a mood's progression is made of.
public struct SongLibrary: Sendable {
    public let songs: [Song]
    public let source: String

    public struct Song: Sendable, Hashable, Identifiable, Decodable {
        public let title: String
        public let artist: String
        public let year: Int
        public let genres: [String]
        /// The song's key: 0 = C.
        public let key: Int
        /// Index into `ScaleCatalogue.scales` of the mode that fits its chords best.
        public let scaleIndex: Int
        public let sections: [Section]

        public var id: String { "\(artist)|\(title)" }
        public var decade: Int { year / 10 * 10 }

        enum CodingKeys: String, CodingKey { case title = "t", artist = "a", year = "y", genres = "g", key = "k", scaleIndex = "m", sections = "s" }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            title = try c.decode(String.self, forKey: .title)
            artist = try c.decode(String.self, forKey: .artist)
            year = try c.decode(Int.self, forKey: .year)
            genres = try c.decodeIfPresent([String].self, forKey: .genres) ?? []
            key = try c.decode(Int.self, forKey: .key)
            scaleIndex = try c.decode(Int.self, forKey: .scaleIndex)
            sections = try c.decode([Section].self, forKey: .sections)
        }

        public init(title: String, artist: String, year: Int, genres: [String], key: Int, scaleIndex: Int, sections: [Section]) {
            self.title = title; self.artist = artist; self.year = year; self.genres = genres
            self.key = key; self.scaleIndex = scaleIndex; self.sections = sections
        }
    }

    public struct Section: Sendable, Hashable, Decodable {
        /// "verse", "chorus", "bridge"…
        public let name: String
        public let chords: [SongChord]

        enum CodingKeys: String, CodingKey { case name = "n", chords = "c" }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            chords = try c.decode([String].self, forKey: .chords).compactMap(SongChord.init(code:))
        }

        public init(name: String, chords: [SongChord]) {
            self.name = name
            self.chords = chords
        }
    }

    /// Everything decoded from the bundled file, once.
    public static let billboard: SongLibrary = {
        guard let url = Bundle.module.url(forResource: "billboard", withExtension: "json", subdirectory: "Songs"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else {
            return SongLibrary(songs: [], source: "")
        }
        return SongLibrary(songs: file.songs, source: file.source)
    }()

    private struct File: Decodable {
        let source: String
        let songs: [Song]
    }

    public init(songs: [Song], source: String) {
        self.songs = songs
        self.source = source
    }

    public var decades: [Int] { Array(Set(songs.map(\.decade))).sorted() }

    /// Genres, most songs first.
    public var genres: [String] {
        var counts: [String: Int] = [:]
        for s in songs { for g in s.genres { counts[g, default: 0] += 1 } }
        return counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map(\.key)
    }

    /// Songs whose title or artist contains every word of `text`, optionally in one decade and
    /// genre ("" = songs without a known genre). Sorted by artist, then title.
    public func search(_ text: String = "", decade: Int? = nil, genre: String? = nil) -> [Song] {
        let words = text.lowercased().split(separator: " ").map(String.init)
        return songs.filter { s in
            if let decade, s.decade != decade { return false }
            if let genre { if genre.isEmpty ? !s.genres.isEmpty : !s.genres.contains(genre) { return false } }
            let hay = "\(s.title) \(s.artist)".lowercased()
            return words.allSatisfy { hay.contains($0) }
        }
    }
}

/// A chord as semitones above a key, and its triad quality.
public struct SongChord: Sendable, Hashable {
    public enum Quality: String, Sendable, Hashable { case major = "", minor = "m", diminished = "o", augmented = "+" }

    public var semitones: Int
    public var quality: Quality

    public init(semitones: Int, quality: Quality) {
        self.semitones = ((semitones % 12) + 12) % 12
        self.quality = quality
    }

    /// "9m" → A minor in C (vi); "10" → B♭ major in C (♭VII).
    public init?(code: String) {
        let digits = code.prefix { $0.isNumber }
        guard let n = Int(digits), let q = Quality(rawValue: String(code.dropFirst(digits.count))) else { return nil }
        self.init(semitones: n, quality: q)
    }

    /// Pitch classes above the key: root, third, fifth.
    public var tones: [Int] {
        let third = quality == .minor || quality == .diminished ? 3 : 4
        let fifth = quality == .diminished ? 6 : quality == .augmented ? 8 : 7
        return [semitones, (semitones + third) % 12, (semitones + fifth) % 12]
    }

    /// "Am", "B♭", "F♯°" with the key at `key` (0 = C).
    public func name(key: Int) -> String {
        let pc = (key + semitones) % 12
        let flats = ["C", "D♭", "D", "E♭", "E", "F", "G♭", "G", "A♭", "A", "B♭", "B"]
        // Flat keys (F, B♭, E♭, A♭, D♭) and flat-degree chords (♭III, ♭VI, ♭VII…) are spelled with flats.
        let useFlats = [5, 10, 3, 8, 1].contains(((key % 12) + 12) % 12) || [1, 3, 8, 10].contains(semitones)
        let root = useFlats ? flats[pc] : ScaleCatalogue.sharpNames[pc]
        switch quality {
        case .major: return root
        case .minor: return root + "m"
        case .diminished: return root + "°"
        case .augmented: return root + "+"
        }
    }

    /// Roman numeral above the key: I, vi, ♭VII, ii°.
    public var numeral: String {
        let names = ["I", "♭II", "II", "♭III", "III", "IV", "♯IV", "V", "♭VI", "VI", "♭VII", "VII"]
        let n = names[semitones]
        switch quality {
        case .major: return n
        case .minor: return n.lowercased()
        case .diminished: return n.lowercased() + "°"
        case .augmented: return n + "+"
        }
    }

    /// Parse typed chords ("Am F C G", "Bb7 Ebmaj7 F", "F#dim") relative to `key`.
    public static func parse(_ text: String, key: Int) -> [SongChord]? {
        let letters: [Character: Int] = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11]
        let tokens = text.replacingOccurrences(of: "|", with: " ").replacingOccurrences(of: ",", with: " ")
            .split(whereSeparator: \.isWhitespace)
        guard !tokens.isEmpty else { return nil }
        var out: [SongChord] = []
        for token in tokens {
            var rest = Substring(token)
            guard let first = rest.first?.uppercased().first, let base = letters[first] else { return nil }
            rest = rest.dropFirst()
            var pc = base
            while let c = rest.first, "#♯b♭".contains(c) {
                pc += (c == "#" || c == "♯") ? 1 : -1
                rest = rest.dropFirst()
            }
            let q = rest.split(separator: "/").first.map(String.init)?.lowercased() ?? ""
            let quality: Quality
            if q.hasPrefix("dim") || q.hasPrefix("°") || q.hasPrefix("ø") || q.hasPrefix("m7b5") { quality = .diminished }
            else if q.hasPrefix("aug") || q.hasPrefix("+") { quality = .augmented }
            else if q.hasPrefix("maj") || q.hasPrefix("ma") && !q.hasPrefix("m7") { quality = .major }
            else if q.hasPrefix("m") || q.hasPrefix("-") || q.hasPrefix("min") { quality = .minor }
            else { quality = .major }
            out.append(SongChord(semitones: pc - key, quality: quality))
        }
        return out
    }
}

/// A song's chords as scale degrees of the piece's key and scale.
public struct FittedProgression: Sendable, Equatable {
    /// Scale degrees (0 = the piece's tonic chord), one per chord.
    public var degrees: [Int]
    /// Per chord: played as written, as the scale's own chord on that root (e.g. a major II
    /// becomes the scale's minor ii), or bent to the nearest scale chord (root not in the scale).
    public var fits: [Fit]

    public enum Fit: Sendable, Equatable { case exact, quality, bent }

    public var exactCount: Int { fits.filter { $0 == .exact }.count }
    public var bentCount: Int { fits.filter { $0 == .bent }.count }
}

extension SongLibrary {
    /// The chords as scale degrees of `harmony` (its root is the song's key; only its scale
    /// steps matter). Roots in the scale keep their degree; other roots move to the scale chord
    /// that shares the most notes with them.
    public static func fit(_ chords: [SongChord], into harmony: HarmonyContext) -> FittedProgression {
        let steps = harmony.scaleSteps
        let n = steps.count
        func tone(_ i: Int) -> Int { steps[((i % n) + n) % n] }
        func triad(_ d: Int) -> [Int] { [tone(d), tone(d + 2), tone(d + 4)] }
        func quality(_ d: Int) -> SongChord.Quality? {
            let t = triad(d)
            let third = (t[1] - t[0] + 12) % 12, fifth = (t[2] - t[0] + 12) % 12
            switch (third, fifth) {
            case (4, 7): return .major
            case (3, 7): return .minor
            case (3, 6): return .diminished
            case (4, 8): return .augmented
            default: return nil
            }
        }
        var degrees: [Int] = [], fits: [FittedProgression.Fit] = []
        for c in chords {
            if let d = steps.firstIndex(of: c.semitones) {
                degrees.append(d)
                fits.append(quality(d) == c.quality ? .exact : .quality)
            } else {
                let tones = Set(c.tones)
                let best = (0..<n).max { a, b in
                    let sa = Set(triad(a)).intersection(tones).count, sb = Set(triad(b)).intersection(tones).count
                    if sa != sb { return sa < sb }
                    // Equal overlap: prefer the root nearest the song's root.
                    func dist(_ d: Int) -> Int { let x = abs(tone(d) - c.semitones); return min(x, 12 - x) }
                    return dist(a) > dist(b)
                } ?? 0
                degrees.append(best)
                fits.append(.bent)
            }
        }
        return FittedProgression(degrees: degrees, fits: fits)
    }
}
