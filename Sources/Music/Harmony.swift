import Foundation
import Tonic

/// Scales offered by the `harmony.scale` choice param. Order matters: scenes store the index.
public enum ScaleCatalogue {
    public static let scales: [Scale] = [
        .major, .minor, .dorian, .phrygian, .lydian, .mixolydian, .locrian,
        .harmonicMinor, .melodicMinor, .pentatonicMajor, .pentatonicMinor,
        .whole, .chromatic,
    ]

    public static var names: [String] { scales.map(\.description) }

    /// Index = semitones above C.
    public static let rootNames = ["C", "C♯/D♭", "D", "D♯/E♭", "E", "F", "F♯/G♭", "G", "G♯/A♭", "A", "A♯/B♭", "B"]
}

/// Key, scale and current chord, resolved to MIDI-note arithmetic.
///
/// Chords are built by stacking every other scale degree (thirds in a 7-note scale), which
/// works for any scale in the catalogue, including pentatonic and whole-tone.
public struct HarmonyContext: Sendable, Equatable {
    public var root: Int
    /// Semitone offsets from the root, ascending, starting at 0.
    public var scaleSteps: [Int]
    /// Current chord as a scale-degree index (0 = tonic).
    public var chordDegree: Int
    public var chordSize: Int

    public init(root: Int, scaleSteps: [Int], chordDegree: Int = 0, chordSize: Int = 3) {
        self.root = ((root % 12) + 12) % 12
        self.scaleSteps = scaleSteps.isEmpty ? [0] : scaleSteps
        self.chordDegree = chordDegree
        self.chordSize = max(1, chordSize)
    }

    public init(root: Int, scale: Scale, chordDegree: Int = 0, chordSize: Int = 3) {
        let steps = Array(Set(scale.intervals.map { $0.semitones % 12 })).sorted()
        self.init(root: root, scaleSteps: steps, chordDegree: chordDegree, chordSize: chordSize)
    }

    /// MIDI note for a scale degree, where degree 0 at octave 4 is the root near middle C.
    /// Degrees outside 0..<count wrap into neighbouring octaves.
    public func note(degree: Int, octave: Int = 4) -> Int {
        let n = scaleSteps.count
        let wrapped = ((degree % n) + n) % n
        let octaveShift = Int((Double(degree) / Double(n)).rounded(.down))
        return 12 * (octave + 1 + octaveShift) + root + scaleSteps[wrapped]
    }

    /// Degrees of the current chord (stacked thirds from chordDegree).
    public var chordDegrees: [Int] {
        (0..<chordSize).map { chordDegree + 2 * $0 }
    }

    /// Pitch classes (0...11) in the current scale.
    public var scalePitchClasses: Set<Int> {
        Set(scaleSteps.map { (root + $0) % 12 })
    }

    /// Pitch classes in the current chord.
    public var chordPitchClasses: Set<Int> {
        Set(chordDegrees.map { ((note(degree: $0) % 12) + 12) % 12 })
    }

    /// The chord tone `index` (0 = chord root) at the given octave; indexes beyond the
    /// chord size climb into higher octaves.
    public func chordTone(_ index: Int, octave: Int) -> Int {
        let size = chordDegrees.count
        let i = ((index % size) + size) % size
        let up = Int((Double(index) / Double(size)).rounded(.down))
        return note(degree: chordDegrees[i], octave: octave + up)
    }

    /// Nearest MIDI note whose pitch class is in `classes` (ties go down).
    public static func nearest(_ pitch: Double, in classes: Set<Int>) -> Int {
        let centre = Int(pitch.rounded())
        guard !classes.isEmpty else { return centre }
        var best = centre
        var bestDistance = Double.infinity
        for candidate in (centre - 12)...(centre + 12) where classes.contains(((candidate % 12) + 12) % 12) {
            let d = abs(Double(candidate) - pitch)
            if d < bestDistance { best = candidate; bestDistance = d }
        }
        return best
    }
}

/// Deterministic RNG so a scene + seed sounds recognisably the same run to run.
public struct SeededRandom: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    /// SplitMix64.
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    public mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }

    public mutating func chance(_ p: Double) -> Bool { unit() < p }
}

/// Stable string hash (FNV-1a). Swift's `Hasher` is randomised per process, which would give
/// an app a different motif every launch.
public func stableHash(_ s: String) -> UInt64 {
    var h: UInt64 = 0xCBF2_9CE4_8422_2325
    for byte in s.utf8 {
        h ^= UInt64(byte)
        h &*= 0x0000_0100_0000_01B3
    }
    return h
}
