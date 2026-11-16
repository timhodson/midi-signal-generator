import Foundation
import Music
import Params

/// Randomises the melodic presentation of the piece (key, scale, progressions, motifs, registers,
/// patterns, optionally tempo and drums) by a chosen **deviation**, now or on a schedule.
///
/// Variations are measured from a **home** (the scene as loaded, or whatever was marked home), so
/// repeated variations stay within reach of it; or, with "from: where it is now", they drift.
/// Scheduled changes wait for the end of a chord progression (a phrase), so the key never lurches
/// mid-phrase. See docs/decisions/0017-variation.md.
public final class Variation {
    public static let intervals: [(label: String, minutes: Double)] = [
        ("Off", 0), ("5 min", 5), ("10 min", 10), ("15 min", 15), ("30 min", 30), ("1 hour", 60), ("2 hours", 120), ("4 hours", 240),
    ]
    public static let groups = ["harmony", "motifs", "generators", "tempo", "drums"]

    public static let params: [ParamSpec] = [
        ParamSpec("variation.amount", default: 0.35,
                  help: "Deviation: how far each variation strays from home. 0.1 = a couple of small changes (a neighbouring key, an octave); 0.5 = a new key and scale family, reworked progressions, new motifs; 1 = almost everything changes, including unusual scales."),
        ParamSpec("variation.every", kind: .choice, default: 0, options: intervals.map(\.label),
                  help: "Vary the piece automatically this often. The change waits for the end of the current chord progression, so it lands on a phrase boundary."),
        ParamSpec("variation.from", kind: .choice, default: 0, options: ["Home", "Where it is now"],
                  help: "Home = every variation is a fresh take on the home settings, so the piece never wanders far. Where it is now = each variation builds on the last, so the piece drifts further over time."),
        ParamSpec("variation.waitForPhrase", kind: .toggle, default: 1,
                  help: "Scheduled variations wait for the end of the chord progression. Off: they apply at the next chord change. (Randomise now always uses the next chord change.)"),
        ParamSpec("variation.harmony", kind: .toggle, default: 1,
                  help: "Vary the key, the scale, chord size, chord length and every mood's chord progression."),
        ParamSpec("variation.motifs", kind: .toggle, default: 1,
                  help: "Vary the generated app motifs (a new set of tunes), their length, range, speed and register, and the notes network events play."),
        ParamSpec("variation.generators", kind: .toggle, default: 1,
                  help: "Vary registers and patterns: pad octave and spread, pulse range and grid, bass pattern and register, sub drone mode."),
        ParamSpec("variation.tempo", kind: .toggle, default: 0,
                  help: "Vary the tempo too (by up to a quarter either way at full deviation)."),
        ParamSpec("variation.drums", kind: .toggle, default: 0,
                  help: "Vary the drummer: the groove for each mood, swing and fill style."),
    ]

    enum Rule {
        case root, scale, seed
        case choice([Int]?)
        case integer(ClosedRange<Int>)
        case continuous(ClosedRange<Double>)
    }

    struct Item {
        let id: String
        let group: String
        let rule: Rule
    }

    static let items: [Item] = [
        Item(id: "harmony.root", group: "harmony", rule: .root),
        Item(id: "harmony.scale", group: "harmony", rule: .scale),
        Item(id: "harmony.chordSize", group: "harmony", rule: .integer(3...5)),
        Item(id: "harmony.barsPerChord", group: "harmony", rule: .integer(1...4)),
        Item(id: "gen.motif.seed", group: "motifs", rule: .seed),
        Item(id: "gen.motif.length", group: "motifs", rule: .integer(2...8)),
        Item(id: "gen.motif.range", group: "motifs", rule: .integer(3...14)),
        Item(id: "gen.motif.stepBeats", group: "motifs", rule: .continuous(0.25...1)),
        Item(id: "gen.motif.octave", group: "motifs", rule: .integer(4...6)),
        Item(id: "gen.packets.seed", group: "motifs", rule: .seed),
        Item(id: "gen.packets.octave", group: "motifs", rule: .integer(3...5)),
        Item(id: "gen.drone.octave", group: "generators", rule: .integer(2...4)),
        Item(id: "gen.drone.spread", group: "generators", rule: .integer(0...2)),
        Item(id: "gen.pulse.octave", group: "generators", rule: .integer(3...5)),
        Item(id: "gen.pulse.span", group: "generators", rule: .integer(5...24)),
        Item(id: "gen.pulse.step", group: "generators", rule: .choice([1, 2, 3])),
        Item(id: "gen.bass.pattern", group: "generators", rule: .choice([0, 1, 2, 3])), // genre figures come with styles
        Item(id: "gen.bass.octave", group: "generators", rule: .integer(1...3)),
        Item(id: "gen.sub.mode", group: "generators", rule: .choice(nil)),
        Item(id: "clock.bpm", group: "tempo", rule: .continuous(40...110)),
        Item(id: "gen.drums.groove.quiet", group: "drums", rule: .choice([0, 1, 2, 6])),
        Item(id: "gen.drums.groove.calm", group: "drums", rule: .choice([1, 2, 3, 5, 6])),
        Item(id: "gen.drums.groove.busy", group: "drums", rule: .choice([2, 3, 4, 5, 6])),
        Item(id: "gen.drums.groove.focused", group: "drums", rule: .choice([1, 2, 4, 6])),
        Item(id: "gen.drums.swing", group: "drums", rule: .continuous(0...0.33)),
        Item(id: "gen.drums.fillStyle", group: "drums", rule: .choice(nil)),
    ]

    /// Scales by how far they are from everyday modes: the first list is always available, the
    /// second from deviation 0.5, the third from 0.85. Chromatic is never picked (it has no chords).
    static let scaleTiers: [[Int]] = [[0, 1, 2, 4, 5, 9, 10], [3, 7, 8], [6, 11]]

    /// Settings a style chooses for its genre, which variations leave alone while it's active.
    static let styleOwned: Set<String> = ["gen.bass.pattern", "gen.sub.mode", "gen.pulse.step", "harmony.chordSize"]

    /// Record a change made elsewhere (a style), so "What changed" shows it.
    func note(_ reason: String, changes: [String], now: Double) {
        record(.init(time: now, reason: reason, changes: changes))
    }

    public struct Applied: Sendable, Hashable {
        public var time: Double
        public var reason: String
        public var changes: [String]
    }

    struct Home {
        var values: [String: Double]
        var progressions: [Conductor.Mood: [Int]]
    }

    private var home: Home?
    private(set) var pendingReason: String?
    private var pendingManual = false
    private var nextAt: Double?
    private var lastEvery = 0.0
    public private(set) var log: [Applied] = []

    public init() {}

    var homeIsSet: Bool { home != nil }

    /// Remember the current settings as home.
    func makeHome(_ p: ParamStore, _ conductor: Conductor) {
        var values: [String: Double] = [:]
        for item in Self.items where p.specs[item.id] != nil { values[item.id] = p.baseValue(item.id) }
        home = Home(values: values, progressions: conductor.progressions)
    }

    func request(_ reason: String, manual: Bool) {
        pendingReason = reason
        pendingManual = manual
    }

    /// Keep the schedule; returns seconds until the next scheduled variation (nil = off).
    func schedule(now: Double, _ p: ParamStore) -> Double? {
        let i = min(max(p.int("variation.every"), 0), Self.intervals.count - 1)
        let every = Self.intervals[i].minutes * 60
        if every != lastEvery { lastEvery = every; nextAt = every > 0 ? now + every : nil }
        guard let next = nextAt else { return nil }
        if now >= next {
            if pendingReason == nil { request("every \(Self.intervals[i].label)", manual: false) }
            nextAt = now + every
        }
        return max((nextAt ?? now) - now, 0)
    }

    /// Whether a pending variation should land on this bar.
    func shouldApply(atChordBoundary: Bool, phraseStarts: Bool, _ p: ParamStore) -> Bool {
        guard pendingReason != nil, atChordBoundary else { return false }
        return pendingManual || !p.bool("variation.waitForPhrase") || phraseStarts
    }

    /// A progression picked by hand becomes part of home, so "back home" and variations from
    /// home keep it.
    func setHomeProgression(_ mood: Conductor.Mood, _ degrees: [Int]) {
        home?.progressions[mood] = degrees
    }

    /// Put back the progressions of pinned moods after something rewrote them.
    private func keepPinned(_ conductor: Conductor, from saved: [Conductor.Mood: [Int]]) {
        for m in conductor.pinned { conductor.progressions[m] = saved[m] }
    }

    /// Put home back. Returns what changed.
    func returnHome(_ p: ParamStore, _ conductor: Conductor, now: Double) -> [String] {
        guard let home else { return [] }
        let before = describe(p, conductor)
        let current = conductor.progressions
        for (id, v) in home.values { try? p.set(id, v) }
        conductor.progressions = home.progressions
        keepPinned(conductor, from: current)
        let changes = diff(before, describe(p, conductor), p)
        record(.init(time: now, reason: "back home", changes: changes))
        return changes
    }

    /// Make a variation. Returns what changed, in words.
    /// With a style active, variations stay inside it: its scales, its tempo range, progressions
    /// from its pool, and its bass, pulse and groove choices left alone.
    func apply(_ p: ParamStore, _ conductor: Conductor, rng: inout SeededRandom, now: Double, style: Style? = nil) -> [String] {
        let reason = pendingReason ?? "randomised"
        pendingReason = nil
        if home == nil { makeHome(p, conductor) }
        guard let home else { return [] }
        let d = min(max(p.value("variation.amount"), 0), 1)
        let fromHome = p.int("variation.from") == 0
        let enabled = Set(Self.groups.filter { p.bool("variation.\($0)") })
        let before = describe(p, conductor)
        let current = conductor.progressions

        for item in Self.items where enabled.contains(item.group) {
            guard let spec = p.specs[item.id] else { continue }
            if style != nil, Self.styleOwned.contains(item.id) || item.id.hasPrefix("gen.drums.groove.") { continue }
            let start = fromHome ? (home.values[item.id] ?? p.baseValue(item.id)) : p.baseValue(item.id)
            var v = start
            // Seeds are all-or-nothing, so they change less often than other settings.
            let chance = { if case .seed = item.rule { return d * 0.7 } else { return d } }()
            if rng.chance(chance) {
                if let style, item.id == "harmony.scale" {
                    let pool = style.scales.filter { $0 != Int(start) }
                    if !pool.isEmpty { v = Double(pool[Int(rng.next() % UInt64(pool.count))]) }
                } else if let style, item.id == "clock.bpm" {
                    v = (style.bpm.lowerBound + rng.unit() * (style.bpm.upperBound - style.bpm.lowerBound)).rounded()
                } else {
                    v = mutate(item.rule, start, d: d, spec: spec, rng: &rng)
                }
            }
            try? p.set(item.id, v)
        }

        if let style, enabled.contains("harmony") {
            // Fresh progressions from the style (and its genres' songs), as many moods as deviation says.
            let before = conductor.progressions
            _ = style.pickProgressions(p, conductor, scale: p.int("harmony.scale"), rng: &rng)
            for mood in Conductor.Mood.allCases where !rng.chance(max(d, 0.25)) {
                conductor.progressions[mood] = fromHome ? (home.progressions[mood] ?? before[mood]) : before[mood]
            }
        } else if enabled.contains("harmony") {
            let harmony = conductor.harmony(p)
            for mood in Conductor.Mood.allCases {
                let start = fromHome ? (home.progressions[mood] ?? [0]) : (conductor.progressions[mood] ?? [0])
                conductor.progressions[mood] = Self.vary(progression: start, mood: mood, d: d, harmony: harmony, rng: &rng)
            }
        } else if fromHome {
            conductor.progressions = home.progressions
        }

        keepPinned(conductor, from: current)
        let changes = diff(before, describe(p, conductor), p)
        record(.init(time: now, reason: reason, changes: changes.isEmpty ? ["nothing changed this time"] : changes))
        return changes
    }

    private func record(_ a: Applied) {
        log.append(a)
        if log.count > 20 { log.removeFirst(log.count - 20) }
    }

    func mutate(_ rule: Rule, _ v: Double, d: Double, spec: ParamSpec, rng: inout SeededRandom) -> Double {
        switch rule {
        case .root:
            // Around the circle of fifths: neighbouring keys at low deviation, distant ones at high.
            let reach = max(1, Int((d * 5).rounded()))
            let k = Int(rng.next() % UInt64(reach)) + 1
            let step = rng.chance(0.5) ? 7 * k : -7 * k
            return Double(((Int(v) + step) % 12 + 12) % 12)
        case .scale:
            let tiers = d >= 0.85 ? 3 : d >= 0.5 ? 2 : 1
            let pool = Self.scaleTiers.prefix(tiers).flatMap { $0 }.filter { $0 != Int(v) }
            return Double(pool.isEmpty ? Int(v) : pool[Int(rng.next() % UInt64(pool.count))])
        case .seed:
            return Double(Int(rng.next() % 9999) + 1)
        case .choice(let allowed):
            let all = allowed ?? Array(0..<spec.options.count)
            let pool = all.filter { $0 != Int(v) }
            return pool.isEmpty ? v : Double(pool[Int(rng.next() % UInt64(pool.count))])
        case .integer(let r):
            let reach = max(1, Int((d * Double(r.upperBound - r.lowerBound) / 2).rounded()))
            var step = Int(rng.next() % UInt64(reach)) + 1
            if rng.chance(0.5) { step = -step }
            var n = Int(v) + step
            if !r.contains(n) { n = Int(v) - step } // bounce off the edge
            return Double(min(max(n, r.lowerBound), r.upperBound))
        case .continuous(let r):
            let span = r.upperBound - r.lowerBound
            let n = v + (rng.unit() * 2 - 1) * d * span * 0.5
            return ((min(max(n, r.lowerBound), r.upperBound)) * 100).rounded() / 100
        }
    }

    /// A reworked progression: it starts on the tonic (usually), avoids diminished chords, and at
    /// higher deviation changes more chords and may gain or lose one.
    static func vary(progression: [Int], mood: Conductor.Mood, d: Double, harmony: HarmonyContext, rng: inout SeededRandom) -> [Int] {
        let steps = max(harmony.scaleSteps.count, 1)
        let allowed = (0..<steps).filter { !isDiminished($0, harmony) }
        var p = progression.map { (($0 % steps) + steps) % steps }
        if p.isEmpty { p = [0] }
        if rng.chance(d * 0.5) {
            if p.count > 2, rng.chance(0.5) { p.removeLast() } else if p.count < 8 { p.append(p[p.count - 1]) }
        }
        for i in p.indices {
            if i == 0 && !rng.chance(d * 0.3) { continue } // keep home base
            guard rng.chance(d) else { continue }
            let neighbours = Set([i > 0 ? p[i - 1] : -1])
            let pool = allowed.filter { !neighbours.contains($0) && $0 != p[i] }
            if !pool.isEmpty { p[i] = pool[Int(rng.next() % UInt64(pool.count))] }
        }
        // A pedal-like focused mood keeps its repeated chords.
        if mood == .focused, p.count >= 4, rng.chance(1 - d) { p = [p[0], p[0], p[2], p[2]] + p.dropFirst(4) }
        return p
    }

    static func isDiminished(_ degree: Int, _ h: HarmonyContext) -> Bool {
        let root = h.note(degree: degree, octave: 4)
        let fifth = h.note(degree: degree + 4, octave: 4)
        guard h.scaleSteps.count >= 7 else { return false }
        return (fifth - root) % 12 == 6
    }

    // MARK: Describing changes

    private struct Picture {
        var values: [String: Double]
        var progressions: [String]
    }

    private func describe(_ p: ParamStore, _ conductor: Conductor) -> Picture {
        var values: [String: Double] = [:]
        for item in Self.items where p.specs[item.id] != nil { values[item.id] = p.baseValue(item.id) }
        let h = conductor.harmony(p)
        let progs = Conductor.Mood.allCases.map { m in
            "\(m.rawValue): " + (conductor.progressions[m] ?? []).map { h.chordName(degree: $0) }.joined(separator: " ")
        }
        return Picture(values: values, progressions: progs)
    }

    private func diff(_ a: Picture, _ b: Picture, _ p: ParamStore) -> [String] {
        var out: [String] = []
        for item in Self.items {
            guard let x = a.values[item.id], let y = b.values[item.id], abs(x - y) > 1e-9, let spec = p.specs[item.id] else { continue }
            switch item.rule {
            case .root: out.append("key \(ScaleCatalogue.rootNames[Int(x)]) → \(ScaleCatalogue.rootNames[Int(y)])")
            case .seed: out.append(item.id == "gen.motif.seed" ? "a new set of app motifs" : "new notes for network sites")
            default: out.append("\(Self.name(item.id)) \(Self.format(x, spec)) → \(Self.format(y, spec))")
            }
        }
        for (x, y) in zip(a.progressions, b.progressions) where x != y {
            let mood = y.prefix { $0 != ":" }
            out.append("\(mood): \(x.dropFirst(mood.count + 2)) → \(y.dropFirst(mood.count + 2))")
        }
        return out
    }

    static func name(_ id: String) -> String {
        switch id {
        case "harmony.scale": "scale"
        case "harmony.chordSize": "chord size"
        case "harmony.barsPerChord": "bars per chord"
        case "clock.bpm": "tempo"
        default:
            id.replacingOccurrences(of: "gen.", with: "").replacingOccurrences(of: ".", with: " ")
                .replacingOccurrences(of: "noteBeats", with: "note length").replacingOccurrences(of: "stepBeats", with: "step")
        }
    }

    static func format(_ v: Double, _ spec: ParamSpec) -> String {
        switch spec.kind {
        case .choice: spec.options.indices.contains(Int(v)) ? spec.options[Int(v)] : "\(Int(v))"
        case .integer, .toggle: "\(Int(v))"
        default: v.formatted(.number.precision(.fractionLength(0...2)))
        }
    }
}
