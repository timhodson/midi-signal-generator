import AUHost
import Engine
import Foundation
import MIDIOut
import Router

// MARK: - Model: a voice's sounds (its main output and layers) and the hosted synths behind them

extension AppModel {
    /// The voice as it is now (the running session's copy, which follows live destination changes).
    func voice(_ role: String) -> VoiceConfig? { scene.voices.first { $0.role == role } }

    /// Where output `layer` of a voice plays: 0 = its main sound, 1… its layers.
    func destination(of role: String, layer: Int) -> String {
        guard let v = voice(role) else { return CoreMIDISink.virtualDestination }
        return layer == 0 ? v.destination : v.layers[safe: layer - 1]?.destination ?? CoreMIDISink.virtualDestination
    }

    /// "King of FM 2 · DX Tub Bells": the synth and the preset it has now, not the id it was given.
    func instrumentLabel(_ id: String) -> String {
        guard let inst = hostedInstruments.first(where: { $0.id == id }) ?? scene.instruments.first(where: { $0.id == id }) else { return id }
        let name = inst.component.split(separator: ":").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? inst.component
        guard let preset = presetName(id) else { return name }
        return "\(name) · \(preset)"
    }

    func presetName(_ id: String) -> String? {
        guard let spec = specsByID["au.\(id).preset"] else { return scene.instruments.first { $0.id == id }?.preset }
        return spec.options[safe: Int(base(spec.id))]?.trimmingCharacters(in: .whitespaces)
    }

    /// Voices (and layers) that play on a hosted synth: "lead", "pad layer 1".
    func users(ofInstrument id: String) -> [String] {
        let d = InstrumentConfig.destinationPrefix + id
        return scene.voices.flatMap { v in
            (v.destination == d ? [v.role] : []) + v.layers.enumerated().filter { $0.element.destination == d }.map { "\(v.role) layer \($0.offset + 1)" }
        }
    }

    /// Every Audio Unit instrument on this Mac, for "New hosted synth".
    var installedSynths: [(name: String, maker: String)] {
        AUHostSink.availableInstruments().map { ($0.name, $0.manufacturerName) }
    }

    /// Change the scene's structure (voices' layers, hosted synths) and reload the sound with it.
    /// Every setting carries over; hosted synths take a moment to load again.
    func restructure(_ change: (inout Scene) -> Void) async {
        if let s = session { scene = s.currentScene() }
        change(&scene)
        if isRunning { await restart() }
    }

    func addLayer(_ role: String) async {
        await restructure { scene in
            guard let i = scene.voices.firstIndex(where: { $0.role == role }) else { return }
            let v = scene.voices[i]
            scene.voices[i].layers.append(VoiceLayer(destination: CoreMIDISink.virtualDestination, channel: v.channel))
        }
    }

    /// Remove a layer (1…); later layers move up, taking their settings with them.
    func removeLayer(_ role: String, _ layer: Int) async {
        await restructure { scene in
            guard let i = scene.voices.firstIndex(where: { $0.role == role }), scene.voices[i].layers.indices.contains(layer - 1) else { return }
            let count = scene.voices[i].layers.count
            scene.voices[i].layers.remove(at: layer - 1)
            scene.renumber(prefix: { VoiceLayer.prefix(role: role, number: $0) }, removed: layer, count: count)
        }
    }

    /// Load another hosted synth and play output `layer` of `role` on it.
    func addHostedSynth(_ component: String, role: String, layer: Int) async {
        await restructure { scene in
            let id = Self.newInstrumentID(for: component, taken: Set(scene.instruments.map(\.id)))
            scene.instruments.append(InstrumentConfig(id: id, component: component, volume: 0.6))
            guard let i = scene.voices.firstIndex(where: { $0.role == role }) else { return }
            if layer == 0 { scene.voices[i].destination = InstrumentConfig.destinationPrefix + id }
            else if scene.voices[i].layers.indices.contains(layer - 1) { scene.voices[i].layers[layer - 1].destination = InstrumentConfig.destinationPrefix + id }
        }
    }

    /// Unload the hosted synths no voice or layer plays on.
    func removeUnusedSynths() async {
        await restructure { scene in
            let used = Set(scene.voices.flatMap(\.destinations))
            let gone = scene.instruments.filter { !used.contains($0.destination) }.map(\.id)
            scene.instruments.removeAll { gone.contains($0.id) }
            scene.params = scene.params.filter { key, _ in !gone.contains { key.hasPrefix("au.\($0).") } }
            scene.routes.removeAll { r in gone.contains { r.target.hasPrefix("au.\($0).") } }
        }
    }

    var unusedSynths: [InstrumentConfig] {
        let used = Set(scene.voices.flatMap(\.destinations))
        return hostedInstruments.filter { !used.contains($0.destination) }
    }

    /// "King of FM 2" → "kingoffm2", then "kingoffm2b"…: short, stable, and safe in param ids.
    static func newInstrumentID(for component: String, taken: Set<String>) -> String {
        let name = component.split(separator: ":").last.map(String.init) ?? component
        let base = String(name.lowercased().filter { $0.isLetter || $0.isNumber }.prefix(12)).nilIfEmpty ?? "synth"
        if !taken.contains(base) { return base }
        for c in "bcdefghijklmnopqrstuvwxyz" where !taken.contains(base + String(c)) { return base + String(c) }
        return base + String(taken.count)
    }
}

extension AppModel {
    // MARK: Effects on a hosted synth

    /// Every Audio Unit effect on this Mac, for "Add effect".
    var installedEffects: [(name: String, maker: String)] {
        AUHostSink.availableEffects().map { ($0.name, $0.manufacturerName) }
    }

    func addEffect(_ component: String, to instrument: String) async {
        await restructure { scene in
            guard let i = scene.instruments.firstIndex(where: { $0.id == instrument }) else { return }
            scene.instruments[i].effects.append(EffectConfig(component: component))
        }
    }

    /// Remove effect `number` (1…) from a synth's chain; later effects move up with their settings.
    func removeEffect(_ number: Int, from instrument: String) async {
        await restructure { scene in
            guard let i = scene.instruments.firstIndex(where: { $0.id == instrument }),
                  scene.instruments[i].effects.indices.contains(number - 1) else { return }
            let count = scene.instruments[i].effects.count
            scene.instruments[i].effects.remove(at: number - 1)
            scene.renumber(prefix: { "au.\(instrument).fx\($0)" }, removed: number, count: count)
        }
    }

    /// Move effect `number` one place earlier (-1) or later (+1) in the chain.
    func moveEffect(_ number: Int, by offset: Int, in instrument: String) async {
        await restructure { scene in
            guard let i = scene.instruments.firstIndex(where: { $0.id == instrument }) else { return }
            let a = number - 1, b = a + offset
            guard scene.instruments[i].effects.indices.contains(a), scene.instruments[i].effects.indices.contains(b) else { return }
            scene.instruments[i].effects.swapAt(a, b)
            scene.swapPrefixes("au.\(instrument).fx\(a + 1).", "au.\(instrument).fx\(b + 1).")
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
