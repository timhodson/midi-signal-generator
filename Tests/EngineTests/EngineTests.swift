import Foundation
import Testing
@testable import Engine
import MIDIOut
import Music

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
