import Engine
import MIDIOut
import Music
import Router
import SwiftUI

// MARK: - The graph

/// One box on the signal-flow page: a panel (generator, voice, hosted synth) or a plain node
/// (a signal source, a MIDI output).
struct FlowNode: Identifiable, Hashable {
    enum Kind: Hashable {
        case panel(PanelID)
        case harmony, packets, quantise, mixer
        case output(String)
        /// A signal that modulates settings (a mod route's source), e.g. "net.total.bytesPerSec".
        case modSource(String)
    }

    let id: String
    let kind: Kind
}

struct FlowEdge: Hashable {
    let from: String
    let to: String
    /// The voice whose notes travel this cable, for its colour and activity; nil = a control signal.
    var role: String?
    /// Why the cable is there, for its tooltip in the inspector.
    var meaning: String
    /// Modulation routes (indices into the scene's routes) this cable stands for; empty = not modulation.
    var routes: [Int] = []
    var isModulation: Bool { !routes.isEmpty }
}

/// Signals → Generators → Voices → Outputs, as the app is wired right now.
@MainActor
enum FlowGraph {
    static let columns = ["Signals", "Generators", "Voices", "Outputs"]

    static func id(_ p: PanelID) -> String { "panel:\(p.id)" }

    static func build(_ model: AppModel) -> (columns: [[FlowNode]], edges: [FlowEdge]) {
        let gens = Panels.groups(.generators, model: model).filter { $0 != "activity" }
        let voices = Panels.groups(.voices, model: model)
        let activity = PanelID(page: .generators, group: "activity")
        var signals = [FlowNode(id: id(activity), kind: .panel(activity)),
                       FlowNode(id: "packets", kind: .packets),
                       FlowNode(id: "harmony", kind: .harmony)]
        if !model.packetCapture && !gens.contains("packets") { signals.removeAll { $0.id == "packets" } }
        var genNodes = gens.map { g -> FlowNode in let p = PanelID(page: .generators, group: g); return FlowNode(id: id(p), kind: .panel(p)) }
        let voiceNodes = voices.map { v -> FlowNode in let p = PanelID(page: .voices, group: v); return FlowNode(id: id(p), kind: .panel(p)) }

        var outputs: [FlowNode] = []
        var edges: [FlowEdge] = []
        func gen(_ g: String) -> String { id(PanelID(page: .generators, group: g)) }
        func voice(_ v: String) -> String { id(PanelID(page: .voices, group: v)) }

        // Signals → generators.
        if gens.contains("motif") { edges.append(.init(from: id(activity), to: gen("motif"), meaning: "an app waking up plays its motif")) }
        if gens.contains("packets") { edges.append(.init(from: "packets", to: gen("packets"), meaning: "lookups, handshakes and closes become figures")) }
        if gens.contains("drums"), model.effective("gen.drums.accents") >= 0.5 {
            edges.append(.init(from: "packets", to: gen("drums"), meaning: "network events add drum accents"))
        }
        for g in ["drone", "bass", "sub"] where gens.contains(g) {
            edges.append(.init(from: "harmony", to: gen(g), meaning: "plays the current chord"))
        }
        if gens.contains("drums") { edges.append(.init(from: "harmony", to: gen("drums"), meaning: "the mood picks the groove; phrase ends bring fills")) }

        // Generators → voices.
        for g in gens {
            guard let role = Panels.role(PanelID(page: .generators, group: g), model: model), voices.contains(role) else { continue }
            edges.append(.init(from: gen(g), to: voice(role), role: role, meaning: "plays on the \(role) voice"))
        }

        // Voices → outputs.
        for v in voices {
            let dest = model.destination(of: v)
            let nodeID: String
            if dest.hasPrefix(InstrumentConfig.destinationPrefix),
               model.hostedInstruments.contains(where: { $0.destination == dest }) {
                let p = PanelID(page: .instruments, group: String(dest.dropFirst(InstrumentConfig.destinationPrefix.count)))
                nodeID = id(p)
                if !outputs.contains(where: { $0.id == nodeID }) { outputs.append(FlowNode(id: nodeID, kind: .panel(p))) }
            } else {
                nodeID = "out:\(dest)"
                if !outputs.contains(where: { $0.id == nodeID }) { outputs.append(FlowNode(id: nodeID, kind: .output(dest))) }
            }
            edges.append(.init(from: voice(v), to: nodeID, role: v, meaning: "sends to \(DestinationPicker.label(dest, model: model))"))
        }

        // Modulation: one box per route source, a cable to whatever owns each target setting.
        var modEdges: [String: FlowEdge] = [:]
        for (i, route) in model.routes.enumerated() {
            let source = "mod:\(route.source)"
            if !signals.contains(where: { $0.id == source }) { signals.append(FlowNode(id: source, kind: .modSource(route.source))) }
            guard let owner = owner(of: route.target, model: model) else { continue }
            switch owner {
            case "quantise" where !genNodes.contains(where: { $0.id == "quantise" }):
                genNodes.append(FlowNode(id: "quantise", kind: .quantise))
            case "mixer" where !outputs.contains(where: { $0.id == "mixer" }):
                outputs.append(FlowNode(id: "mixer", kind: .mixer))
            default: break
            }
            let key = source + ">" + owner
            let text = "modulates \(targetName(route.target, model: model)) (\(route.amount >= 0 ? "+" : "")\(route.amount.formatted(.number.precision(.fractionLength(2)))))"
            if var e = modEdges[key] {
                e.routes.append(i)
                e.meaning += "; " + text
                modEdges[key] = e
            } else {
                modEdges[key] = FlowEdge(from: source, to: owner, meaning: text, routes: [i])
            }
        }
        edges += modEdges.values.sorted { ($0.from, $0.to) < ($1.from, $1.to) }
        return ([signals, genNodes, voiceNodes, outputs], edges)
    }

    /// The box that owns a setting: its generator, voice, hosted synth, or the Quantise / Harmony / Mixer box.
    static func owner(of target: String, model: AppModel) -> String? {
        let parts = target.split(separator: ".").map(String.init)
        guard parts.count >= 2 else { return nil }
        switch parts[0] {
        case "gen": return id(PanelID(page: .generators, group: parts[1]))
        case "activity": return id(PanelID(page: .generators, group: "activity"))
        case "voice": return id(PanelID(page: .voices, group: parts[1]))
        case "au":
            return model.hostedInstruments.contains { $0.id == parts[1] } ? id(PanelID(page: .instruments, group: parts[1])) : nil
        case "mix": return "mixer"
        case "quant", "macro": return "quantise"
        case "harmony", "conductor", "clock": return "harmony"
        default: return nil
        }
    }

    static func targetName(_ target: String, model: AppModel) -> String {
        model.specsByID[target].map { $0.label == $0.id ? ParamRow.shortLabel($0.id).lowercased() : $0.label } ?? target
    }

    static func sourceName(_ source: String) -> String {
        let parts = source.split(separator: "#", maxSplits: 1).map(String.init)
        let key = parts.count > 1 ? parts[1] : nil
        switch parts[0] {
        case "net.total.bytesPerSec": return "Total traffic"
        case "net.app.bytesPerSec": return "\(key ?? "App") traffic"
        case "net.pkt.perSec": return "Packets per second"
        case "net.flows.tcp": return "Open connections"
        case "net.proto.bytesPerSec": return "\(key?.uppercased() ?? "Protocol") traffic"
        default: return source
        }
    }

    /// Everything upstream and downstream of `focus` (including it).
    static func path(from focus: String, _ edges: [FlowEdge]) -> (nodes: Set<String>, edges: Set<FlowEdge>) {
        var up: Set<String> = [focus], down: Set<String> = [focus]
        var changed = true
        while changed {
            changed = false
            for e in edges {
                if down.contains(e.from), down.insert(e.to).inserted { changed = true }
                if up.contains(e.to), up.insert(e.from).inserted { changed = true }
            }
        }
        let lit = edges.filter { (down.contains($0.from) && down.contains($0.to)) || (up.contains($0.from) && up.contains($0.to)) }
        return (up.union(down), Set(lit))
    }
}

private struct NodeFrames: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

// MARK: - The page

/// The whole patch at a glance: which signals drive which generators, which voice each generator
/// plays, and where each voice goes. Cables glow while notes travel them; hovering or selecting a
/// box lights its whole path. Click a box to open its settings in the inspector.
struct FlowView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("flow.selected") private var selected = ""
    @State private var hovered: String?

    var body: some View {
        Group {
            if model.specs.isEmpty {
                NotRunningHint()
            } else {
                let graph = FlowGraph.build(model)
                let all = graph.columns.flatMap { $0 }
                let focus = hovered ?? (all.contains { $0.id == selected } ? selected : nil)
                let path = focus.map { FlowGraph.path(from: $0, graph.edges) }
                ScrollView([.vertical, .horizontal]) {
                    HStack(alignment: .top, spacing: 46) {
                        ForEach(Array(graph.columns.enumerated()), id: \.offset) { c, nodes in
                            VStack(alignment: .leading, spacing: 10) {
                                ColumnLegend(text: FlowGraph.columns[c])
                                ForEach(nodes) { node in
                                    FlowNodeView(node: node, selected: node.id == selected) {
                                        selected = selected == node.id ? "" : node.id
                                    }
                                    .opacity(path.map { $0.nodes.contains(node.id) ? 1 : 0.4 } ?? 1)
                                    .onHover { hovered = $0 ? node.id : (hovered == node.id ? nil : hovered) }
                                    .anchorPreference(key: NodeFrames.self, value: .bounds) { [node.id: $0] }
                                }
                            }
                            .frame(width: 206)
                        }
                    }
                    .padding(20)
                    .backgroundPreferenceValue(NodeFrames.self) { anchors in
                        GeometryReader { proxy in
                            Cables(edges: graph.edges, frames: anchors.mapValues { proxy[$0] }, lit: path?.edges)
                        }
                        .allowsHitTesting(false)
                    }
                }
                .defaultScrollAnchor(.topLeading)
                .inspector(isPresented: Binding(get: { all.contains { $0.id == selected } }, set: { if !$0 { selected = "" } })) {
                    if let node = all.first(where: { $0.id == selected }) {
                        FlowInspector(node: node, edges: graph.edges.filter { $0.from == node.id || $0.to == node.id })
                            .inspectorColumnWidth(min: 360, ideal: 440, max: 900)
                    }
                }
            }
        }
        .skinnedPage(model.skin, shade: 0.45)
        .navigationTitle("Signal flow")
    }
}

private struct ColumnLegend: View {
    @Environment(\.skin) private var skin
    let text: String

    var body: some View {
        Text(skin == .studio ? text.uppercased() : text)
            .font(skin == .studio ? Studio.legend(11, weight: .bold) : .subheadline.weight(.semibold))
            .tracking(skin == .studio ? 1.5 : 0)
            .foregroundStyle(.secondary)
            .padding(.leading, 4)
    }
}

/// Patch cables between boxes: a curve from the right edge of one to the left edge of the next,
/// a jack at each end, glowing while notes (or events, or chord changes) travel it.
private struct Cables: View {
    @Environment(AppModel.self) private var model
    let edges: [FlowEdge]
    let frames: [String: CGRect]
    let lit: Set<FlowEdge>?

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 12, paused: !model.visualsActive)) { tl in
            Canvas { gc, _ in
                let now = model.engineNow(at: tl.date)
                for e in edges {
                    guard let a = frames[e.from], let b = frames[e.to] else { continue }
                    let p0 = CGPoint(x: a.maxX, y: a.midY), p1 = CGPoint(x: b.minX, y: b.midY)
                    let dx = max((p1.x - p0.x) * 0.5, 30)
                    var path = Path()
                    path.move(to: p0)
                    path.addCurve(to: p1, control1: CGPoint(x: p0.x + dx, y: p0.y), control2: CGPoint(x: p1.x - dx, y: p1.y))
                    let colour = e.isModulation ? Color(red: 1, green: 0.72, blue: 0.25) : e.role.map { RoleStyle.color($0) } ?? Color(white: 0.75)
                    let dim = lit.map { $0.contains(e) ? 1.0 : 0.15 } ?? 0.75
                    let activity = self.activity(e, now: now)
                    if activity > 0 {
                        gc.stroke(path, with: .color(colour.opacity(0.35 * activity * dim)), style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    }
                    gc.stroke(path, with: .color(Color.black.opacity(0.5 * dim)), style: StrokeStyle(lineWidth: 4.5, lineCap: .round))
                    gc.stroke(path, with: .color(colour.opacity((0.55 + 0.45 * activity) * dim)),
                              style: StrokeStyle(lineWidth: e.isModulation ? 2 : 2.5, lineCap: .round,
                                                 dash: e.isModulation ? [1, 4] : e.role == nil ? [6, 4] : []))
                    for p in [p0, p1] {
                        let r = CGRect(x: p.x - 4.5, y: p.y - 4.5, width: 9, height: 9)
                        gc.fill(Path(ellipseIn: r), with: .color(Color(white: 0.15).opacity(dim)))
                        gc.stroke(Path(ellipseIn: r), with: .color(colour.opacity(0.9 * dim)), lineWidth: 1.5)
                    }
                }
            }
        }
    }

    /// 0…1: how busy this cable is right now.
    private func activity(_ e: FlowEdge, now: Double) -> Double {
        guard let s = model.status else { return 0 }
        if e.isModulation {
            // How far the routes on this cable are pushing their targets right now.
            let pushes = e.routes.compactMap { i -> Double? in
                guard model.routes.indices.contains(i) else { return nil }
                let t = model.routes[i].target
                guard let spec = model.specsByID[t], let v = s.values[t], let b = s.bases[t] else { return nil }
                return abs(v - b) / max(spec.span, .ulpOfOne)
            }
            return min((pushes.max() ?? 0) * 4, 1)
        }
        if let role = e.role {
            let n = s.recentNotes.lazy.filter { $0.role == role && $0.time <= now && $0.time > now - 1.5 }.count
            return min(Double(n) / 4, 1)
        }
        switch e.from {
        case "packets":
            return s.netEvents.last { $0.played }.map { max(0, 1 - (s.time - $0.time) / 2) } ?? 0
        case "harmony":
            return s.chordHistory.last.map { max(0, 1 - (now - $0.time) / 2) } ?? 0
        default: // app activity → motif: lead notes from motifs
            return s.recentNotes.last { $0.motif != nil && $0.time <= now }.map { max(0, 1 - (now - $0.time) / 2) } ?? 0
        }
    }
}

// MARK: - Boxes

private struct FlowNodeView: View {
    @Environment(AppModel.self) private var model
    let node: FlowNode
    let selected: Bool
    let action: () -> Void

    var body: some View {
        switch node.kind {
        case .panel(let p):
            PanelTile(panel: p, selected: selected, compact: true, action: action)
        case .harmony:
            let s = model.status
            InfoTile(title: "Harmony", icon: "music.note.list", color: .yellow,
                     lines: ["mood \(s?.mood ?? "?") · \(s?.chordHistory.last?.name ?? "")",
                             "\(s?.key ?? "") · \(Int((s?.bpm ?? 0).rounded())) bpm"],
                     selected: selected, action: action)
        case .packets:
            let s = model.status
            let live = s?.capture.map { (s?.time ?? 0) - $0.lastSeen < 4 } ?? false
            InfoTile(title: "Network packets", icon: "antenna.radiowaves.left.and.right", color: .teal,
                     lines: [live ? "capturing · \(Int(s?.capture?.packetsPerSecond ?? 0)) packets/s" : model.packetCapture ? "not capturing" : "off this session",
                             s?.netEvents.last.map { "\(EventFeed.kindLabel($0)) \($0.name)" } ?? "no events yet"],
                     selected: selected, action: action)
        case .modSource(let source):
            let value = model.status?.signals[source] ?? 0
            let count = model.routes.filter { $0.source == source }.count
            InfoTile(title: FlowGraph.sourceName(source), icon: "waveform.path", color: Color(red: 1, green: 0.72, blue: 0.25),
                     lines: [source.contains("bytesPerSec") ? Format.rate(value) : value.formatted(.number.precision(.fractionLength(0...1))),
                             "modulates \(count) setting\(count == 1 ? "" : "s")"],
                     selected: selected, action: action)
        case .quantise:
            InfoTile(title: "Quantise", icon: "square.grid.3x3", color: .gray,
                     lines: ["pitch \(model.effective("quant.pitch.strength").formatted(.number.precision(.fractionLength(2)))) · time \(model.effective("quant.time.strength").formatted(.number.precision(.fractionLength(2))))"],
                     selected: selected, action: action)
        case .mixer:
            InfoTile(title: "Mixer", icon: "slider.vertical.3", color: .gray,
                     lines: ["master \(model.effective("mix.master").formatted(.number.precision(.fractionLength(2))))"],
                     selected: selected, action: action)
        case .output(let dest):
            let ok: Bool = dest == CoreMIDISink.virtualDestination || (model.destinationStatus[dest] ?? false)
            InfoTile(title: DestinationPicker.label(dest, model: model), icon: DestinationPicker.icon(dest, model: model),
                     color: ok ? .green : .orange,
                     lines: [dest == CoreMIDISink.virtualDestination ? "MIDI port for other apps" : ok ? "connected" : "waiting for the device"],
                     selected: selected, action: action)
        }
    }
}

/// A box for something that isn't a settings panel (a signal source, a MIDI output).
private struct InfoTile: View {
    @Environment(\.skin) private var skin
    let title: String
    let icon: String
    let color: Color
    let lines: [String]
    let selected: Bool
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(color).frame(width: 16)
                if skin == .studio {
                    Text(title.uppercased()).font(Studio.legend(11, weight: .bold)).tracking(1).lineLimit(1)
                } else {
                    Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                }
            }
            if skin == .studio {
                LCDLines(lines: lines)
            } else {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                    Text(l).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if skin == .studio { PanelBackground(cornerRadius: 8, shade: selected ? 0 : 0.12) }
            else { RoundedRectangle(cornerRadius: 10).fill(selected ? color.opacity(0.16) : Color.primary.opacity(0.05)) }
        }
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? color : .clear, lineWidth: 1.5))
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }
}

// MARK: - Inspector

private struct FlowInspector: View {
    @Environment(AppModel.self) private var model
    let node: FlowNode
    let edges: [FlowEdge]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                switch node.kind {
                case .panel(let p):
                    PanelHeader(panel: p)
                    connections
                    GroupPanel(panel: p)
                case .harmony:
                    Text("Harmony").font(.title3.weight(.semibold))
                    connections
                    Text("The conductor turns smoothed traffic into a mood; each mood plays its own chord progression, changing on bar lines. The pad, bass and sub play the chords; the drummer's groove follows the mood and fills at the end of each progression.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Open the Harmony page") { model.navigate = .harmony }
                case .packets:
                    Text("Network packets").font(.title3.weight(.semibold))
                    connections
                    NetworkEventsCard()
                case .modSource(let source):
                    Text(FlowGraph.sourceName(source)).font(.title3.weight(.semibold))
                    connections
                    Text("A signal that moves settings through Modulation routes. Each route maps the signal's range onto part of a setting's range; the cables glow by how far each one is pushing its setting right now.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Edit routes on the Modulation page") { model.navigate = .modulation }
                case .quantise:
                    Text("Quantise").font(.title3.weight(.semibold))
                    connections
                    Button("Open the Quantise page") { model.navigate = .quantise }
                case .mixer:
                    Text("Mixer").font(.title3.weight(.semibold))
                    connections
                    Button("Open the Mixer") { model.navigate = .mixer }
                case .output(let dest):
                    Text(DestinationPicker.label(dest, model: model)).font(.title3.weight(.semibold))
                    connections
                    Text("A MIDI output. Change where a voice goes from the voice's box (or on the Voices page).")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
        }
        .environment(\.skin, model.skin)
    }

    /// What feeds this box and what it feeds, in words.
    private var connections: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(edges, id: \.self) { e in
                let into = e.to == node.id
                HStack(spacing: 6) {
                    Image(systemName: into ? "arrow.down.right" : "arrow.up.right").foregroundStyle(.secondary)
                    Text(into ? "from \(name(e.from)): \(e.meaning)" : "to \(name(e.to)): \(e.meaning)")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func name(_ id: String) -> String {
        if id == "harmony" { return "Harmony" }
        if id == "quantise" { return "Quantise" }
        if id == "mixer" { return "Mixer" }
        if id.hasPrefix("mod:") { return FlowGraph.sourceName(String(id.dropFirst(4))) }
        if id == "packets" { return "Network packets" }
        if id.hasPrefix("out:") { return DestinationPicker.label(String(id.dropFirst(4)), model: model) }
        let parts = id.dropFirst("panel:".count).split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, let page = PanelPage(rawValue: parts[0]) else { return id }
        return Panels.title(PanelID(page: page, group: parts[1]))
    }
}
