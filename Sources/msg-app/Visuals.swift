import Engine
import Music
import SwiftUI

/// One colour per voice role, used everywhere notes are drawn.
enum RoleStyle {
    static let order = ["pad", "lead", "pulse", "bass", "sub", "drums"]
    /// Roles whose notes are drum sounds, not pitches: left out of keyboards and pitched rolls
    /// unless asked for by name.
    static let unpitched: Set<String> = ["drums"]

    static func color(_ role: String) -> Color {
        switch role {
        case "pad": .purple
        case "lead": .orange
        case "pulse": .teal
        case "bass": .blue
        case "sub": .indigo
        case "drums": .pink
        default: .gray
        }
    }
}

struct RoleLegend: View {
    var roles: [String] = RoleStyle.order.filter { !RoleStyle.unpitched.contains($0) }
    var body: some View {
        HStack(spacing: 14) {
            ForEach(roles, id: \.self) { r in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2).fill(RoleStyle.color(r)).frame(width: 12, height: 8)
                    Text(r).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// A card that frames a visual with a title and a one-line explanation.
struct VisualCard<Content: View>: View {
    @Environment(\.skin) private var skin
    let title: String
    var caption: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if skin == .studio {
                Text(title.uppercased()).font(Studio.legend(11, weight: .bold)).tracking(1).foregroundStyle(Studio.label)
            } else {
                Text(title).font(.headline)
            }
            if let caption { Text(caption).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if skin == .studio {
                PanelBackground(cornerRadius: 8, shade: 0.2)
            } else {
                RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.35))
            }
        }
    }
}

// MARK: - Piano roll

/// Scrolling piano roll of recent and scheduled notes. Rows for the current scale are shaded,
/// chord notes more strongly, so you can see notes land in (or out of) the harmony.
struct PianoRoll: View {
    @Environment(AppModel.self) private var model
    var roles: Set<String>?
    var window: Double = 14
    var ahead: Double = 2
    /// Fixed pitch range (e.g. a voice's range); nil = fit to the notes.
    var pitchRange: ClosedRange<Int>?
    var showChords = true
    /// Frames per second. Big "hero" rolls scroll smoothly at 24; small lanes are fine at 12.
    var fps: Double = 24
    @State private var hover: CGPoint?
    /// Snapshot/testing aid: behave as if the pointer were here (inspecting, paused).
    var inspectAt: CGPoint?
    /// While the pointer is over the roll, time stands still so the note being inspected stays put.
    @State private var frozenAt: Double?
    /// The data as it was when frozen, so notes being inspected can't scroll out of the history.
    @State private var frozenStatus: EngineStatus?
    /// After inspecting, ease from where we stopped back to live.
    @State private var catchUp: (from: Double, started: Date)?
    private static let catchUpSeconds = 0.5

    private func displayTime(at date: Date) -> Double {
        if let frozenAt { return frozenAt }
        let live = model.engineNow(at: date)
        guard let c = catchUp else { return live }
        let t = date.timeIntervalSince(c.started) / Self.catchUpSeconds
        guard t < 1 else { return live }
        let ease = 1 - pow(1 - t, 3)
        return c.from + (live - c.from) * ease
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / (frozenAt == nil ? fps : 12), paused: !model.visualsActive)) { tl in
            Canvas { gc, size in
                draw(&gc, size, now: displayTime(at: tl.date), status: frozenStatus ?? model.status,
                     paused: frozenAt != nil || inspectAt != nil, hoverPoint: inspectAt ?? hover)
            }
        }
        .onContinuousHover { phase in
            switch phase {
            case .active(let p):
                hover = p
                if frozenAt == nil {
                    frozenAt = displayTime(at: Date())
                    frozenStatus = model.status
                }
            case .ended:
                hover = nil
                if let f = frozenAt { catchUp = (f, Date()) }
                frozenAt = nil
                frozenStatus = nil
            }
        }
    }

    private func draw(_ gc: inout GraphicsContext, _ size: CGSize, now: Double, status: EngineStatus?, paused: Bool = false,
                      hoverPoint: CGPoint? = nil) {
        Perf.canvasFrames += 1
        guard let s = status else { return }
        let start = now - window, end = now + ahead
        let notes = s.recentNotes.filter { (roles?.contains($0.role) ?? !RoleStyle.unpitched.contains($0.role)) && $0.time + $0.duration >= start && $0.time <= end }
        let band: CGFloat = showChords ? 18 : 0
        var lo = pitchRange?.lowerBound ?? (notes.map(\.note).min() ?? 48) - 3
        var hi = pitchRange?.upperBound ?? (notes.map(\.note).max() ?? 72) + 3
        if hi - lo < 18 { let mid = (hi + lo) / 2; lo = mid - 9; hi = mid + 9 }
        let rows = CGFloat(hi - lo + 1)
        let rowH = (size.height - band) / rows
        func x(_ t: Double) -> CGFloat { CGFloat((t - start) / (end - start)) * size.width }
        func y(_ n: Int) -> CGFloat { band + CGFloat(hi - n) * rowH }

        // Harmony rows.
        let scale = Set(s.scalePitchClasses), chord = Set(s.chordPitchClasses)
        for n in lo...hi {
            let pc = ((n % 12) + 12) % 12
            let rect = CGRect(x: 0, y: y(n), width: size.width, height: rowH)
            if chord.contains(pc) { gc.fill(Path(rect), with: .color(.accentColor.opacity(0.13))) }
            else if scale.contains(pc) { gc.fill(Path(rect), with: .color(.primary.opacity(0.05))) }
            if pc == 0 {
                gc.fill(Path(CGRect(x: 0, y: y(n) + rowH - 0.5, width: size.width, height: 0.5)), with: .color(.primary.opacity(0.2)))
                if rowH * 12 > 40 {
                    gc.draw(Text("C\(n / 12 - 1)").font(.system(size: 9)).foregroundStyle(.secondary), at: CGPoint(x: 4, y: y(n) + rowH / 2), anchor: .leading)
                }
            }
        }

        // Bar and beat lines from the engine's clock.
        let spb = 60 / max(s.bpm, 1)
        let beatAtStart = s.beat - (s.time - start) / spb
        var b = beatAtStart.rounded(.up)
        while true {
            let t = s.time + (b - s.beat) * spb
            if t > end { break }
            let isBar = Int(b) % 4 == 0
            gc.fill(Path(CGRect(x: x(t), y: band, width: isBar ? 1 : 0.5, height: size.height - band)),
                    with: .color(.primary.opacity(isBar ? 0.25 : 0.08)))
            b += 1
        }

        // Chord band.
        if showChords {
            let events = s.chordHistory
            for (i, e) in events.enumerated() {
                let next = i + 1 < events.count ? events[i + 1].time : end
                guard next >= start, e.time <= end else { continue }
                let r = CGRect(x: max(x(e.time), 0), y: 0, width: max(x(next) - max(x(e.time), 0) - 2, 0), height: band - 3)
                gc.fill(Path(roundedRect: r, cornerRadius: 3), with: .color(.accentColor.opacity(0.22)))
                // Only label chords wide enough to read; clip so labels never overlap.
                if r.width > 34 {
                    var label = gc
                    label.clip(to: Path(r))
                    label.draw(Text(r.width > 60 ? "\(e.name)  \(e.numeral)" : e.name).font(.system(size: 10, weight: .semibold)),
                               at: CGPoint(x: r.minX + 5, y: r.midY), anchor: .leading)
                }
            }
        }

        // Notes: future (scheduled) ones are outlined.
        var hovered: (EngineStatus.PlayedNote, CGRect)?
        for n in notes where n.note >= lo && n.note <= hi {
            let r = CGRect(x: x(n.time), y: y(n.note) + 0.5, width: max(x(n.time + n.duration) - x(n.time), 3), height: max(rowH - 1, 2))
            let colour = RoleStyle.color(n.role)
            if n.time > now {
                gc.stroke(Path(roundedRect: r, cornerRadius: 2), with: .color(colour.opacity(0.8)), lineWidth: 1)
            } else {
                gc.fill(Path(roundedRect: r, cornerRadius: 2), with: .color(colour.opacity(0.35 + 0.65 * Double(n.velocity) / 127)))
            }
            if let h = hoverPoint, r.insetBy(dx: -2, dy: -3).contains(h) { hovered = (n, r) }
        }

        // Highlight the hovered note and, for motifs, every note of that same wake-up.
        if let (n, r) = hovered {
            if let tag = n.motif {
                for m in notes where m.motif?.app == tag.app && m.motif?.instance == tag.instance && m.id != n.id && m.note >= lo && m.note <= hi {
                    let mr = CGRect(x: x(m.time), y: y(m.note) + 0.5, width: max(x(m.time + m.duration) - x(m.time), 3), height: max(rowH - 1, 2))
                    gc.stroke(Path(roundedRect: mr.insetBy(dx: -1.5, dy: -1.5), cornerRadius: 3), with: .color(.primary.opacity(0.75)), lineWidth: 1)
                }
            }
            gc.stroke(Path(roundedRect: r.insetBy(dx: -2, dy: -2), cornerRadius: 3), with: .color(.primary), lineWidth: 2)
        }

        // Details live in a fixed panel on the left, so they never cover the note being inspected.
        if paused {
            var lines = [Text("⏸ paused").font(.system(size: 10, weight: .semibold)).foregroundStyle(.orange)]
            if let (n, _) = hovered {
                lines.append(Text("\(n.role) · \(Format.note(n.note)) · velocity \(n.velocity)").font(.system(size: 11, weight: .semibold)))
                lines.append(Text(n.why).font(.system(size: 11)))
                if let tag = n.motif {
                    let count = notes.filter { $0.motif?.app == tag.app && $0.motif?.instance == tag.instance }.count
                    lines.append(Text("step \(tag.step + 1) of \(count) in this motif").font(.system(size: 10)).foregroundStyle(.secondary))
                }
                lines.append(Text(n.time > now ? String(format: "plays in %.1f s", n.time - now) : String(format: "%.1f s ago", now - n.time))
                    .font(.system(size: 10)).foregroundStyle(.secondary))
            } else {
                lines.append(Text("point at a note for details").font(.system(size: 10)).foregroundStyle(.secondary))
            }
            let width = min(240, size.width * 0.32)
            let resolved = lines.map { gc.resolve($0) }
            let heights = resolved.map { $0.measure(in: CGSize(width: width - 16, height: 200)).height }
            let box = CGRect(x: 4, y: band + 4, width: width, height: min(heights.reduce(0, +) + CGFloat(lines.count - 1) * 2 + 12, size.height - band - 8))
            gc.fill(Path(roundedRect: box, cornerRadius: 6), with: .color(Color(nsColor: .windowBackgroundColor).opacity(0.92)))
            gc.stroke(Path(roundedRect: box, cornerRadius: 6),
                      with: .color(hovered.map { RoleStyle.color($0.0.role) } ?? .orange), lineWidth: 1)
            var yy = box.minY + 6
            for (text, h) in zip(resolved, heights) {
                gc.draw(text, in: CGRect(x: box.minX + 8, y: yy, width: width - 16, height: h))
                yy += h + 2
            }
        }

        // Playhead.
        gc.fill(Path(CGRect(x: x(now), y: 0, width: 1.5, height: size.height)), with: .color(.primary.opacity(0.7)))
    }
}

// MARK: - Keyboard

/// A piano keyboard showing scale notes (dots), chord notes (accent dots), sounding notes
/// (lit in their voice's colour) and an optional draggable range.
struct KeyboardView: View {
    var low = 21
    var high = 108
    var scale: Set<Int> = []
    var chord: Set<Int> = []
    var sounding: [Int: Color] = [:]
    var range: ClosedRange<Int>?
    var rangeColor: Color = .accentColor
    var onRangeChange: ((Int, Int) -> Void)?
    var showLabels = true
    @State private var dragging: Int? // 0 = low handle, 1 = high handle

    private static let blackPCs: Set<Int> = [1, 3, 6, 8, 10]
    private static func isBlack(_ n: Int) -> Bool { blackPCs.contains(((n % 12) + 12) % 12) }

    private func layout(_ size: CGSize) -> [(note: Int, rect: CGRect)] {
        let whites = (low...high).filter { !Self.isBlack($0) }
        let w = size.width / CGFloat(max(whites.count, 1))
        var out: [(Int, CGRect)] = []
        var i = 0
        for n in low...high {
            if Self.isBlack(n) {
                out.append((n, CGRect(x: CGFloat(i) * w - w * 0.3, y: 0, width: w * 0.6, height: size.height * 0.6)))
            } else {
                out.append((n, CGRect(x: CGFloat(i) * w, y: 0, width: w, height: size.height)))
                i += 1
            }
        }
        return out
    }

    private func note(at x: CGFloat, _ size: CGSize) -> Int {
        let keys = layout(size)
        return keys.first(where: { !Self.isBlack($0.note) && $0.rect.minX <= x && x < $0.rect.maxX })?.note
            ?? (x < 0 ? low : high)
    }

    var body: some View {
        GeometryReader { geo in
            Canvas { gc, size in
                let keys = layout(size)
                for pass in [false, true] {
                    for (n, rect) in keys where Self.isBlack(n) == pass {
                        let pc = ((n % 12) + 12) % 12
                        var fill: Color = pass ? Color(white: 0.15) : Color(white: 0.93)
                        if let c = sounding[n] { fill = c }
                        gc.fill(Path(roundedRect: rect.insetBy(dx: pass ? 0 : 0.5, dy: 0), cornerRadius: 2), with: .color(fill))
                        if let r = range, !r.contains(n) {
                            gc.fill(Path(rect), with: .color(.black.opacity(0.45)))
                        }
                        if chord.contains(pc) || scale.contains(pc) {
                            let d = min(rect.width * 0.45, 7)
                            let dot = CGRect(x: rect.midX - d / 2, y: rect.maxY - d - 4, width: d, height: d)
                            gc.fill(Path(ellipseIn: dot), with: .color(chord.contains(pc) ? .accentColor : (pass ? .white.opacity(0.5) : .gray.opacity(0.6))))
                        }
                        if showLabels, pc == 0, !pass, rect.width > 9 {
                            gc.draw(Text("C\(n / 12 - 1)").font(.system(size: 8)).foregroundStyle(.gray), at: CGPoint(x: rect.midX, y: rect.maxY - 18))
                        }
                    }
                }
                if let r = range {
                    for (i, n) in [r.lowerBound, r.upperBound].enumerated() {
                        guard let rect = keys.first(where: { $0.note == n })?.rect else { continue }
                        let xh = i == 0 ? rect.minX : rect.maxX
                        gc.fill(Path(roundedRect: CGRect(x: xh - 2, y: -2, width: 4, height: size.height + 4), cornerRadius: 2), with: .color(rangeColor))
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(onRangeChange == nil ? nil : DragGesture(minimumDistance: 0)
                .onChanged { g in
                    guard let r = range else { return }
                    let n = note(at: g.location.x, geo.size)
                    if dragging == nil {
                        dragging = abs(n - r.lowerBound) <= abs(n - r.upperBound) ? 0 : 1
                    }
                    if dragging == 0 { onRangeChange?(min(n, r.upperBound), r.upperBound) }
                    else { onRangeChange?(r.lowerBound, max(n, r.lowerBound)) }
                }
                .onEnded { _ in dragging = nil })
        }
    }
}

extension AppModel {
    /// Notes sounding right now, coloured by role.
    func soundingNotes(roles: Set<String>? = nil) -> [Int: Color] {
        guard let s = status else { return [:] }
        let now = engineNow()
        var out: [Int: Color] = [:]
        for n in s.recentNotes where (roles?.contains(n.role) ?? !RoleStyle.unpitched.contains(n.role)) && n.time <= now && now < n.time + n.duration {
            out[n.note] = RoleStyle.color(n.role)
        }
        return out
    }
}

// MARK: - Mood ladder

/// Smoothed traffic on a log scale with the mood bands. Drag the two handles to move the
/// quiet / busy thresholds.
struct MoodLadder: View {
    @Environment(AppModel.self) private var model
    private let lo = 2.0, hi = 8.0 // 100 B/s ... 100 MB/s
    @State private var dragging: String?

    private func pos(_ v: Double, _ w: CGFloat) -> CGFloat { CGFloat((log10(max(v, 1)) - lo) / (hi - lo)) * w }
    private func value(_ x: CGFloat, _ w: CGFloat) -> Double { pow(10, lo + Double(min(max(x / w, 0), 1)) * (hi - lo)) }

    var body: some View {
        let quiet = model.base("conductor.quietBelow"), busy = model.base("conductor.busyAbove")
        let s = model.status
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                ZStack(alignment: .topLeading) {
                    band("QUIET", from: 0, to: pos(quiet, w), color: .green, current: s?.mood == "quiet")
                    band("CALM", from: pos(quiet, w), to: pos(busy, w), color: .blue, current: s?.mood == "calm")
                    band(s?.mood == "focused" ? "FOCUSED" : "BUSY / FOCUSED", from: pos(busy, w), to: w, color: .orange,
                         current: s?.mood == "busy" || s?.mood == "focused")
                    if let s {
                        // Raw total (thin) and smoothed (what the mood uses).
                        Rectangle().fill(.primary.opacity(0.4)).frame(width: 1, height: h).offset(x: pos(s.totalRate, w))
                        Image(systemName: "arrowtriangle.down.fill").foregroundStyle(.primary)
                            .offset(x: pos(s.smoothedRate, w) - 6, y: -14)
                        Rectangle().fill(.primary).frame(width: 2.5, height: h).offset(x: pos(s.smoothedRate, w) - 1)
                    }
                    handle(x: pos(quiet, w), h: h)
                    handle(x: pos(busy, w), h: h)
                }
                // Children are positioned with offsets, which don't size the ZStack: pin it to the full
                // width so the whole bar (including the busy handle) takes the drag.
                .frame(width: w, height: h, alignment: .topLeading)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if dragging == nil {
                            dragging = abs(g.startLocation.x - pos(quiet, w)) < abs(g.startLocation.x - pos(busy, w)) ? "quiet" : "busy"
                        }
                        let v = value(g.location.x, w)
                        if dragging == "quiet" { model.set("conductor.quietBelow", min(v, busy * 0.9)) }
                        else { model.set("conductor.busyAbove", max(v, quiet * 1.1)) }
                    }
                    .onEnded { _ in dragging = nil })
            }
            .frame(height: 44)
            .padding(.top, 14)
            HStack {
                ForEach([1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8], id: \.self) { v in
                    Text(Format.rate(v)).font(.caption2).foregroundStyle(.secondary)
                    if v < 1e8 { Spacer() }
                }
            }
            if let s {
                Text("▼ smoothed \(Format.rate(s.smoothedRate)) decides the mood · thin line = this second's \(Format.rate(s.totalRate)) · drag the handles to move the thresholds")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func band(_ label: String, from a: CGFloat, to b: CGFloat, color: Color, current: Bool) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(color.opacity(current ? 0.45 : 0.18))
            .overlay(alignment: .leading) {
                Text(label).font(.caption.weight(current ? .bold : .regular)).padding(.leading, 6).lineLimit(1)
            }
            .frame(width: max(b - a, 0))
            .offset(x: a)
    }

    private func handle(x: CGFloat, h: CGFloat) -> some View {
        Capsule().fill(.white).frame(width: 8, height: h + 8)
            .shadow(radius: 1.5)
            .offset(x: x - 4, y: -4)
    }
}

// MARK: - Progression editor

/// Each mood's chords as chips. Click a chip to change, move or remove it; + adds a chord.
struct ProgressionEditor: View {
    @Environment(AppModel.self) private var model

    private func condition(_ mood: String) -> String {
        let quiet = Format.rate(model.base("conductor.quietBelow")), busy = Format.rate(model.base("conductor.busyAbove"))
        let focus = Int((model.base("conductor.focusRatio") * 100).rounded())
        switch mood {
        case "quiet": return "below \(quiet)"
        case "calm": return "\(quiet) – \(busy)"
        case "busy": return "above \(busy), spread out"
        case "focused": return "above \(busy), one app ≥ \(focus)%"
        case "flurry": return "gesture: \(model.base("conductor.flurryApps").formatted()) apps wake within \(model.base("conductor.flurryWindow").formatted()) s"
        default: return ""
        }
    }

    var body: some View {
        let s = model.status
        let rows = (s?.progressions ?? []) + (s?.gestures ?? [])
        VStack(alignment: .leading, spacing: 10) {
            ForEach(rows, id: \.mood) { p in
                let current = s?.mood == p.mood
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(p.mood.capitalized).fontWeight(current ? .bold : .medium)
                            .foregroundStyle(current ? Color.accentColor : .primary)
                        Text(condition(p.mood)).font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(width: 210, alignment: .leading)
                    HStack(spacing: 6) {
                        ForEach(Array(p.degrees.enumerated()), id: \.offset) { i, degree in
                            chip(p, i, degree, playing: current && i == s?.progressionIndex)
                        }
                        Menu {
                            ForEach(s?.chordChoices ?? [], id: \.degree) { c in
                                Button("\(c.name)   \(c.numeral)") { model.setProgression(p.mood, p.degrees + [c.degree]) }
                            }
                        } label: { Image(systemName: "plus") }
                            .menuStyle(.borderlessButton).fixedSize()
                            .help("Add a chord to the end")
                    }
                    Spacer()
                    if let defaults = Self.defaults[p.mood], defaults != p.degrees {
                        Button("Reset") { model.setProgression(p.mood, defaults) }.controlSize(.small)
                    }
                }
            }
        }
    }

    private func chip(_ p: MoodProgression, _ i: Int, _ degree: Int, playing: Bool) -> some View {
        ProgressionChip(progression: p, index: i, degree: degree, playing: playing)
    }

    static let defaults: [String: [Int]] = Dictionary(
        uniqueKeysWithValues: Conductor.defaultProgressions.map { ($0.key.rawValue, $0.value) }
    ).merging(Conductor.defaultGestures) { a, _ in a }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

// MARK: - Chord palette

/// Every chord the current key and scale offer. Each is built by stacking every other scale
/// note from its starting step (1·3·5, 2·4·6…), so changing root, scale or chord size reshapes them
/// all. Click to hear one now; use its menu to add it to a mood's progression.
struct ChordPalette: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let s = model.status
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(s?.chordChoices ?? [], id: \.degree) { c in
                    ChordCard(choice: c, playing: c.degree == s?.chordDegree)
                }
            }
        }
    }

    /// Close voicing within C3–B4 for the mini keyboard.
    static func voicing(_ pcs: [Int]) -> [Int] {
        guard let root = pcs.first else { return [] }
        var notes: [Int] = []
        var last = 48 + root
        for (i, pc) in pcs.enumerated() {
            var n = 48 + pc
            if i > 0 { while n <= last { n += 12 } }
            if n > 71 { n -= 12 }
            notes.append(n)
            last = n
        }
        return notes
    }
}

struct ChordCard: View {
    @Environment(AppModel.self) private var model
    let choice: EngineStatus.ChordChoice
    let playing: Bool

    private var targets: [MoodProgression] { (model.status?.progressions ?? []) + (model.status?.gestures ?? []) }

    private var addMenu: some View {
        Menu {
            Section("Add \(choice.name) to") {
                ForEach(targets, id: \.mood) { p in
                    Button(p.mood.capitalized) { model.setProgression(p.mood, p.degrees + [choice.degree]) }
                }
            }
        } label: { Image(systemName: "plus.circle") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Add \(choice.name) to a mood's progression")
    }

    private var keys: some View {
        let lit: [Int: Color] = Dictionary(uniqueKeysWithValues: ChordPalette.voicing(choice.pitchClasses).map { ($0, Color.accentColor.opacity(0.85)) })
        return KeyboardView(low: 48, high: 71, sounding: lit, showLabels: false)
            .frame(height: 34)
            .allowsHitTesting(false)
    }

    var body: some View {
        let steps = choice.steps.map(String.init).joined(separator: "·")
        let shape = RoundedRectangle(cornerRadius: 8)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(choice.name).font(.title3.weight(.semibold))
                Text(choice.numeral).font(.callout).foregroundStyle(.secondary)
                Spacer()
                addMenu
            }
            Text("steps \(steps)  ·  \(choice.notes.joined(separator: " "))")
                .font(.caption.monospaced()).foregroundStyle(.secondary)
            keys
        }
        .padding(8)
        .frame(width: 168)
        .background(playing ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.06), in: shape)
        .overlay(shape.stroke(playing ? Color.accentColor : Color.clear, lineWidth: 1.5))
        .contentShape(shape)
        .onTapGesture { model.auditionChord(choice.degree) }
        .help("Click to hear \(choice.name) now (the progression carries on at the next chord change)")
    }
}

/// One chord in a progression. Click to open an editor: pick any chord of the scale, move,
/// duplicate or remove it.
struct ProgressionChip: View {
    @Environment(AppModel.self) private var model
    let progression: MoodProgression
    let index: Int
    let degree: Int
    let playing: Bool
    @State private var editing = false

    private var choices: [EngineStatus.ChordChoice] { model.status?.chordChoices ?? [] }
    private var choice: EngineStatus.ChordChoice? { choices.first { $0.degree == degree % max(choices.count, 1) } }

    private func update(_ change: (inout [Int]) -> Void) {
        var d = progression.degrees
        change(&d)
        model.setProgression(progression.mood, d)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6)
        Button { editing = true } label: {
            VStack(spacing: 1) {
                Text(choice?.name ?? "?").font(.body.weight(playing ? .bold : .semibold))
                Text(choice?.numeral ?? "").font(.caption2).foregroundStyle(.secondary)
                Text(choice?.notes.joined(separator: " ") ?? "").font(.system(size: 9).monospaced()).foregroundStyle(.secondary)
            }
            .frame(minWidth: 48)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(playing ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.08), in: shape)
            .overlay(shape.stroke(playing ? Color.accentColor : Color.clear, lineWidth: 1.5))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .help("Click to change this chord")
        .popover(isPresented: $editing, arrowEdge: .bottom) { editor }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(progression.mood.capitalized), chord \(index + 1) of \(progression.degrees.count)").font(.headline)
            Text("Pick the chord for this step. They're the chords of the current scale, so changing key or scale changes them all.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(96), spacing: 6), count: 4), spacing: 6) {
                ForEach(choices, id: \.degree) { c in
                    Button {
                        update { $0[index] = c.degree }
                    } label: {
                        VStack(spacing: 1) {
                            Text(c.name).font(.body.weight(.semibold))
                            Text("\(c.numeral) · \(c.notes.joined(separator: " "))").font(.caption2).foregroundStyle(.secondary)
                        }
                        .frame(width: 90, height: 38)
                        .background(c.degree == degree ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.08),
                                    in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }
            Divider()
            HStack {
                Button { update { $0.swapAt(index, index - 1) }; editing = false } label: { Label("Move left", systemImage: "arrow.left") }
                    .disabled(index == 0)
                Button { update { $0.swapAt(index, index + 1) }; editing = false } label: { Label("Move right", systemImage: "arrow.right") }
                    .disabled(index == progression.degrees.count - 1)
                Button { update { $0.insert(degree, at: index) }; editing = false } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                Spacer()
                Button(role: .destructive) { update { $0.remove(at: index) }; editing = false } label: { Label("Remove", systemImage: "trash") }
                    .disabled(progression.degrees.count == 1)
            }
            Button { model.auditionChord(degree) } label: { Label("Hear this chord now", systemImage: "speaker.wave.2") }
        }
        .padding(14)
        .frame(width: 440)
    }
}
