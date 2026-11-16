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
        /// The channel strip: EQ, then the fader/pan mixer, which also feeds the FX sends.
        let eq = AVAudioUnitEQ(numberOfBands: 3)
        let mixer = AVAudioMixerNode()
        /// One per FX bus (Mixer.buses), post-fader.
        var sends: [AVAudioMixerNode] = []
        var volume: Double
        var muted = false
        var soloed = false
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
        /// Changes made outside the app (the plugin's own editor window), collected from
        /// observer callbacks on any thread and applied on the engine queue.
        let inbox = ExternalChanges()
        var observerToken: AUParameterObserverToken?
        var presetObservation: NSKeyValueObservation?
        var idByAddress: [AUParameterAddress: String] = [:]
        var lastPresetPoll = Date.distantPast
        lazy var presetNumbers: [Int] = (unit.auAudioUnit.factoryPresets ?? []).map(\.number)
        /// Param id -> what to do when it changes (see applyParams).
        var targets: [String: Target] = [:]

        /// An effect in a synth's chain (`au.<synth>.fx<N>`), not a synth.
        public let isEffect: Bool

        enum Target {
            case preset, volume, pan, bypass
            case parameter(AUParameter)
            case eqGain(Int), eqFrequency(Int), send(Int), mute, solo
        }

        init(config: InstrumentConfig, unit: AVAudioUnit, isEffect: Bool = false) {
            self.config = config
            self.unit = unit
            self.isEffect = isEffect
            volume = config.volume
            presetNames = unit.auAudioUnit.factoryPresets?.map(\.name) ?? []
        }

        var prefix: String { "au.\(config.id)" }
    }

    public let engine = AVAudioEngine()
    /// Param id -> instrument id, for routing changes.
    private var instrumentByParam: [String: String] = [:]
    private var changeCursor = 0
    public private(set) var instruments: [String: Instrument] = [:]
    /// Each synth's effects, in chain order.
    public private(set) var effects: [String: [Instrument]] = [:]
    /// Synths and effects by id ("j6", "j6.fx1"): everything with parameters and an editor.
    public private(set) var plugins: [String: Instrument] = [:]
    public var log: (String) -> Void = { print($0) }
    let meterLock = NSLock()
    private var peak: Float = 0
    var levelsByKey: [String: Float] = [:]
    var buses: [FXBus] = []
    var globalMixIDs: Set<String> = []
    var mixerDirty = false
    var reverbRoom = -1

    /// Tempo, beat and play state for the plugins (their arps and synced effects follow it).
    let hostTransport = HostTransport()

    private init() {}

    public func transport(_ state: TransportState) { hostTransport.update(state) }

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
            self.meterLock.withLock { self.peak = max(self.peak, p); self.levelsByKey["master"] = p }
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
        find(query, in: availableInstruments())
    }

    /// Every Audio Unit effect (types `aufx` and `aumf`) installed on this Mac.
    public static func availableEffects() -> [AVAudioUnitComponent] {
        [kAudioUnitType_Effect, kAudioUnitType_MusicEffect].flatMap { type in
            AVAudioUnitComponentManager.shared().components(matching: AudioComponentDescription(
                componentType: type, componentSubType: 0, componentManufacturer: 0, componentFlags: 0, componentFlagsMask: 0))
        }
        .sorted { ($0.manufacturerName, $0.name) < ($1.manufacturerName, $1.name) }
    }

    public static func effectComponent(named query: String) -> AVAudioUnitComponent? {
        find(query, in: availableEffects())
    }

    private static func find(_ query: String, in list: [AVAudioUnitComponent]) -> AVAudioUnitComponent? {
        let q = query.lowercased()
        return list.first { $0.name.lowercased() == q || "\($0.manufacturerName): \($0.name)".lowercased() == q }
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
            // Before render resources are allocated, so the plugin picks them up.
            unit.auAudioUnit.musicalContextBlock = host.hostTransport.musicalContextBlock
            unit.auAudioUnit.transportStateBlock = host.hostTransport.transportStateBlock
            let inst = Instrument(config: config, unit: unit)
            if let name = config.preset {
                guard let i = Self.presetIndex(of: name, in: inst.presetNames) else {
                    throw AUHostError.presetNotFound(name, config.component)
                }
                inst.presetIndex = i // applied once the engine runs; see below
            }
            host.engine.attach(unit)
            host.instruments[config.id] = inst
            host.plugins[config.id] = inst
            for (n, fx) in config.effects.enumerated() {
                guard let component = effectComponent(named: fx.component) else { throw AUHostError.effectNotFound(fx.component) }
                let unit = try await AVAudioUnit.instantiate(with: component.audioComponentDescription,
                                                             options: fx.outOfProcess ? .loadOutOfProcess : [])
                unit.auAudioUnit.musicalContextBlock = host.hostTransport.musicalContextBlock
                unit.auAudioUnit.transportStateBlock = host.hostTransport.transportStateBlock
                let effect = Instrument(config: InstrumentConfig(id: config.effectID(n + 1), component: fx.component, preset: fx.preset,
                                                                 outOfProcess: fx.outOfProcess),
                                        unit: unit, isEffect: true)
                if let name = fx.preset {
                    guard let i = Self.presetIndex(of: name, in: effect.presetNames) else { throw AUHostError.presetNotFound(name, fx.component) }
                    effect.presetIndex = i
                }
                host.engine.attach(unit)
                host.effects[config.id, default: []].append(effect)
                host.plugins[effect.config.id] = effect
            }
        }
        if !configs.isEmpty {
            host.buildMixer()
            host.installMeter()
            host.hostTransport.sampleRateBits.store(host.engine.outputNode.outputFormat(forBus: 0).sampleRate.bitPattern, ordering: .relaxed)
            host.engine.prepare()
            try host.engine.start()
            // The MIDI block is only valid once render resources are allocated.
            for inst in host.instruments.values { inst.midi = inst.unit.auAudioUnit.scheduleMIDIEventBlock }
            // Presets only take effect on a running plugin: Synth One J6 accepts a preset set
            // before the engine starts and reports it as current, but keeps its default sound.
            // Its parameter values also update asynchronously, so wait for them to settle
            // before they become our parameters' defaults.
            for inst in host.plugins.values.sorted(by: { $0.config.id < $1.config.id }) {
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
        // The plugin may keep reporting the old preset for a while; don't mistake that for
        // the user picking it again in the plugin's window.
        inst.lastPresetPoll = Date().addingTimeInterval(2.5)
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
            store.register(ParamSpec("\(p).volume", default: inst.config.volume,
                                     help: "How loud \(inst.config.component) is in the mix. Balance layers here; keep the Output peak below about −3 dBFS."))
            store.register(ParamSpec("\(p).pan", kind: .continuous, range: -1...1, default: inst.config.pan,
                                     help: "Where \(inst.config.component) sits left (−1) to right (+1). Spreading layers apart makes the mix clearer and wider."))
            inst.pushed["\(p).volume"] = inst.config.volume
            inst.pushed["\(p).pan"] = inst.config.pan
            inst.targets["\(p).volume"] = .volume
            inst.targets["\(p).pan"] = .pan
            registerPluginParams(inst, in: store)
            for fx in effects[inst.config.id] ?? [] {
                store.register(ParamSpec("\(fx.prefix).bypass", kind: .toggle, default: 0,
                                         help: "Take \(fx.config.component) out of \(inst.config.component)'s chain (the sound passes through untouched). Compare with and without."))
                fx.pushed["\(fx.prefix).bypass"] = 0
                fx.targets["\(fx.prefix).bypass"] = .bypass
                registerPluginParams(fx, in: store)
            }
        }
        registerMixerParams(in: store)
        for inst in plugins.values { for id in inst.targets.keys { instrumentByParam[id] = inst.config.id } }
        changeCursor = store.changeCursor
    }

    /// A plugin's preset and every one of its parameters, synced both ways with its own window.
    private func registerPluginParams(_ inst: Instrument, in store: ParamStore) {
        do {
            let p = inst.prefix
            if !inst.presetNames.isEmpty {
                store.register(ParamSpec("\(p).preset", kind: .choice, default: Double(inst.presetIndex ?? 0),
                                         options: inst.presetNames,
                                         help: inst.isEffect
                                             ? "A factory setting of \(inst.config.component). Changing it reloads all of the effect's settings. Picking one in its own window updates this too."
                                             : "The factory sound of \(inst.config.component). Changing it reloads all of the synth's settings. Picking a preset in the synth's own window updates this too."))
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
                    help: "\(inst.config.component)'s own \"\(param.displayName)\" control, the same as turning it in the synth's window. Route traffic to it in Modulation to make it move with the network."
                ))
                inst.parameters[id] = param
                inst.pushed[id] = Double(param.value)
                inst.idByAddress[param.address] = id
            }
            observeExternalChanges(inst)
            if !inst.presetNames.isEmpty { inst.targets["\(p).preset"] = .preset }
            for (id, param) in inst.parameters { inst.targets[id] = .parameter(param) }
        }
    }

    /// Two-way sync: when the user turns a knob or picks a preset in the plugin's own window,
    /// pull that into our params so the app (and saved scenes) follow.
    private func observeExternalChanges(_ inst: Instrument) {
        let au = inst.unit.auAudioUnit
        let inbox = inst.inbox
        // Our own writes pass this token as originator, so they don't echo back.
        inst.observerToken = au.parameterTree?.token(byAddingParameterObserver: { address, value in
            inbox.param(address, value)
        })
        let numbers = (au.factoryPresets ?? []).map(\.number)
        inst.presetObservation = au.observe(\.currentPreset, options: [.new]) { au, _ in
            guard let preset = au.currentPreset else { return }
            inbox.preset(numbers.firstIndex(of: preset.number), name: preset.name)
        }
    }

    /// Apply changes made in the plugin's own window to the store.
    private func drainExternalChanges(_ inst: Instrument, _ store: ParamStore) {
        var (params, preset) = inst.inbox.take()
        // Some plugins (Synth One J6) update `currentPreset` asynchronously without KVO, so also
        // poll it twice a second. Skip while one of our own preset changes is settling.
        if preset == nil, inst.resyncAt == nil, Date().timeIntervalSince(inst.lastPresetPoll) > 0.5 {
            inst.lastPresetPoll = Date()
            if let current = inst.unit.auAudioUnit.currentPreset,
               let index = inst.presetNumbers.firstIndex(of: current.number), index != inst.presetIndex {
                preset = .init(index: index, name: current.name)
            }
        }
        for (address, value) in params {
            guard let id = inst.idByAddress[address] else { continue }
            try? store.set(id, Double(value))
            inst.pushed[id] = store.value(id)
        }
        guard let preset else { return }
        let id = "\(inst.prefix).preset"
        if let index = preset.index, index != inst.presetIndex {
            try? store.set(id, Double(index))
            inst.pushed[id] = Double(index)
            inst.presetIndex = index
            log("♪ \(inst.config.id) preset → \(preset.name) (from the synth's window)")
        }
        // A user preset (not in the factory list) still changes every value: re-read them.
        inst.resyncAt = Date().addingTimeInterval(0.6)
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

    /// Called every engine tick. Only params whose value changed since the last call are
    /// looked at (via the store's change log), not all of them.
    public func applyParams(_ store: ParamStore) {
        for inst in plugins.values {
            drainExternalChanges(inst, store)
            if let due = inst.resyncAt, Date() >= due {
                inst.resyncAt = nil
                resync(inst, store)
            }
        }
        let (ids, cursor) = store.changes(since: changeCursor)
        changeCursor = cursor
        if mixerDirty || ids.contains(where: globalMixIDs.contains) {
            mixerDirty = false
            applyGlobalMix(store)
        }
        for id in Set(ids) {
            guard let owner = instrumentByParam[id], let inst = plugins[owner],
                  let target = inst.targets[id], let v = changed(id, inst, store) else { continue }
            switch target {
            case .preset:
                select(preset: Int(v), on: inst)
                // The plugin updates its values asynchronously; adopt them a moment later.
                inst.resyncAt = Date().addingTimeInterval(0.6)
                log("♪ \(inst.config.id) preset → \(inst.presetNames[safe: Int(v)] ?? "?")")
            case .pan: inst.mixer.pan = Float(v)
            case .bypass: inst.unit.auAudioUnit.shouldBypassEffect = v >= 0.5
            case .parameter(let param): param.setValue(AUValue(v), originator: inst.observerToken)
            default: _ = applyMixer(target, v, inst)
            }
        }
    }

    private func changed(_ id: String, _ inst: Instrument, _ store: ParamStore) -> Double? {
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

/// Thread-safe mailbox for changes reported by plugin observers.
final class ExternalChanges: @unchecked Sendable {
    struct Preset { var index: Int?; var name: String }
    private let lock = NSLock()
    private var params: [AUParameterAddress: AUValue] = [:]
    private var preset: Preset?

    func param(_ address: AUParameterAddress, _ value: AUValue) { lock.withLock { params[address] = value } }
    func preset(_ index: Int?, name: String) { lock.withLock { preset = Preset(index: index, name: name) } }

    func take() -> ([AUParameterAddress: AUValue], Preset?) {
        lock.withLock {
            defer { params.removeAll(); preset = nil }
            return (params, preset)
        }
    }
}

public enum AUHostError: Error, CustomStringConvertible {
    case notFound(String)
    case presetNotFound(String, String)
    case duplicateID(String)
    case effectNotFound(String)

    public var description: String {
        switch self {
        case .notFound(let c): "No Audio Unit instrument named \"\(c)\". Run --list-instruments."
        case .presetNotFound(let p, let c): "\(c) has no factory preset \"\(p)\"."
        case .duplicateID(let id): "Two instruments use the id \"\(id)\"."
        case .effectNotFound(let c): "No Audio Unit effect named \"\(c)\"."
        }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
