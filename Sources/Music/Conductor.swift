import Foundation
import Params
import Tonic

/// The slow, harmonic layer. Classifies the network "mood" into a state, picks the chord
/// progression for that state, and changes chords only on bar boundaries, with hysteresis
/// (docs/decisions/0006-harmony-changes-on-boundaries.md).
public final class Conductor: @unchecked Sendable {
    public enum Mood: String, CaseIterable, Codable, Sendable {
        /// Almost nothing on the wire.
        case quiet
        /// Some traffic, spread across apps.
        case calm
        /// Lots of traffic, spread across apps.
        case busy
        /// One app dominates (streaming, a big download).
        case focused
    }

    public static let params: [ParamSpec] = [
        ParamSpec("conductor.introBars", kind: .integer, range: 0...16, default: 4, unit: "bars", modulatable: false,
                  help: "How the piece begins: over these bars it builds up (the pad first, then bass, then pulse and drums, which land with a fill), and the apps' motifs come in once it's going. 0 = everything from the first beat."),
        ParamSpec("conductor.introAfterPause", kind: .toggle, default: 0, modulatable: false,
                  help: "Build up again with the intro after a pause, instead of carrying straight on."),
        ParamSpec("clock.bpm", kind: .continuous, range: 20...200, default: 66, unit: "bpm",
                  help: "Speed of the musical grid everything snaps to. Lower feels more ambient and spacious; it also slows chord changes, since those are counted in bars."),
        ParamSpec("harmony.root", kind: .choice, default: 2, options: ScaleCatalogue.rootNames,
                  help: "The key's home note. Changes the pitch of everything at once; the mood and shape of the music stay the same."),
        ParamSpec("harmony.scale", kind: .choice, default: 2, options: ScaleCatalogue.names,
                  help: "Which notes are 'allowed'. Sets the colour: Major bright, Minor sad, Dorian wistful (default), Lydian dreamy, Phrygian dark, the pentatonics can't clash, Whole tone floats, Chromatic means anything goes."),
        ParamSpec("harmony.chordSize", kind: .integer, range: 1...6, default: 3,
                  help: "Notes in each chord. 3 = plain triads, 4 = sevenths (jazzier, lusher), 5–6 = big ambiguous clusters. Affects the pad and which tones the bass and quantiser use."),
        ParamSpec("harmony.barsPerChord", kind: .integer, range: 1...16, default: 2,
                  help: "How long each chord lasts. 1 = restless, 2 = default, 4–8 = slow ambient drift."),
        ParamSpec("harmony.hysteresis", kind: .continuous, range: 0...300, default: 10, unit: "s",
                  help: "How long the network must stay in a new mood before the music follows. Short = the harmony reacts quickly to bursts; long = it only changes for sustained shifts."),
        ParamSpec("harmony.changeOnPhrase", kind: .toggle, default: 1,
                  help: "On: a new mood waits until the current chord progression finishes (smooth, musical). Off: switches at the next chord (more responsive, can feel abrupt)."),
        ParamSpec("conductor.smoothing", kind: .continuous, range: 0...120, default: 8, unit: "s",
                  help: "How much traffic is averaged before choosing a mood, in seconds. Higher ignores brief spikes (calmer harmony); lower reacts to every burst."),
        ParamSpec("conductor.quietBelow", kind: .continuous, range: 0...1_000_000, default: 8_000, unit: "B/s",
                  help: "Mood threshold. When smoothed total traffic is below this, the mood is QUIET and the slow two-chord quiet progression plays. Raise it to stay in quiet more often."),
        ParamSpec("conductor.busyAbove", kind: .continuous, range: 1_000...100_000_000, default: 1_500_000, unit: "B/s",
                  help: "Mood threshold. When smoothed traffic is above this, the mood is BUSY (more chords, more motion) or FOCUSED if one app dominates. Between this and 'quiet below' the mood is CALM."),
        ParamSpec("conductor.focusRatio", kind: .continuous, range: 0.3...1, default: 0.7,
                  help: "When the network is busy and one app has at least this share of the traffic (streaming, a big download), the mood is FOCUSED: a pedal-like progression that sits still. Lower it to get focused more readily."),
        ParamSpec("conductor.flurryApps", kind: .integer, range: 2...20, default: 3,
                  help: "When this many apps wake up within the flurry window, the music plays a cadence (v → i), a little 'arrival' gesture. Lower = more frequent gestures."),
        ParamSpec("conductor.flurryWindow", kind: .continuous, range: 0.5...60, default: 4, unit: "s",
                  help: "Time window for counting apps waking up towards a flurry."),
        ParamSpec("conductor.flurryCooldown", kind: .continuous, range: 0...600, default: 60, unit: "s",
                  help: "Minimum time between two flurry cadences, so gestures stay special."),
    ]

    public var progressions: [Mood: [Int]]
    /// Moods whose progression was picked by hand (a song, typed chords, edited chips): variations
    /// and styles leave these chords alone.
    public var pinned: Set<Mood> = []
    /// Degree sequences inserted ahead of the progression when a gesture fires.
    public var gestures: [String: [Int]]

    public private(set) var mood: Mood = .quiet
    /// The smoothed total the mood is classified from.
    public var smoothedRate: Double { smoothedTotal ?? 0 }
    public private(set) var progressionIndex = 0
    public private(set) var chordDegree = 0
    /// A gesture is queued for the next chord boundaries.
    public var gesturePending: Bool { !gestureQueue.isEmpty }
    /// Chords in the current mood's progression.
    public var progressionLength: Int { max(progressions[mood]?.count ?? 1, 1) }
    /// Bumped every time a flurry fires.
    public private(set) var flurries = 0
    private var candidate: Mood = .quiet
    private var candidateSince: Double = 0
    private var gestureQueue: [Int] = []
    private var recentActivations: [Double] = []
    private var lastFlurry: Double = -.infinity
    private var smoothedTotal: Double?
    private var smoothedApps: [String: Double] = [:]
    private var lastObserve: Double?

    public init(progressions: [Mood: [Int]], gestures: [String: [Int]]) {
        self.progressions = progressions
        self.gestures = gestures
        chordDegree = progressions[.quiet]?.first ?? 0
    }

    public func harmony(_ p: ParamStore) -> HarmonyContext {
        HarmonyContext(root: p.int("harmony.root"),
                       scale: ScaleCatalogue.scales[p.int("harmony.scale")],
                       chordDegree: chordDegree,
                       chordSize: p.int("harmony.chordSize"))
    }

    public func classify(total: Double, perApp: [String: Double], params p: ParamStore) -> Mood {
        if total < p.value("conductor.quietBelow") { return .quiet }
        let top = perApp.values.max() ?? 0
        if total >= p.value("conductor.busyAbove") {
            return top / max(total, 1) >= p.value("conductor.focusRatio") ? .focused : .busy
        }
        return .calm
    }

    /// Feed the latest traffic picture. Cheap; call whenever new data arrives.
    public func observe(total: Double, perApp: [String: Double], activations: [Activation],
                        now: Double, params p: ParamStore) -> [String] {
        var notes: [String] = []
        let tau = p.value("conductor.smoothing")
        let dt = now - (lastObserve ?? now)
        lastObserve = now
        let alpha = tau <= 0 || smoothedTotal == nil ? 1 : 1 - exp(-dt / tau)
        smoothedTotal = (smoothedTotal ?? total) + (total - (smoothedTotal ?? total)) * alpha
        for key in Set(perApp.keys).union(smoothedApps.keys) {
            let old = smoothedApps[key] ?? 0
            smoothedApps[key] = old + ((perApp[key] ?? 0) - old) * alpha
        }
        let next = classify(total: smoothedTotal ?? total, perApp: smoothedApps, params: p)
        if dt == 0, recentActivations.isEmpty, progressionIndex <= 0, next != mood {
            // The first reading: start in the mood the network is in, rather than in "quiet" and
            // drifting there a phrase or two later.
            mood = next
            candidate = next
            candidateSince = now
            notes.append("starting in the \(next.rawValue) mood")
        }
        if next != candidate {
            candidate = next
            candidateSince = now
        }

        let window = p.value("conductor.flurryWindow")
        recentActivations.append(contentsOf: activations.map(\.time))
        recentActivations.removeAll { now - $0 > window }
        if recentActivations.count >= p.int("conductor.flurryApps"), now - lastFlurry >= p.value("conductor.flurryCooldown"),
           let gesture = gestures["flurry"], !gesture.isEmpty {
            gestureQueue.append(contentsOf: gesture)
            lastFlurry = now
            flurries += 1
            recentActivations.removeAll()
            notes.append("flurry of \(p.int("conductor.flurryApps"))+ apps → gesture \(gesture)")
        }
        return notes
    }

    /// Start the current mood's progression again from its first chord (after a variation).
    public func restartPhrase() {
        gestureQueue.removeAll()
        progressionIndex = -1
        chordDegree = progressions[mood]?.first ?? 0
    }

    /// Jump to a chord now (audition). The progression carries on from where it was at the
    /// next chord boundary.
    public func force(chord degree: Int) { chordDegree = degree }

    /// Call on every bar line. Returns true on a chord boundary (even if the new chord has the
    /// same degree, so pads re-articulate).
    public func onBar(_ bar: Int, now: Double, params p: ParamStore) -> Bool {
        guard bar % max(p.int("harmony.barsPerChord"), 1) == 0 else { return false }

        if !gestureQueue.isEmpty {
            chordDegree = gestureQueue.removeFirst()
            // A finished gesture (e.g. a cadence) ends the phrase: the progression restarts
            // afterwards, which is also a point where the mood may change.
            if gestureQueue.isEmpty { progressionIndex = -1 }
            return true
        }

        let progression = progressions[mood] ?? [0]
        var nextIndex = (progressionIndex + 1) % max(progression.count, 1)
        let moodReady = candidate != mood && now - candidateSince >= p.value("harmony.hysteresis")
        if moodReady, !p.bool("harmony.changeOnPhrase") || nextIndex == 0 {
            mood = candidate
            nextIndex = 0
        }
        progressionIndex = nextIndex
        chordDegree = (progressions[mood] ?? [0])[safe: progressionIndex] ?? 0
        return true
    }

    public static let defaultProgressions: [Mood: [Int]] = [
        // Degrees are scale steps (0 = tonic); chords are stacked thirds, so the quality depends
        // on the scale. Names below are for the default D Dorian. Avoids degree 5 (B° in Dorian).
        .quiet: [0, 3],             // Dm G        i IV      — slow breathing
        .calm: [0, 6, 3, 4],        // Dm C G Am   i VII IV v
        .busy: [0, 4, 2, 3, 0, 6],  // Dm Am F G Dm C — more motion
        .focused: [0, 0, 6, 6],     // Dm Dm C C   — pedal-like, one thing dominates
    ]

    public static let defaultGestures: [String: [Int]] = [
        "flurry": [4, 0],           // v → i cadence when lots of apps wake at once
    ]
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
