import Engine
import Params
import SwiftUI

/// One control for any `ParamSpec`, picked by kind. This is what "every musical decision is a
/// parameter" buys: no hand-built UI per setting.
struct ParamRow: View {
    @Environment(AppModel.self) private var model
    let spec: ParamSpec
    /// Replaces the spec's label (e.g. "Depth" on a mod route).
    var label: String?
    /// Show a box for typing an exact value (Advanced drawers).
    var typing = false

    private var base: Double { model.base(spec.id) }
    private var effective: Double { model.effective(spec.id) }
    private var modulated: Bool { abs(effective - base) > max(spec.span * 0.002, 1e-6) }

    /// Byte-rate thresholds span decades, so their sliders work on a log scale.
    private var isLog: Bool { spec.unit == "B/s" }

    /// Hosted synths' own controls all share one generic explanation; keep it to the tooltip.
    private var showsInlineHelp: Bool {
        guard model.showExplanations, !spec.help.isEmpty else { return false }
        let parts = spec.id.split(separator: ".")
        return !(parts.first == "au" && !["preset", "volume", "pan"].contains(parts.last ?? ""))
    }

    var body: some View {
        let _ = Perf.paramRowBodies += 1
        VStack(alignment: .leading, spacing: 3) {
            row
            if showsInlineHelp {
                Text(spec.help)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 252)
                    .padding(.trailing, 122)
            }
        }
        .padding(.vertical, 2)
        .help(spec.help)
    }

    private var row: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label ?? (spec.label == spec.id ? Self.shortLabel(spec.id) : spec.label))
                    .lineLimit(1)
                Text(spec.id).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: 240, alignment: .leading)

            control.frame(maxWidth: .infinity)

            VStack(alignment: .trailing, spacing: 1) {
                if typing, spec.kind == .continuous || spec.kind == .normalised || spec.kind == .integer {
                    TextField("", value: Binding(get: { base }, set: { model.set(spec.id, $0) }),
                              format: .number.precision(.significantDigits(1...6)))
                        .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 100)
                        .help("Type an exact value and press Return")
                } else {
                    Text(Self.format(base, spec)).monospacedDigit()
                }
                if modulated {
                    Text("~ \(Self.format(effective, spec))")
                        .font(.caption).monospacedDigit().foregroundStyle(.orange)
                        .help("Current value including modulation")
                }
            }
            .frame(width: 110, alignment: .trailing)
        }
    }

    @ViewBuilder private var control: some View {
        switch spec.kind {
        case .toggle:
            Toggle("", isOn: Binding(get: { base >= 0.5 }, set: { model.set(spec.id, $0 ? 1 : 0) }))
                .labelsHidden().toggleStyle(.switch).frame(maxWidth: .infinity, alignment: .leading)
        case .choice:
            Picker("", selection: Binding(get: { Int(base) }, set: { model.set(spec.id, Double($0)) })) {
                ForEach(Array(spec.options.enumerated()), id: \.offset) { i, name in
                    Text(name.trimmingCharacters(in: .whitespaces)).tag(i)
                }
            }
            .labelsHidden()
        case .integer:
            HStack {
                if spec.span <= 24 {
                    Slider(value: Binding(get: { base }, set: { model.set(spec.id, $0.rounded()) }), in: spec.range, step: 1)
                } else {
                    Slider(value: Binding(get: { base }, set: { model.set(spec.id, $0.rounded()) }), in: spec.range)
                }
                Stepper("", value: Binding(get: { base }, set: { model.set(spec.id, $0) }), in: spec.range, step: 1)
                    .labelsHidden()
            }
        case .normalised, .continuous:
            ZStack(alignment: .bottomLeading) {
                Slider(value: sliderBinding, in: 0...1)
                if modulated {
                    GeometryReader { geo in
                        Capsule().fill(.orange)
                            .frame(width: 3, height: 8)
                            .offset(x: max(0, min(geo.size.width - 3, geo.size.width * position(of: effective))), y: -1)
                    }
                    .frame(height: 8)
                    .allowsHitTesting(false)
                }
            }
        }
    }

    /// Slider works on 0...1; map to the param's range (log for byte rates).
    private var sliderBinding: Binding<Double> {
        Binding(get: { position(of: base) }, set: { model.set(spec.id, value(at: $0)) })
    }

    private func position(of v: Double) -> Double {
        if isLog {
            let lo = log10(max(spec.range.lowerBound, 1)), hi = log10(max(spec.range.upperBound, 10))
            return (log10(max(v, 1)) - lo) / (hi - lo)
        }
        return (v - spec.range.lowerBound) / max(spec.span, .ulpOfOne)
    }

    private func value(at p: Double) -> Double {
        if isLog {
            let lo = log10(max(spec.range.lowerBound, 1)), hi = log10(max(spec.range.upperBound, 10))
            return pow(10, lo + p * (hi - lo))
        }
        return spec.range.lowerBound + p * spec.span
    }

    /// "quant.pitch.strength" -> "Pitch strength"; "gen.drone.octave" -> "Octave" (the group
    /// header already says which generator); "harmony.chordSize" -> "Chord size".
    static func shortLabel(_ id: String) -> String {
        var parts = id.split(separator: ".").map(String.init)
        parts.removeFirst()
        if ["gen", "voice", "au", "mod"].contains(String(id.split(separator: ".").first ?? "")), parts.count > 1 {
            parts.removeFirst()
        }
        var out = ""
        for c in parts.joined(separator: " ") {
            if c.isUppercase, !out.isEmpty, out.last != " " { out.append(" ") }
            out.append(c)
        }
        return out.prefix(1).uppercased() + out.dropFirst().lowercased()
    }

    static func format(_ v: Double, _ spec: ParamSpec) -> String {
        switch spec.kind {
        case .toggle: return v >= 0.5 ? "on" : "off"
        case .choice:
            return spec.options.indices.contains(Int(v)) ? "#\(Int(v))" : "\(Int(v))"
        case .integer:
            if spec.id.hasPrefix("voice."), spec.id.hasSuffix(".low") || spec.id.hasSuffix(".high") {
                return "\(Format.note(Int(v)))  (\(Int(v)))"
            }
            return "\(Int(v))\(spec.unit.isEmpty ? "" : " \(spec.unit)")"
        case .normalised, .continuous:
            if spec.unit == "B/s" { return Format.rate(v) }
            let digits = spec.span >= 100 ? 0 : spec.span >= 10 ? 1 : 2
            return String(format: "%.\(digits)f", v) + (spec.unit.isEmpty ? "" : " \(spec.unit)")
        }
    }
}

/// A searchable list of param rows, grouped by the id component after the prefix.
struct ParamSection: View {
    @Environment(AppModel.self) private var model
    let title: String
    let prefixes: [String]
    /// Which id component names the group: 1 = "gen.drone.x" -> "drone".
    var groupComponent = 0
    /// Live visual shown above everything (what's playing, and what these controls change).
    var hero: AnyView?
    /// Extra view at the top of a group, by group key ("conductor", "bass"…).
    var accessory: (String) -> AnyView? = { _ in nil }
    @State private var filter = ""

    var body: some View {
        let specs = model.specs(withPrefix: prefixes).filter { s in
            filter.isEmpty || s.id.localizedCaseInsensitiveContains(filter) || s.label.localizedCaseInsensitiveContains(filter)
                || s.help.localizedCaseInsensitiveContains(filter)
        }
        let groups = Dictionary(grouping: specs) { groupKey($0.id) }
        let order = specs.map { groupKey($0.id) }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }

        List {
            if model.specs.isEmpty {
                NotRunningHint()
            } else if let hero, filter.isEmpty {
                Section { hero.listRowSeparator(.hidden).padding(.vertical, 6) }
            }
            ForEach(order, id: \.self) { group in
                Section {
                    if let first = groups[group]?.first,
                       let doc = ParamDocs.description(for: groupPrefix(first.id)),
                       group == order.first(where: { g in groups[g]?.first.flatMap { ParamDocs.description(for: groupPrefix($0.id)) } == doc }) {
                        Text(doc).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.vertical, 4)
                    }
                    if filter.isEmpty, let extra = accessory(group) { extra.listRowSeparator(.hidden).padding(.bottom, 6) }
                    let all = groups[group] ?? []
                    // Params a visual above can set live in an Advanced drawer (unless you're searching).
                    let advanced = filter.isEmpty ? all.filter { VisualControls.covers($0.id) } : []
                    let shown = all.filter { !advanced.contains($0) }
                    if model.useKnobs, filter.isEmpty {
                        // Switches as LED buttons, pickers as rows, everything continuous as a knob grid.
                        let toggles = shown.filter { $0.kind == .toggle }
                        if !toggles.isEmpty {
                            HStack(spacing: 10) {
                                ForEach(toggles, id: \.id) { LEDButton(spec: $0, color: Pages.color(forGroup: group)) }
                                Spacer()
                            }
                            .listRowSeparator(.hidden)
                        }
                        ForEach(shown.filter { $0.kind == .choice }, id: \.id) { ParamRow(spec: $0) }
                        let knobs = shown.filter(\.isKnob)
                        if !knobs.isEmpty {
                            KnobGrid(specs: knobs, color: Pages.color(forGroup: group)).listRowSeparator(.hidden)
                        }
                    } else {
                        ForEach(shown, id: \.id) { ParamRow(spec: $0) }
                    }
                    if !advanced.isEmpty {
                        AdvancedDrawer(specs: advanced)
                    }
                } header: {
                    Text(Self.title(group)).font(.headline)
                }
            }
        }
        .searchable(text: $filter, placement: .toolbar, prompt: "Filter \(title.lowercased())")
        .navigationTitle(title)
    }
}

extension ParamSection {
    /// Which group an id belongs to: "gen.drone.octave" -> "drone" (groupComponent 1). Ids too short
    /// to have that component ("activity.threshold") group by their first part instead.
    func groupKey(_ id: String) -> String {
        let parts = id.split(separator: ".").map(String.init)
        return parts.count > groupComponent + 1 ? parts[groupComponent] : parts[0]
    }

    /// "gen.drone.octave" with groupComponent 1 -> "gen.drone"; "activity.threshold" -> "activity".
    func groupPrefix(_ id: String) -> String {
        let parts = id.split(separator: ".")
        return parts.count > groupComponent + 1 ? parts.prefix(groupComponent + 1).joined(separator: ".") : String(parts[0])
    }

    static func title(_ group: String) -> String {
        ["gen": "Generators", "quant": "Quantise", "macro": "Macros", "sub": "Sub drone", "drone": "Pad (drone)",
         "motif": "Lead (motifs)", "pulse": "Pulse", "bass": "Bass", "activity": "App activity"][group] ?? group.capitalized
    }
}

/// Params that have a direct visual control (drag handles), so their sliders are tucked away.
enum VisualControls {
    static let ids: Set<String> = [
        "conductor.quietBelow", "conductor.busyAbove",              // Harmony → mood bar
        "quant.pitch.strength", "quant.density.maxPerSecond",       // Quantise → strength bar, density line
        "quant.velocity.floor", "quant.velocity.ceiling", "quant.velocity.curve", // velocity curve
    ]

    static func covers(_ id: String) -> Bool {
        if ids.contains(id) { return true }
        // Voices → range keyboards.
        return id.hasPrefix("voice.") && (id.hasSuffix(".low") || id.hasSuffix(".high"))
    }
}

/// Collapsed by default: sliders and exact-value entry for settings the visuals already control.
struct AdvancedDrawer: View {
    let specs: [ParamSpec]
    @State private var open = false

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            ForEach(specs, id: \.id) { ParamRow(spec: $0, typing: true) }
        } label: {
            Label("Advanced: \(specs.map { ParamRow.shortLabel($0.id).lowercased() }.joined(separator: ", ")). Set by dragging in the visual above; open for sliders and exact values",
                  systemImage: "slider.horizontal.3")
                .font(.callout).foregroundStyle(.secondary)
        }
        .listRowSeparator(.hidden)
    }
}

struct NotRunningHint: View {
    var body: some View {
        ContentUnavailableView("Not running", systemImage: "waveform.slash",
                               description: Text("Press Start to load the scene. Parameters appear once it runs."))
    }
}

enum Format {
    static func rate(_ bytesPerSecond: Double) -> String {
        switch bytesPerSecond {
        case ..<1_000: String(format: "%.0f B/s", bytesPerSecond)
        case ..<1_000_000: String(format: "%.1f kB/s", bytesPerSecond / 1_000)
        default: String(format: "%.1f MB/s", bytesPerSecond / 1_000_000)
        }
    }

    static func note(_ n: Int) -> String {
        let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
        return "\(names[((n % 12) + 12) % 12])\(n / 12 - 1)"
    }
}
