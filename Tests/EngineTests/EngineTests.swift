import Foundation
import Testing
@testable import Engine
import MIDIOut
import Music
import Params

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
