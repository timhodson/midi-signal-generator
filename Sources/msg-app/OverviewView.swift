import Charts
import Engine
import SwiftUI

struct OverviewView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                TransportBar()
                if let error = model.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red).textSelection(.enabled)
                }
                ForEach(model.messages, id: \.self) { m in
                    Text(m).font(.callout).foregroundStyle(m.hasPrefix("⚠︎") ? .orange : .secondary)
                }
                if model.isRunning {
                    StatusCards()
                    if model.specsByID["macro.faithfulness"] != nil {
                        SkinBox {
                            ParamRow(spec: model.specsByID["macro.faithfulness"]!,
                                     label: "Faithfulness  ·  0 tidy and musical — 1 raw sonification")
                        }
                    }
                    HStack(alignment: .top, spacing: 16) {
                        SkinBox(title: "Traffic") {
                            TrafficChart().frame(height: 220)
                            TrafficLegend()
                        }
                        SkinBox(title: "Busiest apps") { TopApps().frame(height: 220) }
                            .frame(width: 320)
                    }
                    SkinBox(title: "Recent notes") { RecentNotes() }
                } else {
                    NotRunningHint().frame(maxWidth: .infinity, minHeight: 300)
                }
            }
            .padding(20)
        }
        .navigationTitle("Overview")
    }
}

struct TransportBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 12) {
            if model.isRunning {
                Button { model.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                    .help("Stop and unload everything (hosted synths too). Every setting is kept for the next Start. To hold the music without unloading, use Pause at the top of the window.")
            } else {
                Button { Task { await model.start() } } label: { Label("Start", systemImage: "play.fill") }
                    .disabled(model.isStarting)
                    .skinProminent(.green)
            }
            if model.isStarting { ProgressView().controlSize(.small) }

            SkinPicker(title: "Source", selection: $model.sourceKind,
                       options: AppModel.SourceKind.allCases.map { ($0, $0.rawValue) })
            .frame(width: 220)
            .disabled(model.isRunning)

            if model.sourceKind == .replay {
                Button(model.replayURL?.lastPathComponent ?? "Choose recording…") { model.chooseReplayFile() }
                    .disabled(model.isRunning)
                SkinPicker(title: "Speed", selection: $model.replaySpeed,
                           options: [0.5, 1, 2, 4, 8].map { ($0, "×\($0.formatted())") })
                .frame(width: 110).disabled(model.isRunning)
                Toggle("Loop", isOn: $model.replayLoop).disabled(model.isRunning)
            }
            Toggle(isOn: $model.recording) { Label("Record", systemImage: "record.circle") }
                .toggleStyle(.button)
                .tint(model.recording ? .red : nil)
                .disabled(model.isRunning)
                .help("Record incoming signals to recordings/ so they can be replayed while tuning.")
            Spacer()
            Text(model.sceneURL?.lastPathComponent ?? "built-in scene").foregroundStyle(.secondary)
        }
    }
}

struct StatusCards: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let s = model.status
        HStack(spacing: 12) {
            Card(title: "Mood", value: s?.mood.capitalized ?? "–", detail: s.map { "smoothed \(Format.rate($0.smoothedRate))" })
            Card(title: "Chord", value: s.map { $0.chord.joined(separator: " ") } ?? "–",
                 detail: s.map { "degree \($0.chordDegree + 1) · \($0.key)" })
            Card(title: "Tempo", value: s.map { String(format: "%.0f bpm", $0.bpm) } ?? "–",
                 detail: s.map { String(format: "bar %d", Int($0.beat / 4) + 1) })
            Card(title: "Traffic", value: s.map { Format.rate($0.totalRate) } ?? "–", detail: "total, this interval")
            Card(title: "Sounding", value: s.map { "\($0.sounding)" } ?? "–", detail: "notes")
            if model.session?.auHost != nil {
                Card(title: "Output", value: String(format: "%.1f dBFS", model.peakDB),
                     detail: "peak", warn: model.peakDB > -1)
            }
        }
    }
}

struct Card: View {
    @Environment(\.skin) private var skin
    let title: String
    let value: String
    var detail: String?
    var warn = false

    var body: some View {
        if skin == .studio {
            VStack(alignment: .leading, spacing: 6) {
                Text(title.uppercased()).font(Studio.legend(10, weight: .bold)).tracking(1).foregroundStyle(Studio.label)
                LCDReadout(value: value, detail: detail, warn: warn)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PanelBackground(cornerRadius: 8, shade: 0.2))
        } else {
            plain
        }
    }

    private var plain: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold)).monospacedDigit().lineLimit(1)
                .foregroundStyle(warn ? .red : .primary)
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct TrafficChart: View {
    @Environment(AppModel.self) private var model
    /// The threshold being dragged ("conductor.quietBelow" / "conductor.busyAbove").
    @State private var dragging: String?
    @State private var nearLine = false

    var body: some View {
        let points = model.history
        let now = points.last?.time ?? 0
        let quiet = model.base("conductor.quietBelow")
        let busy = model.base("conductor.busyAbove")
        Chart {
            ForEach(points) { p in
                LineMark(x: .value("Seconds ago", p.time - now), y: .value("Bytes/s", p.total), series: .value("Series", "Total"))
                    .foregroundStyle(.gray.opacity(0.6))
                    .interpolationMethod(.stepEnd)
                LineMark(x: .value("Seconds ago", p.time - now), y: .value("Bytes/s", p.smoothed), series: .value("Series", "Smoothed"))
                    .foregroundStyle(.blue)
                    .lineStyle(StrokeStyle(lineWidth: 2))
            }
            RuleMark(y: .value("Quiet below", max(quiet, 1)))
                .foregroundStyle(.green.opacity(dragging == Self.quietID ? 1 : 0.6))
                .lineStyle(StrokeStyle(lineWidth: dragging == Self.quietID ? 2 : 1, dash: [4, 4]))
                .annotation(position: .top, alignment: .leading) { Text("quiet").font(.caption2).foregroundStyle(.green) }
                .annotation(position: .overlay, alignment: .trailing) { handle(.green, Self.quietID) }
            RuleMark(y: .value("Busy above", max(busy, 1)))
                .foregroundStyle(.red.opacity(dragging == Self.busyID ? 1 : 0.6))
                .lineStyle(StrokeStyle(lineWidth: dragging == Self.busyID ? 2 : 1, dash: [4, 4]))
                .annotation(position: .top, alignment: .leading) { Text("busy").font(.caption2).foregroundStyle(.red) }
                .annotation(position: .overlay, alignment: .trailing) { handle(.red, Self.busyID) }
        }
        // Drag a dashed line to move that threshold (the same settings as Harmony → Mood).
        .chartOverlay { proxy in
            GeometryReader { geo in
                let plot = proxy.plotFrame.map { geo[$0] } ?? .zero
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        if case .active(let p) = phase {
                            let near = line(near: p.y - plot.minY, proxy: proxy, quiet: quiet, busy: busy) != nil
                            if near != nearLine { nearLine = near; near ? NSCursor.resizeUpDown.push() : NSCursor.pop() }
                        } else if nearLine { nearLine = false; NSCursor.pop() }
                    }
                    .gesture(DragGesture(minimumDistance: 1)
                        .onChanged { g in
                            if dragging == nil {
                                guard let id = line(near: g.startLocation.y - plot.minY, proxy: proxy, quiet: quiet, busy: busy) else { return }
                                dragging = id
                            }
                            guard let id = dragging, let raw: Double = proxy.value(atY: g.location.y - plot.minY) else { return }
                            let v = Self.tidy(min(max(raw, 100), 100_000_000))
                            if id == Self.quietID { model.set(id, min(v, busy * 0.9)) } else { model.set(id, max(v, quiet * 1.1)) }
                        }
                        .onEnded { _ in dragging = nil })
            }
        }
        .onDisappear { if nearLine { nearLine = false; NSCursor.pop() } }
        .chartYScale(domain: 100...100_000_000, type: .log)
        .chartXScale(domain: -180...0)
        .chartPlotStyle { $0.clipped() }
        .chartYAxis {
            AxisMarks(values: [1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8]) { v in
                AxisGridLine()
                AxisValueLabel { Text(Format.rate(v.as(Double.self) ?? 0)) }
            }
        }
        .chartXAxisLabel("seconds ago")
    }
}

extension TrafficChart {
    static let quietID = "conductor.quietBelow", busyID = "conductor.busyAbove"

    /// The grip at the right end of a threshold line.
    func handle(_ color: Color, _ id: String) -> some View {
        Capsule().fill(color.opacity(dragging == id ? 1 : 0.75))
            .overlay(Image(systemName: "arrow.up.and.down").font(.system(size: 7, weight: .bold)).foregroundStyle(.black.opacity(0.7)))
            .frame(width: 22, height: 11)
            .help("Drag to move this threshold")
    }

    /// Which threshold line (if any) is within grabbing distance of a y position in the plot.
    func line(near y: CGFloat, proxy: ChartProxy, quiet: Double, busy: Double) -> String? {
        let candidates = [(Self.quietID, quiet), (Self.busyID, busy)].compactMap { id, v in
            proxy.position(forY: max(v, 1)).map { (id, abs($0 - y)) }
        }
        return candidates.filter { $0.1 <= 8 }.min { $0.1 < $1.1 }?.0
    }

    /// Thresholds read better as round numbers: two significant figures (8.3 kB/s, not 8,271 B/s).
    static func tidy(_ v: Double) -> Double {
        let p = pow(10, floor(log10(v)) - 1)
        return (v / p).rounded() * p
    }
}

/// What the traffic chart's lines mean.
struct TrafficLegend: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 18) {
            item(Path { p in p.move(to: .init(x: 0, y: 7)); p.addLine(to: .init(x: 6, y: 7)); p.addLine(to: .init(x: 6, y: 2))
                        p.addLine(to: .init(x: 13, y: 2)); p.addLine(to: .init(x: 13, y: 5)); p.addLine(to: .init(x: 20, y: 5)) },
                 .gray.opacity(0.8), "total traffic, each second")
            item(Path { p in p.move(to: .init(x: 0, y: 6)); p.addCurve(to: .init(x: 20, y: 2), control1: .init(x: 8, y: 6), control2: .init(x: 12, y: 2)) },
                 .blue, "smoothed: this decides the mood", width: 2)
            item(line, .green, "quiet below \(Format.rate(model.base("conductor.quietBelow")))", dash: [3, 3])
            item(line, .red, "busy above \(Format.rate(model.base("conductor.busyAbove")))", dash: [3, 3])
            Spacer(minLength: 0)
            Text("Log scale. Drag a dashed line to move its threshold.").foregroundStyle(.tertiary)
        }
        .font(.caption)
    }

    private var line: Path { Path { p in p.move(to: .init(x: 0, y: 4)); p.addLine(to: .init(x: 20, y: 4)) } }

    private func item(_ path: Path, _ color: Color, _ text: String, width: CGFloat = 1.5, dash: [CGFloat] = []) -> some View {
        HStack(spacing: 6) {
            path.stroke(color, style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round, dash: dash))
                .frame(width: 20, height: 8)
            Text(text).foregroundStyle(.secondary)
        }
    }
}

struct TopApps: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let apps = Array((model.status?.topApps ?? []).filter { $0.bytesPerSecond > 0 }.prefix(6))
        if apps.isEmpty {
            Text("No traffic yet").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Chart(apps, id: \.app) { a in
                BarMark(x: .value("Bytes/s", min(log10(max(a.bytesPerSecond, 1)), 8)), y: .value("App", a.app), height: .fixed(16))
                    .annotation(position: .trailing) { Text(Format.rate(a.bytesPerSecond)).font(.caption2) }
            }
            .chartXScale(domain: 0...8)
            .chartPlotStyle { $0.clipped() }
            .chartXAxis(.hidden)
        }
    }
}

struct RecentNotes: View {
    @Environment(AppModel.self) private var model

    private func colour(_ role: String) -> Color {
        switch role {
        case "pad": .purple
        case "lead": .orange
        case "pulse": .teal
        case "bass": .blue
        case "sub": .indigo
        default: .gray
        }
    }

    var body: some View {
        let notes = Array((model.status?.recentNotes ?? []).suffix(12).reversed())
        VStack(alignment: .leading, spacing: 3) {
            if notes.isEmpty { Text("Waiting for notes…").foregroundStyle(.secondary) }
            ForEach(notes) { n in
                HStack(spacing: 10) {
                    Circle().fill(colour(n.role)).frame(width: 8, height: 8)
                    Text(n.role).frame(width: 44, alignment: .leading)
                    Text(Format.note(n.note)).monospaced().frame(width: 44, alignment: .leading)
                    Text("v\(n.velocity)").monospacedDigit().frame(width: 40, alignment: .leading).foregroundStyle(.secondary)
                    Text(n.why).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                }
                .font(.callout)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The middle of the toolbar: play/pause, randomise, and what's playing. Pause holds the music
/// with everything still loaded; Stop (on the Overview) unloads the session.
struct PlayControls: View {
    @Environment(AppModel.self) private var model
    @Environment(\.skin) private var skin

    var body: some View {
        HStack(spacing: 8) {
            Button { Task { await model.playPause() } } label: {
                Image(systemName: !model.isRunning || model.paused ? "play.fill" : "pause.fill").frame(width: 22)
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(model.isStarting)
            .help(!model.isRunning ? "Start (⌘↩)" : model.paused ? "Play (⌘↩)" : "Pause (⌘↩): the music holds, everything stays loaded")
            Button { model.randomise() } label: { Image(systemName: "dice").frame(width: 22) }
                .disabled(!model.isRunning)
                .help("Randomise: vary the piece at the next chord (key, scale, progressions, motifs…) by the deviation set on the Variation page")
            Button { model.stop() } label: { Image(systemName: "stop.fill").frame(width: 22) }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!model.isRunning)
                .help("Stop (⌘.): unload everything, hosted synths too. Settings are kept for the next start.")
            Text(readout).font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(model.paused ? .orange : .secondary)
                .lineLimit(1).frame(minWidth: 180, alignment: .leading)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(skin == .studio ? 0.45 : 0.08)))
        }
        .controlSize(.regular)
    }

    private var readout: String {
        if model.isStarting { return "starting…" }
        guard model.isRunning, let s = model.status else { return "stopped" }
        if model.paused { return "paused · \(s.chordHistory.last?.name ?? "") · \(Int(s.bpm.rounded())) bpm" }
        let bar = Int(s.beat / 4) + 1, beat = Int(s.beat.truncatingRemainder(dividingBy: 4)) + 1
        return "\(bar).\(beat) · \(s.key) · \(s.chordHistory.last?.name ?? "") · \(Int(s.bpm.rounded())) bpm"
    }
}
