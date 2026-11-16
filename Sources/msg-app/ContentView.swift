import SwiftUI

/// Pages, in the order signals travel: what's happening → signals → music → sound.
enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case overview = "Overview"
    case flow = "Signal flow"
    case tabletop = "Tabletop"
    case modulation = "Modulation"
    case harmony = "Harmony"
    case style = "Style"
    case generators = "Generators"
    case motifs = "Motifs"
    case quantise = "Quantise"
    case variation = "Variation"
    case voices = "Voices"
    case instruments = "Instruments"
    case mixer = "Mixer"

    var id: String { rawValue }

    static let sections: [(title: String, items: [SidebarItem])] = [
        ("At a glance", [.overview, .flow, .tabletop]),
        ("Signals", [.modulation, .harmony]),
        ("Music", [.style, .generators, .motifs, .quantise, .variation]),
        ("Sound", [.voices, .mixer]),
    ]

    var icon: String {
        switch self {
        case .overview: "waveform.path.ecg"
        case .flow: "point.3.filled.connected.trianglepath.dotted"
        case .variation: "dice"
        case .style: "guitars"
        case .harmony: "music.note.list"
        case .quantise: "square.grid.3x3"
        case .generators: "sparkles"
        case .motifs: "music.quarternote.3"
        case .voices: "arrow.triangle.branch"
        case .tabletop: "rectangle.3.group"
        case .mixer: "slider.vertical.3"
        case .instruments: "pianokeys"
        case .modulation: "point.3.connected.trianglepath.dotted"
        }
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State var selection: SidebarItem = .overview

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(SidebarItem.sections, id: \.title) { section in
                    Section(section.title) {
                        ForEach(section.items) { item in
                            Label(item.rawValue, systemImage: item.icon).tag(item)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            detail(selection).skinnedPage(model.skin)
        }
        .toolbar {
            ToolbarItem(placement: .principal) { PlayControls() }
            ToolbarItemGroup {
                @Bindable var model = model
                Picker("Skin", selection: $model.skin) {
                    ForEach(SkinStyle.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("The look. Studio is the hardware-style skin.")
                Picker("Controls", selection: $model.useKnobs) {
                    Label("Knobs", systemImage: "dial.medium").tag(true)
                    Label("Sliders", systemImage: "slider.horizontal.3").tag(false)
                }
                .pickerStyle(.segmented)
                .help("Show continuous settings as knobs or as sliders with inline explanations")
                Toggle(isOn: $model.showExplanations) { Label("Explanations", systemImage: "text.bubble") }
                    .help("Show what each setting does under its control")
                Button { Task { await model.openScene() } } label: { Label("Open Scene", systemImage: "folder") }
                    .help("Open a scene (JSON)")
                Button { model.saveSceneAsking() } label: { Label("Save Scene", systemImage: "square.and.arrow.down") }
                    .help("Save the current scene, including every tweak")
            }
        }
        .navigationTitle(model.session?.scene.name ?? model.scene.name)
        .onChange(of: model.navigate) { _, page in
            if let page { selection = page; model.navigate = nil }
        }
        .background(WindowVisibility { visible in
            if !model.forceVisualsActive { model.visualsActive = visible }
        })
    }

    @ViewBuilder func detail(_ item: SidebarItem) -> some View {
        switch item {
        case .overview: OverviewView()
        case .flow: FlowView()
        case .variation: VariationView()
        case .style: StyleView()
        case .harmony:
            ParamSection(title: "Harmony", prefixes: ["clock.", "harmony.", "conductor."],
                         hero: Pages.harmonyHero, accessory: Pages.harmonyAccessory)
        case .quantise:
            ParamSection(title: "Quantise", prefixes: ["macro.", "quant."], groupComponent: 0, hero: Pages.quantiseHero)
        case .generators: TilePage(page: .generators)
        case .motifs: MotifsView()
        case .voices: TilePage(page: .voices)
        case .tabletop: TabletopView()
        case .mixer: MixerView()
        case .instruments: TilePage(page: .instruments)
        case .modulation: ModulationView()
        }
    }
}
