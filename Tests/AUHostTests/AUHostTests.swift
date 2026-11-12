import AppKit
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
