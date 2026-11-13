import AppKit
import AVFoundation
import Foundation
import Testing
@testable import AUHost
import Params
import Router

@Suite struct AUHostTests {
    @Test func stripsSharedParamPrefixWhenSafe() {
        #expect(AUHostSink.paramNames(["neoncutoff", "neonverbMix"]) == ["cutoff", "verbMix"])
        // Stripping would leave an empty name: keep the originals.
        #expect(AUHostSink.paramNames(["gain", "gainFine"]) == ["gain", "gainFine"])
        #expect(AUHostSink.paramNames(["a.b c"]) == ["a_b_c"])
    }

    @Test func presetLookupIsForgiving() {
        let names = ["2025: Space Trip", "Heaven’s Gate Pad ", "PWM String Pad"]
        #expect(AUHostSink.presetIndex(of: "heaven's gate pad", in: names) == 1)
        #expect(AUHostSink.presetIndex(of: "Heaven’s Gate Pad", in: names) == 1)
        #expect(AUHostSink.presetIndex(of: "2", in: names) == 2)
        #expect(AUHostSink.presetIndex(of: "Nope", in: names) == nil)
    }

    @Test func instrumentConfigDefaults() throws {
        let json = #"{"id": "j6", "component": "Synth One J6"}"#
        let c = try JSONDecoder().decode(InstrumentConfig.self, from: Data(json.utf8))
        #expect(c.outOfProcess)
        #expect(c.volume == 0.8)
        #expect(c.preset == nil)
        #expect(c.destination == "au:j6")
    }
}

/// Integration: needs Synth One J6 installed; skipped otherwise.
@Suite(.serialized, .enabled(if: AUHostSink.component(named: "Synth One J6") != nil, "Synth One J6 not installed"))
struct AUHostSyncTests {
    @MainActor @Test func changesMadeInThePluginFlowBackIntoParams() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited) // plugins need AppKit (ADR 0010)
        let host = try await AUHostSink.load([InstrumentConfig(id: "j6", component: "Synth One J6", preset: "Intersteller Pad")])
        defer { host.stop(tail: 0) }
        let store = ParamStore()
        host.registerParams(in: store)
        #expect(store.value("au.j6.preset") == 27)

        // As if the user turned a knob in the J6's own window.
        let au = try #require(host.instruments["j6"]).unit.auAudioUnit
        let cutoff = try #require(au.parameterTree?.allParameters.first { $0.identifier == "neoncutoffLayer1" })
        cutoff.setValue(0.123, originator: nil)
        try await Task.sleep(for: .milliseconds(300))
        host.applyParams(store)
        #expect(abs(store.value("au.j6.cutoffLayer1") - 0.123) < 0.001)

        // As if the user picked a preset there.
        au.currentPreset = au.factoryPresets?[95]
        for _ in 0..<30 where store.value("au.j6.preset") != 95 {
            try await Task.sleep(for: .milliseconds(100))
            host.applyParams(store)
        }
        #expect(store.value("au.j6.preset") == 95)
        try await Task.sleep(for: .milliseconds(700))
        host.applyParams(store)  // re-read after the plugin settles
        #expect(abs(store.value("au.j6.cutoffLayer1") - 0.684) < 0.01)
    }
}

extension AUHostSyncTests {
    @MainActor @Test func presetChosenInTheAppSticks() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited) // plugins need AppKit (ADR 0010)
        let host = try await AUHostSink.load([InstrumentConfig(id: "j6", component: "Synth One J6", preset: "Intersteller Pad")])
        defer { host.stop(tail: 0) }
        let store = ParamStore()
        host.registerParams(in: store)
        try store.set("au.j6.preset", 95)
        for _ in 0..<40 {   // 4 s: longer than the plugin's lag
            host.applyParams(store)
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(store.value("au.j6.preset") == 95)
        #expect(host.instruments["j6"]?.unit.auAudioUnit.currentPreset?.number == 95)
    }
}

/// The mixer graph, on Apple's built-in synth (always installed). No notes are played.
@Suite(.serialized) struct MixerTests {
    @MainActor @Test func channelStripsAndBusesAreWiredAndFollowParams() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let host = try await AUHostSink.load([InstrumentConfig(id: "a", component: "DLSMusicDevice", outOfProcess: false),
                                              InstrumentConfig(id: "b", component: "DLSMusicDevice", outOfProcess: false)])
        defer { host.stop(tail: 0) }
        let store = ParamStore()
        store.register([ParamSpec("clock.bpm", kind: .continuous, range: 20...200, default: 60)])
        host.registerParams(in: store)
        try store.set("mix.master", 0) // keep it silent
        try store.set("au.a.eqLow", -6)
        try store.set("au.a.sendReverb", 0.5)
        try store.set("mix.delay.beats", 0.5)
        try store.set("au.b.solo", 1)
        host.applyParams(store)

        let a = try #require(host.instruments["a"]), b = try #require(host.instruments["b"])
        // Dry to master plus one post-fader send per bus.
        #expect(host.engine.outputConnectionPoints(for: a.mixer, outputBus: 0).count == 1 + Mixer.buses.count)
        #expect(a.eq.bands[0].gain == -6)
        #expect(a.sends[0].outputVolume == 0.5)
        #expect(a.mixer.outputVolume == 0)              // not soloed while b is
        #expect(b.mixer.outputVolume == Float(b.config.volume))
        #expect(abs(((host.buses[1].effect as? AVAudioUnitDelay)?.delayTime ?? 0) - 0.5) < 1e-6) // 0.5 beats at 60 bpm
        try store.set("clock.bpm", 120)
        host.applyParams(store)
        #expect(abs(((host.buses[1].effect as? AVAudioUnitDelay)?.delayTime ?? 0) - 0.25) < 1e-6)
        try store.set("au.b.solo", 0)
        try store.set("au.a.mute", 1)
        host.applyParams(store)
        #expect(a.mixer.outputVolume == 0 && b.mixer.outputVolume > 0)
    }
}
