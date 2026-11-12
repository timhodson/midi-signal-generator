import Testing
@testable import Music
import Params
import SignalBus

private let dDorian = HarmonyContext(root: 2, scale: .dorian)

@Suite struct HarmonyTests {
    @Test func degreesMapToScaleNotes() {
        #expect(dDorian.note(degree: 0) == 62)   // D4
        #expect(dDorian.note(degree: 7) == 74)   // D5
        #expect(dDorian.note(degree: -1) == 60)  // C4 (b7 below)
    }

    @Test func chordsStackThirds() {
        var h = dDorian
        h.chordDegree = 3 // IV in dorian = G major
        #expect(h.chordPitchClasses == [7, 11, 2])
    }

    @Test func nearestSnapsToAllowedPitchClass() {
        #expect(HarmonyContext.nearest(63.2, in: [2, 5, 9]) == 62)
        #expect(HarmonyContext.nearest(64, in: [5]) == 65)
    }
}

@Suite struct QuantiserTests {
    @Test func pitchStrengthIsAContinuum() {
        // 63.4 (D#) is out of D dorian: raw keeps it, scale snaps to E or D, chord snaps to D/F/A.
        #expect(Quantiser.quantisePitch(63.4, strength: 0, harmony: dDorian, roll: 0.5) == 63)
        #expect(dDorian.scalePitchClasses.contains(Quantiser.quantisePitch(63.4, strength: 0.5, harmony: dDorian, roll: 0.5) % 12))
        #expect(dDorian.chordPitchClasses.contains(Quantiser.quantisePitch(63.4, strength: 1, harmony: dDorian, roll: 0.99) % 12))
    }

    @Test func timeQuantiseMovesTowardsNextGridLine() {
        var clock = MusicalClock()
        _ = clock.advance(to: 1, bpm: 60)     // starts clock at t=1, beat 0
        _ = clock.advance(to: 1.1, bpm: 60)   // beat 0.1
        let full = Quantiser.quantiseTime(1.1, clock: clock, grid: 0.5, strength: 1, swing: 0)
        let half = Quantiser.quantiseTime(1.1, clock: clock, grid: 0.5, strength: 0.5, swing: 0)
        let none = Quantiser.quantiseTime(1.1, clock: clock, grid: 0.5, strength: 0, swing: 0)
        #expect(abs(full - 1.5) < 1e-9)
        #expect(abs(half - 1.3) < 1e-9)
        #expect(none == 1.1)
    }

    @Test func velocityCurveRespectsFloorAndCeiling() {
        #expect(Quantiser.velocity(0, curve: 1, floor: 20, ceiling: 100) == 20)
        #expect(Quantiser.velocity(1, curve: 1, floor: 20, ceiling: 100) == 100)
        #expect(Quantiser.velocity(0.5, curve: 2, floor: 0, ceiling: 100) == 25)
    }
}

@Suite struct ClockTests {
    @Test func crossingsAreStartExclusiveEndInclusive() {
        #expect(MusicalClock.crossings(of: 1, in: 0..<2) == [1, 2])
        #expect(MusicalClock.crossings(of: 0.25, in: 0.9..<1.3) == [1, 1.25])
    }
}

@Suite struct ConductorTests {
    private func store() -> ParamStore {
        let s = ParamStore()
        s.register(Conductor.params)
        return s
    }

    @Test func classifiesMoods() {
        let c = Conductor(progressions: Conductor.defaultProgressions, gestures: [:])
        let p = store()
        #expect(c.classify(total: 100, perApp: [:], params: p) == .quiet)
        #expect(c.classify(total: 100_000, perApp: ["a": 50_000, "b": 50_000], params: p) == .calm)
        #expect(c.classify(total: 5_000_000, perApp: ["a": 4_500_000, "b": 500_000], params: p) == .focused)
        #expect(c.classify(total: 5_000_000, perApp: ["a": 2_500_000, "b": 2_500_000], params: p) == .busy)
    }

    @Test func moodChangeWaitsForHysteresisAndPhraseEnd() throws {
        let c = Conductor(progressions: [.quiet: [0, 3], .calm: [0, 5, 3, 4]], gestures: [:])
        let p = store()
        try p.set("harmony.hysteresis", 5)
        try p.set("harmony.barsPerChord", 1)
        try p.set("conductor.smoothing", 0)
        _ = c.observe(total: 100_000, perApp: ["a": 100_000], activations: [], now: 0, params: p)
        _ = c.onBar(1, now: 2, params: p)          // too soon: still quiet, index 1
        #expect(c.mood == .quiet)
        _ = c.onBar(2, now: 6, params: p)          // ready, and quiet's progression wraps here
        #expect(c.mood == .calm)
        #expect(c.chordDegree == 0)
    }

    @Test func flurryInsertsGesture() throws {
        let c = Conductor(progressions: [.quiet: [0]], gestures: ["flurry": [4, 0]])
        let p = store()
        try p.set("conductor.flurryApps", 2)
        try p.set("harmony.barsPerChord", 1)
        let acts = [Activation(key: "a", bytesPerSecond: 1, time: 0), Activation(key: "b", bytesPerSecond: 1, time: 0)]
        #expect(!c.observe(total: 0, perApp: [:], activations: acts, now: 0, params: p).isEmpty)
        _ = c.onBar(1, now: 1, params: p)
        #expect(c.chordDegree == 4)
        // Cooldown: a second flurry straight away is ignored.
        #expect(c.observe(total: 0, perApp: [:], activations: acts, now: 2, params: p).isEmpty)
    }

    @Test func moodCanChangeAfterAGesture() throws {
        let c = Conductor(progressions: [.quiet: [0, 3, 5], .calm: [1]], gestures: ["flurry": [4]])
        let p = store()
        try p.set("harmony.barsPerChord", 1)
        try p.set("harmony.hysteresis", 0)
        try p.set("conductor.smoothing", 0)
        try p.set("conductor.flurryApps", 2)
        let acts = [Activation(key: "a", bytesPerSecond: 1, time: 0), Activation(key: "b", bytesPerSecond: 1, time: 0)]
        _ = c.onBar(1, now: 0, params: p)                       // quiet, index 1 (mid-phrase)
        _ = c.observe(total: 100_000, perApp: ["a": 100_000], activations: acts, now: 0, params: p)
        _ = c.onBar(2, now: 1, params: p)                       // gesture
        #expect(c.chordDegree == 4)
        _ = c.onBar(3, now: 2, params: p)                       // phrase ended by gesture → calm
        #expect(c.mood == .calm)
        #expect(c.chordDegree == 1)
    }
}

@Suite struct GeneratorTests {
    @Test func motifIsStablePerAppAndRespectsRange() {
        let a = MotifGenerator.shape(for: "Safari", length: 8, range: 5)
        #expect(a == MotifGenerator.shape(for: "Safari", length: 8, range: 5))
        #expect(a.offsets.count == 8)
        #expect(a.offsets.allSatisfy { abs($0) <= 5 })
        #expect(a.offsets != MotifGenerator.shape(for: "Mail", length: 8, range: 5).offsets)
    }

    @Test func activityFiresOnceThenRespectsCooldown() throws {
        let p = ParamStore()
        p.register(ActivityTracker.params)
        try p.set("activity.threshold", 1_000)
        try p.set("activity.cooldown", 10)
        var t = ActivityTracker()
        #expect(t.update(rates: ["x": 5_000], now: 0, params: p, ignore: []).count == 1)
        #expect(t.update(rates: ["x": 5_000], now: 1, params: p, ignore: []).isEmpty)   // still active
        #expect(t.update(rates: ["x": 0], now: 2, params: p, ignore: []).isEmpty)
        #expect(t.update(rates: ["x": 5_000], now: 3, params: p, ignore: []).isEmpty)   // cooldown
        _ = t.update(rates: ["x": 0], now: 12, params: p, ignore: [])
        #expect(t.update(rates: ["x": 5_000], now: 13, params: p, ignore: []).count == 1)
    }
}

@Suite struct ChordNameTests {
    @Test func namesDorianTriads() {
        let names = (0..<7).map { dDorian.chordName(degree: $0) }
        #expect(names == ["Dm", "Em", "F", "G", "Am", "B°", "C"])
        #expect((0..<7).map { dDorian.romanNumeral(degree: $0) } == ["i", "ii", "III", "IV", "v", "vi°", "VII"])
    }

    @Test func namesSevenths() {
        let c = HarmonyContext(root: 0, scale: .major, chordSize: 4)
        #expect(c.chordName(degree: 0) == "Cmaj7")
        #expect(c.chordName(degree: 4) == "G7")
        #expect(c.chordName(degree: 1) == "Dm7")
    }
}

@Suite struct MotifDesignTests {
    @Test func matchingPrefersExactThenContainsThenWildcard() {
        let designs = [MotifDesign(match: "*", steps: [0]), MotifDesign(match: "brave", steps: [1]),
                       MotifDesign(match: "Brave Browser H", steps: [2])]
        #expect(MotifDesign.best(for: "Brave Browser H", in: designs)?.steps == [2])
        #expect(MotifDesign.best(for: "Brave Helper", in: designs)?.steps == [1])
        #expect(MotifDesign.best(for: "Mail", in: designs)?.steps == [0])
        #expect(MotifDesign.best(for: "Mail", in: [designs[1]]) == nil)
    }

    @Test func designedMotifPlaysScaleStepsOverTheChord() {
        let gen = MotifGenerator()
        gen.designs = [MotifDesign(match: "Safari", steps: [0, nil, 2, 4], anchor: .chord, octave: 4)]
        let p = ParamStore()
        p.register(gen.params)
        var harmony = dDorian
        harmony.chordDegree = 3                                      // G chord
        var clock = MusicalClock()
        _ = clock.advance(to: 1, bpm: 60)
        let ctx = GeneratorContext(now: 1, clock: clock, beats: 0..<0, harmony: harmony, params: p, chordChanged: false,
                                   activations: [Activation(key: "Safari", bytesPerSecond: 50_000, time: 1)], totalRate: 0)
        var rng = SeededRandom(seed: 1)
        let notes = gen.tick(ctx, rng: &rng).notes
        #expect(notes.map(\.pitch) == [.exact(67), .exact(71), .exact(74)])   // G4 B4 D5, rest skipped
        #expect(notes[1].time > notes[0].time + 0.5)                          // the rest kept its time
    }

    @Test func convertingGeneratedMotifKeepsLengthAndStaysInScale() {
        let d = MotifDesign.fromGenerated(app: "Spotify", length: 6, range: 7, octave: 5, harmony: dDorian)
        #expect(d.steps.count == 6)
        #expect(d.steps.allSatisfy { $0 != nil })
        #expect(d.anchor == .key)
    }
}

@Suite struct RandomMotifTests {
    @Test func randomStepsAreAnchoredAndStayInTheirPool() {
        var rng = SeededRandom(seed: 42)
        for _ in 0..<50 {
            let steps = MotifDesign.randomSteps(count: 8, chordNotesOnly: true, using: &rng)
            #expect(steps.count == 8)
            #expect(steps.first == 0)
            #expect(steps.compactMap { $0 }.allSatisfy { [-3, 0, 2, 4, 7, 9, 11].contains($0) })
        }
        let any = MotifDesign.randomSteps(count: 12, chordNotesOnly: false, using: &rng)
        #expect(any.compactMap { $0 }.allSatisfy { (-3...11).contains($0) })
    }
}

@Suite struct PacketGeneratorTests {
    let harmony = HarmonyContext(root: 2, scaleSteps: [0, 2, 3, 5, 7, 9, 10]) // D Dorian

    func context(_ events: [SignalSample], at now: Double = 10, gen: PacketGenerator, params: ParamStore) -> GeneratorContext {
        var clock = MusicalClock()
        _ = clock.advance(to: 1, bpm: 60)   // beat 0 at t = 1, then 1 beat = 1 s
        _ = clock.advance(to: now, bpm: 60)
        return GeneratorContext(now: now, clock: clock, beats: 0..<0, harmony: harmony, params: params, chordChanged: false,
                                activations: [], totalRate: 0, events: events)
    }

    func setup(_ sets: [String: Double] = [:]) -> (PacketGenerator, ParamStore) {
        let g = PacketGenerator()
        let p = ParamStore()
        p.register(g.params)
        for (k, v) in sets { try! p.set(k, v) }
        return (g, p)
    }

    @Test func sitesGroupSubdomains() {
        #expect(PacketGenerator.site(of: "lb-140-82-121-4.iad.github.com") == "github.com")
        #expect(PacketGenerator.site(of: "www.bbc.co.uk.") == "bbc.co.uk")
        #expect(PacketGenerator.site(of: "140.82.121.4") == "140.82.121.4")
        #expect(PacketGenerator.site(of: "2606:50c0::153") == "2606:50c0::153")
    }

    @Test func lookupIsAPickupJustBeforeTheNextBeat() throws {
        let (g, p) = setup()
        var rng = SeededRandom(seed: 1)
        let notes = g.tick(context([.event("net.dns.query", key: "github.com")], at: 10.1, gen: g, params: p), rng: &rng).notes
        let n = try #require(notes.first)
        #expect(notes.count == 1)
        #expect(abs(n.time - 10.75) < 1e-9)   // a sixteenth before beat 11
        #expect(n.role == "pulse")
        // Same site, same scale step, every time.
        let d = PacketGenerator.degree(for: "github.com", steps: 7)
        #expect(n.pitch == .exact(harmony.note(degree: d, octave: 5)))
    }

    @Test func handshakeAnswerArrivesAfterTheStretchedRoundTrip() {
        let (g, p) = setup(["gen.packets.stretch": 10])
        var rng = SeededRandom(seed: 1)
        let tcp = g.tick(context([.event("net.tcp.open", key: "github.com", 0.03)], gen: g, params: p), rng: &rng).notes
        #expect(tcp.count == 3)
        #expect(abs(tcp[1].time - tcp[0].time - 0.3) < 1e-9)
        let quic = g.tick(context([.event("net.quic.open", key: "google.com", 0.02)], at: 20, gen: g, params: p), rng: &rng).notes
        #expect(quic.count == 2)                                           // no separate ACK
    }

    @Test func cooldownAndLimitSkipWithReasons() {
        let (g, p) = setup(["gen.packets.maxPerSecond": 1, "gen.packets.cooldown": 30])
        var rng = SeededRandom(seed: 1)
        let burst: [SignalSample] = [
            .event("net.dns.query", key: "a.example.com"),
            .event("net.dns.query", key: "b.example.com"),   // same site: cooldown
            .event("net.dns.query", key: "other.org"),       // limit: one token
            .event("net.tls.hello", key: "other.org"),       // names only
        ]
        let notes = g.tick(context(burst, gen: g, params: p), rng: &rng).notes
        #expect(notes.count == 1)
        let d = g.drainDecisions()
        #expect(d.map(\.played) == [true, false, false, false])
        #expect(d[1].reason.contains("cooldown"))
        #expect(d[2].reason.contains("limit"))
        #expect(g.drainDecisions().isEmpty)
    }

    @Test func switchedOffKindsAreSkipped() {
        let (g, p) = setup(["gen.packets.lan": 0])
        var rng = SeededRandom(seed: 1)
        #expect(g.tick(context([.event("net.lan.announce", key: "_airplay._tcp")], gen: g, params: p), rng: &rng).notes.isEmpty)
        #expect(g.drainDecisions().first?.played == false)
    }
}
