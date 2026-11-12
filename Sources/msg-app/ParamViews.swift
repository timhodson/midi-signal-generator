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
                Text(Self.format(base, spec)).monospacedDigit()
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
                Slider(value: Binding(get: { base }, set: { model.set(spec.id, $0.rounded()) }),
                       in: spec.range, step: 1)
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

    static func shortLabel(_ id: String) -> String {
        let last = id.split(separator: ".").last.map(String.init) ?? id
        // camelCase -> "camel case"
        var out = ""
        for c in last {
            if c.isUppercase, !out.isEmpty { out.append(" ") }
            out.append(c)
        }
        return out.prefix(1).uppercased() + out.dropFirst().lowercased()
    }

    static func format(_ v: Double, _ spec: ParamSpec) -> String {
        switch spec.kind {
        case .toggle: return v >= 0.5 ? "on" : "off"
        case .choice:
            return spec.options.indices.contains(Int(v)) ? "#\(Int(v))" : "\(Int(v))"
        case .integer: return "\(Int(v))\(spec.unit.isEmpty ? "" : " \(spec.unit)")"
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
    @State private var filter = ""

    var body: some View {
        let specs = model.specs(withPrefix: prefixes).filter { s in
            filter.isEmpty || s.id.localizedCaseInsensitiveContains(filter) || s.label.localizedCaseInsensitiveContains(filter)
                || s.help.localizedCaseInsensitiveContains(filter)
        }
        let groups = Dictionary(grouping: specs) { s in
            s.id.split(separator: ".").dropFirst(groupComponent).first.map(String.init) ?? ""
        }
        let order = specs.map { s in s.id.split(separator: ".").dropFirst(groupComponent).first.map(String.init) ?? "" }
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }

        List {
            if model.specs.isEmpty {
                NotRunningHint()
            }
            ForEach(order, id: \.self) { group in
                Section {
                    if let first = groups[group]?.first,
                       let doc = ParamDocs.description(for: groupPrefix(first.id)) {
                        Text(doc).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.vertical, 4)
                    }
                    if group == "conductor" { MoodTable().padding(.bottom, 6) }
                    ForEach(groups[group] ?? [], id: \.id) { ParamRow(spec: $0) }
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
    /// "gen.drone.octave" with groupComponent 1 -> "gen.drone".
    func groupPrefix(_ id: String) -> String {
        id.split(separator: ".").prefix(groupComponent + 1).joined(separator: ".")
    }

    static func title(_ group: String) -> String {
        ["gen": "Generators", "quant": "Quantise", "macro": "Macros", "sub": "Sub drone", "drone": "Pad (drone)",
         "motif": "Lead (motifs)", "pulse": "Pulse", "bass": "Bass", "activity": "App activity"][group] ?? group.capitalized
    }
}

/// What each mood plays, and when the network counts as that mood, at the current settings.
struct MoodTable: View {
    @Environment(AppModel.self) private var model

    private func condition(_ mood: String) -> String {
        let quiet = Format.rate(model.effective("conductor.quietBelow"))
        let busy = Format.rate(model.effective("conductor.busyAbove"))
        let focus = Int((model.effective("conductor.focusRatio") * 100).rounded())
        switch mood {
        case "quiet": return "traffic below \(quiet)"
        case "calm": return "\(quiet) – \(busy)"
        case "busy": return "above \(busy), spread across apps"
        case "focused": return "above \(busy), one app ≥ \(focus)%"
        default: return ""
        }
    }

    var body: some View {
        let status = model.status
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            GridRow {
                Text("Mood").font(.caption).foregroundStyle(.secondary)
                Text("When (smoothed traffic)").font(.caption).foregroundStyle(.secondary)
                Text("Chord progression").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(status?.progressions ?? [], id: \.mood) { p in
                let now = status?.mood == p.mood
                GridRow {
                    Text(p.mood.capitalized).fontWeight(now ? .bold : .regular)
                        .foregroundStyle(now ? Color.accentColor : .primary)
                    Text(condition(p.mood)).foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        ForEach(Array(zip(p.chords, p.numerals).enumerated()), id: \.offset) { i, chord in
                            let playing = now && i == status?.progressionIndex
                            VStack(spacing: 0) {
                                Text(chord.0).fontWeight(playing ? .bold : .regular)
                                Text(chord.1).font(.caption2).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(playing ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 4))
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .topTrailing) {
            if let s = status {
                Text("now: \(s.mood) at \(Format.rate(s.smoothedRate))").font(.caption).foregroundStyle(.secondary).padding(8)
            }
        }
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
