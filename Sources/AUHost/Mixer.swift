import AVFoundation
import Foundation
import Params

/// The hosted mix, laid out like a desk:
///
///   synth → EQ (low shelf, mid bell, high shelf) → channel (fader, pan, mute/solo) ─┬→ master
///                                                                                  ├→ send → reverb bus → return ─→ master
///                                                                                  └→ send → delay bus  → return ─→ master
///
/// Sends are post-fader. Every control is a param (`au.<id>.eqLow`, `au.<id>.sendReverb`,
/// `mix.delay.beats`…), so the mod matrix can ride them. Only hosted synths have audio here;
/// voices sent out over MIDI are mixed on the device that plays them.
public enum Mixer {
    public struct Bus: Sendable {
        public let id: String
        public let name: String
    }

    public static let buses = [Bus(id: "reverb", name: "Reverb"), Bus(id: "delay", name: "Delay")]
    public static let reverbRooms: [(String, AVAudioUnitReverbPreset)] = [
        ("Small room", .smallRoom), ("Medium room", .mediumRoom), ("Large room", .largeRoom),
        ("Medium hall", .mediumHall), ("Large hall", .largeHall), ("Plate", .plate),
        ("Chamber", .mediumChamber), ("Cathedral", .cathedral),
    ]
    static let eqBands = ["Low", "Mid", "High"]
}

final class FXBus {
    let input = AVAudioMixerNode()
    let effect: AVAudioUnitEffect
    let output = AVAudioMixerNode()
    init(effect: AVAudioUnitEffect) { self.effect = effect }
}

extension AUHostSink {
    /// Wire every instrument through its channel strip and the FX buses. Call before starting the engine.
    func buildMixer() {
        let main = engine.mainMixerNode
        let reverb = AVAudioUnitReverb()
        reverb.loadFactoryPreset(.largeHall)
        reverb.wetDryMix = 100
        let delay = AVAudioUnitDelay()
        delay.wetDryMix = 100
        delay.delayTime = 0.7
        delay.feedback = 35
        delay.lowPassCutoff = 5000
        buses = [FXBus(effect: reverb), FXBus(effect: delay)]
        for bus in buses {
            engine.attach(bus.input)
            engine.attach(bus.effect)
            engine.attach(bus.output)
            engine.connect(bus.input, to: bus.effect, format: nil)
            engine.connect(bus.effect, to: bus.output, format: nil)
            engine.connect(bus.output, to: main, format: nil)
        }
        for inst in instruments.values.sorted(by: { $0.config.id < $1.config.id }) {
            let eq = inst.eq
            eq.bands[0].filterType = .lowShelf; eq.bands[0].frequency = 150
            eq.bands[1].filterType = .parametric; eq.bands[1].frequency = 1000; eq.bands[1].bandwidth = 1.2
            eq.bands[2].filterType = .highShelf; eq.bands[2].frequency = 6000
            for b in eq.bands { b.gain = 0; b.bypass = false }
            engine.attach(eq)
            engine.attach(inst.mixer)
            engine.connect(inst.unit, to: eq, format: nil)
            engine.connect(eq, to: inst.mixer, format: nil)
            inst.sends = buses.map { _ in AVAudioMixerNode() }
            var points = [AVAudioConnectionPoint(node: main, bus: main.nextAvailableInputBus)]
            for (send, bus) in zip(inst.sends, buses) {
                engine.attach(send)
                engine.connect(send, to: bus.input, fromBus: 0, toBus: bus.input.nextAvailableInputBus, format: nil)
                send.outputVolume = 0
                points.append(AVAudioConnectionPoint(node: send, bus: 0))
            }
            engine.connect(inst.mixer, to: points, fromBus: 0, format: nil)
            inst.mixer.outputVolume = Float(inst.config.volume)
            inst.mixer.pan = Float(inst.config.pan)
            installLevelTap(on: inst.mixer, key: inst.config.id)
        }
    }

    func registerMixerParams(in store: ParamStore) {
        for inst in instruments.values.sorted(by: { $0.config.id < $1.config.id }) {
            let p = inst.prefix, name = inst.config.component
            let specs = [
                ParamSpec("\(p).eqLow", kind: .continuous, range: -15...15, default: 0, unit: "dB",
                          help: "Bass of \(name) (shelf below 150 Hz). Cut to stop low pads and bass clouding each other; boost for weight."),
                ParamSpec("\(p).eqMid", kind: .continuous, range: -15...15, default: 0, unit: "dB",
                          help: "Midrange of \(name) around the mid frequency. Cut a little to make room for other voices; boost to bring it forward."),
                ParamSpec("\(p).eqMidFreq", kind: .continuous, range: 150...6000, default: 1000, unit: "Hz",
                          help: "Where the mid band of \(name) works. Low (200–400 Hz) = body and mud; 1–3 kHz = presence; above = bite."),
                ParamSpec("\(p).eqHigh", kind: .continuous, range: -15...15, default: 0, unit: "dB",
                          help: "Treble of \(name) (shelf above 6 kHz). Cut for a softer, further-away sound; boost for air and sparkle."),
                ParamSpec("\(p).sendReverb", default: 0,
                          help: "How much of \(name) goes to the reverb bus (after the fader). More = further back in a bigger space."),
                ParamSpec("\(p).sendDelay", default: 0,
                          help: "How much of \(name) goes to the delay bus (after the fader): echoes in time with the tempo."),
                ParamSpec("\(p).mute", kind: .toggle, default: 0, help: "Silence \(name) in the mix (its notes still play)."),
                ParamSpec("\(p).solo", kind: .toggle, default: 0, help: "Hear only soloed channels. The FX returns stay on."),
            ]
            store.register(specs)
            for s in specs { inst.pushed[s.id] = s.defaultValue }
            inst.targets["\(p).eqLow"] = .eqGain(0)
            inst.targets["\(p).eqMid"] = .eqGain(1)
            inst.targets["\(p).eqMidFreq"] = .eqFrequency(1)
            inst.targets["\(p).eqHigh"] = .eqGain(2)
            inst.targets["\(p).sendReverb"] = .send(0)
            inst.targets["\(p).sendDelay"] = .send(1)
            inst.targets["\(p).mute"] = .mute
            inst.targets["\(p).solo"] = .solo
        }
        guard !instruments.isEmpty else { return }
        store.register([
            ParamSpec("mix.master", default: 0.9, help: "Master level of the hosted mix. Keep the master meter out of the red."),
            ParamSpec("mix.reverb.return", default: 0.8, help: "Level of the reverb coming back into the mix."),
            ParamSpec("mix.reverb.room", kind: .choice, default: 4, options: Mixer.reverbRooms.map(\.0),
                      help: "The space the reverb imitates. Rooms are short and close; halls and the cathedral are long and ambient; plate is bright and smooth."),
            ParamSpec("mix.delay.return", default: 0.7, help: "Level of the echoes coming back into the mix."),
            ParamSpec("mix.delay.beats", kind: .continuous, range: 0.125...2, default: 0.75, unit: "beats",
                      help: "Echo spacing in beats, so it follows the tempo: 0.75 = a dotted eighth (a classic ambient delay), 0.5 = eighth, 1 = a beat. Capped at 2 s."),
            ParamSpec("mix.delay.feedback", kind: .continuous, range: 0...0.95, default: 0.35,
                      help: "How many echoes: each repeat is this much of the last. Above 0.7 they hang around a long time."),
            ParamSpec("mix.delay.tone", kind: .continuous, range: 500...15000, default: 5000, unit: "Hz",
                      help: "Echoes are filtered above this frequency. Lower = darker, tape-like repeats that sit behind the mix."),
        ])
        for id in ["mix.master", "mix.reverb.return", "mix.reverb.room", "mix.delay.return", "mix.delay.beats",
                   "mix.delay.feedback", "mix.delay.tone", "clock.bpm"] { globalMixIDs.insert(id) }
        mixerDirty = true
    }

    /// Apply a channel-strip param. Returns true if handled.
    func applyMixer(_ target: Instrument.Target, _ v: Double, _ inst: Instrument) -> Bool {
        switch target {
        case .volume: inst.volume = v; updateChannelLevels()
        case .mute: inst.muted = v >= 0.5; updateChannelLevels()
        case .solo: inst.soloed = v >= 0.5; updateChannelLevels()
        case .eqGain(let b): inst.eq.bands[b].gain = Float(v)
        case .eqFrequency(let b): inst.eq.bands[b].frequency = Float(v)
        case .send(let i): inst.sends[safe: i]?.outputVolume = Float(v)
        default: return false
        }
        return true
    }

    func updateChannelLevels() {
        let anySolo = instruments.values.contains { $0.soloed }
        for inst in instruments.values {
            let audible = !inst.muted && (!anySolo || inst.soloed)
            inst.mixer.outputVolume = audible ? Float(inst.volume) : 0
        }
    }

    /// Master and FX bus settings (and the delay time, which follows the tempo).
    func applyGlobalMix(_ store: ParamStore) {
        guard buses.count == 2, let reverb = buses[0].effect as? AVAudioUnitReverb,
              let delay = buses[1].effect as? AVAudioUnitDelay else { return }
        engine.mainMixerNode.outputVolume = Float(store.value("mix.master"))
        buses[0].output.outputVolume = Float(store.value("mix.reverb.return"))
        let room = min(max(store.int("mix.reverb.room"), 0), Mixer.reverbRooms.count - 1)
        if room != reverbRoom { reverb.loadFactoryPreset(Mixer.reverbRooms[room].1); reverbRoom = room }
        buses[1].output.outputVolume = Float(store.value("mix.delay.return"))
        let bpm = max(store.value("clock.bpm"), 1)
        delay.delayTime = min(store.value("mix.delay.beats") * 60 / bpm, 2)
        delay.feedback = Float(store.value("mix.delay.feedback") * 100)
        delay.lowPassCutoff = Float(store.value("mix.delay.tone"))
    }

    func installLevelTap(on node: AVAudioNode, key: String) {
        node.installTap(onBus: 0, bufferSize: 2048, format: node.outputFormat(forBus: 0)) { [weak self] buffer, _ in
            guard let self, let channels = buffer.floatChannelData else { return }
            var p: Float = 0
            for c in 0..<Int(buffer.format.channelCount) {
                for i in 0..<Int(buffer.frameLength) { p = max(p, abs(channels[c][i])) }
            }
            self.meterLock.withLock { self.levelsByKey[key] = p }
        }
    }

    /// The latest peak level (0…1+, linear) of each channel strip by instrument id, and "master".
    public func levels() -> [String: Float] {
        meterLock.withLock { levelsByKey }
    }
}
