import Charts
import Engine
import Music
import SwiftUI

/// Where data-driven notes wanted to be (hollow) and where the pitch quantiser put them (filled).
/// Background rows: scale notes shaded, current chord notes highlighted.
struct PitchPullView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let s = model.strengthSplit
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                let w = geo.size.width
                let strength = model.base("quant.pitch.strength")
                ZStack(alignment: .leading) {
                    HStack(spacing: 0) {
                        segment("raw \(s.raw)%", s.raw, .gray, w)
                        segment("in scale \(s.scale)%", s.scale, .blue, w)
                        segment("chord tone \(s.chord)%", s.chord, .accentColor, w)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    Capsule().fill(.white).frame(width: 8, height: 26).shadow(radius: 1.5)
                        .offset(x: w * CGFloat(strength) - 4)
                }
                .frame(width: w, height: 18, alignment: .leading)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                    model.set("quant.pitch.strength", Double(min(max(g.location.x / w, 0), 1)))
                })
            }
            .frame(height: 18)
            Text("Drag the handle: left = raw data pitches, middle = always in the scale, right = only chord notes.")
                .font(.caption).foregroundStyle(.secondary)
            Canvas { gc, size in draw(&gc, size) }
        }
    }

    private func segment(_ label: String, _ pct: Int, _ color: Color, _ width: CGFloat) -> some View {
        Rectangle().fill(color.opacity(0.55))
            .overlay(Text(pct >= 15 ? label : "").font(.caption2.weight(.semibold)).lineLimit(1))
            .frame(width: width * CGFloat(pct) / 100)
    }

    private func draw(_ gc: inout GraphicsContext, _ size: CGSize) {
        guard let st = model.status else { return }
        let notes = Array(st.recentNotes.filter { $0.rawPitch != nil && $0.time <= model.engineNow() }.suffix(28))
        guard !notes.isEmpty else {
            gc.draw(Text("Waiting for lead / pulse notes…").foregroundStyle(.secondary), at: CGPoint(x: size.width / 2, y: size.height / 2))
            return
        }
        let pitches = notes.flatMap { [Double($0.note), $0.rawPitch ?? Double($0.note)] }
        let lo = Int((pitches.min() ?? 60).rounded(.down)) - 2, hi = Int((pitches.max() ?? 72).rounded(.up)) + 2
        let rowH = size.height / CGFloat(hi - lo + 1)
        func y(_ p: Double) -> CGFloat { CGFloat(Double(hi) - p + 0.5) * rowH }
        let scale = Set(st.scalePitchClasses), chord = Set(st.chordPitchClasses)
        for n in lo...hi {
            let pc = ((n % 12) + 12) % 12
            let r = CGRect(x: 0, y: y(Double(n)) - rowH / 2, width: size.width, height: rowH)
            if chord.contains(pc) { gc.fill(Path(r), with: .color(.accentColor.opacity(0.14))) }
            else if scale.contains(pc) { gc.fill(Path(r), with: .color(.primary.opacity(0.05))) }
        }
        let slot = size.width / CGFloat(notes.count)
        for (i, n) in notes.enumerated() {
            let x = slot * (CGFloat(i) + 0.5)
            let raw = n.rawPitch ?? Double(n.note)
            let c = RoleStyle.color(n.role)
            var line = Path(); line.move(to: CGPoint(x: x, y: y(raw))); line.addLine(to: CGPoint(x: x, y: y(Double(n.note))))
            gc.stroke(line, with: .color(c.opacity(0.6)), lineWidth: 1.5)
            let d: CGFloat = min(rowH, 10)
            gc.stroke(Path(ellipseIn: CGRect(x: x - d / 2, y: y(raw) - d / 2, width: d, height: d)), with: .color(c), lineWidth: 1.5)
            gc.fill(Path(ellipseIn: CGRect(x: x - d / 2, y: y(Double(n.note)) - d / 2, width: d, height: d)), with: .color(c))
        }
    }
}

/// When notes were asked for (top, hollow) and when they sounded (bottom, filled) against the
/// quantise grid, including swing. Long lines = strong snapping.
struct TimingView: View {
    @Environment(AppModel.self) private var model
    var window: Double = 8

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 24, paused: !model.visualsActive)) { tl in
            Canvas { gc, size in draw(&gc, size, now: model.engineNow(at: tl.date)) }
        }
    }

    private func draw(_ gc: inout GraphicsContext, _ size: CGSize, now: Double) {
        guard let s = model.status else { return }
        let start = now - window, end = now + 1
        func x(_ t: Double) -> CGFloat { CGFloat((t - start) / (end - start)) * size.width }
        let spb = 60 / max(s.bpm, 1)
        let grid = model.gridBeats
        let swing = model.base("quant.time.swing")
        // Grid lines (odd steps shifted by swing).
        var k = ((s.beat - (s.time - start) / spb) / grid).rounded(.down)
        while true {
            let beat = k * grid + (Int(k) % 2 != 0 ? swing * grid : 0)
            let t = s.time + (beat - s.beat) * spb
            if t > end { break }
            let onBeat = abs(beat.truncatingRemainder(dividingBy: 1)) < 1e-6
            gc.fill(Path(CGRect(x: x(t), y: 0, width: onBeat ? 1 : 0.5, height: size.height)),
                    with: .color(.primary.opacity(onBeat ? 0.3 : 0.12)))
            k += 1
        }
        let top = size.height * 0.22, bottom = size.height * 0.78
        gc.draw(Text("asked").font(.caption2).foregroundStyle(.secondary), at: CGPoint(x: 4, y: top - 12), anchor: .leading)
        gc.draw(Text("played").font(.caption2).foregroundStyle(.secondary), at: CGPoint(x: 4, y: bottom + 12), anchor: .leading)
        for n in s.recentNotes where (n.role == "lead" || n.role == "pulse") && n.time >= start && n.rawTime <= end {
            let c = RoleStyle.color(n.role)
            var p = Path(); p.move(to: CGPoint(x: x(n.rawTime), y: top)); p.addLine(to: CGPoint(x: x(n.time), y: bottom))
            gc.stroke(p, with: .color(c.opacity(0.5)), lineWidth: 1)
            gc.stroke(Path(ellipseIn: CGRect(x: x(n.rawTime) - 4, y: top - 4, width: 8, height: 8)), with: .color(c), lineWidth: 1.5)
            gc.fill(Path(ellipseIn: CGRect(x: x(n.time) - 4, y: bottom - 4, width: 8, height: 8)), with: .color(c.opacity(n.time > now ? 0.4 : 1)))
        }
        gc.fill(Path(CGRect(x: x(now), y: 0, width: 1.5, height: size.height)), with: .color(.primary.opacity(0.7)))
    }
}

/// The velocity curve as currently set, with recent notes plotted on it. Drag the left end
/// (floor), the right end (ceiling) or the middle (bend).
struct VelocityCurveView: View {
    private func handles(floor: Double, ceiling: Double, curve: Double) -> [(Int, Double, Double)] {
        [(0, 0, floor), (1, 0.5, floor + (ceiling - floor) * pow(0.5, curve)), (2, 1, ceiling)]
    }

    @Environment(AppModel.self) private var model

    var body: some View {
        let floor = model.base("quant.velocity.floor"), ceiling = model.base("quant.velocity.ceiling")
        let curve = model.base("quant.velocity.curve")
        let line = stride(from: 0.0, through: 1.0, by: 0.02).map { ($0, floor + (ceiling - floor) * pow($0, curve)) }
        let notes = (model.status?.recentNotes ?? []).suffix(80)
        Chart {
            ForEach(line, id: \.0) { p in
                LineMark(x: .value("Intensity", p.0), y: .value("Velocity", p.1))
                    .foregroundStyle(.primary).lineStyle(StrokeStyle(lineWidth: 2))
            }
            ForEach(Array(notes), id: \.id) { n in
                PointMark(x: .value("Intensity", min(max(n.intensity, 0), 1)), y: .value("Velocity", n.velocity))
                    .foregroundStyle(RoleStyle.color(n.role).opacity(0.7))
                    .symbolSize(25)
            }
        }
        .chartXScale(domain: 0...1)
        .chartYScale(domain: 0...127)
        .chartXAxisLabel("generator intensity (from data)")
        .chartYAxisLabel("MIDI velocity")
        .chartOverlay { proxy in
            GeometryReader { geo in
                if let plot = proxy.plotFrame {
                    let frame = geo[plot]
                    // Handles: floor (left end), ceiling (right end), bend (middle).
                    ForEach(handles(floor: floor, ceiling: ceiling, curve: curve), id: \.0) { h in
                        if let p = proxy.position(for: (h.1, h.2)) {
                            Circle().fill(.white).frame(width: 12, height: 12).shadow(radius: 1.5)
                                .position(x: frame.minX + p.x, y: frame.minY + p.y)
                                .allowsHitTesting(false)
                        }
                    }
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                        .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                            let start = g.startLocation.x / frame.width
                            let loc = CGPoint(x: g.location.x, y: g.location.y)
                            guard let (x, v): (Double, Double) = proxy.value(at: loc) else { return }
                            let vel = min(max(v, 1), 127)
                            if start < 0.25 {
                                model.set("quant.velocity.floor", min(vel, ceiling - 1))
                            } else if start > 0.75 {
                                model.set("quant.velocity.ceiling", max(vel, floor + 1))
                            } else {
                                // Bend the curve so it passes through the pointer.
                                let xi = min(max(x, 0.05), 0.95)
                                let f = min(max((vel - floor) / max(ceiling - floor, 1), 0.01), 0.99)
                                model.set("quant.velocity.curve", log(f) / log(xi))
                            }
                        })
                }
            }
        }
    }
}

/// Melodic notes per second over the last few seconds against the limit.
struct DensityMeter: View {
    @Environment(AppModel.self) private var model
    // Fixed log scale 0.25…40 notes/s (the limit's range), so dragging doesn't move the scale.
    private static let lo = log(0.25), hi = log(40.0)
    private func pos(_ v: Double) -> CGFloat { CGFloat((log(max(v, 0.25)) - Self.lo) / (Self.hi - Self.lo)) }

    var body: some View {
        let now = model.engineNow()
        let recent = (model.status?.recentNotes ?? []).filter { ($0.role == "lead" || $0.role == "pulse") && now - $0.time < 5 && $0.time <= now }
        let rate = Double(recent.count) / 5
        let limit = model.base("quant.density.maxPerSecond")
        let lo = Self.lo, hi = Self.hi
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4).fill(.primary.opacity(0.08))
                    RoundedRectangle(cornerRadius: 4).fill(rate >= limit * 0.95 ? Color.orange : .teal)
                        .frame(width: rate > 0 ? max(w * pos(rate), 2) : 0)
                    Capsule().fill(.red).frame(width: 5, height: 22).offset(x: w * pos(limit) - 2.5)
                }
                .frame(width: w, height: 14, alignment: .leading)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                    let f = Double(min(max(g.location.x / w, 0), 1))
                    model.set("quant.density.maxPerSecond", (exp(lo + f * (hi - lo)) * 4).rounded() / 4)
                })
            }
            .frame(height: 14)
            Text(String(format: "%.1f melodic notes/s now · drag the red line to set the limit (%.2g/s) · %.0f%% chance each note plays",
                        rate, limit, model.base("quant.density.probability") * 100))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

extension AppModel {
    /// Current split of pitch-quantise outcomes, as whole percentages.
    var strengthSplit: (raw: Int, scale: Int, chord: Int) {
        let s = base("quant.pitch.strength")
        let chord = max(0, 2 * s - 1), inScale = min(1, 2 * s)
        let c = Int((chord * 100).rounded()), sc = Int(((inScale - chord) * 100).rounded())
        return (max(0, 100 - c - sc), sc, c)
    }

    /// Grid size in beats for the current `quant.time.grid` choice.
    var gridBeats: Double {
        let options = Quantiser.gridOptions
        return options[min(max(Int(base("quant.time.grid")), 0), options.count - 1)].beats
    }
}
