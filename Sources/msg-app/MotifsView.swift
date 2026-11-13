import Engine
import Music
import SwiftUI

/// Each app plays a motif on the lead voice when it wakes. This page lists the apps heard, shows the
/// motif each one plays, and lets you design your own in scale steps (so they stay in key).
struct MotifsView: View {
    @Environment(AppModel.self) private var model

    enum Selection: Hashable {
        case design(String)
        case app(String)
    }

    @State private var selection: Selection?

    init(selection: Selection? = nil) {
        _selection = State(initialValue: selection)
    }

    var body: some View {
        if !model.isRunning {
            NotRunningHint().navigationTitle("Motifs")
        } else {
            HStack(spacing: 0) {
                sidebar.frame(width: 300)
                Divider()
                ScrollView {
                    detail.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .navigationTitle("Motifs")
        }
    }

    // MARK: List

    private var sidebar: some View {
        let apps = model.orderedApps
        return List(selection: $selection) {
            Section {
                ForEach(model.motifDesigns) { d in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(d.match == "*" ? "All other apps (*)" : "“\(d.match)”").fontWeight(.medium).lineLimit(1)
                            Text("\(d.steps.count) steps · follows \(d.anchor == .chord ? "the chord" : "the key")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        MotifThumb(notes: model.resolve(d), active: model.soundingMotifSteps["design:" + d.id] ?? [])
                            .frame(width: 84, height: 26)
                    }
                    .tag(Selection.design(d.id))
                }
                Button { newDesign(match: "*") } label: { Label("New design", systemImage: "plus") }
                    .buttonStyle(.borderless)
            } header: {
                Text("Your designs")
            }
            Section("Apps heard (\(apps.count))") {
                ForEach(apps, id: \.name) { a in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(a.name).lineLimit(1)
                            Text("\(a.wakes) wake-ups · \(Format.rate(a.bytesPerSecond))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        MotifThumb(notes: model.motif(for: a.name), active: model.soundingMotifSteps["app:" + a.name] ?? [])
                            .frame(width: 84, height: 26)
                        if a.ignored {
                            Text("ignored").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                                .background(.gray.opacity(0.3), in: Capsule())
                        } else if let d = MotifDesign.best(for: a.name, in: model.motifDesigns) {
                            Text(d.match == "*" ? "default" : "custom").font(.caption2)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color.accentColor.opacity(0.35), in: Capsule())
                        }
                    }
                    .tag(Selection.app(a.name))
                }
            }
        }
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        switch selection {
        case .design(let id):
            if let d = model.motifDesigns.first(where: { $0.id == id }) {
                DesignEditor(design: d)
            }
        case .app(let name):
            AppMotifPanel(app: name) { newDesign(from: name) }
        case nil:
            VisualCard(title: "Motifs: hearing who is talking",
                       caption: """
                       When an app's traffic jumps above the activity threshold after being quiet, it plays its own short \
                       motif on the lead voice. By default each app's motif is generated from its name: the same app always \
                       gets the same tune, but its pitches are raw and the quantiser pulls them into key, which can \
                       occasionally clash with the chord. Pick an app to see and hear its motif, then "Customise" it, or \
                       make a design that applies to several apps.
                       """) {
                HStack {
                    Button { newDesign(match: "*") } label: { Label("Design a default motif for all apps", systemImage: "plus") }
                }
            }
            MotifGallery { selection = $0 }
        }
    }

    private func newDesign(match: String) {
        let d = MotifDesign(match: match, steps: [0, 2, 4, nil], anchor: .chord)
        model.updateDesign(d)
        selection = .design(d.id)
    }

    private func newDesign(from app: String) {
        guard let h = model.harmony else { return }
        // Start from what it sounds like now (after the pitch quantiser), not the raw pitches.
        var d = MotifDesign.fromPitches(app: app, pitches: model.generatedMotif(for: app).map(\.played),
                                        octave: Int(model.base("gen.motif.octave")), harmony: h)
        d.octave = nil
        model.updateDesign(d)
        selection = .design(d.id)
    }
}

/// What an app currently plays, and why.
struct AppMotifPanel: View {
    @Environment(AppModel.self) private var model
    let app: String
    let customise: () -> Void

    var body: some View {
        let info = model.status?.apps.first { $0.name == app }
        let design = MotifDesign.best(for: app, in: model.motifDesigns)
        VStack(alignment: .leading, spacing: 14) {
            VisualCard(title: app, caption: caption(info, design)) {
                HStack {
                    Button { model.previewMotif(for: app) } label: { Label("Play its motif now", systemImage: "play.fill") }
                    if design == nil {
                        Button { customise() } label: { Label("Customise this motif", systemImage: "slider.horizontal.3") }
                            .help("Turns the generated motif into a design you can edit (nearest scale steps).")
                        Button { randomFor(app) } label: { Label("Try a random motif", systemImage: "dice") }
                            .help("Makes a random design for this app (chord notes only) and plays it. Delete the design to go back to the generated one.")
                    }
                }
            }
            if let design {
                VisualCard(title: "Plays: \(design.match == "*" ? "the default design" : "design “\(design.match)”")",
                           caption: "Select the design in the list to edit it.") {
                    MotifStrip(notes: model.resolve(design), active: model.soundingMotifSteps["app:" + app] ?? []).frame(height: 120)
                }
            } else {
                VisualCard(title: "Plays: its generated motif",
                           caption: "Hollow: the pitch generated from the app's name. Filled: what the pitch quantiser makes of it now (with the current strength, it can vary). Notes outside the highlighted chord rows are the ones that can sound discordant.") {
                    MotifStrip(notes: model.generatedMotif(for: app), active: model.soundingMotifSteps["app:" + app] ?? []).frame(height: 120)
                }
            }
        }
    }

    private func randomFor(_ app: String) {
        var rng = SystemRandomNumberGenerator()
        let steps = MotifDesign.randomSteps(count: Int(model.base("gen.motif.length")), chordNotesOnly: true, using: &rng)
        model.updateDesign(MotifDesign(match: app, steps: steps, anchor: .chord))
        model.previewMotif(for: app)
    }

    private func caption(_ info: EngineStatus.AppInfo?, _ design: MotifDesign?) -> String {
        guard let info else { return "Not heard yet." }
        var parts = ["\(info.wakes) wake-ups so far", "now \(Format.rate(info.bytesPerSecond))"]
        if info.ignored { parts.append("ignored as a background service (Generators → App activity → Ignore)") }
        parts.append("wakes when it goes above \(Format.rate(model.base("activity.threshold"))) after being quiet, at most every \(Int(model.base("activity.cooldown"))) s")
        return parts.joined(separator: " · ")
    }
}

/// A step-sequencer grid for one design: columns are steps, rows are scale steps above the anchor.
struct DesignEditor: View {
    @Environment(AppModel.self) private var model
    let design: MotifDesign
    private let rows = Array((-3...11).reversed())

    private func update(_ change: (inout MotifDesign) -> Void) {
        var d = design
        change(&d)
        model.updateDesign(d)
    }

    var body: some View {
        let h = model.harmony
        let octave = design.octave ?? Int(model.base("gen.motif.octave"))
        let anchor = design.anchor == .chord ? (h?.chordDegree ?? 0) : 0
        let chordPCs = Set(model.status?.chordPitchClasses ?? [])
        // A row is a chord note if the note it plays now is in the current chord.
        let chordSteps = Set(rows.filter { r in
            h.map { chordPCs.contains((($0.note(degree: anchor + r, octave: octave) % 12) + 12) % 12) } ?? false
        })
        let live = model.soundingMotifSteps["design:" + design.id] ?? []
        VStack(alignment: .leading, spacing: 14) {
            VisualCard(title: "Design", caption: "Which apps it's for, and what the steps are measured from.") {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        Text("Applies to")
                        TextField("app name, part of a name, or * for all", text: Binding(
                            get: { design.match }, set: { v in update { $0.match = v } }))
                            .textFieldStyle(.roundedBorder).frame(width: 320)
                        Text(design.match == "*" ? "every app without a more specific design" : "apps whose name contains this (an exact name wins)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    GridRow {
                        Text("Steps follow")
                        Picker("", selection: Binding(get: { design.anchor }, set: { v in update { $0.anchor = v } })) {
                            Text("the chord (moves with the harmony)").tag(MotifDesign.Anchor.chord)
                            Text("the key (same notes on every chord)").tag(MotifDesign.Anchor.key)
                        }
                        .labelsHidden().frame(width: 320)
                        Text("Following the chord, step 0 is the chord's root, so the motif always fits.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    GridRow {
                        Text("Step length")
                        HStack {
                            Slider(value: Binding(get: { design.stepBeats ?? model.base("gen.motif.stepBeats") },
                                                  set: { v in update { $0.stepBeats = (v * 4).rounded() / 4 } }), in: 0.25...2)
                            Text("\((design.stepBeats ?? model.base("gen.motif.stepBeats")).formatted()) beats").monospacedDigit()
                        }
                        .frame(width: 320)
                        Button("Use the generator's setting") { update { $0.stepBeats = nil } }.disabled(design.stepBeats == nil)
                    }
                    GridRow {
                        Text("Octave")
                        Stepper("\(octave)", value: Binding(get: { octave }, set: { v in update { $0.octave = v } }), in: 2...7)
                        Button("Use the generator's setting") { update { $0.octave = nil } }.disabled(design.octave == nil)
                    }
                }
            }

            VisualCard(title: "Steps",
                       caption: "Click a cell to put a note on that step; click it again for a rest. Rows are scale steps above \(design.anchor == .chord ? "the current chord's root" : "the key's home note"); highlighted rows are chord notes, the safest choices. Note names are for what's playing now.") {
                Grid(horizontalSpacing: 2, verticalSpacing: 2) {
                    ForEach(rows, id: \.self) { row in
                        GridRow {
                            let note = h.map { Format.note($0.note(degree: anchor + row, octave: octave)) } ?? ""
                            Text("\(row >= 0 ? "+" : "")\(row)  \(note)").font(.caption.monospaced())
                                .foregroundStyle(chordSteps.contains(row) ? Color.accentColor : .secondary)
                                .frame(width: 74, alignment: .leading)
                            ForEach(Array(design.steps.enumerated()), id: \.offset) { i, step in
                                let on = step == row
                                let playing = live.contains(i)
                                Rectangle()
                                    .fill(on ? (playing ? Color.white : Color.orange)
                                             : (chordSteps.contains(row) ? Color.accentColor.opacity(playing ? 0.35 : 0.18)
                                                                         : Color.primary.opacity(playing ? 0.16 : 0.06)))
                                    .shadow(color: on && playing ? .orange : .clear, radius: 6)
                                    .frame(width: 30, height: 16)
                                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(step == nil && row == 0 ? Color.secondary : .clear, style: StrokeStyle(dash: [2])))
                                    .contentShape(Rectangle())
                                    .onTapGesture { update { $0.steps[i] = on ? nil : row } }
                            }
                        }
                    }
                    GridRow {
                        Text("").frame(width: 74)
                        ForEach(Array(design.steps.enumerated()), id: \.offset) { i, step in
                            Text(step == nil ? "rest" : "\(i + 1)").font(.caption2.weight(live.contains(i) ? .bold : .regular))
                                .foregroundStyle(live.contains(i) ? Color.orange : .secondary).frame(width: 30)
                        }
                    }
                }
                HStack {
                    Button { update { $0.steps.append(nil) } } label: { Label("Add step", systemImage: "plus") }
                        .disabled(design.steps.count >= 16)
                    Button { update { _ = $0.steps.popLast() } } label: { Label("Remove last", systemImage: "minus") }
                        .disabled(design.steps.count <= 1)
                    Menu {
                        Button("Chord notes only (always consonant)") { randomise(chordNotesOnly: true) }
                        Button("Any scale notes (more colour)") { randomise(chordNotesOnly: false) }
                    } label: { Label("Randomise", systemImage: "dice") }
                        .fixedSize()
                        .help("Replace the steps with a random motif of the same length, and play it")
                    Spacer()
                    Button { model.previewMotif(for: previewApp) } label: { Label("Play now", systemImage: "play.fill") }
                        .buttonStyle(.borderedProminent)
                        .help("Plays as if \(previewApp) woke up")
                    Button(role: .destructive) { model.deleteDesign(design.id) } label: { Label("Delete design", systemImage: "trash") }
                }
            }

            VisualCard(title: "How it sounds over the current chord") {
                MotifStrip(notes: model.resolve(design), active: live).frame(height: 110)
            }
        }
    }

    private func randomise(chordNotesOnly: Bool) {
        var rng = SystemRandomNumberGenerator()
        update {
            $0.steps = MotifDesign.randomSteps(count: max($0.steps.count, 3), chordNotesOnly: chordNotesOnly, using: &rng)
            // Chord-note steps only fit when they're measured from the chord.
            if chordNotesOnly { $0.anchor = .chord }
        }
        model.previewMotif(for: previewApp)
    }

    /// An app name that this design applies to, for previewing.
    private var previewApp: String {
        if design.match != "*", !design.match.isEmpty,
           let app = model.status?.apps.first(where: { MotifDesign.best(for: $0.name, in: model.motifDesigns)?.id == design.id }) {
            return app.name
        }
        return design.match == "*" ? "__preview__" : design.match
    }
}

/// Notes of a motif on a small pitch grid: hollow = raw/asked pitch, filled = played.
struct MotifStrip: View {
    @Environment(AppModel.self) private var model
    let notes: [(raw: Double?, played: Int?)]
    /// Steps sounding right now (lit up).
    var active: Set<Int> = []

    var body: some View {
        Canvas { gc, size in
            guard let s = model.status, !notes.isEmpty else { return }
            let pitches = notes.flatMap { [$0.raw, $0.played.map(Double.init)].compactMap { $0 } }
            let lo = Int((pitches.min() ?? 60).rounded(.down)) - 2, hi = Int((pitches.max() ?? 72).rounded(.up)) + 2
            let rowH = size.height / CGFloat(hi - lo + 1)
            func y(_ p: Double) -> CGFloat { CGFloat(Double(hi) - p + 0.5) * rowH }
            let scale = Set(s.scalePitchClasses), chord = Set(s.chordPitchClasses)
            for n in lo...hi {
                let pc = ((n % 12) + 12) % 12
                let r = CGRect(x: 0, y: y(Double(n)) - rowH / 2, width: size.width, height: rowH)
                if chord.contains(pc) { gc.fill(Path(r), with: .color(.accentColor.opacity(0.16))) }
                else if scale.contains(pc) { gc.fill(Path(r), with: .color(.primary.opacity(0.05))) }
            }
            let slot = size.width / CGFloat(notes.count)
            for i in active where i < notes.count {
                gc.fill(Path(roundedRect: CGRect(x: slot * CGFloat(i) + 2, y: 0, width: slot - 4, height: size.height), cornerRadius: 4),
                        with: .color(.white.opacity(0.12)))
            }
            for (i, n) in notes.enumerated() {
                let x = slot * (CGFloat(i) + 0.5)
                let d = min(rowH * 1.2, 12) * (active.contains(i) ? 1.5 : 1)
                if let raw = n.raw, let played = n.played {
                    var line = Path(); line.move(to: CGPoint(x: x, y: y(raw))); line.addLine(to: CGPoint(x: x, y: y(Double(played))))
                    gc.stroke(line, with: .color(.orange.opacity(0.6)), lineWidth: 1.5)
                }
                if let raw = n.raw {
                    gc.stroke(Path(ellipseIn: CGRect(x: x - d / 2, y: y(raw) - d / 2, width: d, height: d)), with: .color(.orange), lineWidth: 1.5)
                }
                if let played = n.played {
                    let pc = ((played % 12) + 12) % 12
                    let colour: Color = chord.contains(pc) ? .orange : (scale.contains(pc) ? .yellow : .red)
                    gc.fill(Path(ellipseIn: CGRect(x: x - d / 2, y: y(Double(played)) - d / 2, width: d, height: d)), with: .color(colour))
                    gc.draw(Text(Format.note(played)).font(.system(size: 9)), at: CGPoint(x: x, y: y(Double(played)) - d))
                } else if n.raw == nil {
                    gc.draw(Text("rest").font(.system(size: 9)).foregroundStyle(.secondary), at: CGPoint(x: x, y: size.height / 2))
                }
            }
        }
    }
}

extension AppModel {
    /// A design's notes over the current chord.
    func resolve(_ design: MotifDesign) -> [(raw: Double?, played: Int?)] {
        guard let h = harmony else { return [] }
        let anchor = design.anchor == .chord ? h.chordDegree : 0
        let octave = design.octave ?? Int(base("gen.motif.octave"))
        return design.steps.map { s in (nil, s.map { h.note(degree: anchor + $0, octave: octave) }) }
    }

    /// An app's generated motif: raw pitches, and where the pitch quantiser would most likely put them
    /// (nearest scale note at strength ≤ 0.5, nearest chord note above).
    func generatedMotif(for app: String) -> [(raw: Double?, played: Int?)] {
        guard let h = harmony else { return [] }
        let shape = MotifGenerator.shape(for: app, length: Int(base("gen.motif.length")), range: Int(base("gen.motif.range")),
                                         seed: Int(base("gen.motif.seed")))
        let centre = Double(12 * (Int(base("gen.motif.octave")) + 1) + h.root + shape.start)
        let strength = base("quant.pitch.strength")
        return shape.offsets.map { o in
            let raw = centre + Double(o)
            let played = strength > 0.5 ? HarmonyContext.nearest(raw, in: h.chordPitchClasses)
                : strength > 0 ? HarmonyContext.nearest(raw, in: h.scalePitchClasses) : Int(raw.rounded())
            return (raw, played)
        }
    }
}

/// A tiny picture of a motif: one dot per step on a mini pitch range. Lit steps are sounding now.
struct MotifThumb: View {
    @Environment(AppModel.self) private var model
    let notes: [(raw: Double?, played: Int?)]
    var active: Set<Int> = []

    var body: some View {
        let chord = Set(model.status?.chordPitchClasses ?? [])
        Canvas { gc, size in
            let played = notes.compactMap(\.played)
            guard let lo = played.min(), let hi = played.max() else { return }
            let span = Double(max(hi - lo, 6))
            let slot = size.width / CGFloat(max(notes.count, 1))
            for (i, n) in notes.enumerated() {
                guard let p = n.played else { continue }
                let x = slot * (CGFloat(i) + 0.5)
                let y = size.height - 4 - CGFloat(Double(p - lo) / span) * (size.height - 8)
                let lit = active.contains(i)
                let d: CGFloat = lit ? 8 : 5
                let inChord = chord.contains(((p % 12) + 12) % 12)
                gc.fill(Path(ellipseIn: CGRect(x: x - d / 2, y: y - d / 2, width: d, height: d)),
                        with: .color(lit ? .white : (inChord ? .orange : .yellow)))
            }
        }
        .background(active.isEmpty ? Color.primary.opacity(0.06) : Color.orange.opacity(0.3), in: RoundedRectangle(cornerRadius: 4))
    }
}

/// Every motif at a glance: your designs and every app heard. Click one to open it.
struct MotifGallery: View {
    @Environment(AppModel.self) private var model
    let select: (MotifsView.Selection) -> Void

    var body: some View {
        let apps = model.orderedApps
        VisualCard(title: "All motifs", caption: "Designs and every app heard. Lit cards are playing now; orange dots are chord notes, yellow are other scale notes.") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 10)], spacing: 10) {
                ForEach(model.motifDesigns) { d in
                    card(d.match == "*" ? "All other apps (*)" : "“\(d.match)”", "design", model.resolve(d),
                         model.soundingMotifSteps["design:" + d.id] ?? []) { select(.design(d.id)) }
                }
                ForEach(apps, id: \.name) { a in
                    let design = MotifDesign.best(for: a.name, in: model.motifDesigns)
                    card(a.name, a.ignored ? "ignored" : design == nil ? "generated" : "uses design",
                         model.motif(for: a.name), model.soundingMotifSteps["app:" + a.name] ?? []) { select(.app(a.name)) }
                }
            }
        }
    }

    private func card(_ title: String, _ kind: String, _ notes: [(raw: Double?, played: Int?)], _ active: Set<Int>,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title).fontWeight(.medium).lineLimit(1)
                    Spacer()
                    Text(kind).font(.caption2).foregroundStyle(.secondary)
                }
                MotifThumb(notes: notes, active: active).frame(height: 44)
            }
            .padding(8)
            .background(Color.primary.opacity(active.isEmpty ? 0.05 : 0.12), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(active.isEmpty ? Color.clear : .orange, lineWidth: 1.5))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

extension AppModel {
    /// What an app plays: its design if one matches, otherwise its generated motif.
    func motif(for app: String) -> [(raw: Double?, played: Int?)] {
        if let d = MotifDesign.best(for: app, in: motifDesigns) { return resolve(d) }
        return generatedMotif(for: app)
    }
}
