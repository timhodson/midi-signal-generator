import Params
import SwiftUI

/// The mod matrix: signal → parameter routes with live input values.
struct ModulationView: View {
    @Environment(AppModel.self) private var model
    @State private var adding = false

    var body: some View {
        List {
            if !model.isRunning { NotRunningHint() }
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
        .navigationTitle("Modulation")
        .sheet(isPresented: $adding) { AddRouteSheet() }
    }
}

struct RouteRow: View {
    @Environment(AppModel.self) private var model
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
            if let depth = model.specsByID["mod.\(index).amount"] { ParamRow(spec: depth, label: "Depth") }
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
