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
        ParamSpec("clock.bpm", kind: .continuous, range: 20...200, default: 66, unit: "bpm",
                  help: "Tempo of the musical grid."),
        ParamSpec("harmony.root", kind: .choice, default: 2, options: ScaleCatalogue.rootNames,
                  help: "Key centre."),
        ParamSpec("harmony.scale", kind: .choice, default: 2, options: ScaleCatalogue.names,
                  help: "Scale / mode used by the pitch quantiser and chords."),
        ParamSpec("harmony.chordSize", kind: .integer, range: 1...6, default: 3,
                  help: "Notes per chord (stacked thirds): 3 = triad, 4 = seventh..."),
        ParamSpec("harmony.barsPerChord", kind: .integer, range: 1...16, default: 2,
                  help: "How long each chord lasts."),
        ParamSpec("harmony.hysteresis", kind: .continuous, range: 0...300, default: 10, unit: "s",
                  help: "A new mood must persist this long before the progression changes."),
        ParamSpec("harmony.changeOnPhrase", kind: .toggle, default: 1,
                  help: "Wait for the current progression to finish before switching to a new one."),
        ParamSpec("conductor.smoothing", kind: .continuous, range: 0...120, default: 8, unit: "s",
                  help: "Time constant for smoothing traffic before classifying the mood (bursty data flips less)."),
        ParamSpec("conductor.quietBelow", kind: .continuous, range: 0...1_000_000, default: 8_000, unit: "B/s",
                  help: "Total rate under which the mood is 'quiet'."),
        ParamSpec("conductor.busyAbove", kind: .continuous, range: 1_000...100_000_000, default: 1_500_000, unit: "B/s",
                  help: "Total rate over which the mood is 'busy' (or 'focused')."),
        ParamSpec("conductor.focusRatio", kind: .continuous, range: 0.3...1, default: 0.7,
                  help: "Share of traffic one app needs for the mood to be 'focused'."),
        ParamSpec("conductor.flurryApps", kind: .integer, range: 2...20, default: 3,
                  help: "This many app activations within the flurry window trigger the flurry gesture."),
        ParamSpec("conductor.flurryWindow", kind: .continuous, range: 0.5...60, default: 4, unit: "s",
                  help: "Window for counting activations towards a flurry."),
        ParamSpec("conductor.flurryCooldown", kind: .continuous, range: 0...600, default: 60, unit: "s",
                  help: "Minimum time between flurry gestures."),
    ]

    public var progressions: [Mood: [Int]]
    /// Degree sequences inserted ahead of the progression when a gesture fires.
    public var gestures: [String: [Int]]

    public private(set) var mood: Mood = .quiet
    /// The smoothed total the mood is classified from.
    public var smoothedRate: Double { smoothedTotal ?? 0 }
    public private(set) var progressionIndex = 0
    public private(set) var chordDegree = 0
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
            recentActivations.removeAll()
            notes.append("flurry of \(p.int("conductor.flurryApps"))+ apps → gesture \(gesture)")
        }
        return notes
    }

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
        .quiet: [0, 3],             // i  iv   — slow breathing
        .calm: [0, 5, 3, 4],        // i  VI iv v
        .busy: [0, 4, 5, 3, 0, 6],  // more motion
        .focused: [0, 0, 6, 6],     // pedal-like, one thing dominates
    ]

    public static let defaultGestures: [String: [Int]] = [
        "flurry": [4, 0],           // v → i cadence when lots of apps wake at once
    ]
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
