import Params
import Router
import SwiftUI

/// One hosted synth on its own (a pinned card, a pop-out window, a box in Signal flow): what it
/// plays, its sound and its editor. Voices show the same controls under the synth they play on.
struct InstrumentPanel: View {
    @Environment(AppModel.self) private var model
    let config: InstrumentConfig

    var body: some View {
        let users = model.users(ofInstrument: config.id)
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading) {
                        Text(model.instrumentLabel(config.id)).font(.title3.weight(.semibold))
                        Text(users.isEmpty ? "No voice plays on it: pick it in a voice, or unload it there" : "Plays " + users.joined(separator: ", "))
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
                ForEach(model.scene.voices.filter { $0.destinations.contains(config.destination) }.map(\.role), id: \.self) { RoleLane(role: $0) }
                HostedSynthControls(config: config)
            }
            .padding(6)
        }
    }
}
