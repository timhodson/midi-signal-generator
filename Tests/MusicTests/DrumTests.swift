import Foundation
import Testing
@testable import Music
import Params
import SignalBus

let drumKey = HarmonyContext(root: 2, scale: .dorian)

/// Runs the drummer like the engine does: one tick per 16th at 60 bpm (1 beat = 1 s).
struct DrumRig {
    let gen = DrumGenerator()
    let params = ParamStore()
    var clock = MusicalClock()
    var rng = SeededRandom(seed: 7)
    var now = 0.0

    init(_ sets: [String: Double] = [:]) {
        params.register(Conductor.params)
        params.register(gen.params)
        try! params.set("clock.bpm", 60)
        try! params.set("gen.drums.humanise", 0)
        try! params.set("gen.drums.velocityHumanise", 0)
        try! params.set("gen.drums.swing", 0)
        for (k, v) in sets { try! params.set(k, v) }
        _ = clock.advance(to: 0.0001, bpm: 60)
    }

    /// Play `bars` bars; returns every note with its bar and step.
    mutating func play(bars: Int, rate: Double = 0, mood: String = "calm", progressionIndex: (Int) -> Int = { _ in 0 },
                       progressionLength: Int = 4, flurryAtBar: Int? = nil,
                       events: [Int: [SignalSample]] = [:]) -> [(bar: Int, step: Int, note: NoteIntent)] {
        var out: [(Int, Int, NoteIntent)] = []
        // Five ticks per 16th, so hits are asked for shortly before they're due (as in the engine).
        for t in 0..<(bars * 16 * 5) {
            let i = t % 5 == 0 ? t / 5 : -1
            now += 0.05
            let beats = clock.advance(to: now, bpm: 60)
            let bar = Int(clock.beat / 4)
            let ctx = GeneratorContext(now: now, clock: clock, beats: beats, harmony: drumKey, params: params, chordChanged: false,
                                       activations: [], totalRate: rate, events: events[i] ?? [], mood: mood,
                                       progressionIndex: progressionIndex(bar), progressionLength: progressionLength,
                                       flurry: flurryAtBar.map { i == $0 * 16 + 2 } ?? false)
            for n in gen.tick(ctx, rng: &rng).notes {
                let b = clock.beat(atTime: n.time)
                let global = Int((b * 4).rounded())
                out.append((global / 16, global % 16, n))
            }
        }
        return out
    }

    func lane(_ n: NoteIntent) -> DrumLane? {
        guard case .exact(let note) = n.pitch else { return nil }
        return DrumLane.allCases.first { params.int("gen.drums.note.\($0.rawValue)") == note }
    }
}

@Suite struct DrumTests {
    @Test func cellChanceRampsAroundItsThreshold() throws {
        let ghost = try #require(DrumCell("g"))
        #expect(ghost.chance(complexity: 0.3) == 0)
        #expect(abs(ghost.chance(complexity: 0.5) - 0.5) < 1e-9)
        #expect(ghost.chance(complexity: 0.7) == 1)
        #expect(try #require(DrumCell("x")).chance(complexity: 0) == 1)
        #expect(DrumCell(".") == nil)
    }

    @Test func euclidSpreadsHitsEvenly() {
        #expect(DrumGroove.euclid(hits: 4, steps: 16) == "X...x...x...x...")
        #expect(DrumGroove.euclid(hits: 3, steps: 8, accent: nil) == "x..x..x.")
        #expect(DrumGroove.euclid(hits: 2, steps: 8, rotate: 1, accent: nil) == ".x...x..")
        #expect(DrumGroove.euclid(hits: 0, steps: 4) == "....")
    }

    @Test func hitsAreLockedExactAndOnTheGrid() {
        var rig = DrumRig()
        let notes = rig.play(bars: 4, rate: 50_000)
        #expect(!notes.isEmpty)
        for (_, _, n) in notes {
            #expect(n.locked && n.essential && n.role == "drums")
            let b = rig.clock.beat(atTime: n.time) * 4
            #expect(abs(b - b.rounded()) < 1e-6) // humanise and swing are off
        }
    }

    @Test func lockedIntentsSkipTimeQuantising() {
        let p = ParamStore()
        p.register(Quantiser.params)
        var clock = MusicalClock()
        _ = clock.advance(to: 1, bpm: 60)
        var q = Quantiser()
        var rng = SeededRandom(seed: 1)
        let intent = NoteIntent(role: "drums", pitch: .exact(36), intensity: 0.5, time: 1.03, beats: 0.1, essential: true, locked: true)
        #expect(q.resolve(intent, harmony: drumKey, clock: clock, params: p, rng: &rng)?.start == 1.03)
    }

    @Test func lowPresenceIsATextureAndSnareBecomesRim() {
        var rig = DrumRig(["gen.drums.presence": 0.1, "gen.drums.groove.calm": 2]) // Heartbeat
        let lanes = Set(rig.play(bars: 4, rate: 50_000).compactMap { rig.lane($0.note) })
        #expect(lanes.isSubset(of: [.rim, .shaker]))
        #expect(lanes.contains(.rim))
        // Heartbeat has rim and snare together on beats 2 and 4: one click, not two.
        var again = DrumRig(["gen.drums.presence": 0.1, "gen.drums.groove.calm": 2])
        let rims = again.play(bars: 4, rate: 50_000).filter { again.lane($0.note) == .rim }
        #expect(Set(rims.map { "\($0.bar)/\($0.step)" }).count == rims.count)
        var full = DrumRig(["gen.drums.presence": 1, "gen.drums.groove.calm": 2])
        let fullLanes = Set(full.play(bars: 4, rate: 50_000).compactMap { full.lane($0.note) })
        #expect(fullLanes.isSuperset(of: [.kick, .snare, .hat]))
    }

    @Test func complexityAddsOptionalSteps() {
        var sparse = DrumRig(["gen.drums.complexity": 0, "gen.drums.response": 0, "gen.drums.presence": 1])
        var busy = DrumRig(["gen.drums.complexity": 1, "gen.drums.response": 0, "gen.drums.presence": 1])
        let a = sparse.play(bars: 8, rate: 50_000).count, b = busy.play(bars: 8, rate: 50_000).count
        #expect(b > a * 2)
    }

    @Test func trafficRaisesComplexity() {
        var rig = DrumRig(["gen.drums.complexity": 0.2, "gen.drums.response": 0.5, "gen.drums.smoothing": 0])
        _ = rig.play(bars: 1, rate: 10_000_000)
        #expect(abs(rig.gen.effectiveComplexity(rig.params) - 0.7) < 1e-9)
    }

    @Test func phraseEndBringsAFillAndACrash() {
        // Progression of 2 chords × 2 bars: bar 3 is the last bar of the phrase.
        var rig = DrumRig(["gen.drums.fills": 1, "gen.drums.presence": 1, "harmony.barsPerChord": 2])
        let notes = rig.play(bars: 6, rate: 50_000, progressionIndex: { ($0 / 2) % 2 }, progressionLength: 2)
        let fill = notes.filter { $0.note.why.contains("end of the phrase") }
        #expect(!fill.isEmpty)
        #expect(fill.allSatisfy { $0.bar == 3 && $0.step >= 8 })
        #expect(notes.contains { rig.lane($0.note) == .crash && $0.bar == 4 && $0.step == 0 })
    }

    @Test func flurryFillsTheRestOfTheBar() {
        var rig = DrumRig(["gen.drums.fills": 0])
        let notes = rig.play(bars: 4, rate: 50_000, flurryAtBar: 1)
        let fill = notes.filter { $0.note.why.contains("flurry") }
        #expect(!fill.isEmpty && fill.allSatisfy { $0.bar == 1 && $0.step >= 8 })
    }

    @Test func idleNetworkThinsThenRests() {
        var rig = DrumRig(["gen.drums.restAfter": 3, "gen.drums.idleBelow": 1_000, "gen.drums.complexity": 1, "gen.drums.smoothing": 0])
        let notes = rig.play(bars: 6, rate: 0)
        #expect(notes.filter { $0.bar >= 1 }.allSatisfy { $0.note.why.contains("always") }) // only core hits while idle
        #expect(!notes.contains { $0.bar >= 4 })                         // then nothing
        #expect(rig.gen.status(params: rig.params).phase == "resting")
        let back = rig.play(bars: 2, rate: 100_000)
        #expect(!back.isEmpty)
    }

    @Test func moodChangeCrashesAndOffMeansSilence() {
        var rig = DrumRig(["gen.drums.presence": 1, "gen.drums.groove.busy": 0])
        _ = rig.play(bars: 2, rate: 50_000, mood: "calm")
        let notes = rig.play(bars: 2, rate: 50_000, mood: "busy")
        #expect(notes.map { rig.lane($0.note) } == [.crash]) // the change is marked, then the Off groove is silent
    }

    @Test func customGrooveReplacesTheBuiltIn() {
        var rig = DrumRig(["gen.drums.groove.calm": 1, "gen.drums.presence": 1])
        rig.gen.custom = [DrumGroove(name: "Shaker", lanes: [.kick: "x...x...x...x..."])]
        let notes = rig.play(bars: 2, rate: 50_000)
        #expect(Set(notes.compactMap { rig.lane($0.note) }) == [.kick])
        #expect(rig.gen.status(params: rig.params).customised == ["Shaker"])
    }

    @Test func networkAccentsLandOnTheNextSixteenth() {
        var rig = DrumRig(["gen.drums.accents": 1, "gen.drums.groove.calm": 0])
        let notes = rig.play(bars: 1, rate: 50_000, events: [5: [.event("net.dns.query", key: "github.com")]])
        #expect(notes.count == 1)
        #expect(rig.lane(notes[0].note) == .rim && notes[0].note.why.contains("github.com"))
    }
}
