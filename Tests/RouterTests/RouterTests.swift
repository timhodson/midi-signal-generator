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
        let r = try #require(router.route(n, params: p))
        #expect(r.destination == "iPad")
        #expect(r.channel == 2)
        #expect(r.note == 58)
        #expect(abs(r.start - 1.02) < 1e-9)
        #expect(router.route(ResolvedNote(role: "nope", note: 60, velocity: 1, start: 0, duration: 1, why: ""), params: p) == nil)
    }
}
