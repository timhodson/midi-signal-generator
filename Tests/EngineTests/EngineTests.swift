import Foundation
import Testing
@testable import Engine
import MIDIOut
import Music
import Params
import Router

@Suite struct EngineTests {
    @Test func editedProgressionsPlayAndAreSaved() throws {
        let engine = try Engine(scene: .default, sink: PrintSink { _ in })
        engine.setProgression("calm", [0, 2, 4])
        engine.setProgression("flurry", [6, 0])
        engine.setProgression("quiet", [])            // ignored: a mood needs a chord
        let saved = engine.currentScene()
        #expect(saved.progressions["calm"] == [0, 2, 4])
        #expect(saved.gestures["flurry"] == [6, 0])
        #expect(saved.progressions["quiet"] == Scene.default.progressions["quiet"])
        // Round-trips through a new engine.
        let again = try Engine(scene: saved, sink: PrintSink { _ in })
        #expect(again.currentScene().progressions["calm"] == [0, 2, 4])
    }
}

@Suite struct DrumSceneTests {
    /// A scene from before the drummer, with every voice on one destination.
    func oldScene(destination: String, instruments: String = "[]") -> Data {
        Data("""
        {"name": "old", "seed": 1, "params": {}, "routes": [], "macros": [], "progressions": {}, "gestures": {}, "ignoreApps": [],
         "instruments": \(instruments),
         "voices": [{"role": "pad", "destination": "\(destination)", "channel": 1, "low": 36, "high": 72, "transpose": 0, "latencyMs": 0, "maxPolyphony": 8}]}
        """.utf8)
    }

    @Test func oldExternalScenesGetDrumsOnChannelTenOfThePadsDestination() throws {
        let s = try JSONDecoder().decode(Scene.self, from: oldScene(destination: "network"))
        let drums = try #require(s.voices.first { $0.role == "drums" })
        #expect(drums.destination == "network" && drums.channel == 10)
        #expect(s.instruments.isEmpty)
    }

    @Test func oldHostedScenesGetTheBuiltInKit() throws {
        let s = try JSONDecoder().decode(Scene.self, from: oldScene(destination: "au:j6",
            instruments: #"[{"id": "j6", "component": "Synth One J6"}]"#))
        #expect(s.voices.first { $0.role == "drums" }?.destination == "au:drums")
        #expect(s.instruments.contains { $0.id == "drums" && $0.component == "DLSMusicDevice" && !$0.outOfProcess })
    }

    @Test func editedGroovesRoundTrip() throws {
        var s = Scene.default
        s.grooves = [DrumGroove(name: "Shaker", lanes: [.kick: "x...x...x...x..."])]
        let back = try JSONDecoder().decode(Scene.self, from: s.encoded())
        #expect(back.grooves == s.grooves)
        #expect(back.voices.filter { $0.role == "drums" }.count == 1)
    }
}

@Suite struct VoiceDestinationTests {
    @Test func movingAVoiceRoutesItsNotesAndIsSaved() throws {
        var lines: [String] = []
        let engine = try Engine(scene: .default, sink: PrintSink { lines.append($0) })
        engine.log = { _ in }
        engine.setVoiceDestination("lead", "My iPad Bluetooth")
        engine.setVoiceDestination("nope", "virtual") // unknown roles are ignored
        let saved = engine.currentScene()
        #expect(saved.voices.first { $0.role == "lead" }?.destination == "My iPad Bluetooth")
        #expect(saved.voices.first { $0.role == "pad" }?.destination == "virtual")
        #expect(!saved.voices.contains { $0.role == "nope" })
    }
}

@Suite struct VariationTests {
    /// The engine's params and conductor, as the engine sets them up.
    func rig(_ sets: [String: Double] = [:]) throws -> (Variation, ParamStore, Conductor) {
        let engine = try Engine(scene: .default, sink: PrintSink { _ in })
        let p = engine.params
        for (k, v) in sets { try p.set(k, v) }
        let c = Conductor(progressions: Conductor.defaultProgressions, gestures: Conductor.defaultGestures)
        let v = Variation()
        v.makeHome(p, c)
        return (v, p, c)
    }

    @Test func zeroDeviationChangesNothing() throws {
        let (v, p, c) = try rig(["variation.amount": 0])
        var rng = SeededRandom(seed: 1)
        #expect(v.apply(p, c, rng: &rng, now: 0).isEmpty)
    }

    @Test func variationsStayInRangeAndAvoidDiminishedChords() throws {
        let (v, p, c) = try rig(["variation.amount": 1, "variation.tempo": 1, "variation.drums": 1])
        var rng = SeededRandom(seed: 7)
        for _ in 0..<40 {
            _ = v.apply(p, c, rng: &rng, now: 0)
            #expect((3...5).contains(p.int("harmony.chordSize")))
            #expect((40...110).contains(p.value("clock.bpm")))
            #expect(p.int("harmony.scale") != 12) // never chromatic
            let h = c.harmony(p)
            for prog in c.progressions.values {
                #expect(!prog.isEmpty && prog.count <= 8)
                if prog.count > 0, h.scaleSteps.count >= 7 { #expect(prog.dropFirst().allSatisfy { !Variation.isDiminished($0, h) }) }
            }
        }
    }

    @Test func lowDeviationKeepsScalesFamiliar() throws {
        let (v, p, c) = try rig(["variation.amount": 0.3])
        var rng = SeededRandom(seed: 3)
        for _ in 0..<40 {
            _ = v.apply(p, c, rng: &rng, now: 0)
            #expect(Variation.scaleTiers[0].contains(p.int("harmony.scale")))
        }
    }

    @Test func fromHomeStaysNearHomeAndReturnHomeRestores() throws {
        let (v, p, c) = try rig(["variation.amount": 0.2])
        let homeRoot = p.int("harmony.root"), homeCalm = c.progressions[.calm]
        var rng = SeededRandom(seed: 11)
        for _ in 0..<30 {
            _ = v.apply(p, c, rng: &rng, now: 0)
            // At 0.2 the key moves at most one step round the circle of fifths from home.
            let d = ((p.int("harmony.root") - homeRoot) % 12 + 12) % 12
            #expect([0, 5, 7].contains(d))
        }
        let back = v.returnHome(p, c, now: 1)
        #expect(p.int("harmony.root") == homeRoot && c.progressions[.calm] == homeCalm)
        _ = back
    }

    @Test func switchedOffGroupsDontMove() throws {
        let (v, p, c) = try rig(["variation.amount": 1, "variation.harmony": 0, "variation.motifs": 0, "variation.generators": 0])
        var rng = SeededRandom(seed: 5)
        let before = (p.int("harmony.root"), p.int("gen.motif.seed"), p.int("gen.bass.pattern"), c.progressions)
        _ = v.apply(p, c, rng: &rng, now: 0)
        #expect(p.int("harmony.root") == before.0 && p.int("gen.motif.seed") == before.1 && p.int("gen.bass.pattern") == before.2)
        #expect(c.progressions == before.3)
    }

    @Test func scheduleFiresAndWaitsForThePhrase() throws {
        let (v, p, _) = try rig(["variation.every": 1]) // 5 min
        #expect(v.schedule(now: 0, p) == 300)
        _ = v.schedule(now: 301, p)
        #expect(v.pendingReason != nil)
        #expect(!v.shouldApply(atChordBoundary: true, phraseStarts: false, p))
        #expect(v.shouldApply(atChordBoundary: true, phraseStarts: true, p))
    }

    @Test func motifSeedGivesEveryAppANewTune() {
        let a = MotifGenerator.shape(for: "Safari", length: 6, range: 7)
        #expect(a == MotifGenerator.shape(for: "Safari", length: 6, range: 7, seed: 0))
        #expect(MotifGenerator.shape(for: "Safari", length: 6, range: 7, seed: 42) == MotifGenerator.shape(for: "Safari", length: 6, range: 7, seed: 42))
    }
}

@Suite struct ClockOutTests {
    /// Run the clock from beat 0 in 5 ms ticks at `bpm` for `seconds`, as the engine does.
    func run(_ c: inout ClockOut, seconds: Double, bpm: Double = 120, from: Double = 0,
             clock: inout MusicalClock, destinations: Set<String> = ["ipad"], enabled: Bool = true,
             transport: Bool = true) -> [ClockOut.Message] {
        var out: [ClockOut.Message] = []
        var t = from
        while t < from + seconds - 1e-9 {
            t += 0.005
            let beats = clock.advance(to: t, bpm: bpm)
            out += c.advance(beats: beats, clock: clock, destinations: destinations, enabled: enabled, transport: transport)
        }
        return out
    }

    @Test func twentyFourPulsesPerBeatOnTime() {
        var c = ClockOut(), clock = MusicalClock()
        let out = run(&c, seconds: 2.0, clock: &clock) // 4 beats at 120 bpm
        let pulses = out.filter { $0.bytes == [0xF8] }
        // Beat 0 is the first tick (0.005 s), so 2 s covers just under 4 beats: pulses 0…95.
        #expect(pulses.count == 4 * 24)
        #expect(abs((pulses.first?.time ?? 9) - clock.time(ofBeat: 0)) < 1e-9)
        // Evenly spaced: 0.5 s per beat / 24.
        let times = pulses.compactMap(\.time)
        for (a, b) in zip(times, times.dropFirst()) { #expect(abs((b - a) - 0.5 / 24) < 1e-9) }
        // Start once, on beat 0, before that beat's pulse.
        #expect(out.filter { $0.bytes == [0xFA] }.count == 1)
        #expect(out.first?.bytes == [0xFA])
    }

    @Test func newDestinationStartsOnTheNextBar() {
        var c = ClockOut(), clock = MusicalClock()
        _ = run(&c, seconds: 0.6, clock: &clock) // into beat 2
        let out = run(&c, seconds: 2.0, from: 0.6, clock: &clock, destinations: ["ipad", "bt"])
        // The newcomer gets clock straight away (to lock its tempo) but Start only at beat 4.
        let start = out.first { $0.bytes == [0xFA] }
        #expect(start?.destination == "bt")
        #expect(abs((start?.time ?? 0) - clock.time(ofBeat: 4)) < 1e-9) // the next bar line
        #expect(out.contains { $0.destination == "bt" && $0.bytes == [0xF8] && ($0.time ?? 9) < clock.time(ofBeat: 4) })
        #expect(!out.contains { $0.destination == "ipad" && $0.bytes == [0xFA] })
    }

    @Test func droppedOrDisabledDestinationsGetStop() {
        var c = ClockOut(), clock = MusicalClock()
        _ = run(&c, seconds: 0.5, clock: &clock, destinations: ["ipad", "bt"])
        let dropped = run(&c, seconds: 0.1, from: 0.5, clock: &clock, destinations: ["ipad"])
        #expect(dropped.first == .init(destination: "bt", bytes: [0xFC], time: nil))
        let off = run(&c, seconds: 0.1, from: 0.6, clock: &clock, enabled: false)
        #expect(off == [.init(destination: "ipad", bytes: [0xFC], time: nil)])
        #expect(c.targets.isEmpty)
    }

    @Test func pulsesOnlyWithoutTransport() {
        var c = ClockOut(), clock = MusicalClock()
        let out = run(&c, seconds: 1, clock: &clock, transport: false)
        #expect(!out.contains { $0.bytes != [0xF8] })
    }

    @Test func noBurstAfterAStall() {
        var c = ClockOut(), clock = MusicalClock()
        _ = run(&c, seconds: 0.5, clock: &clock)
        // The queue was blocked for 3 s: one big step.
        let beats = clock.advance(to: 3.5, bpm: 120)
        let out = c.advance(beats: beats, clock: clock, destinations: ["ipad"], enabled: true, transport: true,
                            notBefore: 3.5 - 0.005)
        #expect(out.filter { $0.bytes == [0xF8] }.count <= 1) // not the 6 beats' worth it missed
    }

    @Test func tempoChangesFollow() {
        var c = ClockOut(), clock = MusicalClock()
        _ = run(&c, seconds: 1, clock: &clock)
        let out = run(&c, seconds: 1, bpm: 60, from: 1, clock: &clock)
        let times = out.filter { $0.bytes == [0xF8] }.compactMap(\.time)
        #expect(times.count >= 20)
        #expect(abs((times[11] - times[10]) - 1.0 / 24) < 1e-9) // 60 bpm: 1 s a beat
    }

    @Test func restartSendsStopThenStartOnTheNextBar() {
        var c = ClockOut(), clock = MusicalClock()
        _ = run(&c, seconds: 0.3, clock: &clock)
        #expect(c.restart() == [.init(destination: "ipad", bytes: [0xFC], time: nil)])
        let out = run(&c, seconds: 2, from: 0.3, clock: &clock)
        #expect(abs((out.first { $0.bytes == [0xFA] }?.time ?? 0) - clock.time(ofBeat: 4)) < 1e-9)
    }
}

@Suite struct TransportTests {
    @Test func beatAtAnotherTime() {
        let s = TransportState(bpm: 120, beat: 8, uptimeNanos: 1_000_000_000, beatsPerBar: 4, playing: true)
        #expect(abs(s.beat(atUptimeNanos: 1_500_000_000) - 9) < 1e-9)
        #expect(abs(s.beat(atUptimeNanos: 750_000_000) - 7.5) < 1e-9) // before the anchor
    }
}

@Suite struct StyleTests {
    /// Every setting a style names must exist, and every named option must be one of its choices,
    /// or the style would silently skip it.
    @Test func everySettingResolves() throws {
        let engine = try Engine(scene: .default, sink: PrintSink { _ in })
        for style in Style.all {
            for (id, value) in style.settings where !id.hasPrefix("au.") && !id.hasPrefix("mix.") { // hosted-only
                let spec = try #require(engine.params.specs[id], "\(style.name): no param \(id)")
                switch value {
                case .option(let name):
                    #expect(spec.options.contains { $0.trimmingCharacters(in: .whitespaces) == name }, "\(style.name): \(id) has no option \(name)")
                case .number(let n):
                    #expect(spec.range.contains(n), "\(style.name): \(id) = \(n) is outside \(spec.range)")
                }
            }
            #expect(style.scales.allSatisfy { ScaleCatalogue.scales.indices.contains($0) })
            #expect(!style.progressions.isEmpty)
        }
        #expect(Style.choices.count == Style.all.count + 1)
    }

    @Test func applyingSetsTempoScaleGroovesAndProgressions() throws {
        let engine = try Engine(scene: .default, sink: PrintSink { _ in })
        let conductor = Conductor(progressions: Conductor.defaultProgressions, gestures: [:])
        for (i, style) in Style.all.enumerated() {
            var rng = SeededRandom(seed: UInt64(i + 1))
            let changes = style.apply(engine.params, conductor, rng: &rng)
            let p = engine.params
            #expect(style.bpm.contains(p.value("clock.bpm")))
            #expect(style.scales.contains(p.int("harmony.scale")))
            #expect(changes.contains { $0.hasPrefix("tempo") })
            let busy = DrumGroove.choices[p.int("gen.drums.groove.busy")]
            #expect(DrumGroove.builtIn.contains { $0.name == busy } || busy == "Off", "\(style.name): busy groove \(busy)")
            // No mood ends up on a diminished chord progression from the pool.
            let h = conductor.harmony(p)
            for mood in Conductor.Mood.allCases {
                let prog = try #require(conductor.progressions[mood])
                #expect(!prog.isEmpty)
                #expect(!prog.allSatisfy { Variation.isDiminished($0, h) }, "\(style.name) \(mood): \(prog)")
            }
        }
    }

    @Test func songsLendProgressionsInTheirGenre() {
        let funk = Style.all.first { $0.name == "Funk" }!
        let sections = funk.songSections(scale: funk.scales[0])
        #expect(!sections.isEmpty)
        #expect(sections.allSatisfy { $0.song.genres.contains(where: funk.songGenres.contains) })
    }

    @Test func styleIsAppliedOnTheNextChordAndNoneRestoresTheScene() throws {
        let engine = try Engine(scene: .default, sink: PrintSink { _ in })
        let bpm = engine.params.value("clock.bpm"), bass = engine.params.int("gen.bass.pattern")
        try engine.params.set("style.name", Double(Style.choices.firstIndex(of: "House")!))
        #expect(engine.activeStyle?.name == "House")
        try engine.start()
        defer { engine.stop() }
        // At 66 bpm a 2-bar chord boundary comes within ~8 s; the first bar crossing is enough here.
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline, engine.queue.sync(execute: { engine.params.value("clock.bpm") }) < 120 { Thread.sleep(forTimeInterval: 0.1) }
        #expect(engine.queue.sync { engine.params.value("clock.bpm") } >= 120)
        #expect(engine.queue.sync { BassGenerator.patterns[engine.params.int("gen.bass.pattern")] } == "Off-beat")
        engine.queue.sync { try? engine.params.set("style.name", 0) }
        let back = Date().addingTimeInterval(20)
        while Date() < back, engine.queue.sync(execute: { engine.params.value("clock.bpm") }) != bpm { Thread.sleep(forTimeInterval: 0.1) }
        #expect(engine.queue.sync { engine.params.value("clock.bpm") } == bpm)
        #expect(engine.queue.sync { engine.params.int("gen.bass.pattern") } == bass)
    }
}


@Suite struct SoundSuggestionTests {
    @Test func everyStyleHasHints() {
        for style in Style.all { #expect(Style.soundHints[style.name] != nil, "\(style.name) has no sound hints") }
    }

    @Test func presetsMatchedByName() {
        let presets = ["Init", "Juno Strings Pad", "Big Brass 80s", "Saw Bass 1", "Pluck Arp", "Wobble Monster", "Glass Bell"]
        let synthwave = Style.all.first { $0.name == "Synthwave" }!
        #expect(synthwave.suggestedPresets(role: "pad", presets: presets).first?.name == "Big Brass 80s")
        #expect(synthwave.suggestedPresets(role: "bass", presets: presets).first?.name == "Saw Bass 1")
        let dubstep = Style.all.first { $0.name == "Dubstep" }!
        #expect(dubstep.suggestedPresets(role: "bass", presets: presets).first?.name == "Wobble Monster")
        #expect(synthwave.suggestedPresets(role: "pulse", presets: ["Init"]).isEmpty)
    }
}

@Suite struct StructureEditTests {
    @Test func removingANumberedItemMovesLaterOnesUp() throws {
        var s = Scene.default
        s.params = ["voice.pad.layer1.transpose": 12, "voice.pad.layer2.transpose": 7, "voice.pad.layer3.transpose": -12, "voice.pad.channel": 2]
        s.routes = [ModRoute(source: "lfo.1", target: "voice.pad.layer1.velocityScale", amount: 1),
                    ModRoute(source: "lfo.1", target: "voice.pad.layer3.velocityScale", amount: 1)]
        s.renumber(prefix: { "voice.pad.layer\($0)" }, removed: 1, count: 3)
        #expect(s.params == ["voice.pad.layer1.transpose": 7, "voice.pad.layer2.transpose": -12, "voice.pad.channel": 2])
        #expect(s.routes.map(\.target) == ["voice.pad.layer2.velocityScale"])
    }

    @Test func swappingExchangesSettingsAndRoutes() {
        var s = Scene.default
        s.params = ["au.j6.fx1.mix": 0.2, "au.j6.fx2.mix": 0.9, "au.j6.fx10.mix": 0.5]
        s.routes = [ModRoute(source: "lfo.1", target: "au.j6.fx2.mix", amount: 1)]
        s.swapPrefixes("au.j6.fx1.", "au.j6.fx2.")
        #expect(s.params == ["au.j6.fx1.mix": 0.9, "au.j6.fx2.mix": 0.2, "au.j6.fx10.mix": 0.5])
        #expect(s.routes[0].target == "au.j6.fx1.mix")
    }

    @Test func effectsAreSavedOnlyWhenThere() throws {
        let plain = InstrumentConfig(id: "j6", component: "Synth One J6")
        #expect(!String(decoding: try JSONEncoder().encode(plain), as: UTF8.self).contains("effects"))
        let withFX = InstrumentConfig(id: "j6", component: "Synth One J6", effects: [EffectConfig(component: "AUDelay", preset: "Slapback")])
        #expect(try JSONDecoder().decode(InstrumentConfig.self, from: JSONEncoder().encode(withFX)) == withFX)
        #expect(withFX.effectID(1) == "j6.fx1")
    }
}

@Suite struct PauseTests {
    @Test func pauseHoldsTheMusicAndPlayCarriesOn() throws {
        final class Lines: @unchecked Sendable { var all: [String] = [] }
        let lines = Lines()
        let engine = try Engine(scene: .default, sink: PrintSink { lines.all.append($0) }) // sink runs on the engine queue
        engine.log = { _ in }
        try engine.start()
        defer { engine.stop() }
        Thread.sleep(forTimeInterval: 1)
        #expect(engine.queue.sync { lines.all.contains { $0.hasPrefix("on ") } })   // the first chord sounded

        engine.queue.sync { engine.setPaused(true) }
        Thread.sleep(forTimeInterval: 0.3)
        let (beat, offs) = engine.queue.sync { () -> (Double, Bool) in
            let b = engine.currentBeat
            let released = lines.all.contains { $0.hasPrefix("off ") }
            lines.all = []
            return (b, released)
        }
        #expect(offs)                                                     // pausing released what was sounding
        Thread.sleep(forTimeInterval: 1.2)
        engine.queue.sync {
            #expect(!lines.all.contains { $0.hasPrefix("on ") })          // nothing new while paused
            #expect(abs(engine.currentBeat - beat) < 0.01)               // and the beat stood still
        }

        engine.queue.sync { engine.setPaused(false) }
        Thread.sleep(forTimeInterval: 0.6)
        #expect(engine.queue.sync { lines.all.contains { $0.hasPrefix("on ") } }) // the chord again, straight away
    }
}
