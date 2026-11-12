import Foundation
import MIDIOut
import Music
import Params
import Router
import SignalBus

/// Owns the clock and runs the pipeline on one serial queue:
///
///   sources -> SignalBus -> ModMatrix -> Conductor + Generators -> Quantiser -> Router -> Scheduler -> sink
///
/// All mutable state is confined to `queue`; sources hop onto it to post samples.
public final class Engine: @unchecked Sendable {
    public let params = ParamStore()
    public let bus = SignalBus()
    public let queue = DispatchQueue(label: "msg.engine", qos: .userInteractive)

    public var log: (String) -> Void = { print($0) }
    /// Log every note (dry-run / verbose).
    public var logNotes = false

    private let scene: Scene
    private let modMatrix: ModMatrix
    private let conductor: Conductor
    private let generators: [Generator]
    private let router: VoiceRouter
    private let scheduler: NoteScheduler
    private var quantiser = Quantiser()
    private var activity = ActivityTracker()
    private var clock = MusicalClock()
    private var rng: SeededRandom
    private var sources: [SignalSource] = []
    private var timer: DispatchSourceTimer?
    private let startTime = DispatchTime.now().uptimeNanoseconds
    private var lastTick: Double = 0
    private var seenAppVersion = 0
    private var lastStatus: Double = 0
    private var firstTick = true

    public static let tickInterval: Double = 0.005
    /// Generators look this far ahead so notes are scheduled before they're due.
    public static let lookahead: Double = 0.05

    public init(scene: Scene, sink: MIDISink) throws {
        self.scene = scene
        rng = SeededRandom(seed: scene.seed)
        modMatrix = ModMatrix(routes: scene.routes)
        var progressions: [Conductor.Mood: [Int]] = Conductor.defaultProgressions
        for (k, v) in scene.progressions {
            guard let mood = Conductor.Mood(rawValue: k) else { throw ParamError.unknown("progressions.\(k)") }
            progressions[mood] = v
        }
        conductor = Conductor(progressions: progressions, gestures: scene.gestures)
        generators = [DroneGenerator(), MotifGenerator(), PulseGenerator()]
        router = VoiceRouter(voices: scene.voices)
        scheduler = NoteScheduler(sink: sink)

        params.register(Conductor.params)
        params.register(Quantiser.params)
        params.register(ActivityTracker.params)
        for g in generators { params.register(g.params) }
        router.registerParams(in: params)
        modMatrix.registerParams(in: params)
        for m in scene.macros {
            params.register(ParamSpec(m.id, default: 0.5, modulatable: false, help: m.help))
        }

        for (id, value) in scene.params.sorted(by: { $0.key < $1.key }) where !id.hasPrefix("macro.") {
            try params.set(id, value)
        }
        // Macros only apply if the scene sets them explicitly, so a scene's own values win.
        for (id, value) in scene.params where id.hasPrefix("macro.") {
            try setParam(id, value)
        }
    }

    /// Set a parameter (or macro) by id. Call on `queue` once running.
    public func setParam(_ id: String, _ value: Double) throws {
        try params.set(id, value)
        if let macro = scene.macros.first(where: { $0.id == id }) {
            try macro.apply(params.value(id), to: params)
        }
    }

    public var now: Double { Double(DispatchTime.now().uptimeNanoseconds - startTime) / 1e9 }

    public func add(_ source: SignalSource) { sources.append(source) }

    public func start() throws {
        for s in sources {
            try s.start { [weak self] samples in
                guard let self else { return }
                self.queue.async { self.bus.post(samples, at: self.now) }
            }
        }
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        t.schedule(deadline: .now(), repeating: Self.tickInterval, leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.tick() }
        lastTick = now
        t.resume()
        timer = t
        log("engine started: \(params.order.count) params, sources: \(sources.map(\.name).joined(separator: ", "))")
    }

    /// Stop sources, release all notes. Blocks until done.
    public func stop() {
        sources.forEach { $0.stop() }
        queue.sync {
            timer?.cancel()
            timer = nil
            scheduler.panic()
        }
    }

    // MARK: - Tick

    private func tick() {
        let t = now
        let dt = max(t - lastTick, 0)
        lastTick = t

        modMatrix.apply(to: params, dt: dt) { [bus] in bus.value($0) }

        // Look ahead: generators work on the musical time slightly in the future so the
        // scheduler holds notes before they're due.
        let horizon = t + Self.lookahead
        let beats = clock.advance(to: horizon, bpm: params.value("clock.bpm"))

        // Fresh per-app data -> activations + mood.
        var activations: [Activation] = []
        let total = bus.value("net.total.bytesPerSec") ?? 0
        if let v = bus.streamVersion["net.app.bytesPerSec"], v != seenAppVersion {
            seenAppVersion = v
            let rates = bus.streams["net.app.bytesPerSec"] ?? [:]
            activations = activity.update(rates: rates, now: horizon, params: params, ignore: Set(scene.ignoreApps))
            for line in conductor.observe(total: total, perApp: rates, activations: activations, now: t, params: params) {
                log("♪ \(line)")
            }
        }
        _ = bus.drainEvents() // no event-producing sources yet; keep the buffer bounded

        var chordChanged = false
        for barBeat in MusicalClock.crossings(of: Double(clock.beatsPerBar), in: beats) {
            let bar = Int((barBeat / Double(clock.beatsPerBar)).rounded())
            let before = conductor.mood
            if conductor.onBar(bar, now: t, params: params) { chordChanged = true }
            if conductor.mood != before { log("♪ mood \(before.rawValue) → \(conductor.mood.rawValue)") }
        }
        if firstTick { chordChanged = true; firstTick = false } // sound the first chord immediately

        let harmony = conductor.harmony(params)
        if chordChanged, logNotes {
            let names = harmony.chordDegrees.map { noteName(harmony.note(degree: $0)).dropLast() }
            log("♪ chord \(harmony.chordDegree + 1) [\(names.joined(separator: " "))] mood=\(conductor.mood.rawValue)")
        }

        let ctx = GeneratorContext(now: horizon, clock: clock, beats: beats, harmony: harmony, params: params,
                                   chordChanged: chordChanged, activations: activations, totalRate: total)
        for g in generators {
            let out = g.tick(ctx, rng: &rng)
            for intent in out.notes {
                guard let resolved = quantiser.resolve(intent, harmony: harmony, clock: clock, params: params, rng: &rng),
                      let routed = router.route(resolved, params: params) else { continue }
                scheduler.schedule(routed)
                if logNotes {
                    log("\(String(format: "%8.2f", routed.start))s \(routed.role.padding(5)) ch\(String(routed.channel + 1).padding(2)) "
                        + "\(noteName(routed.note).padding(4)) v\(String(routed.velocity).padding(3)) "
                        + "\(String(format: "%.2f", routed.duration))s  \(routed.why)")
                }
            }
            for control in out.controls {
                if let routed = router.route(control, params: params) { scheduler.schedule(routed) }
            }
        }

        scheduler.fire(now: t)

        if t - lastStatus >= 10 {
            lastStatus = t
            let top = (bus.streams["net.app.bytesPerSec"] ?? [:]).sorted { $0.value > $1.value }.prefix(3)
                .map { "\($0.key) \(formatRate($0.value))" }.joined(separator: ", ")
            log("· total \(formatRate(total)) (smoothed \(formatRate(conductor.smoothedRate))) | mood \(conductor.mood.rawValue) | sounding \(scheduler.soundingCount) | \(top)")
        }
    }
}

extension String {
    func padding(_ width: Int) -> String {
        count >= width ? self : self + String(repeating: " ", count: width - count)
    }
}
