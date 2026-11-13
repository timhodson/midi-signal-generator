import Foundation
import Params

// MARK: - Lanes and grooves

/// One drum sound. Lanes are what grooves are written in; the kit map turns them into notes.
public enum DrumLane: String, CaseIterable, Codable, Sendable {
    case kick, rim, snare, hat, openHat, shaker, tomHigh, tomLow, crash

    public var label: String {
        switch self {
        case .kick: "Kick"
        case .rim: "Rim"
        case .snare: "Snare"
        case .hat: "Closed hat"
        case .openHat: "Open hat"
        case .shaker: "Shaker"
        case .tomHigh: "High tom"
        case .tomLow: "Low tom"
        case .crash: "Crash"
        }
    }

    /// General MIDI percussion note (channel 10).
    public var gmNote: Int {
        switch self {
        case .kick: 36
        case .rim: 37
        case .snare: 38
        case .hat: 42
        case .openHat: 46
        case .shaker: 70 // maracas
        case .tomHigh: 50
        case .tomLow: 45
        case .crash: 49
        }
    }

    /// The presence a lane needs before it plays. Light sounds come first, so low presence is
    /// a shaker-and-rim texture and high presence is a full kit.
    public var presenceNeeded: Double {
        switch self {
        case .shaker, .rim: 0
        case .hat: 0.2
        case .kick: 0.3
        case .tomLow: 0.4
        case .tomHigh, .openHat: 0.45
        case .snare: 0.55
        case .crash: 0.7
        }
    }

    public var defaultLevel: Double {
        switch self {
        case .hat, .shaker: 0.7
        case .crash: 0.6
        default: 1
        }
    }
}

/// One step of a groove.
public struct DrumCell: Sendable, Equatable {
    /// 0...1 before presence and intensity.
    public var velocity: Double
    /// Complexity at which the step has a 50% chance. Below 0 = always plays (a core hit).
    public var threshold: Double

    public var isCore: Bool { threshold < 0 }

    /// The characters grooves are written with, in the order a click cycles through them.
    public static let symbols: [Character] = [".", "x", "X", "o", "g", "-"]

    public init?(_ c: Character) {
        switch c {
        case "X": velocity = 1; threshold = -1
        case "x": velocity = 0.75; threshold = -1
        case "o": velocity = 0.6; threshold = 0.3
        case "g": velocity = 0.35; threshold = 0.5
        case "-": velocity = 0.5; threshold = 0.7
        default: return nil
        }
    }

    public static func describe(_ c: Character) -> String {
        switch c {
        case "X": "accent (always)"
        case "x": "hit (always)"
        case "o": "optional hit (plays from complexity ≈ 0.3)"
        case "g": "ghost note (soft; from complexity ≈ 0.5)"
        case "-": "rare extra (from complexity ≈ 0.7)"
        default: "rest"
        }
    }

    /// Chance this step plays at a given complexity: a soft ramp ±0.1 around its threshold.
    public func chance(complexity: Double) -> Double {
        isCore ? 1 : min(max((complexity - threshold) / 0.2 + 0.5, 0), 1)
    }
}

/// A one-bar pattern, one string per lane: "X...x...". See `DrumCell` for the symbols.
public struct DrumGroove: Codable, Sendable, Equatable, Identifiable {
    public var name: String
    public var steps: Int
    public var lanes: [String: String]

    public var id: String { name }

    public init(name: String, steps: Int = 16, lanes: [DrumLane: String]) {
        self.name = name
        self.steps = steps
        self.lanes = Dictionary(uniqueKeysWithValues: lanes.map { ($0.key.rawValue, $0.value) })
    }

    public func symbol(_ lane: DrumLane, _ step: Int) -> Character {
        guard let row = lanes[lane.rawValue], !row.isEmpty, steps > 0 else { return "." }
        let i = ((step % steps) + steps) % steps
        guard i < row.count else { return "." }
        return row[row.index(row.startIndex, offsetBy: i)]
    }

    public func cell(_ lane: DrumLane, _ step: Int) -> DrumCell? { DrumCell(symbol(lane, step)) }

    /// A copy with one step changed.
    public func setting(_ lane: DrumLane, _ step: Int, to symbol: Character) -> DrumGroove {
        var g = self
        var row = Array(lanes[lane.rawValue] ?? "")
        while row.count < steps { row.append(".") }
        row[step] = symbol
        g.lanes[lane.rawValue] = String(row)
        return g
    }

    // MARK: Library

    /// Choice options for the per-mood groove params. "Off" = no drums in that mood.
    /// New grooves go on the end: scenes store the index.
    public static let choices = ["Off", "Shaker", "Heartbeat", "Brushes", "Halftime", "Broken", "Euclidean",
                                 "Four on the floor", "Disco", "Synthwave", "Backbeat", "Boom bap", "Dubstep", "Funk", "Breakdown"]
    public static let euclidean = "Euclidean"

    public static let builtIn: [DrumGroove] = [
        DrumGroove(name: "Shaker", lanes: [
            .shaker: "x.g.o.g.x.g.o.g-",
            .rim:    "........o.......",
            .kick:   "x...............",
            .tomLow: "..........-.....",
        ]),
        DrumGroove(name: "Heartbeat", lanes: [
            .kick:   "X..g......x.....",
            .rim:    "....x.......x...",
            .snare:  "....x.......x...",
            .hat:    "o.g.o.g.o.g.o.g.",
            .shaker: "..-...-...-...-.",
            .tomLow: "...............-",
        ]),
        DrumGroove(name: "Brushes", lanes: [
            .kick:    "X.....o...x...g.",
            .snare:   "....x.......x...",
            .rim:     "..g.....g.....g.",
            .hat:     "x.o.x.o.x.o.x.og",
            .openHat: "..............-.",
            .shaker:  "-.-.-.-.-.-.-.-.",
        ]),
        DrumGroove(name: "Halftime", lanes: [
            .kick:    "X.........o.....",
            .snare:   "........X.......",
            .rim:     "........x.......",
            .hat:     "x.g.o.g.x.g.o.g.",
            .openHat: "......-.......-.",
            .tomLow:  "-.............-.",
        ]),
        // Genre grooves (styles, ADR 0020). Snare backbeats need presence ≥ 0.55, crashes 0.7.
        DrumGroove(name: "Four on the floor", lanes: [
            .kick:    "X...x...x...x...",
            .snare:   "....x.......x...",
            .hat:     "g.o.g.o.g.o.g.o.",
            .openHat: "..x...x...x...x.",
            .shaker:  ".g.g.g.g.g.g.g.g",
        ]),
        DrumGroove(name: "Disco", lanes: [
            .kick:    "X...x...x...x...",
            .snare:   "....X.......X...",
            .hat:     "x..gx..gx..gx..g",
            .openHat: "..x...x...x...x.",
            .tomLow:  "..............o.",
        ]),
        DrumGroove(name: "Synthwave", lanes: [
            .kick:    "X.......x.o.....",
            .snare:   "....X.......X...",
            .hat:     "x.x.x.x.x.x.x.x.",
            .openHat: "..............-.",
            .tomLow:  "..............o.",
        ]),
        DrumGroove(name: "Backbeat", lanes: [
            .kick:    "X.....o.x.o.....",
            .snare:   "....X.......X..g",
            .hat:     "x.x.x.x.x.x.x.x.",
            .openHat: "..............o.",
        ]),
        DrumGroove(name: "Boom bap", lanes: [
            .kick:    "X......o..x.....",
            .snare:   "....X.......X..g",
            .hat:     "x.x.x.x.x.x.x.xg",
            .openHat: "..........-.....",
            .rim:     "...........g....",
        ]),
        DrumGroove(name: "Dubstep", lanes: [
            .kick:    "X.....o...x.....",
            .snare:   "........X.......",
            .hat:     "x.gx.gx.x.gx.gx.",
            .openHat: ".......-.......-",
            .tomLow:  "...........o..o.",
        ]),
        DrumGroove(name: "Funk", lanes: [
            .kick:    "X..x..o.x.o..o..",
            .snare:   "....X..g.g..X..g",
            .hat:     "xgxgxgxgxgxgxgxg",
            .openHat: "..........-.....",
        ]),
        DrumGroove(name: "Breakdown", lanes: [
            .hat:     "..x...x...x...x.",
            .shaker:  "x.g.x.g.x.g.x.g.",
            .rim:     "............-...",
        ]),
        DrumGroove(name: "Broken", lanes: [
            .kick:   "X..o..x...o..g..",
            .snare:  "....x..g....x...",
            .rim:    "...g......g.....",
            .hat:    "x.x.ogx.x.x.og.x",
            .shaker: "-...-...-...-...",
        ]),
    ]

    /// Fills replace every lane but kick and hat for their last steps (16 steps, read from the end).
    public static let fillStyles = ["Auto", "Soft", "Toms", "Snare roll"]
    public static let fills: [String: DrumGroove] = [
        "Soft": DrumGroove(name: "Soft fill", lanes: [
            .rim:    "........o...o.x.",
            .shaker: "....g.g.o.o.x.xX",
        ]),
        "Toms": DrumGroove(name: "Tom fill", lanes: [
            .snare:   "........g.o.....",
            .tomHigh: "............x.o.",
            .tomLow:  ".............x.X",
            .rim:     "........g.o.....",
        ]),
        "Snare roll": DrumGroove(name: "Snare roll", lanes: [
            .snare: "........g.g.oxxX",
            .rim:   "........g.g.oxxX",
        ]),
    ]

    /// Euclidean rhythm: `hits` spread as evenly as possible over `steps`, turned by `rotate`.
    public static func euclid(hits: Int, steps: Int, rotate: Int = 0, symbol: Character = "x", accent: Character? = "X") -> String {
        guard steps > 0 else { return "" }
        let k = min(max(hits, 0), steps)
        var row = [Character](repeating: ".", count: steps)
        guard k > 0 else { return String(row) }
        var first = true
        for i in 0..<steps where (i * k) % steps < k {
            let j = ((i + rotate) % steps + steps) % steps
            row[j] = first ? (accent ?? symbol) : symbol
            first = false
        }
        return String(row)
    }
}

// MARK: - Status (for UIs)

public struct DrumStatus: Sendable, Equatable {
    public struct Hit: Sendable, Equatable, Hashable, Identifiable {
        public var id: Int
        public var lane: String
        public var bar: Int
        public var step: Int
        public var time: Double
        public var velocity: Double
        public var why: String
    }

    public var enabled: Bool
    public var mood: String
    /// The groove for the current mood ("Off" when the mood has none).
    public var groove: String
    /// What the drummer is doing: "playing", "thinning", "resting", "off", "no groove".
    public var phase: String
    public var phaseDetail: String
    public var complexity: Double
    public var complexityBase: Double
    public var complexityFromTraffic: Double
    public var smoothedTraffic: Double
    public var presence: Double
    public var stepsPerBar: Int
    /// Bar the next / current fill is in, and its first step; nil = none planned.
    public var fillBar: Int?
    public var fillStart: Int
    public var fillReason: String
    public var fill: DrumGroove
    public var crashBar: Int?
    /// Every groove as the drummer will play it (custom edits applied, Euclidean built from its params).
    public var grooves: [DrumGroove]
    /// Grooves changed from the built-in version (by name).
    public var customised: [String]
    public var hits: [Hit]
    /// Lane -> MIDI note in the kit map.
    public var notes: [String: Int]
}

// MARK: - Generator

/// The drummer: a one-bar groove per mood whose *feel* follows the data. Total traffic raises the
/// groove's complexity (optional steps and ghost notes fill in), presence decides how much kit is
/// playing, phrase ends and flurries bring fills and crashes, and an idle network thins the groove
/// out and finally rests it. See docs/decisions/0016-drummer.md.
public final class DrumGenerator: Generator {
    public let id = "drums"
    public static let role = "drums"

    /// Grooves edited in the app, replacing built-ins of the same name.
    public var custom: [DrumGroove] = []

    private var smoothed: Double?
    private var lastNow: Double?
    private var lastMood: String?
    private var idleBars = 0
    private var fillBar: Int?
    private var fillReason = ""
    private var crashBar: Int?
    private var crashReason = ""
    private var hits: [DrumStatus.Hit] = []
    private var hitCounter = 0
    private var accentTokens: Double = 0
    private var lastAccentRefill: Double?
    private var currentBar = 0
    private var mood = "quiet"
    private var stepsPerBar = 16

    public init() {}

    public var params: [ParamSpec] {
        var specs = [
            ParamSpec("gen.drums.enabled", kind: .toggle, default: 1,
                      help: "The drummer: a groove for each mood whose feel follows the network. Plays on the drums voice (MIDI channel 10, General MIDI drum notes)."),
            ParamSpec("gen.drums.presence", default: 0.4,
                      help: "How much drum kit there is. Low = a texture of shaker, rim clicks and soft hats under the ambience; middle adds kick and toms; high = a full kit with snare backbeats and crashes that drives the piece. Below the snare's level its hits are played as rim clicks."),
            ParamSpec("gen.drums.complexity", default: 0.3,
                      help: "How busy the groove is before traffic adds to it. 0 = only the always-on hits; 0.5 = optional hits and some ghost notes; 1 = every step written in the groove, including the rare extras."),
            ParamSpec("gen.drums.response", default: 0.4,
                      help: "How much traffic raises complexity. 0 = traffic doesn't change the groove; 0.4 = a busy network adds about 0.3; 1 = from 1 kB/s to 10 MB/s it sweeps the whole range."),
            ParamSpec("gen.drums.smoothing", kind: .continuous, range: 0...60, default: 6, unit: "s",
                      help: "How much traffic is averaged before it changes the groove. Higher = the groove builds and relaxes slowly instead of twitching with every burst."),
            ParamSpec("gen.drums.intensity", default: 0.55, help: "Overall loudness of the drums."),
            ParamSpec("gen.drums.swing", kind: .continuous, range: 0...0.5, default: 0.12,
                      help: "Delays every second 16th for a shuffled feel. 0 = straight; 0.15 = a gentle lilt; 0.33 = a strong swing. Separate from the other voices' swing in Quantise."),
            ParamSpec("gen.drums.humanise", kind: .continuous, range: 0...30, default: 6, unit: "ms",
                      help: "Random timing wobble per hit, in ms. A little makes it sound played rather than programmed."),
            ParamSpec("gen.drums.velocityHumanise", kind: .continuous, range: 0...0.5, default: 0.12,
                      help: "Random loudness variation per hit. 0 = machine-even; 0.1–0.2 = a drummer's natural unevenness."),
            ParamSpec("gen.drums.fills", default: 0.6,
                      help: "Chance of a fill in the last bar of each chord progression (the end of a phrase). A crash follows on the next downbeat if presence allows. Flurries of apps waking always fill."),
            ParamSpec("gen.drums.fillBeats", kind: .integer, range: 1...4, default: 2, unit: "beats",
                      help: "Length of fills, at the end of the bar. 1 = a quick pickup; 4 = a whole bar of fill."),
            ParamSpec("gen.drums.fillStyle", kind: .choice, default: 0, options: DrumGroove.fillStyles,
                      help: "Auto = soft shaker-and-rim fills at low presence, tom fills from presence 0.5. Or pick one: Soft, Toms, Snare roll."),
            ParamSpec("gen.drums.idleBelow", kind: .continuous, range: 0...100_000, default: 3_000, unit: "B/s",
                      help: "When smoothed traffic is below this, the network counts as idle: the drummer drops to the always-on hits and, after 'rest after', stops."),
            ParamSpec("gen.drums.restAfter", kind: .integer, range: 0...64, default: 8, unit: "bars",
                      help: "Bars of idle network before the drummer stops altogether. It comes back on the next bar when traffic returns. 0 = never rest."),
        ]
        for mood in Conductor.Mood.allCases {
            let def: Double = switch mood { case .quiet: 1; case .calm: 2; case .busy: 3; case .focused: 4 }
            specs.append(ParamSpec("gen.drums.groove.\(mood.rawValue)", kind: .choice, default: def, options: DrumGroove.choices,
                                   help: "The groove in the \(mood.rawValue.uppercased()) mood. Shaker = a light texture; Heartbeat = kick pairs and a soft backbeat; Brushes = a steady 16th feel; Halftime = slow and heavy; Broken = syncopated; Euclidean = built from the Euclid settings below. Genre grooves (Four on the floor, Disco, Synthwave, Backbeat, Boom bap, Dubstep, Funk, Breakdown) come with styles and need presence ≥ 0.55 for their snare. Off = no drums in this mood."))
        }
        specs += [
            ParamSpec("gen.drums.accents", kind: .toggle, default: 0,
                      help: "Network events add percussion on the grid: a DNS lookup is a rim click, a reset connection a choked open hat, a LAN announcement a shaker. Needs the packet capture helper."),
            ParamSpec("gen.drums.accentLevel", default: 0.5, help: "Loudness of network-event accents."),
            ParamSpec("gen.drums.accentMax", kind: .continuous, range: 0.25...8, default: 2, unit: "/s",
                      help: "Most accents per second, so a page load doesn't become a drum roll."),
        ]
        let euclidDefaults: [(DrumLane, Int, Int)] = [(.kick, 3, 0), (.rim, 2, 4), (.hat, 7, 0), (.shaker, 5, 2), (.tomLow, 0, 0)]
        for (lane, hits, rotate) in euclidDefaults {
            specs.append(ParamSpec("gen.drums.euclid.\(lane.rawValue).hits", kind: .integer, range: 0...16, default: Double(hits),
                                   help: "Euclidean groove: \(lane.label.lowercased()) hits spread as evenly as possible over the 16 steps. 0 = silent. Route a signal here and the rhythm grows with it."))
            specs.append(ParamSpec("gen.drums.euclid.\(lane.rawValue).rotate", kind: .integer, range: 0...15, default: Double(rotate),
                                   help: "Euclidean groove: turns the \(lane.label.lowercased()) pattern by this many 16ths, so lanes interlock instead of landing together."))
        }
        for lane in DrumLane.allCases {
            specs.append(ParamSpec("gen.drums.level.\(lane.rawValue)", default: lane.defaultLevel,
                                   help: "Loudness of the \(lane.label.lowercased()) (needs presence ≥ \(lane.presenceNeeded.formatted()) to play at all)."))
        }
        for lane in DrumLane.allCases {
            specs.append(ParamSpec("gen.drums.note.\(lane.rawValue)", kind: .integer, range: 0...127, default: Double(lane.gmNote), modulatable: false,
                                   help: "Kit map: the MIDI note for the \(lane.label.lowercased()). \(lane.gmNote) is General MIDI; change it for kits with their own layout."))
        }
        return specs
    }

    // MARK: Grooves

    public func groove(named name: String, params p: ParamStore) -> DrumGroove? {
        if name == DrumGroove.euclidean { return euclidGroove(p) }
        return custom.first { $0.name == name } ?? DrumGroove.builtIn.first { $0.name == name }
    }

    func euclidGroove(_ p: ParamStore) -> DrumGroove {
        var lanes: [DrumLane: String] = [:]
        for lane in [DrumLane.kick, .rim, .hat, .shaker, .tomLow] {
            let hits = p.int("gen.drums.euclid.\(lane.rawValue).hits")
            let rot = p.int("gen.drums.euclid.\(lane.rawValue).rotate")
            let light = lane == .hat || lane == .shaker
            lanes[lane] = DrumGroove.euclid(hits: hits, steps: 16, rotate: rot, symbol: light ? "o" : "x", accent: light ? "x" : "X")
        }
        return DrumGroove(name: DrumGroove.euclidean, lanes: lanes)
    }

    public func grooveName(for mood: String, params p: ParamStore) -> String {
        let i = p.int("gen.drums.groove.\(mood)")
        return DrumGroove.choices[min(max(i, 0), DrumGroove.choices.count - 1)]
    }

    func fillGroove(_ p: ParamStore) -> DrumGroove {
        let style = DrumGroove.fillStyles[min(max(p.int("gen.drums.fillStyle"), 0), DrumGroove.fillStyles.count - 1)]
        let name = style == "Auto" ? (p.value("gen.drums.presence") < 0.5 ? "Soft" : "Toms") : style
        return DrumGroove.fills[name] ?? DrumGroove.fills["Soft"]!
    }

    // MARK: Tick

    public func tick(_ ctx: GeneratorContext, rng: inout SeededRandom) -> GeneratorOutput {
        var out = GeneratorOutput()
        let p = ctx.params
        mood = ctx.mood

        let dt = lastNow.map { max(ctx.now - $0, 0) } ?? 0
        lastNow = ctx.now
        let tau = p.value("gen.drums.smoothing")
        if let s = smoothed, tau > 0 {
            smoothed = s + (ctx.totalRate - s) * (1 - exp(-dt / tau))
        } else {
            smoothed = ctx.totalRate
        }
        guard p.bool("gen.drums.enabled") else { return out }

        let bpb = ctx.clock.beatsPerBar
        let stepsPerBar = bpb * 4
        self.stepsPerBar = stepsPerBar
        let fillSteps = min(p.int("gen.drums.fillBeats") * 4, stepsPerBar)
        let complexity = effectiveComplexity(p)

        // A flurry fills the rest of this bar if there's room, else the end of the next one.
        if ctx.flurry {
            let b = ctx.beats.upperBound
            let bar = Int((b / Double(bpb)).rounded(.down))
            let step = Int(((b - Double(bar * bpb)) * 4).rounded(.down))
            let names = ctx.activations.prefix(2).map(\.key).joined(separator: ", ")
            fillBar = step < stepsPerBar - fillSteps ? bar : bar + 1
            fillReason = "flurry of apps waking\(names.isEmpty ? "" : " (\(names)…)")"
            crashBar = fillBar! + 1
            crashReason = "after the flurry fill"
        }

        for beat in MusicalClock.crossings(of: 0.25, in: ctx.beats) {
            let global = Int((beat * 4).rounded())
            let bar = global / stepsPerBar
            let step = global % stepsPerBar
            if step == 0 { startBar(bar, ctx, rng: &rng) }
            if resting(p) { continue }
            let thinning = idleBars > 0
            let groove = groove(named: grooveName(for: ctx.mood, params: p), params: p)
            let inFill = fillBar == bar && step >= stepsPerBar - fillSteps
            let fill = fillGroove(p)
            var sounded: Set<DrumLane> = [] // a substituted snare mustn't double a rim hit

            for lane in DrumLane.allCases {
                var cell: DrumCell?
                var why: String
                var certain = false
                if lane == .crash, crashBar == bar, step == 0 {
                    cell = DrumCell("X"); why = "crash · \(crashReason)"; certain = true
                } else if inFill, lane != .kick, lane != .hat {
                    cell = fill.cell(lane, 16 - (stepsPerBar - step))
                    why = "\(fill.name.lowercased()) · \(fillReason)"; certain = true
                } else if let g = groove {
                    cell = g.cell(lane, step)
                    why = "\(g.name) step \(step + 1)"
                } else {
                    continue
                }
                guard let c = cell else { continue }
                if !certain {
                    if thinning, !c.isCore { continue }
                    let chance = c.chance(complexity: complexity)
                    guard rng.chance(chance) else { continue }
                    why += c.isCore ? " · always" : String(format: " · %.0f%% chance at complexity %.2f", chance * 100, complexity)
                    if thinning { why += " · network idle, core hits only" }
                }
                emit(lane, cell: c, beat: beat, bar: bar, step: step, why: why, ctx, &out, sounded: &sounded, rng: &rng)
            }
        }

        if p.bool("gen.drums.accents"), !resting(p) { accents(ctx, &out, rng: &rng) }
        return out
    }

    public func effectiveComplexity(_ p: ParamStore) -> Double {
        min(max(p.value("gen.drums.complexity") + p.value("gen.drums.response") * trafficLevel(smoothed ?? 0), 0), 1)
    }

    private func resting(_ p: ParamStore) -> Bool {
        let after = p.int("gen.drums.restAfter")
        return after > 0 && idleBars >= after
    }

    private func startBar(_ bar: Int, _ ctx: GeneratorContext, rng: inout SeededRandom) {
        let p = ctx.params
        currentBar = bar
        idleBars = (smoothed ?? 0) < p.value("gen.drums.idleBelow") ? idleBars + 1 : 0
        if let last = lastMood, last != ctx.mood {
            crashBar = bar
            crashReason = "mood \(last) → \(ctx.mood)"
        }
        lastMood = ctx.mood
        // The last bar of the progression (unless a gesture is about to take over).
        let bpc = max(p.int("harmony.barsPerChord"), 1)
        let lastBar = bar % bpc == bpc - 1 && ctx.progressionIndex == ctx.progressionLength - 1 && !ctx.gesturePending
        if lastBar, fillBar != bar, rng.chance(p.value("gen.drums.fills")) {
            fillBar = bar
            fillReason = "end of the phrase"
            crashBar = bar + 1
            crashReason = "after the phrase fill"
        }
        if let f = fillBar, f < bar { fillBar = nil }
        if let c = crashBar, c < bar { crashBar = nil }
    }

    private func emit(_ requested: DrumLane, cell: DrumCell, beat: Double, bar: Int, step: Int, why: String,
                      _ ctx: GeneratorContext, _ out: inout GeneratorOutput, sounded: inout Set<DrumLane>, rng: inout SeededRandom) {
        let p = ctx.params
        let presence = p.value("gen.drums.presence")
        var lane = requested
        var velocity = cell.velocity
        var why = why
        if presence < lane.presenceNeeded {
            // Below the snare's level its backbeat survives as a rim click.
            guard lane == .snare else { return }
            lane = .rim
            velocity *= 0.8
            why += " · snare played as rim at presence \(presence.formatted(.number.precision(.fractionLength(2))))"
        }
        guard sounded.insert(lane).inserted else { return }
        // Fade a lane in over the 0.15 of presence after it arrives.
        let gain = min((presence - lane.presenceNeeded) / 0.15 * 0.6 + 0.4, 1)
        let jitter = (rng.unit() * 2 - 1) * p.value("gen.drums.velocityHumanise")
        let intensity = min(max(p.value("gen.drums.intensity") * velocity * gain * p.value("gen.drums.level.\(lane.rawValue)")
            * (0.6 + 0.4 * presence) * (1 + jitter), 0), 1)
        guard intensity > 0.005 else { return }
        let swung = beat + (step % 2 == 1 ? p.value("gen.drums.swing") * 0.25 : 0)
        let time = ctx.clock.time(ofBeat: swung) + (rng.unit() * 2 - 1) * p.value("gen.drums.humanise") / 1000
        out.notes.append(NoteIntent(role: Self.role, pitch: .exact(p.int("gen.drums.note.\(lane.rawValue)")), intensity: intensity,
                                    time: time, beats: lane == .crash || lane == .openHat ? 1.5 : 0.12,
                                    essential: true, locked: true, why: "\(lane.label.lowercased()) · \(why)"))
        hitCounter += 1
        hits.append(.init(id: hitCounter, lane: lane.rawValue, bar: bar, step: step, time: time, velocity: intensity,
                          why: "\(lane.label) · \(why)"))
        if hits.count > 64 { hits.removeFirst(hits.count - 64) }
    }

    private func accents(_ ctx: GeneratorContext, _ out: inout GeneratorOutput, rng: inout SeededRandom) {
        let p = ctx.params
        let rate = p.value("gen.drums.accentMax")
        accentTokens = lastAccentRefill.map { min(max(1, rate), accentTokens + (ctx.now - $0) * rate) } ?? max(1, rate)
        lastAccentRefill = ctx.now
        let next = (ctx.clock.beat(atTime: ctx.now) * 4).rounded(.up) / 4
        let stepsPerBar = ctx.clock.beatsPerBar * 4
        for e in ctx.events {
            let plan: [(DrumLane, Character, Double)]
            let name = e.key ?? "?"
            switch e.id {
            case "net.dns.query": plan = [(.rim, "o", 0)]
            case "net.tcp.close" where e.value >= 0.5: plan = [(.openHat, "x", 0), (.hat, "g", 0.25)]
            case "net.lan.announce": plan = [(.shaker, "o", 0)]
            default: continue
            }
            guard accentTokens >= 1 else { continue }
            accentTokens -= 1
            let what = e.id == "net.dns.query" ? "DNS lookup \(name)" : e.id == "net.tcp.close" ? "connection to \(name) reset" : "LAN announcement \(name)"
            for (lane, symbol, offset) in plan {
                var sounded: Set<DrumLane> = []
                guard var cell = DrumCell(symbol) else { continue }
                cell.velocity *= p.value("gen.drums.accentLevel") / 0.5
                let beat = next + offset
                let global = Int((beat * 4).rounded())
                emit(lane, cell: cell, beat: beat, bar: global / stepsPerBar, step: global % stepsPerBar,
                     why: "accent · \(what)", ctx, &out, sounded: &sounded, rng: &rng)
            }
        }
    }

    // MARK: Status

    public func status(params p: ParamStore) -> DrumStatus {
        let fillSteps = min(p.int("gen.drums.fillBeats") * 4, stepsPerBar)
        let name = grooveName(for: mood, params: p)
        let enabled = p.bool("gen.drums.enabled")
        let phase: String, detail: String
        let after = p.int("gen.drums.restAfter")
        if !enabled {
            phase = "off"; detail = "The drummer is switched off."
        } else if name == "Off" {
            phase = "no groove"; detail = "The \(mood) mood has no groove (Off)."
        } else if resting(p) {
            phase = "resting"; detail = "Network idle for \(idleBars) bars (below \(formatRate(p.value("gen.drums.idleBelow")))). Back on the next bar when traffic returns."
        } else if idleBars > 0 {
            phase = "thinning"
            detail = "Network idle for \(idleBars) bar\(idleBars == 1 ? "" : "s"): core hits only\(after > 0 ? ", resting after \(after)" : "")."
        } else {
            phase = "playing"
            let fills = Int((p.value("gen.drums.fills") * 100).rounded())
            detail = "\(fills)% chance of a fill at each phrase end; a crash follows when presence is 0.7 or more."
        }
        var grooves = DrumGroove.builtIn.map { g in custom.first { $0.name == g.name } ?? g }
        grooves.append(euclidGroove(p))
        let base = p.value("gen.drums.complexity")
        let total = effectiveComplexity(p)
        return DrumStatus(
            enabled: enabled, mood: mood, groove: name, phase: phase, phaseDetail: detail,
            complexity: total, complexityBase: base, complexityFromTraffic: max(total - base, 0),
            smoothedTraffic: smoothed ?? 0, presence: p.value("gen.drums.presence"), stepsPerBar: stepsPerBar,
            fillBar: fillBar, fillStart: stepsPerBar - fillSteps, fillReason: fillReason, fill: fillGroove(p),
            crashBar: crashBar, grooves: grooves,
            customised: custom.filter { c in DrumGroove.builtIn.first { $0.name == c.name } != c }.map(\.name),
            hits: hits,
            notes: Dictionary(uniqueKeysWithValues: DrumLane.allCases.map { ($0.rawValue, p.int("gen.drums.note.\($0.rawValue)")) })
        )
    }
}

