import Charts
import Engine
import SwiftUI

struct OverviewView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
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
                        GroupBox {
                            ParamRow(spec: model.specsByID["macro.faithfulness"]!,
                                     label: "Faithfulness  ·  0 tidy and musical — 1 raw sonification")
                        }
                    }
                    HStack(alignment: .top, spacing: 16) {
                        GroupBox("Traffic") { TrafficChart().frame(height: 220) }
                        GroupBox("Busiest apps") { TopApps().frame(height: 220) }
                            .frame(width: 320)
                    }
                    GroupBox("Recent notes") { RecentNotes() }
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
                    .keyboardShortcut(".", modifiers: .command)
            } else {
                Button { Task { await model.start() } } label: { Label("Start", systemImage: "play.fill") }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.isStarting)
                    .buttonStyle(.borderedProminent)
            }
            if model.isStarting { ProgressView().controlSize(.small) }

            Picker("Source", selection: $model.sourceKind) {
                ForEach(AppModel.SourceKind.allCases) { Text($0.rawValue).tag($0) }
            }
            .frame(width: 220)
            .disabled(model.isRunning)

            if model.sourceKind == .replay {
                Button(model.replayURL?.lastPathComponent ?? "Choose recording…") { model.chooseReplayFile() }
                    .disabled(model.isRunning)
                Picker("Speed", selection: $model.replaySpeed) {
                    ForEach([0.5, 1, 2, 4, 8], id: \.self) { Text("×\($0.formatted())").tag($0) }
                }
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
    let title: String
    let value: String
    var detail: String?
    var warn = false

    var body: some View {
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
                .foregroundStyle(.green.opacity(0.6)).lineStyle(StrokeStyle(dash: [4, 4]))
                .annotation(position: .top, alignment: .leading) { Text("quiet").font(.caption2).foregroundStyle(.green) }
            RuleMark(y: .value("Busy above", max(busy, 1)))
                .foregroundStyle(.red.opacity(0.6)).lineStyle(StrokeStyle(dash: [4, 4]))
                .annotation(position: .top, alignment: .leading) { Text("busy").font(.caption2).foregroundStyle(.red) }
        }
        .chartYScale(domain: 100...100_000_000, type: .log)
        .chartXScale(domain: -180...0)
        .chartYAxis {
            AxisMarks(values: [1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8]) { v in
                AxisGridLine()
                AxisValueLabel { Text(Format.rate(v.as(Double.self) ?? 0)) }
            }
        }
        .chartXAxisLabel("seconds ago")
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
                BarMark(x: .value("Bytes/s", log10(max(a.bytesPerSecond, 1))), y: .value("App", a.app), height: .fixed(16))
                    .annotation(position: .trailing) { Text(Format.rate(a.bytesPerSecond)).font(.caption2) }
            }
            .chartXScale(domain: 0...8)
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
