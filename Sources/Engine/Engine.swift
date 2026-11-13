import Foundation
import MIDIOut
import Music
import Params
import Router
import SignalBus
import Sources

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
    /// When set, every batch of incoming samples is also written here (see `SignalRecorder`).
    public var recorder: SignalRecorder?
    /// Log every note (dry-run / verbose).
    public var logNotes = false

    private var scene: Scene
    private let modMatrix: ModMatrix
    private let conductor: Conductor
    private let generators: [Generator]
    private var router: VoiceRouter
    private let scheduler: NoteScheduler
    private let parameterisedSink: ParameterisedSink?
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
    private var lastPublish: Double = 0
    private var recentNotes: [EngineStatus.PlayedNote] = []
    private var noteCounter = 0
    private var unroutedRoles: Set<String> = []
    private var chordHistory: [EngineStatus.ChordEvent] = []
    private var auditionPending = false
    private let motif = MotifGenerator()
    private let packets = PacketGenerator()
    private let drums = DrumGenerator()
    private var seenFlurries = 0
    private var netEvents: [EngineStatus.NetEvent] = []
    private var netEventCounter = 0
    private var captureVersion = 0
    private var capture: EngineStatus.Capture?
    private var pendingPreviews: [Activation] = []
    private var appStats: [String: (wakes: Int, last: Double)] = [:]
    /// Seconds between status snapshots. A UI slows this down while it isn't visible. Engine queue only.
    public var statusInterval: Double = 0.1
    /// Called on the engine queue about 10× a second with a snapshot (for UIs).
    public var onStatus: (@Sendable (EngineStatus) -> Void)?

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
        motif.designs = scene.motifs
        drums.custom = scene.grooves
        generators = [DroneGenerator(), motif, PulseGenerator(), BassGenerator(), SubDroneGenerator(), packets, drums]
        router = VoiceRouter(voices: scene.voices)
        scheduler = NoteScheduler(sink: sink)
        parameterisedSink = sink as? ParameterisedSink

        params.register(Conductor.params)
        params.register(Quantiser.params)
        params.register(ActivityTracker.params)
        for g in generators { params.register(g.params) }
        router.registerParams(in: params)
        parameterisedSink?.registerParams(in: params)
        modMatrix.registerParams(in: params)
        for m in scene.macros {
            params.register(ParamSpec(m.id, default: 0.5, modulatable: false, help: m.help))
        }

        for (id, value) in scene.params.sorted(by: { $0.key < $1.key }) where !id.hasPrefix("macro.") {
            // Hosted-instrument params only exist when the instruments are loaded (not in --dry-run).
            if id.hasPrefix("au.") || id.hasPrefix("mix."), params.specs[id] == nil { continue }
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
                self.queue.async {
                    let t = self.now
                    self.recorder?.record(samples, at: t)
                    self.bus.post(samples, at: t)
                }
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
            recorder?.close()
        }
    }

    // MARK: - Tick

    private func tick() {
        let t = now
        let dt = max(t - lastTick, 0)
        lastTick = t

        modMatrix.apply(to: params, dt: dt) { [bus] in bus.value($0) }
        parameterisedSink?.applyParams(params)

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
        let events = bus.drainEvents()
        if let v = bus.streamVersion["net.capture.active"], v != captureVersion {
            captureVersion = v
            capture = .init(interface: bus.streams["net.capture.active"]?.keys.sorted().first ?? "?", lastSeen: t,
                            packetsPerSecond: bus.value("net.pkt.perSec") ?? 0)
        }
        for a in activations { appStats[a.key, default: (0, 0)] = (appStats[a.key, default: (0, 0)].wakes + 1, t) }
        activations += pendingPreviews.map { var a = $0; a.time = horizon; return a }
        pendingPreviews.removeAll()

        var chordChanged = false
        for barBeat in MusicalClock.crossings(of: Double(clock.beatsPerBar), in: beats) {
            let bar = Int((barBeat / Double(clock.beatsPerBar)).rounded())
            let before = conductor.mood
            if conductor.onBar(bar, now: t, params: params) { chordChanged = true }
            if conductor.mood != before { log("♪ mood \(before.rawValue) → \(conductor.mood.rawValue)") }
        }
        if firstTick { chordChanged = true; firstTick = false } // sound the first chord immediately
        if auditionPending { chordChanged = true; auditionPending = false }

        let harmony = conductor.harmony(params)
        if chordChanged {
            chordHistory.append(.init(time: horizon, name: harmony.chordName(degree: harmony.chordDegree),
                                      numeral: harmony.romanNumeral(degree: harmony.chordDegree),
                                      mood: conductor.mood.rawValue))
            if chordHistory.count > 32 { chordHistory.removeFirst(chordHistory.count - 32) }
        }
        if chordChanged, logNotes {
            let names = harmony.chordDegrees.map { noteName(harmony.note(degree: $0)).dropLast() }
            log("♪ chord \(harmony.chordDegree + 1) [\(names.joined(separator: " "))] mood=\(conductor.mood.rawValue)")
        }

        let flurry = conductor.flurries != seenFlurries
        seenFlurries = conductor.flurries
        let ctx = GeneratorContext(now: horizon, clock: clock, beats: beats, harmony: harmony, params: params,
                                   chordChanged: chordChanged, activations: activations, totalRate: total,
                                   events: events, mood: conductor.mood.rawValue,
                                   progressionIndex: conductor.progressionIndex,
                                   progressionLength: conductor.progressionLength,
                                   gesturePending: conductor.gesturePending, flurry: flurry)
        for g in generators {
            let out = g.tick(ctx, rng: &rng)
            for intent in out.notes {
                guard router.voices[intent.role] != nil else {
                    if unroutedRoles.insert(intent.role).inserted {
                        log("⚠︎ the \(intent.role) generator is playing but this scene has no \"\(intent.role)\" voice — add one to hear it")
                    }
                    continue
                }
                guard let resolved = quantiser.resolve(intent, harmony: harmony, clock: clock, params: params, rng: &rng),
                      let routed = router.route(resolved, params: params) else { continue }
                scheduler.schedule(routed)
                noteCounter += 1
                var rawPitch: Double?
                if case .raw(let p) = intent.pitch { rawPitch = p }
                recentNotes.append(.init(id: noteCounter, time: routed.start, role: routed.role, note: routed.note,
                                         velocity: routed.velocity, why: routed.why, duration: routed.duration,
                                         rawTime: intent.time, rawPitch: rawPitch, intensity: intent.intensity,
                                         motif: intent.motif))
                if recentNotes.count > 800 { recentNotes.removeFirst(recentNotes.count - 800) }
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

        for d in packets.drainDecisions() {
            netEventCounter += 1
            netEvents.append(.init(id: netEventCounter, time: t, kind: d.id, name: d.key, value: d.value,
                                   played: d.played, reason: d.reason))
            if logNotes { log("◦ \(d.id) \(d.key) → \(d.played ? "played" : "skipped: \(d.reason)")") }
        }
        if netEvents.count > 80 { netEvents.removeFirst(netEvents.count - 80) }

        scheduler.fire(now: t)

        if let onStatus, t - lastPublish >= statusInterval {
            lastPublish = t
            onStatus(status(at: t, harmony: harmony, total: total))
        }

        if t - lastStatus >= 10 {
            lastStatus = t
            let top = (bus.streams["net.app.bytesPerSec"] ?? [:]).sorted { $0.value > $1.value }.prefix(3)
                .map { "\($0.key) \(formatRate($0.value))" }.joined(separator: ", ")
            log("· total \(formatRate(total)) (smoothed \(formatRate(conductor.smoothedRate))) | mood \(conductor.mood.rawValue) | sounding \(scheduler.soundingCount) | \(top)")
        }
    }
}

extension Engine {
    /// Param specs in registration order. Call on `queue`, or before `start()`.
    public var paramSpecs: [ParamSpec] { params.order.compactMap { params.specs[$0] } }

    /// The scene as it stands now, including every tweak, ready to save. Call on `queue`.
    public func currentScene() -> Scene {
        var s = scene
        // Macros are left out (their effect is already in the target values) so the scene
        // round-trips; route depths go back into the routes themselves.
        s.params = params.baseValues.filter { !$0.key.hasPrefix("mod.") && !$0.key.hasPrefix("macro.") }
        // Keep the scene's own au.* values when instruments aren't loaded (e.g. --dry-run).
        for (id, v) in scene.params where (id.hasPrefix("au.") || id.hasPrefix("mix.")) && params.specs[id] == nil { s.params[id] = v }
        for i in s.routes.indices { s.routes[i].amount = params.baseValue("mod.\(i).amount") }
        s.progressions = Dictionary(uniqueKeysWithValues: conductor.progressions.map { ($0.key.rawValue, $0.value) })
        s.gestures = conductor.gestures
        s.motifs = motif.designs
        s.grooves = drums.custom
        return s
    }

    /// Replace the motif designs (live). Call on `queue`.
    public func setMotifs(_ designs: [MotifDesign]) { motif.designs = designs }

    /// Send a voice somewhere else (live). Notes already sounding finish on the old destination.
    /// Call on `queue`, after the sink can reach `destination`.
    public func setVoiceDestination(_ role: String, _ destination: String) {
        guard router.voices[role] != nil else { return }
        router.voices[role]?.destination = destination
        if let i = scene.voices.firstIndex(where: { $0.role == role }) { scene.voices[i].destination = destination }
        log("→ \(role) now plays on \(destination)")
    }

    /// Replace the edited drum grooves (live). Call on `queue`.
    public func setGrooves(_ grooves: [DrumGroove]) { drums.custom = grooves }

    /// Play an app's motif (designed or generated) on the next tick, as if it had woken. Call on `queue`.
    public func previewMotif(for app: String) {
        pendingPreviews.append(Activation(key: app, bytesPerSecond: 100_000, time: 0))
    }

    fileprivate func appInfos() -> [EngineStatus.AppInfo] {
        let rates = bus.streams["net.app.bytesPerSec"] ?? [:]
        let ignore = Set(scene.ignoreApps)
        let names = Set(rates.keys).union(appStats.keys)
        return names.map { name in
            EngineStatus.AppInfo(name: name, bytesPerSecond: rates[name] ?? 0, wakes: appStats[name]?.wakes ?? 0,
                                 lastWake: appStats[name]?.last, ignored: ignore.contains(name))
        }
        .sorted { ($0.wakes, $0.bytesPerSecond) > ($1.wakes, $1.bytesPerSecond) }
        .prefix(200).map { $0 }
    }

    /// Switch to a chord right now so it can be heard (pads, bass and sub re-strike). Call on `queue`.
    public func auditionChord(_ degree: Int) {
        conductor.force(chord: degree)
        auditionPending = true
    }

    /// Replace a mood's chord progression (scale degrees, 0 = tonic). Call on `queue`.
    /// An empty list is ignored: every mood needs at least one chord.
    public func setProgression(_ mood: String, _ degrees: [Int]) {
        guard !degrees.isEmpty else { return }
        if let m = Conductor.Mood(rawValue: mood) {
            conductor.progressions[m] = degrees
        } else {
            conductor.gestures[mood] = degrees
        }
    }

    fileprivate func status(at t: Double, harmony: HarmonyContext, total: Double) -> EngineStatus {
        var signals: [String: Double] = [:]
        for (id, keyed) in bus.streams {
            for (key, v) in keyed { signals[key.isEmpty ? id : "\(id)#\(key)"] = v }
        }
        let apps = (bus.streams["net.app.bytesPerSec"] ?? [:]).sorted { $0.value > $1.value }.prefix(8)
            .map { EngineStatus.AppRate(app: $0.key, bytesPerSecond: $0.value) }
        var values: [String: Double] = [:]
        for id in params.order { values[id] = params.value(id) }
        return EngineStatus(
            time: t, beat: clock.beat, bpm: clock.bpm, mood: conductor.mood.rawValue,
            chordDegree: harmony.chordDegree,
            chord: harmony.chordDegrees.map { String(noteName(harmony.note(degree: $0)).dropLast()) },
            key: "\(ScaleCatalogue.rootNames[harmony.root]) \(ScaleCatalogue.names[params.int("harmony.scale")])",
            totalRate: total, smoothedRate: conductor.smoothedRate, topApps: Array(apps),
            sounding: scheduler.soundingCount, values: values, bases: params.baseValues, signals: signals,
            recentNotes: recentNotes,
            progressions: conductor.describedProgressions(in: harmony),
            progressionIndex: conductor.progressionIndex,
            gestures: conductor.describedGestures(in: harmony),
            chordChoices: (0..<harmony.scaleSteps.count).map { d in
                var c = harmony
                c.chordDegree = d
                let tones = c.chordDegrees.map { c.note(degree: $0) }
                return .init(degree: d, name: harmony.chordName(degree: d), numeral: harmony.romanNumeral(degree: d),
                             notes: tones.map { ScaleCatalogue.sharpNames[(($0 % 12) + 12) % 12] },
                             steps: c.chordDegrees.map { $0 % harmony.scaleSteps.count + 1 },
                             pitchClasses: tones.map { (($0 % 12) + 12) % 12 })
            },
            chordHistory: chordHistory,
            scalePitchClasses: harmony.scalePitchClasses.sorted(),
            chordPitchClasses: harmony.chordPitchClasses.sorted(),
            root: harmony.root, scaleSteps: harmony.scaleSteps, chordSize: harmony.chordSize,
            apps: appInfos(), motifs: motif.designs, netEvents: netEvents, capture: capture,
            drums: drums.status(params: params)
        )
    }
}

extension String {
    func padding(_ width: Int) -> String {
        count >= width ? self : self + String(repeating: " ", count: width - count)
    }
}
