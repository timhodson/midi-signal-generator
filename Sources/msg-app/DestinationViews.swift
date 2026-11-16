import MIDIOut
import Router
import SwiftUI

/// Voices → each voice: where its notes go. Lists this app's virtual port, the network session,
/// the hosted synths and every MIDI destination macOS knows (Bluetooth, USB, network, IAC, other
/// apps), including devices that are paired or known but not connected right now.
struct DestinationPicker: View {
    @Environment(AppModel.self) private var model
    let role: String

    var body: some View {
        let current = model.destination(of: role)
        VisualCard(title: "\(role.capitalized) \(role.hasSuffix("s") ? "play" : "plays") on",
                   caption: "Pick where this voice's notes go; it switches straight away and is saved with the scene. Devices that aren't connected now can still be picked: notes reach them once they appear.") {
            HStack(spacing: 10) {
                Menu {
                    menuItems(current: current)
                } label: {
                    Label(Self.label(current, model: model), systemImage: Self.icon(current, model: model))
                }
                .frame(maxWidth: 360, alignment: .leading)
                DestinationStatus(destination: current)
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

    @ViewBuilder private func menuItems(current: String) -> some View {
        Section("This Mac") {
            item(CoreMIDISink.virtualDestination, "Virtual port “MIDI Signal Generator” (DAWs, AUM…)", current)
            item(CoreMIDISink.networkDestination,
                 "Network session\(model.networkSessionEnabled ? "" : " (disabled in Audio MIDI Setup)")", current)
        }
        if !model.hostedInstruments.isEmpty {
            Section("Hosted synths") {
                ForEach(model.hostedInstruments, id: \.id) { inst in
                    item(inst.destination, "\(inst.component) (\(inst.id))", current)
                }
            }
        }
        ForEach(MIDIDestinationInfo.Kind.allCases, id: \.self) { kind in
            let list = model.midiDestinations.filter { $0.kind == kind }
            if !list.isEmpty {
                Section(kind.title) {
                    ForEach(list) { d in item(d.address, d.address + (d.online ? "" : " — not connected"), current) }
                }
            }
        }
        if kindOf(current) == nil {
            Section("In the scene") { item(current, "\(current) — not found on this Mac", current) }
        }
    }

    private func item(_ destination: String, _ title: String, _ current: String) -> some View {
        Button {
            model.setDestination(role, destination)
        } label: {
            if destination == current { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }

    private func kindOf(_ destination: String) -> String? {
        if destination == CoreMIDISink.virtualDestination || destination == CoreMIDISink.networkDestination { return "mac" }
        if model.hostedInstruments.contains(where: { $0.destination == destination }) { return "hosted" }
        return model.midiDestinations.first { $0.address == destination }?.kind.rawValue
    }

    static func label(_ destination: String, model: AppModel) -> String {
        switch destination {
        case CoreMIDISink.virtualDestination: return "Virtual port “MIDI Signal Generator”"
        case CoreMIDISink.networkDestination: return "Network session"
        default:
            if let inst = model.hostedInstruments.first(where: { $0.destination == destination }) {
                return model.instrumentLabel(inst.id)
            }
            return destination
        }
    }

    static func icon(_ destination: String, model: AppModel) -> String {
        if destination == CoreMIDISink.virtualDestination { return "pianokeys" }
        if destination == CoreMIDISink.networkDestination { return "network" }
        if destination.hasPrefix(InstrumentConfig.destinationPrefix) { return "waveform" }
        switch model.midiDestinations.first(where: { $0.address == destination })?.kind {
        case .bluetooth: return "dot.radiowaves.left.and.right"
        case .usb: return "cable.connector"
        case .network: return "network"
        case .iac, .app: return "arrow.left.arrow.right"
        default: return "questionmark.circle"
        }
    }
}

/// Connected, waiting for the device, or what to do.
struct DestinationStatus: View {
    @Environment(AppModel.self) private var model
    let destination: String

    var body: some View {
        let (ok, text) = status
        HStack(spacing: 5) {
            Circle().fill(ok ? Color.green : .orange).frame(width: 8, height: 8)
            Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
    }

    private var status: (Bool, String) {
        if destination.hasPrefix(InstrumentConfig.destinationPrefix) {
            return model.hostedInstruments.contains { $0.destination == destination }
                ? (true, "plays inside this app")
                : (false, "this synth isn't loaded in the session")
        }
        if destination == CoreMIDISink.virtualDestination { return (true, "pick “MIDI Signal Generator” as an input in the other app") }
        guard model.isRunning else { return (false, "connects when you press Start") }
        if destination == CoreMIDISink.networkDestination, !model.networkSessionEnabled {
            return (false, "enable the session in Audio MIDI Setup → MIDI Studio → Network")
        }
        if model.destinationStatus[destination] == true { return (true, "connected") }
        let known = model.midiDestinations.first { $0.address == destination }
        if known?.kind == .bluetooth { return (false, "waiting for the device: connect it with Bluetooth MIDI…") }
        return (false, known == nil ? "not on this Mac yet: notes reach it when it appears" : "waiting for the device to connect")
    }
}
