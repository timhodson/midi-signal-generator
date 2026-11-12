import Testing
@testable import Params

@Suite struct ParamStoreTests {
    @Test func sanitisesAndRoundsDiscreteKinds() throws {
        let s = ParamStore()
        s.register(ParamSpec("a", kind: .integer, range: 0...10, default: 3))
        try s.set("a", 7.6)
        #expect(s.value("a") == 8)
        try s.set("a", 99)
        #expect(s.value("a") == 10)
    }

    @Test func unknownIdThrows() {
        #expect(throws: ParamError.self) { try ParamStore().set("nope", 1) }
    }

    @Test func choiceRangeComesFromOptions() {
        let spec = ParamSpec("c", kind: .choice, default: 0, options: ["x", "y", "z"])
        #expect(spec.range == 0...2)
        #expect(!spec.modulatable)
    }

    @Test func modulationOffsetsAreClampedToRange() {
        let s = ParamStore()
        s.register(ParamSpec("d", default: 0.8))
        s.setOffsets(["d": 0.5])
        #expect(s.value("d") == 1)
        #expect(s.baseValue("d") == 0.8)
    }
}

@Suite struct ModMatrixTests {
    @Test func logNormalisationSpansDecades() {
        let r = ModRoute(source: "x", target: "y", amount: 1, inputMin: 1_000, inputMax: 1_000_000, scale: .log)
        #expect(abs(r.normalise(1_000) - 0) < 1e-9)
        #expect(abs(r.normalise(31_622.7766) - 0.5) < 1e-6)
        #expect(r.normalise(10_000_000) == 1)
    }

    @Test func routeDrivesTargetByAmountTimesSpan() {
        let s = ParamStore()
        s.register(ParamSpec("t", kind: .continuous, range: 0...100, default: 10))
        let m = ModMatrix(routes: [ModRoute(source: "sig", target: "t", amount: 0.5, smoothing: 0)])
        m.registerParams(in: s)
        m.apply(to: s, dt: 0.01) { _ in 1 }
        #expect(s.value("t") == 60)
    }

    @Test func macroInterpolatesTargets() throws {
        let s = ParamStore()
        s.register(ParamSpec("p", default: 0))
        let macro = Macro(id: "m", help: "", targets: [.init(param: "p", at0: 1, at1: 0)])
        try macro.apply(0.25, to: s)
        #expect(s.value("p") == 0.75)
    }
}
