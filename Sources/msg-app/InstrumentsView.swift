import Params
import Router
import SwiftUI

struct InstrumentsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let instruments = model.session?.scene.instruments ?? model.scene.instruments
        Group {
            if instruments.isEmpty {
                ContentUnavailableView(
                    "No hosted synths in this scene", systemImage: "pianokeys",
                    description: Text("Open a scene with instruments (e.g. scenes/audiokit-hosted.json), or add an \"instruments\" list to a scene and point voices at \"au:<id>\"."))
            } else if !model.isRunning {
                NotRunningHint()
            } else {
                ScrollView {
                    LazyVStack(spacing: 16) {
                        ForEach(instruments, id: \.id) { InstrumentPanel(config: $0) }
                    }
                    .padding(20)
                }
            }
        }
        .navigationTitle("Instruments")
    }
}

struct InstrumentPanel: View {
    @Environment(AppModel.self) private var model
    let config: InstrumentConfig
    @State private var filter = ""
    @State private var showParams = false

    private var prefix: String { "au.\(config.id)." }

    var body: some View {
        let roles = (model.session?.scene.voices ?? []).filter { $0.destination == config.destination }.map(\.role)
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading) {
                        Text(config.component).font(.title3.weight(.semibold))
                        Text("au:\(config.id) · plays \(roles.isEmpty ? "no voices" : roles.joined(separator: ", "))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.openingEditors.contains(config.id) {
                        ProgressView().controlSize(.small)
                        Text("Opening…").foregroundStyle(.secondary)
                    }
                    Button { model.openEditor(config.id) } label: { Label("Open Editor", systemImage: "macwindow") }
                        .disabled(model.openingEditors.contains(config.id))
                }
                ForEach(roles, id: \.self) { RoleLane(role: $0) }
                if let preset = model.specsByID[prefix + "preset"] { ParamRow(spec: preset) }
                HStack(spacing: 18) {
                    if let v = model.specsByID[prefix + "volume"] { ParamKnob(spec: v, label: "Volume", size: 64) }
                    if let p = model.specsByID[prefix + "pan"] { ParamKnob(spec: p, label: "Pan", size: 64) }
                    Spacer()
                }
                let synthParams = model.specs(withPrefix: [prefix]).filter { !["preset", "volume", "pan"].contains($0.id.dropFirst(prefix.count)) }
                DisclosureGroup("Synth parameters (\(synthParams.count)) — every one is a mod-matrix target", isExpanded: $showParams) {
                    TextField("Filter", text: $filter).textFieldStyle(.roundedBorder).padding(.vertical, 4)
                    let matching = synthParams.filter {
                        filter.isEmpty || $0.id.localizedCaseInsensitiveContains(filter) || $0.label.localizedCaseInsensitiveContains(filter)
                    }
                    if model.useKnobs {
                        KnobGrid(specs: matching)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(matching, id: \.id) { ParamRow(spec: $0) }
                        }
                    }
                }
            }
            .padding(6)
        }
    }
}
