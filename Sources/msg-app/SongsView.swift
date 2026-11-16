import Music
import SwiftUI

/// Pick a chord progression from a real song (the McGill Billboard library) or type one, and use
/// it for a mood. The chords play in the piece's key; optionally switch to the song's scale (and
/// key) so chords outside the current scale come through as written.
struct SongPicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.skin) private var skin

    @State var mood: String
    @State private var text = ""
    @State private var decade: Int?
    @State private var genre: String?
    @State var selection: SongLibrary.Song.ID?
    @State private var useScale = true
    @State private var useKey = false
    @State var typed = ""
    @State private var applied: String?

    private let library = SongLibrary.billboard
    static let moods = ["quiet", "calm", "busy", "focused"]

    var body: some View {
        let results = library.search(text, decade: decade, genre: genre)
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                songList(results).frame(width: 360)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if let song = library.songs.first(where: { $0.id == selection }) {
                            songDetail(song)
                        } else {
                            Text("Pick a song to see its chords, section by section.")
                                .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 120)
                        }
                        typedChords
                    }
                    .padding(16)
                }
            }
            Divider()
            footer
        }
        .frame(width: 1040, height: 700)
        .skinnedPage(model.skin)
    }

    // MARK: Header and footer

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "music.note.list").font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text("Chords from a song").font(.headline)
                Text("\(library.songs.count) Billboard Hot 100 songs, 1958–1991, annotated by hand (McGill Billboard Project, CC0); genres from Wikidata.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("Use for").foregroundStyle(.secondary)
            SkinPicker(selection: $mood, options: Self.moods.map { ($0, $0.capitalized) }).frame(width: 130)
        }
        .padding(14)
    }

    private var footer: some View {
        let scale = ScaleCatalogue.names[Int(model.base("harmony.scale"))]
        let root = ScaleCatalogue.rootNames[Int(model.base("harmony.root"))]
        return HStack(spacing: 14) {
            if let applied {
                Label(applied, systemImage: "checkmark.circle.fill").foregroundStyle(.green).lineLimit(1)
            } else {
                Text("The piece is in \(root) \(scale). Chords keep their place in the key (I, vi, IV…), so they play in the piece's key.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }

    // MARK: List

    private func songList(_ results: [SongLibrary.Song]) -> some View {
        VStack(spacing: 8) {
            TextField("Search title or artist", text: $text).skinField()
            HStack(spacing: 8) {
                SkinPicker(selection: $decade, options: [(Int?.none, "Any decade")] + library.decades.map { (Int?.some($0), "\($0)s") })
                SkinPicker(selection: $genre, options: [(String?.none, "Any genre")] + library.genres.map { (String?.some($0), $0) }
                    + [(String?.some(""), "Unknown genre")])
            }
            .controlSize(.small)
            Text("\(results.count) songs").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            List(results, selection: $selection) { s in
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.title).fontWeight(.medium).lineLimit(1)
                    Text("\(s.artist) · \(String(s.year))\(s.genres.isEmpty ? "" : " · " + s.genres.joined(separator: ", "))")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .tag(s.id)
            }
            .listStyle(.plain)
        }
        .padding(12)
    }

    // MARK: Detail

    private func songDetail(_ song: SongLibrary.Song) -> some View {
        let songScale = ScaleCatalogue.names[song.scaleIndex]
        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(song.title).font(.title3.weight(.semibold))
                Text("\(song.artist) · \(String(song.year))\(song.genres.isEmpty ? "" : " · " + song.genres.joined(separator: ", "))")
                    .foregroundStyle(.secondary)
                Text("Key of \(ScaleCatalogue.rootNames[song.key]); its chords fit \(songScale) best.").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 18) {
                Toggle("Switch to the song's scale (\(songScale))", isOn: $useScale)
                Toggle("and its key (\(ScaleCatalogue.rootNames[song.key]))", isOn: $useKey)
            }
            .toggleStyle(.checkbox)
            ForEach(Array(song.sections.enumerated()), id: \.offset) { _, section in
                sectionCard(section, song: song)
            }
        }
    }

    /// The harmony a fit is measured against: the song's scale (and key) if chosen, else the piece's.
    private func target(_ song: SongLibrary.Song?) -> (root: Int, scale: Int) {
        let root = Int(model.base("harmony.root")), scale = Int(model.base("harmony.scale"))
        guard let song else { return (root, scale) }
        return (useKey ? song.key : root, useScale ? song.scaleIndex : scale)
    }

    private func sectionCard(_ section: SongLibrary.Section, song: SongLibrary.Song) -> some View {
        let t = target(song)
        let harmony = HarmonyContext(root: t.root, scale: ScaleCatalogue.scales[t.scale])
        let fit = SongLibrary.fit(section.chords, into: harmony)
        return SkinBox(title: section.name) {
            chordRow(section.chords, key: song.key, fit: fit)
            HStack {
                Text(summary(fit, in: "\(ScaleCatalogue.rootNames[t.root]) \(ScaleCatalogue.names[t.scale])"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { apply(fit, scale: t.scale, root: t.root, label: "\(song.title) (\(section.name))") } label: {
                    Label("Use for \(mood.capitalized)", systemImage: "arrow.down.to.line")
                }
                .controlSize(.small)
            }
        }
    }

    /// Chord names in the song's key, numerals under them; bent chords are marked.
    private func chordRow(_ chords: [SongChord], key: Int, fit: FittedProgression) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(chords.enumerated()), id: \.offset) { i, c in
                    let f = fit.fits[safe: i] ?? .exact
                    VStack(spacing: 1) {
                        Text(c.name(key: key)).font(.system(.body, design: .monospaced).weight(.semibold))
                        Text(c.numeral).font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 5).fill(f == .bent ? Color.orange.opacity(0.22) : Color.primary.opacity(0.07)))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(f == .quality ? Color.yellow.opacity(0.6) : .clear))
                    .help(f == .exact ? "Plays as written" : f == .quality
                          ? "The scale has a different chord on this root; it plays the scale's own"
                          : "Not in this scale: plays the nearest scale chord")
                }
            }
        }
    }

    private func summary(_ fit: FittedProgression, in scale: String) -> String {
        let n = fit.fits.count, changed = n - fit.exactCount - fit.bentCount
        if fit.exactCount == n { return "All \(n) chords play as written in \(scale)." }
        var parts = ["\(fit.exactCount) of \(n) as written in \(scale)"]
        if changed > 0 { parts.append("\(changed) as the scale's chord on that root (outlined)") }
        if fit.bentCount > 0 { parts.append("\(fit.bentCount) bent to the nearest scale chord (orange)") }
        return parts.joined(separator: "; ") + "."
    }

    // MARK: Typed

    private var typedChords: some View {
        let root = Int(model.base("harmony.root")), scale = Int(model.base("harmony.scale"))
        let chords = SongChord.parse(typed, key: root)
        let fit = chords.map { SongLibrary.fit($0, into: HarmonyContext(root: root, scale: ScaleCatalogue.scales[scale])) }
        return SkinBox(title: "Or type chords") {
            Text("Chord names in the piece's key, \(ScaleCatalogue.rootNames[root]) \(ScaleCatalogue.names[scale]): e.g. Am F C G, or Dm7 G7 Cmaj7. Sevenths and extensions play as their triad (the chord size setting adds notes).")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Am F C G", text: $typed).skinField()
            if let chords, let fit {
                chordRow(chords, key: root, fit: fit)
                HStack {
                    Text(summary(fit, in: "\(ScaleCatalogue.rootNames[root]) \(ScaleCatalogue.names[scale])")).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { apply(fit, scale: scale, root: root, label: typed) } label: {
                        Label("Use for \(mood.capitalized)", systemImage: "arrow.down.to.line")
                    }
                    .controlSize(.small)
                }
            } else if !typed.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("Couldn't read that: use chord names like C, Am, F♯m, B♭7, Ddim.").font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func apply(_ fit: FittedProgression, scale: Int, root: Int, label: String) {
        if scale != Int(model.base("harmony.scale")) { model.set("harmony.scale", Double(scale)) }
        if root != Int(model.base("harmony.root")) { model.set("harmony.root", Double(root)) }
        model.setProgression(mood, fit.degrees)
        applied = "\(mood.capitalized) now plays \(label), kept through variations (pinned)"
    }
}
