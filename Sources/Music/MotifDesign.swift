import Foundation

/// A hand-designed motif for apps (or, later, traffic types / devices) whose name matches.
///
/// Steps are written in *scale steps* above an anchor (the current chord's root, or the key's
/// tonic), not in raw pitches, so a designed motif always stays in key and follows the harmony.
/// `nil` steps are rests (silence, but the rhythm continues).
public struct MotifDesign: Codable, Sendable, Equatable, Identifiable {
    public enum Anchor: String, Codable, Sendable, CaseIterable {
        /// Step 0 = root of whatever chord is playing (motif moves with the harmony).
        case chord
        /// Step 0 = the key's home note (motif keeps the same notes whatever the chord).
        case key
    }

    public var id: String
    /// "*" = every app without a more specific design; otherwise matched against the app name,
    /// ignoring case: an exact name beats a "contains" match.
    public var match: String
    public var steps: [Int?]
    public var anchor: Anchor
    /// Beats between steps; nil uses `gen.motif.stepBeats`.
    public var stepBeats: Double?
    /// Register; nil uses `gen.motif.octave`.
    public var octave: Int?

    public init(id: String = UUID().uuidString, match: String, steps: [Int?], anchor: Anchor = .chord,
                stepBeats: Double? = nil, octave: Int? = nil) {
        self.id = id
        self.match = match
        self.steps = steps
        self.anchor = anchor
        self.stepBeats = stepBeats
        self.octave = octave
    }

    /// 0 = no match, 1 = wildcard, 2 = name contains, 3 = exact name.
    public func matchScore(_ app: String) -> Int {
        let m = match.trimmingCharacters(in: .whitespaces)
        if m == "*" { return 1 }
        guard !m.isEmpty else { return 0 }
        if app.caseInsensitiveCompare(m) == .orderedSame { return 3 }
        return app.localizedCaseInsensitiveContains(m) ? 2 : 0
    }

    /// The best design for an app, if any.
    public static func best(for app: String, in designs: [MotifDesign]) -> MotifDesign? {
        designs.map { ($0, $0.matchScore(app)) }.filter { $0.1 > 0 }.max { $0.1 < $1.1 }?.0
    }

    /// Random steps for "see what comes up". A gentle random walk (so it sounds like a melody, not
    /// noise) over chord-note steps (0, 2, 4, 7, 9, 11 above a chord root) or any scale step, with the
    /// odd rest. Always starts on step 0 so it's anchored.
    public static func randomSteps<R: RandomNumberGenerator>(count: Int, chordNotesOnly: Bool,
                                                            using rng: inout R) -> [Int?] {
        let pool = chordNotesOnly ? [-3, 0, 2, 4, 7, 9, 11] : Array(-3...11)
        var index = pool.firstIndex(of: 0) ?? 0
        var out: [Int?] = [0]
        while out.count < max(count, 1) {
            if Double.random(in: 0..<1, using: &rng) < 0.15 {
                out.append(nil)
                continue
            }
            let move = [-2, -1, -1, 0, 1, 1, 2].randomElement(using: &rng) ?? 0
            index = min(max(index + move, 0), pool.count - 1)
            out.append(pool[index])
        }
        return out
    }

    /// Turn concrete pitches (e.g. what a generated motif plays right now) into the nearest scale
    /// steps above the key tonic at `octave`.
    public static func fromPitches(app: String, pitches: [Int?], octave: Int, harmony: HarmonyContext) -> MotifDesign {
        let candidates = (-14...28).map { ($0, harmony.note(degree: $0, octave: octave)) }
        let steps: [Int?] = pitches.map { p in
            p.flatMap { target in candidates.min { abs($0.1 - target) < abs($1.1 - target) }?.0 }
        }
        return MotifDesign(match: app, steps: steps, anchor: .key, octave: octave)
    }

    /// Turn a generated (chromatic) motif into the nearest scale steps above the key tonic, so it
    /// can be edited. Useful for keeping an app's character but fixing a clashing note.
    public static func fromGenerated(app: String, length: Int, range: Int, octave: Int, harmony: HarmonyContext, seed: Int = 0) -> MotifDesign {
        let shape = MotifGenerator.shape(for: app, length: length, range: range, seed: seed)
        let centre = 12 * (octave + 1) + harmony.root + shape.start
        let steps: [Int?] = shape.offsets.map { offset in
            let target = centre + offset
            // Nearest scale degree to the target pitch, relative to the tonic at `octave`.
            let candidates = (-14...28).map { ($0, harmony.note(degree: $0, octave: octave)) }
            return candidates.min { abs($0.1 - target) < abs($1.1 - target) }?.0
        }
        return MotifDesign(match: app, steps: steps, anchor: .key, octave: octave)
    }
}
