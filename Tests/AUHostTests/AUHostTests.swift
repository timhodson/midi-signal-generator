import Foundation
import Testing
@testable import AUHost
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
