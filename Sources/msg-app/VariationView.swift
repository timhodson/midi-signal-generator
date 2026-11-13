import Engine
import SwiftUI

/// Music → Variation: randomise the melodic presentation (key, scale, progressions, motifs,
/// registers…) by a chosen deviation, now or on a schedule, and see what each variation changed.
struct VariationView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.specs.isEmpty {
                NotRunningHint()
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        VariationActions()
                        VariationControls()
                        VariationHistory()
                    }
                    .padding(18)
                }
            }
        }
        .skinnedPage(model.skin, shade: 0.45)
        .navigationTitle("Variation")
    }
}

private struct VariationActions: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let info = model.status?.variation
        VisualCard(title: "Variation",
                   caption: "A fresh take on the piece: a new key or scale, reworked chord progressions, a new set of app motifs, different registers and patterns. How far it strays is the deviation below. Changes land on the next chord change; scheduled ones wait for the end of a phrase.") {
            HStack(spacing: 10) {
                Button { model.randomise() } label: { Label("Randomise now", systemImage: "dice") }
                    .skinProminent(.yellow)
                Button { model.returnHome() } label: { Label("Return home", systemImage: "house") }
                    .help("Go back to the home settings (the scene as loaded, or what you last made home)")
                Button { model.makeHome() } label: { Label("Make this home", systemImage: "house.badge.plus") }
                    .help("Variations start from what's playing now from here on")
                Spacer()
            }
            .controlSize(.large)
            Group {
                if let pending = info?.pending {
                    Label("Waiting for the \(model.effective("variation.waitForPhrase") >= 0.5 && pending.hasPrefix("every") ? "end of the phrase" : "next chord change"): \(pending)",
                          systemImage: "hourglass")
                } else if let next = info?.nextIn {
                    Label("Next variation in \(Self.duration(next)), at the end of a phrase", systemImage: "clock")
                } else {
                    Label("No schedule: vary by hand, or pick how often below.", systemImage: "clock.badge.xmark")
                }
            }
            .font(.callout).foregroundStyle(.secondary)
        }
    }

    static func duration(_ s: Double) -> String {
        s >= 3600 ? String(format: "%d h %02d min", Int(s) / 3600, Int(s) % 3600 / 60)
            : s >= 60 ? "\(Int((s / 60).rounded(.up))) min" : "\(Int(s)) s"
    }
}

private struct VariationControls: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VisualCard(title: "How far, how often, what",
                   caption: "Deviation: 0.1 nudges a couple of things (a neighbouring key, an octave); 0.5 is a new take (another scale family, reworked progressions, new motifs); 1 changes almost everything, unusual scales included.") {
            HStack(alignment: .top, spacing: 24) {
                if let amount = model.specsByID["variation.amount"] {
                    VStack(spacing: 4) {
                        ParamKnob(spec: amount, label: "Deviation", color: .yellow, size: 92)
                        Text(Self.describe(model.effective("variation.amount"))).font(.caption).foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(["variation.every", "variation.from"], id: \.self) { id in
                        if let spec = model.specsByID[id] { ParamRow(spec: spec) }
                    }
                }
            }
            Text("What varies").font(.subheadline.weight(.semibold)).padding(.top, 4)
            HStack(spacing: 10) {
                ForEach(["variation.harmony", "variation.motifs", "variation.generators", "variation.tempo", "variation.drums", "variation.waitForPhrase"], id: \.self) { id in
                    if let spec = model.specsByID[id] {
                        LEDButton(spec: spec, label: id == "variation.waitForPhrase" ? "Wait for phrase" : nil, color: .yellow)
                    }
                }
                Spacer()
            }
        }
    }

    static func describe(_ d: Double) -> String {
        switch d {
        case ..<0.05: "no change"
        case ..<0.25: "a nudge"
        case ..<0.6: "a new take"
        case ..<0.85: "a different piece"
        default: "anything goes"
        }
    }
}

private struct VariationHistory: View {
    @Environment(AppModel.self) private var model
    @Environment(\.skin) private var skin

    var body: some View {
        let log = Array((model.status?.variation?.log ?? []).reversed())
        let now = model.status?.time ?? 0
        VisualCard(title: "What changed", caption: log.isEmpty ? "Nothing yet. Press Randomise now, or set a schedule." : nil) {
            ForEach(Array(log.prefix(6).enumerated()), id: \.offset) { i, entry in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(entry.reason) · \(Self.ago(now - entry.time))").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    if skin == .studio && i == 0 {
                        LCDScreen(lines: ["\(entry.changes.count) change\(entry.changes.count == 1 ? "" : "s")"] + entry.changes)
                    } else {
                        ForEach(entry.changes, id: \.self) { c in
                            Text("• " + c).font(i == 0 ? .callout : .caption).foregroundStyle(i == 0 ? .primary : .secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.bottom, 6)
            }
        }
    }

    static func ago(_ s: Double) -> String {
        s < 60 ? "just now" : s < 3600 ? "\(Int(s / 60)) min ago" : "\(Int(s / 3600)) h ago"
    }
}
