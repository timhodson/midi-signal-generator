import AVFoundation
import Foundation
import MIDIOut
import Params
import Router

/// Hosts Audio Unit instruments in an `AVAudioEngine` and plays them from the scheduler.
///
/// One plugin instance per `InstrumentConfig`, each through its own mixer (volume, pan) into
/// the main output. MIDI goes straight into the plugin with `scheduleMIDIEventBlock`, with no
/// CoreMIDI hop. Every plugin parameter becomes an `au.<id>.<param>` ParamSpec, so the mod matrix
/// can drive e.g. the J6's cutoff from traffic (docs/decisions/0010-hosted-audio-unit-instruments.md).
public final class AUHostSink: ParameterisedSink, @unchecked Sendable {
    public final class Instrument {
        public let config: InstrumentConfig
        public let unit: AVAudioUnit
        let mixer = AVAudioMixerNode()
        var midi: AUScheduleMIDIEventBlock?
        /// Param id -> plugin parameter.
        var parameters: [String: AUParameter] = [:]
        /// Last value we pushed, per param id. We only push when *our* value changes, so a
        /// preset's own settings aren't overwritten by stale defaults.
        var pushed: [String: Double] = [:]
        var presetIndex: Int?
        let presetNames: [String]
        /// When to re-read the plugin's values after a preset change.
        var resyncAt: Date?

        init(config: InstrumentConfig, unit: AVAudioUnit) {
            self.config = config
            self.unit = unit
            presetNames = unit.auAudioUnit.factoryPresets?.map(\.name) ?? []
        }

        var prefix: String { "au.\(config.id)" }
    }

    public let engine = AVAudioEngine()
    public private(set) var instruments: [String: Instrument] = [:]
    public var log: (String) -> Void = { print($0) }
    private let meterLock = NSLock()
    private var peak: Float = 0

    private init() {}

    /// Highest absolute sample on the output mix since the last call (0...1+). Lets a headless
    /// run confirm sound is really being rendered, and will feed the UI's level meter.
    public func takePeak() -> Float {
        meterLock.withLock {
            defer { peak = 0 }
            return peak
        }
    }

    private func installMeter() {
        let mixer = engine.mainMixerNode
        mixer.installTap(onBus: 0, bufferSize: 2048, format: mixer.outputFormat(forBus: 0)) { [weak self] buffer, _ in
            guard let self, let channels = buffer.floatChannelData else { return }
            var p: Float = 0
            for c in 0..<Int(buffer.format.channelCount) {
                for i in 0..<Int(buffer.frameLength) { p = max(p, abs(channels[c][i])) }
            }
            self.meterLock.withLock { self.peak = max(self.peak, p) }
        }
    }

    // MARK: - Discovery

    /// Every Audio Unit instrument (type `aumu`) installed on this Mac.
    public static func availableInstruments() -> [AVAudioUnitComponent] {
        let any = AudioComponentDescription(componentType: kAudioUnitType_MusicDevice, componentSubType: 0,
                                            componentManufacturer: 0, componentFlags: 0, componentFlagsMask: 0)
        return AVAudioUnitComponentManager.shared().components(matching: any)
            .sorted { ($0.manufacturerName, $0.name) < ($1.manufacturerName, $1.name) }
    }

    /// Matches "Synth One J6" or "AudioKit Pro: Synth One J6", ignoring case.
    public static func component(named query: String) -> AVAudioUnitComponent? {
        let q = query.lowercased()
        return availableInstruments().first {
            $0.name.lowercased() == q || "\($0.manufacturerName): \($0.name)".lowercased() == q
        }
    }

    // MARK: - Loading

    /// Instantiate every instrument, load presets and start the audio engine.
    public static func load(_ configs: [InstrumentConfig]) async throws -> AUHostSink {
        let host = AUHostSink()
        for config in configs {
            guard host.instruments[config.id] == nil else { throw AUHostError.duplicateID(config.id) }
            guard let component = component(named: config.component) else {
                throw AUHostError.notFound(config.component)
            }
            let unit = try await AVAudioUnit.instantiate(
                with: component.audioComponentDescription,
                options: config.outOfProcess ? .loadOutOfProcess : []
            )
            let inst = Instrument(config: config, unit: unit)
            if let name = config.preset {
                guard let i = Self.presetIndex(of: name, in: inst.presetNames) else {
                    throw AUHostError.presetNotFound(name, config.component)
                }
                inst.presetIndex = i // applied once the engine runs; see below
            }
            host.engine.attach(unit)
            host.engine.attach(inst.mixer)
            host.engine.connect(unit, to: inst.mixer, format: nil)
            host.engine.connect(inst.mixer, to: host.engine.mainMixerNode, format: nil)
            inst.mixer.outputVolume = Float(config.volume)
            inst.mixer.pan = Float(config.pan)
            host.instruments[config.id] = inst
        }
        if !configs.isEmpty {
            host.installMeter()
            host.engine.prepare()
            try host.engine.start()
            // The MIDI block is only valid once render resources are allocated.
            for inst in host.instruments.values { inst.midi = inst.unit.auAudioUnit.scheduleMIDIEventBlock }
            // Presets only take effect on a running plugin: Synth One J6 accepts a preset set
            // before the engine starts and reports it as current, but keeps its default sound.
            // Its parameter values also update asynchronously, so wait for them to settle
            // before they become our parameters' defaults.
            for inst in host.instruments.values.sorted(by: { $0.config.id < $1.config.id }) {
                guard let index = inst.presetIndex else { continue }
                let before = snapshot(inst)
                host.select(preset: index, on: inst)
                let after = await settle(inst, from: before)
                if after == before, index != 0, !before.isEmpty {
                    host.log("⚠︎ \(inst.config.id): preset \"\(inst.presetNames[index])\" did not change any parameter — it may not have loaded")
                }
            }
        }
        return host
    }

    /// Find a preset by name or by number. Plugin preset names can carry trailing spaces and
    /// curly apostrophes (J6: "Heaven’s Gate Pad "), so compare trimmed, case-insensitive, with
    /// apostrophes normalised. A bare number ("95") selects by index.
    static func presetIndex(of query: String, in names: [String]) -> Int? {
        func norm(_ s: String) -> String {
            s.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "‘", with: "'")
                .lowercased()
        }
        let q = norm(query)
        if let n = Int(q), names.indices.contains(n) { return n }
        return names.firstIndex { norm($0) == q }
    }

    static func snapshot(_ inst: Instrument) -> [AUValue] {
        (inst.unit.auAudioUnit.parameterTree?.allParameters ?? []).map(\.value)
    }

    /// Wait until parameter values have moved away from `before` and then held still for
    /// 200 ms (or give up after `timeout`). Returns the final values.
    static func settle(_ inst: Instrument, from before: [AUValue], timeout: Double = 2) async -> [AUValue] {
        let start = Date()
        var last = before
        var stableFor = 0
        var moved = false
        while Date().timeIntervalSince(start) < timeout {
            try? await Task.sleep(for: .milliseconds(50))
            let now = snapshot(inst)
            if now != before { moved = true }
            if now == last { stableFor += 1 } else { stableFor = 0; last = now }
            if moved, stableFor >= 4 { break }
        }
        return last
    }

    private func select(preset index: Int, on inst: Instrument) {
        guard let preset = inst.unit.auAudioUnit.factoryPresets?[safe: index] else { return }
        inst.unit.auAudioUnit.currentPreset = preset
        inst.presetIndex = index
    }

    /// Stop audio after letting release tails ring for `tail` seconds.
    public func stop(tail: TimeInterval = 1.5) {
        guard engine.isRunning else { return }
        Thread.sleep(forTimeInterval: tail)
        engine.stop()
    }

    // MARK: - MIDISink

    private func instrument(_ destination: String) -> Instrument? {
        guard destination.hasPrefix(InstrumentConfig.destinationPrefix) else { return nil }
        return instruments[String(destination.dropFirst(InstrumentConfig.destinationPrefix.count))]
    }

    private func send(_ destination: String, _ bytes: [UInt8]) {
        guard let midi = instrument(destination)?.midi else { return }
        bytes.withUnsafeBufferPointer { midi(AUEventSampleTimeImmediate, 0, bytes.count, $0.baseAddress!) }
    }

    public func noteOn(destination: String, channel: Int, note: Int, velocity: Int) {
        send(destination, [0x90 | UInt8(channel & 0x0F), UInt8(note & 0x7F), UInt8(velocity & 0x7F)])
    }

    public func noteOff(destination: String, channel: Int, note: Int) {
        send(destination, [0x80 | UInt8(channel & 0x0F), UInt8(note & 0x7F), 0])
    }

    public func controlChange(destination: String, channel: Int, controller: Int, value: Int) {
        send(destination, [0xB0 | UInt8(channel & 0x0F), UInt8(controller & 0x7F), UInt8(value & 0x7F)])
    }

    public func allNotesOff() {
        for id in instruments.keys {
            for ch in 0..<16 { controlChange(destination: "au:\(id)", channel: ch, controller: 123, value: 0) }
        }
    }

    // MARK: - Parameters

    public func registerParams(in store: ParamStore) {
        for inst in instruments.values.sorted(by: { $0.config.id < $1.config.id }) {
            let p = inst.prefix
            store.register(ParamSpec("\(p).volume", default: inst.config.volume, help: "Output level of \(inst.config.component)."))
            store.register(ParamSpec("\(p).pan", kind: .continuous, range: -1...1, default: inst.config.pan,
                                     help: "Stereo position of \(inst.config.component)."))
            inst.pushed["\(p).volume"] = inst.config.volume
            inst.pushed["\(p).pan"] = inst.config.pan
            if !inst.presetNames.isEmpty {
                store.register(ParamSpec("\(p).preset", kind: .choice, default: Double(inst.presetIndex ?? 0),
                                         options: inst.presetNames,
                                         help: "Factory preset of \(inst.config.component) (see --list-options \(p).preset)."))
                inst.pushed["\(p).preset"] = Double(inst.presetIndex ?? 0)
            }
            let params = inst.unit.auAudioUnit.parameterTree?.allParameters ?? []
            let names = Self.paramNames(params.map(\.identifier))
            for (param, name) in zip(params, names) {
                let id = "\(p).\(name)"
                store.register(ParamSpec(
                    id, label: param.displayName, kind: .continuous,
                    range: Double(param.minValue)...Double(max(param.maxValue, param.minValue + .ulpOfOne)),
                    default: Double(param.value),
                    help: "\(inst.config.component): \(param.displayName)"
                ))
                inst.parameters[id] = param
                inst.pushed[id] = Double(param.value)
            }
        }
    }

    /// Plugin parameter ids often share a prefix ("neoncutoffLayer1", "neonverbMix"). Strip it
    /// when every id stays unique and non-empty, so params read "au.j6.cutoffLayer1".
    static func paramNames(_ ids: [String]) -> [String] {
        let cleaned = ids.map { String($0.map { $0.isLetter || $0.isNumber || $0 == "_" ? $0 : "_" }) }
        guard cleaned.count > 1, var common = cleaned.first else { return cleaned }
        for id in cleaned.dropFirst() {
            while !id.hasPrefix(common) { common.removeLast() }
        }
        let stripped = cleaned.map { String($0.dropFirst(common.count)) }
        return stripped.contains("") || Set(stripped).count != stripped.count ? cleaned : stripped
    }

    public func applyParams(_ store: ParamStore) {
        for inst in instruments.values {
            let p = inst.prefix
            if let v = changed("\(p).preset", inst, store) {
                select(preset: Int(v), on: inst)
                // The plugin updates its values asynchronously; adopt them a moment later.
                inst.resyncAt = Date().addingTimeInterval(0.6)
                log("♪ \(inst.config.id) preset → \(inst.presetNames[safe: Int(v)] ?? "?")")
            }
            if let due = inst.resyncAt, Date() >= due {
                inst.resyncAt = nil
                resync(inst, store)
            }
            if let v = changed("\(p).volume", inst, store) { inst.mixer.outputVolume = Float(v) }
            if let v = changed("\(p).pan", inst, store) { inst.mixer.pan = Float(v) }
            for (id, param) in inst.parameters {
                if let v = changed(id, inst, store) { param.setValue(AUValue(v), originator: nil) }
            }
        }
    }

    private func changed(_ id: String, _ inst: Instrument, _ store: ParamStore) -> Double? {
        guard store.specs[id] != nil else { return nil }
        let v = store.value(id)
        if let last = inst.pushed[id], abs(last - v) < 1e-4 { return nil }
        inst.pushed[id] = v
        return v
    }

    /// After a preset change, adopt the plugin's new values as our base values.
    private func resync(_ inst: Instrument, _ store: ParamStore) {
        for (id, param) in inst.parameters {
            try? store.set(id, Double(param.value))
            inst.pushed[id] = store.value(id)
        }
    }
}

public enum AUHostError: Error, CustomStringConvertible {
    case notFound(String)
    case presetNotFound(String, String)
    case duplicateID(String)

    public var description: String {
        switch self {
        case .notFound(let c): "No Audio Unit instrument named \"\(c)\". Run --list-instruments."
        case .presetNotFound(let p, let c): "\(c) has no factory preset \"\(p)\"."
        case .duplicateID(let id): "Two instruments use the id \"\(id)\"."
        }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
