import AppKit
import Engine
import Music
import Params
import SwiftUI

// MARK: - Panels: one group of settings (a generator, a voice), shown as a tile, expanded, in its own window or on the tabletop

enum PanelPage: String, Codable, CaseIterable, Hashable {
    case generators, voices

    var title: String { rawValue.capitalized }
    var prefixes: [String] { self == .generators ? ["gen.", "activity."] : ["voice."] }
    var groupComponent: Int { 1 }

    @MainActor func accessory(_ group: String) -> AnyView? {
        self == .generators ? Pages.generatorAccessory(group) : Pages.voiceAccessory(group)
    }
}

struct PanelID: Hashable, Codable, Identifiable {
    var page: PanelPage
    var group: String
    var id: String { "\(page.rawValue)/\(group)" }
}

@MainActor
enum Panels {
    static func groupKey(_ id: String, component: Int) -> String {
        let parts = id.split(separator: ".").map(String.init)
        return parts.count > component + 1 ? parts[component] : parts[0]
    }

    static func groupPrefix(_ id: String, component: Int) -> String {
        let parts = id.split(separator: ".")
        return parts.count > component + 1 ? parts.prefix(component + 1).joined(separator: ".") : String(parts[0])
    }

    /// The page's groups in registration order.
    static func groups(_ page: PanelPage, model: AppModel) -> [String] {
        let groups = model.specs(withPrefix: page.prefixes).map { groupKey($0.id, component: page.groupComponent) }
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        guard page == .voices else { return groups }
        // Voices in the same order as their generators, not alphabetical.
        return groups.sorted { (RoleStyle.order.firstIndex(of: $0) ?? 99, $0) < (RoleStyle.order.firstIndex(of: $1) ?? 99, $1) }
    }

    static func specs(_ panel: PanelID, model: AppModel) -> [ParamSpec] {
        model.specs(withPrefix: panel.page.prefixes).filter { groupKey($0.id, component: panel.page.groupComponent) == panel.group }
    }

    static func title(_ panel: PanelID) -> String {
        panel.page == .voices ? "\(panel.group.capitalized) voice" : ParamSection.title(panel.group)
    }

    static func color(_ panel: PanelID) -> Color { Pages.color(forGroup: panel.group) }

    /// The voice whose notes this panel makes or carries, if any.
    static func role(_ panel: PanelID, model: AppModel) -> String? {
        if panel.page == .voices { return panel.group }
        if panel.group == "packets" {
            let i = Int(model.base("gen.packets.role"))
            return PacketGenerator.roles.indices.contains(i) ? PacketGenerator.roles[i] : "pulse"
        }
        return Pages.generatorRoles[panel.group]
    }

    static func enabledParam(_ panel: PanelID) -> String? {
        switch panel.page {
        case .generators: panel.group == "activity" ? nil : "gen.\(panel.group).enabled"
        case .voices: "voice.\(panel.group).enabled"
        }
    }

    /// Two short lines: what it's doing now.
    static func summary(_ panel: PanelID, model: AppModel) -> [String] {
        guard let s = model.status else { return ["Not running"] }
        let now = s.time
        if let id = enabledParam(panel), model.specsByID[id] != nil, model.effective(id) < 0.5 { return ["Switched off"] }
        switch (panel.page, panel.group) {
        case (.generators, "activity"):
            let recent = s.apps.filter { ($0.lastWake ?? -.infinity) > now - 60 }.count
            return ["Wakes above \(Format.rate(model.effective("activity.threshold")))", "\(recent) app\(recent == 1 ? "" : "s") woke in the last minute"]
        case (.generators, "drums"):
            guard let d = s.drums else { return [] }
            return ["\(d.phase.capitalized) · \(d.groove) (\(d.mood))",
                    "presence \(d.presence.formatted(.number.precision(.fractionLength(2)))) · complexity \(d.complexity.formatted(.number.precision(.fractionLength(2))))"]
        case (.generators, "packets"):
            let live = s.capture.map { now - $0.lastSeen < 4 } ?? false
            let last = s.netEvents.last
            return [live ? "Capturing · \(Int(s.capture?.packetsPerSecond ?? 0)) packets/s" : model.packetCapture ? "Not capturing" : "Off for this session",
                    last.map { "\(EventFeed.kindLabel($0)) \($0.name)" + ($0.played ? "" : " (skipped)") } ?? "No events yet"]
        case (.voices, let role):
            let dest = DestinationPicker.label(model.destination(of: role), model: model)
            let sounding = s.recentNotes.filter { $0.role == role && $0.time <= now && now < $0.time + $0.duration }.count
            return [dest, "ch \(Int(model.base("voice.\(role).channel"))) · \(Format.note(Int(model.base("voice.\(role).low"))))–\(Format.note(Int(model.base("voice.\(role).high")))) · \(sounding) sounding"]
        default:
            guard let role = role(panel, model: model) else { return [] }
            let notes = s.recentNotes.filter { $0.role == role && $0.time <= now && $0.time > now - 10 }
            return ["\(notes.count) note\(notes.count == 1 ? "" : "s") in the last 10 s",
                    notes.last.map { "\(Format.note($0.note)): \($0.why)" } ?? "Quiet"]
        }
    }
}

// MARK: - The settings of one panel

/// Explanation, live visual and controls of one group: the body of a tile when expanded, a window or a tabletop card.
struct GroupPanel: View {
    @Environment(AppModel.self) private var model
    let panel: PanelID
    var filter = ""
    var showDoc = true

    var body: some View {
        let all = Panels.specs(panel, model: model).filter { s in
            filter.isEmpty || s.id.localizedCaseInsensitiveContains(filter) || s.help.localizedCaseInsensitiveContains(filter)
        }
        let color = Panels.color(panel)
        VStack(alignment: .leading, spacing: 12) {
            if showDoc, let first = all.first,
               let doc = ParamDocs.description(for: Panels.groupPrefix(first.id, component: panel.page.groupComponent)) {
                Text(doc).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if filter.isEmpty, let extra = panel.page.accessory(panel.group) { extra }
            let advanced = filter.isEmpty ? all.filter { VisualControls.covers($0.id) } : []
            let shown = all.filter { !advanced.contains($0) }
            if model.useKnobs, filter.isEmpty {
                let toggles = shown.filter { $0.kind == .toggle }
                if !toggles.isEmpty {
                    HStack(spacing: 10) {
                        ForEach(toggles, id: \.id) { LEDButton(spec: $0, color: color) }
                        Spacer()
                    }
                }
                ForEach(shown.filter { $0.kind == .choice }, id: \.id) { ParamRow(spec: $0) }
                let knobs = shown.filter(\.isKnob)
                if !knobs.isEmpty { KnobGrid(specs: knobs, color: color) }
            } else {
                ForEach(shown, id: \.id) { ParamRow(spec: $0) }
            }
            if !advanced.isEmpty { AdvancedDrawer(specs: advanced) }
        }
    }
}

/// Title row with pin, pop-out and (optionally) close.
struct PanelHeader: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let panel: PanelID
    var onClose: (() -> Void)?
    var showPopOut = true

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(Panels.color(panel)).frame(width: 12, height: 12)
            Text(Panels.title(panel)).font(.title3.weight(.semibold))
            Spacer()
            PinButton(panel: panel)
            if showPopOut {
                Button { openWindow(value: panel) } label: { Image(systemName: "macwindow.on.rectangle") }
                    .buttonStyle(.borderless).help("Open in its own window")
            }
            if let onClose {
                Button(action: onClose) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).help("Close")
            }
        }
    }
}

struct PinButton: View {
    @Environment(AppModel.self) private var model
    let panel: PanelID

    var body: some View {
        let pinned = model.pinned.contains(panel)
        Button { model.togglePin(panel) } label: { Image(systemName: pinned ? "pin.fill" : "pin") }
            .buttonStyle(.borderless)
            .foregroundStyle(pinned ? Panels.color(panel) : .secondary)
            .help(pinned ? "Remove from the Tabletop" : "Pin to the Tabletop")
    }
}

// MARK: - Tiles

/// Generators / Voices: every group as a small live tile; click one to open its settings underneath.
struct TilePage: View {
    @Environment(AppModel.self) private var model
    let page: PanelPage
    @State private var filter = ""
    @AppStorage private var expanded: String

    init(page: PanelPage) {
        self.page = page
        _expanded = AppStorage(wrappedValue: "", "tiles.\(page.rawValue).expanded")
    }

    var body: some View {
        Group {
            if model.specs.isEmpty {
                NotRunningHint()
            } else {
                let groups = Panels.groups(page, model: model)
                let matching = filter.isEmpty ? groups : groups.filter { g in
                    !Panels.specs(PanelID(page: page, group: g), model: model).filter {
                        $0.id.localizedCaseInsensitiveContains(filter) || $0.help.localizedCaseInsensitiveContains(filter)
                    }.isEmpty || Panels.title(PanelID(page: page, group: g)).localizedCaseInsensitiveContains(filter)
                }
                let open = groups.contains(expanded) ? expanded : nil
                VStack(spacing: 0) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 10)], spacing: 10) {
                        ForEach(groups, id: \.self) { g in
                            let panel = PanelID(page: page, group: g)
                            PanelTile(panel: panel, selected: open == g) {
                                expanded = open == g ? "" : g
                            }
                            .opacity(matching.contains(g) ? 1 : 0.35)
                        }
                    }
                    .padding(14)
                    Divider()
                    if let open {
                        let panel = PanelID(page: page, group: open)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 12) {
                                PanelHeader(panel: panel) { expanded = "" }
                                GroupPanel(panel: panel, filter: filter)
                            }
                            .padding(18)
                        }
                    } else {
                        ContentUnavailableView("Pick a tile", systemImage: "square.grid.2x2",
                                               description: Text("Click a tile to open its settings here. Pin tiles to put them on the Tabletop, or open them in their own windows."))
                    }
                }
            }
        }
        .searchable(text: $filter, placement: .toolbar, prompt: "Filter \(page.title.lowercased())")
        .navigationTitle(page.title)
    }
}

struct PanelTile: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let panel: PanelID
    let selected: Bool
    let action: () -> Void

    var body: some View {
        let color = Panels.color(panel)
        let role = Panels.role(panel, model: model)
        let enabledID = Panels.enabledParam(panel).flatMap { model.specsByID[$0] != nil ? $0 : nil }
        let on = enabledID.map { model.effective($0) >= 0.5 } ?? true
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    if let enabledID { model.set(enabledID, on ? 0 : 1) }
                } label: {
                    Circle().fill(on ? color : Color.secondary.opacity(0.4)).frame(width: 10, height: 10)
                        .shadow(color: on ? color : .clear, radius: 3)
                }
                .buttonStyle(.plain).disabled(enabledID == nil)
                .help(enabledID == nil ? "" : on ? "Switch off" : "Switch on")
                Text(Panels.title(panel)).font(.headline).lineLimit(1)
                Spacer(minLength: 4)
                PinButton(panel: panel)
                Button { openWindow(value: panel) } label: { Image(systemName: "macwindow.on.rectangle") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).help("Open in its own window")
            }
            if let role {
                NoteStrip(role: role).frame(height: 30)
                    .opacity(on ? 1 : 0.4)
            } else {
                Color.clear.frame(height: 30) // keep tiles lined up
            }
            ForEach(Array(Panels.summary(panel, model: model).enumerated()), id: \.offset) { _, line in
                Text(line).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
        .background((selected ? color.opacity(0.16) : Color.primary.opacity(0.05)), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? color : .clear, lineWidth: 1.5))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture(perform: action)
    }
}

/// A tiny scrolling picture of one voice's last 8 seconds: a mark per note, higher = higher pitch.
struct NoteStrip: View {
    @Environment(AppModel.self) private var model
    let role: String
    static let window = 8.0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 10, paused: !model.visualsActive)) { tl in
            Canvas { gc, size in
                gc.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 4), with: .color(.primary.opacity(0.05)))
                guard let s = model.status else { return }
                let now = model.engineNow(at: tl.date)
                let notes = s.recentNotes.filter { $0.role == role && $0.time + $0.duration > now - Self.window && $0.time <= now + 0.5 }
                guard !notes.isEmpty else { return }
                let lo = notes.map(\.note).min()!, hi = max(notes.map(\.note).max()!, lo + 6)
                let colour = RoleStyle.color(role)
                for n in notes {
                    let x0 = CGFloat((n.time - (now - Self.window)) / Self.window) * size.width
                    let w = max(CGFloat(n.duration / Self.window) * size.width, 2)
                    let y = 3 + (size.height - 8) * CGFloat(hi - n.note) / CGFloat(hi - lo)
                    gc.fill(Path(roundedRect: CGRect(x: x0, y: y, width: w, height: 3), cornerRadius: 1.5),
                            with: .color(colour.opacity(0.35 + 0.65 * Double(n.velocity) / 127)))
                }
            }
        }
    }
}

// MARK: - Windows and the tabletop

/// A panel in its own window.
struct PanelWindow: View {
    @Environment(AppModel.self) private var model
    let panel: PanelID

    var body: some View {
        Group {
            if model.specs.isEmpty {
                NotRunningHint()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        PanelHeader(panel: panel, showPopOut: false)
                        GroupPanel(panel: panel)
                    }
                    .padding(18)
                }
            }
        }
        .frame(minWidth: 520, minHeight: 360)
        .navigationTitle(Panels.title(panel))
    }
}

/// Pinned panels side by side, in columns that fit the window. Drag a card's handle onto another to reorder.
struct TabletopView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.pinned.isEmpty {
                ContentUnavailableView("Nothing on the tabletop yet", systemImage: "pin",
                                       description: Text("Pin tiles on the Generators and Voices pages (the pin button) to lay them out here side by side."))
            } else if model.specs.isEmpty {
                NotRunningHint()
            } else {
                GeometryReader { geo in
                    let columns = max(1, Int(geo.size.width / 540))
                    ScrollView {
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(0..<columns, id: \.self) { c in
                                VStack(spacing: 12) {
                                    ForEach(Array(model.pinned.enumerated()).filter { $0.offset % columns == c }, id: \.element.id) { _, panel in
                                        TabletopCard(panel: panel)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .top)
                            }
                        }
                        .padding(14)
                    }
                }
            }
        }
        .navigationTitle("Tabletop")
    }
}

struct TabletopCard: View {
    @Environment(AppModel.self) private var model
    let panel: PanelID
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal").foregroundStyle(.secondary)
                    .help("Drag onto another card to move this one there")
                    .draggable(panel.id)
                PanelHeader(panel: panel) { model.togglePin(panel) }
            }
            GroupPanel(panel: panel, showDoc: false)
        }
        .padding(14)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(targeted ? Panels.color(panel) : .clear, lineWidth: 2))
        .dropDestination(for: String.self) { items, _ in
            guard let id = items.first else { return false }
            model.movePin(id, before: panel)
            return true
        } isTargeted: { targeted = $0 }
    }
}
