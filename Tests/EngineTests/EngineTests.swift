import Testing
@testable import Engine
import MIDIOut

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
