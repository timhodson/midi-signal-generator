import Charts
import Params
import SwiftUI

/// The mod matrix: signal → parameter routes with live input values.
struct ModulationView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.skin) private var skin
    @State private var adding = false

    var body: some View {
        Group {
            if skin == .studio { studio } else { list }
        }
        .navigationTitle("Modulation")
        .sheet(isPresented: $adding) { AddRouteSheet() }
    }

    /// Studio: one engraved panel per route, like patch points on a modular's matrix.
    private var studio: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if !model.isRunning { NotRunningHint() } else { LFOCard() }
                HStack {
                    Text("ROUTES · \(model.routes.count)").font(Studio.legend(12, weight: .bold)).tracking(1.5)
                        .foregroundStyle(Studio.label)
                    Spacer()
                    Button { adding = true } label: { Label("Add Route", systemImage: "plus") }
                        .disabled(!model.isRunning)
                }
                ForEach(Array(model.routes.enumerated()), id: \.offset) { i, route in
                    SkinBox { RouteRow(index: i, route: route) }
                }
                Text("Depth is a fraction of the target's range. Adding or removing a route restarts the session.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)
        }
    }

    private var list: some View {
        List {
            if !model.isRunning { NotRunningHint() } else { LFOCard().listRowSeparator(.hidden) }
            Section {
                ForEach(Array(model.routes.enumerated()), id: \.offset) { i, route in
                    RouteRow(index: i, route: route)
                }
            } header: {
                HStack {
                    Text("Routes")
                    Spacer()
                    Button { adding = true } label: { Label("Add Route", systemImage: "plus") }
                        .disabled(!model.isRunning)
                }
            } footer: {
                Text("Depth is a fraction of the target's range. Adding or removing a route restarts the session.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct RouteRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.skin) private var skin
    let index: Int
    let route: ModRoute

    var body: some View {
        let input = model.status?.signals[route.source]
        let target = model.specsByID[route.target]
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(route.source).font(.body.monospaced())
                Image(systemName: "arrow.right")
                Text(target?.label ?? route.target).font(.body.weight(.medium))
                Text(route.target).font(.caption.monospaced()).foregroundStyle(.secondary)
                Spacer()
                Button(role: .destructive) { Task { await model.removeRoute(at: index) } } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
            }
            HStack(spacing: 16) {
                Text("input \(input.map { route.scale == .log ? Format.rate($0) : String(format: "%.3g", $0) } ?? "–")")
                    .monospacedDigit().foregroundStyle(.secondary)
                // Normalised input meter (what the route actually feeds in).
                ProgressView(value: input.map { route.normalise($0) } ?? 0)
                    .frame(width: 120)
                Text("\(route.scale.rawValue) \(Format.rate(route.inputMin))…\(Format.rate(route.inputMax)), curve \(route.curve.formatted()), smooth \(route.smoothing.formatted()) s")
                    .font(.caption).foregroundStyle(.secondary)
            }
            let depth = model.specsByID["mod.\(index).amount"]
            if skin == .studio {
                // Studio: the depth is a bipolar knob beside the two traces it connects.
                HStack(alignment: .center, spacing: 16) {
                    HStack(spacing: 12) {
                        Sparkline(title: "input, as the route sees it (0–1)",
                                  points: (model.traces[route.source] ?? []).map { ($0.time, route.normalise($0.value)) },
                                  domain: 0...1, color: .teal)
                        Sparkline(title: "\(target?.label ?? route.target), base + modulation",
                                  points: (model.traces["param:" + route.target] ?? []).map { ($0.time, $0.value) },
                                  domain: target.map { $0.range } ?? 0...1, color: .orange,
                                  baseline: model.base(route.target))
                    }
                    .frame(height: 70)
                    if let depth { ParamKnob(spec: depth, label: "Depth", color: .orange, size: 58).frame(width: 90) }
                }
            } else {
                HStack(spacing: 12) {
                    Sparkline(title: "input, as the route sees it (0–1)",
                              points: (model.traces[route.source] ?? []).map { ($0.time, route.normalise($0.value)) },
                              domain: 0...1, color: .teal)
                    Sparkline(title: "\(target?.label ?? route.target), base + modulation",
                              points: (model.traces["param:" + route.target] ?? []).map { ($0.time, $0.value) },
                              domain: target.map { $0.range } ?? 0...1, color: .orange,
                              baseline: model.base(route.target))
                }
                .frame(height: 70)
                if let depth { ParamRow(spec: depth, label: "Depth") }
            }
        }
        .padding(.vertical, 4)
    }
}

struct AddRouteSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var source = "net.total.bytesPerSec"
    @State private var target = ""
    @State private var targetFilter = ""
    @State private var amount = 0.3
    @State private var scale: InputScale = .log
    @State private var inputMin = 1_000.0
    @State private var inputMax = 10_000_000.0
    @State private var smoothing = 2.0

    var body: some View {
        let sources = Array(Set((model.status?.signals.keys).map(Array.init) ?? []).union(["net.total.bytesPerSec"])).sorted()
        let targets = model.specs.filter { $0.modulatable && !$0.id.hasPrefix("mod.") }
            .filter { targetFilter.isEmpty || $0.id.localizedCaseInsensitiveContains(targetFilter) || $0.label.localizedCaseInsensitiveContains(targetFilter) }
        Form {
            Picker("Source signal", selection: $source) { ForEach(sources, id: \.self) { Text($0).tag($0) } }
                .onChange(of: source) { _, s in
                    // LFOs are already 0–1 and fast: linear, unsmoothed.
                    if s.hasPrefix("lfo.") { scale = .linear; inputMin = 0; inputMax = 1; smoothing = 0 }
                }
            TextField("Find target", text: $targetFilter)
            Picker("Target parameter", selection: $target) {
                Text("Choose…").tag("")
                ForEach(targets.prefix(300), id: \.id) { Text("\($0.id)  —  \($0.label)").tag($0.id) }
            }
            Slider(value: $amount, in: -1...1) { Text("Depth \(amount.formatted(.number.precision(.fractionLength(2))))") }
            Picker("Input scale", selection: $scale) {
                Text("log").tag(InputScale.log)
                Text("linear").tag(InputScale.linear)
            }
            TextField("Input min", value: $inputMin, format: .number)
            TextField("Input max", value: $inputMax, format: .number)
            TextField("Smoothing (s)", value: $smoothing, format: .number)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") {
                    let route = ModRoute(source: source, target: target, amount: amount, inputMin: inputMin,
                                         inputMax: inputMax, scale: scale, curve: 1, smoothing: smoothing)
                    dismiss()
                    Task { await model.addRoute(route) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(target.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}

/// A small live line chart (last ~60 s), with an optional dashed baseline (e.g. the base value).
struct Sparkline: View {
    let title: String
    let points: [(Double, Double)]
    let domain: ClosedRange<Double>
    var color: Color = .accentColor
    var baseline: Double?

    static let window = 60.0

    var body: some View {
        let now = points.last?.0 ?? 0
        // Only what fits the window: Charts doesn't clip marks outside the axis domain.
        let visible = points.filter { now - $0.0 <= Self.window }
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            Chart {
                ForEach(Array(visible.enumerated()), id: \.offset) { _, p in
                    LineMark(x: .value("t", p.0 - now), y: .value("v", min(max(p.1, domain.lowerBound), domain.upperBound)))
                        .foregroundStyle(color)
                }
                if let baseline {
                    RuleMark(y: .value("base", baseline)).foregroundStyle(.secondary).lineStyle(StrokeStyle(dash: [3, 3]))
                }
            }
            .chartXScale(domain: -Self.window...0)
            .chartPlotStyle { $0.clipped() }
            .chartYScale(domain: domain.lowerBound...max(domain.upperBound, domain.lowerBound + 0.0001))
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .padding(4)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

/// The two tempo-synced LFOs: a CC to a voice (wobble, pumping) and a signal for routes.
struct LFOCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VisualCard(title: "Tempo-synced LFOs",
                   caption: "Shapes locked to the beat. Switch one on to send it to a voice as a MIDI CC: CC74 (filter) at 1/8 is a dubstep wobble; Pump on CC11 (expression) at 1/4 ducks like sidechain compression. Each is also the signal lfo.1 / lfo.2: add a route from it to ride any setting, hosted synths and the mixer included.") {
            HStack(alignment: .top, spacing: 16) {
                ForEach([1, 2], id: \.self) { n in lfo(n) }
            }
        }
    }

    private func lfo(_ n: Int) -> some View {
        let id = { (s: String) in "lfo.\(n).\(s)" }
        let value = model.status?.signals["lfo.\(n)"] ?? 0
        let on = model.base(id("enabled")) >= 0.5
        return SkinBox(title: "LFO \(n)") {
            HStack(spacing: 10) {
                if let spec = model.specsByID[id("enabled")] { LEDButton(spec: spec, label: "CC out", color: .orange) }
                // Live level.
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.black.opacity(0.35))
                        Capsule().fill(on ? Color.orange : Color.secondary.opacity(0.6))
                            .frame(width: max(4, geo.size.width * value))
                    }
                }
                .frame(height: 8)
                Text(String(format: "%.2f", value)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 34)
            }
            ForEach(["rate", "shape", "role"], id: \.self) { s in
                if let spec = model.specsByID[id(s)] { ParamRow(spec: spec) }
            }
            KnobGrid(specs: ["cc", "low", "high", "phase"].compactMap { model.specsByID[id($0)] }, color: .orange)
        }
    }
}
