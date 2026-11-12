import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case overview = "Overview"
    case harmony = "Harmony"
    case quantise = "Quantise"
    case generators = "Generators"
    case motifs = "Motifs"
    case voices = "Voices"
    case instruments = "Instruments"
    case modulation = "Modulation"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .overview: "waveform.path.ecg"
        case .harmony: "music.note.list"
        case .quantise: "square.grid.3x3"
        case .generators: "sparkles"
        case .motifs: "music.quarternote.3"
        case .voices: "arrow.triangle.branch"
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
            List(SidebarItem.allCases, selection: $selection) { item in
                Label(item.rawValue, systemImage: item.icon).tag(item)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            detail(selection)
        }
        .toolbar {
            ToolbarItemGroup {
                @Bindable var model = model
                Toggle(isOn: $model.showExplanations) { Label("Explanations", systemImage: "text.bubble") }
                    .help("Show what each setting does under its control")
                Button { Task { await model.openScene() } } label: { Label("Open Scene", systemImage: "folder") }
                    .help("Open a scene (JSON)")
                Button { model.saveScene() } label: { Label("Save Scene", systemImage: "square.and.arrow.down") }
                    .help("Save the current scene, including every tweak")
            }
        }
        .navigationTitle(model.session?.scene.name ?? model.scene.name)
        .background(WindowVisibility { visible in
            if !model.forceVisualsActive { model.visualsActive = visible }
        })
    }

    @ViewBuilder func detail(_ item: SidebarItem) -> some View {
        switch item {
        case .overview: OverviewView()
        case .harmony:
            ParamSection(title: "Harmony", prefixes: ["clock.", "harmony.", "conductor."],
                         hero: Pages.harmonyHero, accessory: Pages.harmonyAccessory)
        case .quantise:
            ParamSection(title: "Quantise", prefixes: ["macro.", "quant."], groupComponent: 0, hero: Pages.quantiseHero)
        case .generators:
            ParamSection(title: "Generators", prefixes: ["gen.", "activity."], groupComponent: 1,
                         hero: Pages.generatorsHero, accessory: Pages.generatorAccessory)
        case .motifs: MotifsView()
        case .voices:
            ParamSection(title: "Voices", prefixes: ["voice."], groupComponent: 1, accessory: Pages.voiceAccessory)
        case .instruments: InstrumentsView()
        case .modulation: ModulationView()
        }
    }
}
