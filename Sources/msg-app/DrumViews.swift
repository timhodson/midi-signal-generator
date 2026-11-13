import Engine
import Music
import SwiftUI

/// Generators → Drums: what the drummer is doing and why, the feel controls as draggable bars,
/// the groove as an editable step grid, and the last hits with their reasons.
struct DrumsCard: View {
    var body: some View {
        VStack(spacing: 10) {
            VisualCard(title: "Drummer now",
                       caption: "Drag the bars. Presence decides which drums play (lanes join from left to right); complexity decides how many optional steps fill in, and traffic adds the lighter part.") {
                DrumPhaseLine()
                PresenceBar()
                ComplexityBar()
            }
            VisualCard(title: "Groove",
                       caption: "One bar, 16 steps. Solid cells always play; part-filled cells are optional, filled to their chance of playing at the current complexity. Dim rows need more presence. Click a step to cycle rest → hit → accent → optional → ghost → rare. The column moving across is the beat; cells flash as they play.") {
                DrumGrooveEditor()
            }
            VisualCard(title: "Recent hits", caption: "Newest first, with why each one played.") {
                DrumHitList()
            }
        }
    }
}

// MARK: - Status line

struct DrumPhaseLine: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let d = model.status?.drums
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(Self.color(d?.phase)).frame(width: 9, height: 9)
                .shadow(color: d?.phase == "playing" ? .green : .clear, radius: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(d.map { "\($0.phase.capitalized) · \($0.groove) groove in the \($0.mood) mood" } ?? "Start the engine to hear the drummer.")
                    .font(.callout.weight(.semibold))
                if let d {
                    Text(d.phaseDetail + (d.fillBar != nil ? " Fill planned: \(d.fillReason)." : ""))
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    static func color(_ phase: String?) -> Color {
        switch phase {
        case "playing": .green
        case "thinning": .yellow
        case "resting", "no groove": .orange
        default: .secondary
        }
    }
}

/// Presence as a bar with each lane's entry point marked. Drag to set it.
struct PresenceBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let value = model.effective("gen.drums.presence")
        VStack(alignment: .leading, spacing: 4) {
            Text("Presence \(value.formatted(.number.precision(.fractionLength(2))))").font(.caption.weight(.semibold))
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4).fill(.quaternary)
                    RoundedRectangle(cornerRadius: 4).fill(RoleStyle.color("drums").opacity(0.55))
                        .frame(width: max(w * value, 2))
                    ForEach(Array(Self.marks.enumerated()), id: \.offset) { i, mark in
                        let on = value >= mark.0
                        // Alternate label heights so neighbouring marks don't collide on narrow cards.
                        VStack(spacing: 1) {
                            Rectangle().fill(on ? Color.primary : .secondary).frame(width: 1, height: i % 2 == 0 ? 14 : 28)
                            Text(mark.1).font(.caption2).foregroundStyle(on ? .primary : .secondary).fixedSize()
                        }
                        .offset(x: w * mark.0)
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                    model.set("gen.drums.presence", min(max(g.location.x / max(w, 1), 0), 1))
                })
            }
            .frame(height: 44)
        }
    }

    /// Where lanes come in, grouped so labels don't collide.
    static let marks: [(Double, String)] = [
        (0, "shaker · rim"), (0.2, "hats"), (0.3, "kick"), (0.4, "low tom"), (0.45, "high tom · open hat"),
        (0.55, "snare"), (0.7, "crash"),
    ]
}

/// Complexity: the user's base plus what traffic adds, stacked. Drag to set the base.
struct ComplexityBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let d = model.status?.drums
        let base = d?.complexityBase ?? model.base("gen.drums.complexity")
        let traffic = d?.complexityFromTraffic ?? 0
        VStack(alignment: .leading, spacing: 4) {
            Text("Complexity \((base + traffic).formatted(.number.precision(.fractionLength(2)))) = your \(base.formatted(.number.precision(.fractionLength(2)))) + traffic \(traffic.formatted(.number.precision(.fractionLength(2)))) (smoothed \(Format.rate(d?.smoothedTraffic ?? 0)))")
                .font(.caption.weight(.semibold))
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4).fill(.quaternary)
                    HStack(spacing: 0) {
                        Rectangle().fill(RoleStyle.color("drums").opacity(0.55)).frame(width: max(w * base, 1))
                        Rectangle().fill(RoleStyle.color("drums").opacity(0.25)).frame(width: max(w * min(traffic, 1 - base), 0))
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    ForEach(Self.marks, id: \.0) { at, label in
                        VStack(spacing: 1) {
                            Rectangle().fill(.secondary).frame(width: 1, height: 14)
                            Text(label).font(.caption2).foregroundStyle(.secondary).fixedSize()
                        }
                        .offset(x: w * at)
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                    model.set("gen.drums.complexity", min(max(g.location.x / max(w, 1), 0), 1))
                })
            }
            .frame(height: 30)
        }
    }

    static let marks: [(Double, String)] = [(0.3, "optional hits"), (0.5, "ghost notes"), (0.7, "rare extras")]
}

// MARK: - Groove grid

struct DrumGrooveEditor: View {
    @Environment(AppModel.self) private var model
    /// nil = show whatever the current mood plays.
    @State private var chosen: String?
    @State private var hover: CGPoint?

    static let labelWidth: CGFloat = 150
    static let rowHeight: CGFloat = 22

    var body: some View {
        let d = model.status?.drums
        let playing = d?.groove ?? "Off"
        let name = chosen ?? (playing == "Off" ? "Heartbeat" : playing)
        let groove = d?.grooves.first { $0.name == name }
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Groove", selection: $chosen) {
                    Text("Following the mood (\(playing))").tag(String?.none)
                    Divider()
                    ForEach(DrumGroove.choices.dropFirst(), id: \.self) { Text($0).tag(String?.some($0)) }
                }
                .frame(maxWidth: 320)
                if name == playing {
                    Text("playing now").font(.caption).foregroundStyle(.green)
                } else {
                    Text("not playing in the \(d?.mood ?? "current") mood").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if d?.customised.contains(name) == true {
                    Button("Reset to built-in") { model.resetGroove(name) }.controlSize(.small)
                }
            }
            if let groove, let d {
                grid(groove, d, live: name == playing)
                    .frame(height: Self.rowHeight * CGFloat(DrumLane.allCases.count) + 18)
                if name == playing, let bar = d.fillBar {
                    Text("Orange steps: a fill\(bar > Int(((model.status?.beat ?? 0) / 4).rounded(.down)) ? " next bar" : " this bar") (\(d.fillReason)).")
                        .font(.caption).foregroundStyle(.orange)
                }
                Text(hoverText(groove, d) ?? (name == DrumGroove.euclidean
                    ? "Euclidean is built from the Euclid settings below (hits and rotation per lane), so it isn't edited here. Route a signal to a hits setting and the rhythm grows with it."
                    : "Hover a step for what it is and its chance of playing now."))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Start the engine to see the grooves.").foregroundStyle(.secondary)
            }
        }
    }

    private func cellAt(_ p: CGPoint, width: CGFloat, steps: Int) -> (DrumLane, Int)? {
        let gridW = width - Self.labelWidth
        guard p.x >= Self.labelWidth, p.y >= 18, gridW > 0 else { return nil }
        let step = Int((p.x - Self.labelWidth) / (gridW / CGFloat(steps)))
        let row = Int((p.y - 18) / Self.rowHeight)
        guard step < steps, DrumLane.allCases.indices.contains(row) else { return nil }
        return (DrumLane.allCases[row], step)
    }

    private func hoverText(_ g: DrumGroove, _ d: DrumStatus) -> String? {
        guard let hover, let (lane, step) = cellAt(hover, width: lastWidth, steps: g.steps) else { return nil }
        let sym = g.symbol(lane, step)
        var text = "\(lane.label) · step \(step + 1) (beat \(step / 4 + 1)\(step % 4 == 0 ? "" : " + \(step % 4)/16")): \(DrumCell.describe(sym))"
        if let c = DrumCell(sym) { text += " · \(Int((c.chance(complexity: d.complexity) * 100).rounded()))% chance now" }
        if d.presence < lane.presenceNeeded {
            text += lane == .snare ? " · played as a rim click until presence reaches 0.55" : " · silent until presence reaches \(lane.presenceNeeded.formatted())"
        }
        return text
    }

    @State private var lastWidth: CGFloat = 800

    private func grid(_ g: DrumGroove, _ d: DrumStatus, live: Bool) -> some View {
        GeometryReader { geo in
            TimelineView(.animation(minimumInterval: 1 / 24, paused: !model.visualsActive)) { tl in
                Canvas { gc, size in
                    draw(gc, size: size, g, d, live: live, now: model.engineNow(at: tl.date))
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                if case .active(let p) = phase { hover = p } else { hover = nil }
            }
            .gesture(SpatialTapGesture().onEnded { e in
                guard g.name != DrumGroove.euclidean, let (lane, step) = cellAt(e.location, width: geo.size.width, steps: g.steps) else { return }
                let symbols = DrumCell.symbols
                let i = symbols.firstIndex(of: g.symbol(lane, step)) ?? 0
                model.updateGroove(g.setting(lane, step, to: symbols[(i + 1) % symbols.count]))
            })
            .onAppear { lastWidth = geo.size.width }
            .onChange(of: geo.size.width) { _, w in lastWidth = w }
        }
    }

    private func draw(_ gc: GraphicsContext, size: CGSize, _ g: DrumGroove, _ d: DrumStatus, live: Bool, now: Double) {
        let colour = RoleStyle.color("drums")
        let steps = g.steps
        let cellW = (size.width - Self.labelWidth) / CGFloat(steps)
        let top: CGFloat = 18
        // Where the beat is now.
        let beat = (model.status.map { $0.beat + (now - $0.time) * $0.bpm / 60 } ?? 0)
        let global = Int((beat * 4).rounded(.down))
        let bar = global / max(d.stepsPerBar, 1), playStep = global % max(d.stepsPerBar, 1)

        // Beat numbers.
        for b in 0..<(steps / 4) {
            gc.draw(Text("\(b + 1)").font(.caption2).foregroundStyle(.secondary),
                    at: CGPoint(x: Self.labelWidth + CGFloat(b * 4) * cellW + 6, y: 8), anchor: .leading)
        }
        if live {
            let x = Self.labelWidth + CGFloat(playStep % steps) * cellW
            gc.fill(Path(CGRect(x: x, y: top - 2, width: cellW, height: CGFloat(DrumLane.allCases.count) * Self.rowHeight + 4)),
                    with: .color(.primary.opacity(0.08)))
        }
        let showFill = live && d.fillBar == bar
        let flashing = Set(d.hits.filter { now - $0.time >= 0 && now - $0.time < 0.18 && $0.bar == bar }.map { "\($0.lane)/\($0.step)" })

        for (row, lane) in DrumLane.allCases.enumerated() {
            let y = top + CGFloat(row) * Self.rowHeight
            let active = d.presence >= lane.presenceNeeded
            let asRim = lane == .snare && !active
            let label = "\(lane.label) · \(d.notes[lane.rawValue] ?? lane.gmNote)" + (asRim ? "  → rim" : active ? "" : "  (off)")
            gc.draw(Text(label).font(.caption).foregroundStyle(active ? .primary : .secondary),
                    at: CGPoint(x: 0, y: y + Self.rowHeight / 2), anchor: .leading)
            let rowOpacity = active ? 1.0 : asRim ? 0.6 : 0.3
            for s in 0..<steps {
                let r = CGRect(x: Self.labelWidth + CGFloat(s) * cellW + 1, y: y + 2, width: cellW - 2, height: Self.rowHeight - 4)
                let beatShade = (s / 4) % 2 == 0 ? 0.10 : 0.05
                gc.fill(Path(roundedRect: r, cornerRadius: 3), with: .color(.primary.opacity(beatShade)))
                let inFill = showFill && s >= d.fillStart && lane != .kick && lane != .hat
                let symbol = inFill ? d.fill.symbol(lane, 16 - (d.stepsPerBar - s)) : g.symbol(lane, s)
                if let c = DrumCell(symbol) {
                    let chance = inFill ? 1 : c.chance(complexity: d.complexity)
                    let h = max(r.height * chance, c.isCore ? r.height : 3)
                    let filled = CGRect(x: r.minX, y: r.maxY - h, width: r.width, height: h)
                    gc.fill(Path(roundedRect: filled, cornerRadius: 3),
                            with: .color((inFill ? Color.orange : colour).opacity((0.3 + 0.7 * c.velocity) * rowOpacity)))
                    if !c.isCore, !inFill {
                        gc.stroke(Path(roundedRect: r, cornerRadius: 3), with: .color(colour.opacity(0.5 * rowOpacity)), lineWidth: 1)
                    }
                }
                if flashing.contains("\(asRim ? DrumLane.rim.rawValue : lane.rawValue)/\(s)"), live {
                    gc.stroke(Path(roundedRect: r.insetBy(dx: -1, dy: -1), cornerRadius: 4), with: .color(.white), lineWidth: 2)
                }
            }
        }
    }
}

// MARK: - Hits

struct DrumHitList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let hits = Array((model.status?.drums?.hits ?? []).suffix(10).reversed())
        let now = model.status?.time ?? 0
        if hits.isEmpty {
            Text("No hits yet.").font(.callout).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(hits) { h in
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 2).fill(RoleStyle.color("drums").opacity(0.3 + 0.7 * h.velocity))
                            .frame(width: 10, height: 10)
                        Text("bar \(h.bar + 1) · step \(h.step + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            .frame(width: 104, alignment: .leading)
                        Text(h.why).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 8)
                        Text(h.time > now ? "next" : "\(Int(now - h.time))s").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                    }
                    .font(.callout)
                }
            }
        }
    }
}
