import AUHost
import Engine
import MIDIOut
import Params
import Router
import SwiftUI

// MARK: - Views

/// A voice's sounds, top of its panel: the main sound and each layer, each with where it plays
/// and, for a hosted synth, its preset, level, editor and every synth setting.
struct VoiceSounds: View {
    @Environment(AppModel.self) private var model
    let role: String

    var body: some View {
        let layers = model.voice(role)?.layers.count ?? 0
        VStack(alignment: .leading, spacing: 10) {
            ForEach(0...layers, id: \.self) { layer in
                VoiceOutputCard(role: role, layer: layer)
            }
            HStack(spacing: 10) {
                Button { Task { await model.addLayer(role) } } label: { Label("Add a layer", systemImage: "square.stack.3d.up") }
                    .help("Play this voice's notes on another sound as well: a second synth, an octave up, or the iPad alongside a hosted synth.")
                Spacer()
                Button("Bluetooth MIDI…") { model.showBluetoothMIDI() }
                    .help("Opens macOS's Bluetooth MIDI panel to find, pair and connect devices (an iPad running a synth, a BLE MIDI controller). Once connected they appear in the menu.")
                Button("Audio MIDI Setup") { model.openAudioMIDISetup() }
                    .help("For the network session, IAC buses and everything else about MIDI on this Mac.")
            }
            .controlSize(.small)
        }
        .task {
            // Devices come and go (Bluetooth range, USB cables); keep the menu and status current.
            while !Task.isCancelled {
                model.refreshDestinations()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

/// One output of a voice: where it plays, and the sound there.
struct VoiceOutputCard: View {
    @Environment(AppModel.self) private var model
    let role: String
    let layer: Int

    var body: some View {
        let destination = model.destination(of: role, layer: layer)
        let hosted = model.hostedInstruments.first { $0.destination == destination }
        let prefix = VoiceLayer.prefix(role: role, number: layer)
        let title = layer == 0 ? "\(role.capitalized) \(role.hasSuffix("s") ? "play" : "plays") on" : "Layer \(layer)"
        VisualCard(title: title, caption: layer == 0
                   ? "Where this voice's notes go, and the sound there. Changes apply straight away and are saved with the scene."
                   : "The same notes, played here too.") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    if layer > 0, let on = model.specsByID[prefix + ".enabled"] { LEDButton(spec: on, label: "On", color: RoleStyle.color(role)) }
                    DestinationMenu(role: role, layer: layer)
                    DestinationStatus(destination: destination)
                    Spacer()
                    if let hosted {
                        if model.openingEditors.contains(hosted.id) { ProgressView().controlSize(.small) }
                        Button { model.openEditor(hosted.id) } label: { Label("Open Editor", systemImage: "macwindow") }
                            .disabled(model.openingEditors.contains(hosted.id))
                            .help("The synth's own window. Anything you change there comes back into the app and is saved with the scene.")
                    }
                    if layer > 0 {
                        Button(role: .destructive) { Task { await model.removeLayer(role, layer) } } label: { Image(systemName: "trash") }
                            .help("Remove this layer")
                    }
                }
                .controlSize(.small)
                if layer > 0 {
                    let knobs = ["channel", "transpose", "velocityScale", "latencyMs"].compactMap { model.specsByID["\(prefix).\($0)"] }
                    HStack(spacing: 18) {
                        ForEach(knobs, id: \.id) { ParamKnob(spec: $0, label: Self.layerLabel($0.id), size: 52) }
                        Spacer()
                    }
                }
                if let hosted { HostedSynthControls(config: hosted) }
            }
        }
    }

    static func layerLabel(_ id: String) -> String {
        switch id.split(separator: ".").last ?? "" {
        case "channel": "Channel"
        case "transpose": "Transpose"
        case "velocityScale": "Level"
        case "latencyMs": "Delay ms"
        default: String(id.split(separator: ".").last ?? "")
        }
    }
}

/// A hosted synth's sound: preset, volume, pan, and every plugin parameter.
struct HostedSynthControls: View {
    @Environment(AppModel.self) private var model
    let config: InstrumentConfig
    @State private var filter = ""
    @State private var showParams = false

    private var prefix: String { "au.\(config.id)." }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let others = model.users(ofInstrument: config.id)
            if others.count > 1 {
                Text("This synth also plays \(others.joined(separator: ", ")): changing its sound changes theirs too.")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack(alignment: .center, spacing: 18) {
                if let preset = model.specsByID[prefix + "preset"] { ParamRow(spec: preset).frame(maxWidth: 460) }
                if let v = model.specsByID[prefix + "volume"] { ParamKnob(spec: v, label: "Volume", size: 52) }
                if let p = model.specsByID[prefix + "pan"] { ParamKnob(spec: p, label: "Pan", size: 52) }
                Spacer()
            }
            let synthParams = model.specs(withPrefix: [prefix]).filter { HostedSynthControls.isSynthParam($0.id, prefix: prefix) }
            DisclosureGroup("Synth parameters (\(synthParams.count)): every one is a mod-matrix target", isExpanded: $showParams) {
                TextField("Filter", text: $filter).skinField().padding(.vertical, 4)
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
    }

    /// The plugin's own parameters, not the app's preset/level/mixer controls for it.
    static func isSynthParam(_ id: String, prefix: String) -> Bool {
        let rest = id.dropFirst(prefix.count)
        return !["preset", "volume", "pan", "eqLow", "eqMid", "eqMidFreq", "eqHigh", "sendReverb", "sendDelay", "mute", "solo"].contains(rest)
            && !rest.hasPrefix("fx")
    }
}

/// Where one output of a voice plays: this app's port, the network session, the hosted synths
/// (or a new one), and every MIDI destination macOS knows, including ones not connected now.
struct DestinationMenu: View {
    @Environment(AppModel.self) private var model
    let role: String
    let layer: Int

    var body: some View {
        let current = model.destination(of: role, layer: layer)
        Menu {
            Section("This Mac") {
                item(CoreMIDISink.virtualDestination, "Virtual port “MIDI Signal Generator” (DAWs, AUM…)", current)
                item(CoreMIDISink.networkDestination,
                     "Network session\(model.networkSessionEnabled ? "" : " (disabled in Audio MIDI Setup)")", current)
            }
            Section("Hosted synths") {
                ForEach(model.hostedInstruments, id: \.id) { inst in
                    let users = model.users(ofInstrument: inst.id)
                    item(inst.destination, model.instrumentLabel(inst.id) + (users.isEmpty ? " (not used)" : " (\(users.joined(separator: ", ")))"), current)
                }
                Menu("New hosted synth") {
                    ForEach(model.installedSynths, id: \.name) { s in
                        Button("\(s.name) (\(s.maker))") { Task { await model.addHostedSynth(s.name, role: role, layer: layer) } }
                    }
                }
                if !model.unusedSynths.isEmpty {
                    Button("Unload unused synths (\(model.unusedSynths.map { model.instrumentLabel($0.id) }.joined(separator: ", ")))") {
                        Task { await model.removeUnusedSynths() }
                    }
                }
            }
            ForEach(MIDIDestinationInfo.Kind.allCases, id: \.self) { kind in
                let list = model.midiDestinations.filter { $0.kind == kind }
                if !list.isEmpty {
                    Section(kind.title) {
                        ForEach(list) { d in item(d.address, d.address + (d.online ? "" : " (not connected)"), current) }
                    }
                }
            }
            if !known(current) {
                Section("In the scene") { item(current, "\(current) (not found on this Mac)", current) }
            }
        } label: {
            Label(DestinationPicker.label(current, model: model), systemImage: DestinationPicker.icon(current, model: model))
        }
        .frame(maxWidth: 380, alignment: .leading)
        .help("A new hosted synth reloads the sound for a moment; everything else switches straight away.")
    }

    private func item(_ destination: String, _ title: String, _ current: String) -> some View {
        Button {
            model.setDestination(role, destination, layer: layer)
        } label: {
            if destination == current { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }

    private func known(_ destination: String) -> Bool {
        destination == CoreMIDISink.virtualDestination || destination == CoreMIDISink.networkDestination
            || model.hostedInstruments.contains { $0.destination == destination }
            || model.midiDestinations.contains { $0.address == destination }
    }
}
