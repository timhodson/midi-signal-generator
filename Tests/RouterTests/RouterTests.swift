import Foundation
import Testing
@testable import Router
import Music
import Params

@Suite struct RouterTests {
    @Test func foldsIntoRangeByOctaves() {
        #expect(VoiceRouter.fold(30, low: 48, high: 72) == 54)
        #expect(VoiceRouter.fold(90, low: 48, high: 72) == 66)
        #expect(VoiceRouter.fold(60, low: 48, high: 72) == 60)
        // Range narrower than an octave: clamp to the nearer edge.
        #expect(VoiceRouter.fold(61, low: 62, high: 64) == 62)
    }

    @Test func routesRoleToDestinationChannelAndLatency() throws {
        let router = VoiceRouter(voices: [VoiceConfig(role: "pad", destination: "iPad", channel: 3, low: 40, high: 60, latencyMs: 20)])
        let p = ParamStore()
        router.registerParams(in: p)
        let n = ResolvedNote(role: "pad", note: 70, velocity: 90, start: 1, duration: 2, why: "")
        let r = try #require(router.route(n, params: p).first)
        #expect(r.destination == "iPad")
        #expect(r.channel == 2)
        #expect(r.note == 58)
        #expect(abs(r.start - 1.02) < 1e-9)
        #expect(router.route(ResolvedNote(role: "nope", note: 60, velocity: 1, start: 0, duration: 1, why: ""), params: p).isEmpty)
    }

    @Test func layersPlayTheSameNotesElsewhere() throws {
        let pad = VoiceConfig(role: "pad", destination: "au:j6", channel: 1, low: 48, high: 72,
                              layers: [VoiceLayer(destination: "iPad", channel: 4, transpose: 12, latencyMs: 30)])
        let router = VoiceRouter(voices: [pad])
        let p = ParamStore()
        router.registerParams(in: p)
        try p.set("voice.pad.layer1.velocityScale", 0.5)
        let n = ResolvedNote(role: "pad", note: 40, velocity: 100, start: 1, duration: 2, why: "")
        let out = router.route(n, params: p)
        #expect(out.map(\.destination) == ["au:j6", "iPad"])
        #expect(out.map(\.note) == [52, 64])           // folded into range, then the layer's octave
        #expect(out.map(\.channel) == [0, 3])
        #expect(out.map(\.velocity) == [100, 50])
        #expect(abs(out[1].start - 1.03) < 1e-9)
        // Muting the layer leaves the main sound; muting the voice silences both.
        try p.set("voice.pad.layer1.enabled", 0)
        #expect(router.route(n, params: p).map(\.destination) == ["au:j6"])
        try p.set("voice.pad.layer1.enabled", 1)
        try p.set("voice.pad.enabled", 0)
        #expect(router.route(n, params: p).isEmpty)
        // Controllers reach every layer too.
        try p.set("voice.pad.enabled", 1)
        let cc = router.route(ControlIntent(role: "pad", controller: 74, value: 64, time: 0), params: p)
        #expect(cc.map(\.destination) == ["au:j6", "iPad"])
    }

    @Test func voicesWithoutLayersSaveAsBefore() throws {
        let v = VoiceConfig(role: "lead", destination: "virtual", channel: 2, low: 60, high: 96)
        let json = String(decoding: try JSONEncoder().encode(v), as: UTF8.self)
        #expect(!json.contains("layers"))
        let layered = VoiceConfig(role: "lead", destination: "virtual", channel: 2, low: 60, high: 96,
                                  layers: [VoiceLayer(destination: "au:bells", channel: 2)])
        let back = try JSONDecoder().decode(VoiceConfig.self, from: try JSONEncoder().encode(layered))
        #expect(back == layered)
    }
}
