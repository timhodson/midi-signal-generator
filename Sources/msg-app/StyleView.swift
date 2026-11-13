import Engine
import Music
import SwiftUI

/// Music → Style: make the piece synthwave, house, funk… (ADR 0020). A style sets tempo, scale,
/// progressions (some from real songs of the genre), grooves, bass figures and arpeggios as ordinary
/// settings; the network still drives it, with a breakdown when quiet and the drop when busy.
struct StyleView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.specs.isEmpty {
                NotRunningHint()
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        StyleHeader()
                        StyleGrid()
                        VariationHistory()
                    }
                    .padding(18)
                }
            }
        }
        .skinnedPage(model.skin, shade: 0.45)
        .navigationTitle("Style")
    }
}

private struct StyleHeader: View {
    @Environment(AppModel.self) private var model
    @Environment(\.skin) private var skin

    var body: some View {
        let chosen = Int(model.base("style.name"))
        let name = Style.choices[safe: chosen] ?? "None"
        let pending = model.status?.style?.pending ?? false
        VisualCard(title: "Style",
                   caption: "Pick a genre and the piece takes it on at the next chord change: tempo, scale, chord progressions (some borrowed from real songs of that genre), drum grooves, bass figures and arpeggios. The network still drives it: a quiet network is the breakdown, a busy one the drop. Everything stays tunable on the other pages; None puts the scene back as it was.") {
            HStack(spacing: 12) {
                if skin == .studio {
                    LCDScreen(lines: [name, pending ? "changing at the next chord" : status]).frame(maxWidth: 520)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name).font(.title2.weight(.semibold))
                        Text(pending ? "Changing at the next chord" : status).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button { model.restyle() } label: { Label("New take", systemImage: "dice") }
                    .disabled(chosen == 0)
                    .help("Apply the style again: a new tempo in its range, scale and progressions")
                    .skinProminent(.yellow)
                Button { model.set("style.name", 0) } label: { Label("None", systemImage: "arrow.uturn.backward") }
                    .disabled(chosen == 0)
                    .help("Back to the scene as it was before the first style")
            }
            .controlSize(.large)
        }
    }

    private var status: String {
        guard let s = model.status else { return "" }
        return String(format: "%.0f bpm · %@ · mood %@", s.bpm, s.key, s.mood)
    }
}

private struct StyleGrid: View {
    @Environment(AppModel.self) private var model
    @Environment(\.skin) private var skin

    var body: some View {
        let chosen = Int(model.base("style.name"))
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12)], spacing: 12) {
            ForEach(Array(Style.all.enumerated()), id: \.offset) { i, style in
                tile(style, selected: chosen == i + 1) { model.set("style.name", Double(i + 1)) }
            }
        }
    }

    private func tile(_ style: Style, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(skin == .studio ? style.name.uppercased() : style.name)
                        .font(skin == .studio ? Studio.legend(14, weight: .bold) : .title3.weight(.semibold))
                        .tracking(skin == .studio ? 1 : 0)
                    Spacer()
                    Text("\(Int(style.bpm.lowerBound))–\(Int(style.bpm.upperBound)) bpm").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Text(style.summary).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Text(details(style)).font(.caption).foregroundStyle(.tertiary).lineLimit(3).multilineTextAlignment(.leading)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
            .background {
                if skin == .studio {
                    PanelBackground(cornerRadius: 8, shade: selected ? 0 : 0.2)
                } else {
                    RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(selected ? 0.12 : 0.05))
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(selected ? Color.yellow : .clear, lineWidth: 2)
                .shadow(color: selected ? .yellow.opacity(0.6) : .clear, radius: 4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Make the piece \(style.name): applied at the next chord change")
    }

    private func details(_ style: Style) -> String {
        func setting(_ id: String) -> String? {
            style.settings.first { $0.0 == id }.flatMap { if case .option(let o) = $0.1 { return o } else { return nil } }
        }
        var parts = ["\(style.scales.map { ScaleCatalogue.names[$0] }.joined(separator: " / "))"]
        if let g = setting("gen.drums.groove.busy") { parts.append("drums: \(g)") }
        if let b = setting("gen.bass.pattern") { parts.append("bass: \(b)") }
        if let p = setting("gen.pulse.mode") { parts.append("pulse: \(p)") }
        if !style.songGenres.isEmpty { parts.append("songs: \(style.songGenres.joined(separator: ", "))") }
        return parts.joined(separator: " · ")
    }
}
