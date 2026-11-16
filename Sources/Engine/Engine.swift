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
    private let sink: MIDISink
    private var clockOut = ClockOut()
    /// The style last applied (index into `Style.choices`; 0 = none), a pending (re)apply, and the
    /// scene as it was before the first style, for going back to "None".
    private var appliedStyle = 0
    private var styleRequested = false
    private var beforeStyle: (values: [String: Double], progressions: [Conductor.Mood: [Int]])?
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
    /// Paused: the music holds (no notes, the clock stands still, MIDI clock sends Stop) while
    /// everything stays loaded and settings, signals and the mixer keep working.
    public private(set) var paused = false
    /// The intro: the bar it started on, and how many bars it lasts (conductor.introBars).
    private var intro: (start: Int, bars: Int)?
    private var introPending = true
    private var activitySettled = false
    private var pauseApplied = false
    private var lastPublish: Double = 0
    private var recentNotes: [EngineStatus.PlayedNote] = []
    private var noteCounter = 0
    private var unroutedRoles: Set<String> = []
    private var chordHistory: [EngineStatus.ChordEvent] = []
    private var auditionPending = false
    private let motif = MotifGenerator()
    private let packets = PacketGenerator()
    private let drums = DrumGenerator()
    private let lfos = [LFOGenerator(index: 1), LFOGenerator(index: 2)]
    private let variation = Variation()
    private var pendingHome = false
    private var nextVariationIn: Double?
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
        conductor.pinned = Set((scene.pinnedProgressions ?? []).compactMap(Conductor.Mood.init(rawValue:)))
        motif.designs = scene.motifs
        drums.custom = scene.grooves
        generators = [DroneGenerator(), motif, PulseGenerator(), BassGenerator(), SubDroneGenerator(), packets, drums] + lfos
        router = VoiceRouter(voices: scene.voices)
        scheduler = NoteScheduler(sink: sink)
        self.sink = sink
        parameterisedSink = sink as? ParameterisedSink

        params.register(Conductor.params)
        params.register(Quantiser.params)
        params.register(ActivityTracker.params)
        params.register(Variation.params)
        params.register(ClockOut.params)
        params.register(Style.params)
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
        variation.makeHome(params, conductor)
        // A scene saved with a style already has its settings: don't re-apply on load. One that
        // only asks for a style gets it at the first chord.
        appliedStyle = scene.appliedStyle.flatMap { Style.choices.firstIndex(of: $0) } ?? 0
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
            send(clockOut.stopAll())
            sink.transport(TransportState(bpm: clock.bpm, beat: clock.beat, uptimeNanos: uptime(now),
                                          beatsPerBar: clock.beatsPerBar, playing: false))
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
        if paused {
            holdWhilePaused(t: t, horizon: horizon)
            return
        }
        let beats = clock.advance(to: horizon, bpm: params.value("clock.bpm"))
        tickClock(beats)
        if introPending {
            introPending = false
            let bars = params.int("conductor.introBars")
            let start = Int((beats.lowerBound / Double(clock.beatsPerBar)).rounded(.down))
            intro = bars > 0 ? (start, bars) : nil
            if bars > 0 { drums.planLanding(on: start + bars, reason: "the end of the intro") }
        }
        if let i = intro, beats.lowerBound >= Double((i.start + i.bars) * clock.beatsPerBar) { intro = nil }

        // Fresh per-app data -> activations + mood.
        var activations: [Activation] = []
        let total = bus.value("net.total.bytesPerSec") ?? 0
        if let v = bus.streamVersion["net.app.bytesPerSec"], v != seenAppVersion {
            seenAppVersion = v
            let rates = bus.streams["net.app.bytesPerSec"] ?? [:]
            if activitySettled {
                activations = activity.update(rates: rates, now: horizon, params: params, ignore: Set(scene.ignoreApps))
                // Apps that start talking while the piece is still building count as awake, but
                // don't play or set off a flurry: motifs begin once the intro is over.
                if intro != nil { activations = [] }
            } else {
                activity.settle(rates: rates, now: horizon, params: params) // apps already talking aren't waking up
                activitySettled = true
            }
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
        nextVariationIn = variation.schedule(now: t, params)
        for barBeat in MusicalClock.crossings(of: Double(clock.beatsPerBar), in: beats) {
            let bar = Int((barBeat / Double(clock.beatsPerBar)).rounded())
            // Variations (and going back home) land on chord boundaries, scheduled ones at the end of a phrase.
            let boundary = bar % max(params.int("harmony.barsPerChord"), 1) == 0
            let phraseStarts = boundary && !conductor.gesturePending && conductor.progressionIndex >= conductor.progressionLength - 1
            if boundary, styleRequested || params.int("style.name") != appliedStyle {
                applyStyle(now: t)
                conductor.restartPhrase()
                chordChanged = true
            } else if boundary, pendingHome || variation.shouldApply(atChordBoundary: boundary, phraseStarts: phraseStarts, params) {
                let changes = pendingHome ? variation.returnHome(params, conductor, now: t)
                                          : variation.apply(params, conductor, rng: &rng, now: t, style: activeStyle)
                log("♪ \(pendingHome ? "back home" : "variation"): \(changes.isEmpty ? "no change" : changes.joined(separator: "; "))")
                pendingHome = false
                conductor.restartPhrase()
                chordChanged = true // re-strike pad, bass and sub in the new key
            }
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
                guard var resolved = quantiser.resolve(intent, harmony: harmony, clock: clock, params: params, rng: &rng) else { continue }
                if intro != nil {
                    guard let gain = introGain(role: resolved.role, at: resolved.start) else { continue }
                    resolved.velocity = max(Int((Double(resolved.velocity) * gain).rounded()), 1)
                }
                let outputs = router.route(resolved, params: params)
                guard let routed = outputs.first else { continue }
                // Every layer plays; visuals and the log show the voice's note once.
                for o in outputs { scheduler.schedule(o) }
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
                for routed in router.route(control, params: params) { scheduler.schedule(routed) }
            }
        }

        // LFO values as signals, for Modulation routes (lfo.1, lfo.2).
        bus.post(lfos.map { SignalSample(.stream, "lfo.\($0.index)", value: $0.value, time: t) }, at: t)

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
        s.pinnedProgressions = conductor.pinned.isEmpty ? nil : conductor.pinned.map(\.rawValue).sorted()
        s.motifs = motif.designs
        s.grooves = drums.custom
        s.appliedStyle = appliedStyle > 0 ? Style.choices[safe: appliedStyle] : nil
        return s
    }

    /// Replace the motif designs (live). Call on `queue`.
    public func setMotifs(_ designs: [MotifDesign]) { motif.designs = designs }

    /// Send a voice somewhere else (live). Notes already sounding finish on the old destination.
    /// Call on `queue`, after the sink can reach `destination`.
    /// `layer` 0 is the voice's main sound, 1… its layers.
    public func setVoiceDestination(_ role: String, _ destination: String, layer: Int = 0) {
        guard var v = router.voices[role] else { return }
        if layer == 0 { v.destination = destination } else if v.layers.indices.contains(layer - 1) { v.layers[layer - 1].destination = destination } else { return }
        router.voices[role] = v
        if let i = scene.voices.firstIndex(where: { $0.role == role }) { scene.voices[i] = v }
        log("→ \(role)\(layer == 0 ? "" : " layer \(layer)") now plays on \(destination)")
    }

    /// Vary the piece at the next chord change. Call on `queue`.
    public func randomiseNow() { variation.request("randomised by hand", manual: true) }

    /// Go back to the home settings at the next chord change. Call on `queue`.
    public func returnHome() { pendingHome = true }

    /// Make what's playing now the home that variations start from. Call on `queue`.
    public func makeHome() { variation.makeHome(params, conductor) }

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
                                 lastWake: appStats[name]?.last, ignored: ignore.containsApp(name))
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
    /// `pin`: true = picked by hand, so variations and styles keep it (and it becomes part of
    /// home); false = released to them again (Reset); nil = leave the pin as it is.
    public func setProgression(_ mood: String, _ degrees: [Int], pin: Bool? = nil) {
        guard !degrees.isEmpty else { return }
        if let m = Conductor.Mood(rawValue: mood) {
            conductor.progressions[m] = degrees
            if let pin { if pin { conductor.pinned.insert(m) } else { conductor.pinned.remove(m) } }
            variation.setHomeProgression(m, degrees)
        } else {
            conductor.gestures[mood] = degrees
        }
    }

    /// Keep (or release) a mood's progression from variations and styles. Call on `queue`.
    public func setProgressionPinned(_ mood: String, _ pinned: Bool) {
        guard let m = Conductor.Mood(rawValue: mood) else { return }
        if pinned {
            conductor.pinned.insert(m)
            if let d = conductor.progressions[m] { variation.setHomeProgression(m, d) }
        } else {
            conductor.pinned.remove(m)
        }
    }

    // MARK: - Styles

    /// The style in force, if any.
    var activeStyle: Style? {
        let i = params.int("style.name")
        return i > 0 && i <= Style.all.count ? Style.all[i - 1] : nil
    }

    /// Apply the chosen style (or a new take on it), or put the scene back for "None".
    private func applyStyle(now t: Double) {
        styleRequested = false
        let index = params.int("style.name")
        defer { appliedStyle = index }
        if appliedStyle == 0, index != 0 {
            beforeStyle = (params.baseValues, conductor.progressions)
        }
        guard let style = activeStyle else {
            if let saved = beforeStyle {
                for (id, v) in saved.values where id != "style.name" && params.specs[id]?.id.hasPrefix("mod.") == false {
                    try? params.set(id, v)
                }
                let kept = conductor.progressions.filter { conductor.pinned.contains($0.key) }
                conductor.progressions = saved.progressions.merging(kept) { _, k in k }
                beforeStyle = nil
                variation.note("style off: back to the scene", changes: ["settings and progressions as they were before the style"], now: t)
                log("♪ style off: back to the scene")
            }
            variation.makeHome(params, conductor)
            return
        }
        let changes = style.apply(params, conductor, rng: &rng)
        variation.note(index == appliedStyle ? "new take: \(style.name)" : "style: \(style.name)", changes: changes, now: t)
        variation.makeHome(params, conductor) // variations now start from the style
        log("♪ style \(style.name): \(changes.joined(separator: "; "))")
    }

    /// Apply the current style again with a fresh tempo, scale and progressions. Call on `queue`.
    public func restyle() { if activeStyle != nil { styleRequested = true } }

    // MARK: - Clock out

    /// Engine time → the uptime clock CoreMIDI timestamps are made from.
    private func uptime(_ t: Double) -> UInt64 { startTime &+ UInt64(max(t, 0) * 1e9) }

    /// Every external MIDI destination an enabled voice plays on (hosted synths, "au:…", get the
    /// tempo through their host musical context instead).
    private var clockDestinations: Set<String> {
        Set(router.voices.values.filter { params.bool("voice.\($0.role).enabled") }
            .flatMap(\.destinations).filter { !$0.hasPrefix("au:") })
    }

    private func tickClock(_ beats: Range<Double>) {
        send(clockOut.advance(beats: beats, clock: clock, destinations: clockDestinations,
                              enabled: params.bool("clock.midiOut"), transport: params.bool("clock.transport"),
                              notBefore: now - 0.005))
        sink.transport(TransportState(bpm: clock.bpm, beat: clock.beat, uptimeNanos: uptime(clock.time),
                                      beatsPerBar: clock.beatsPerBar, playing: true))
    }

    private func send(_ messages: [ClockOut.Message]) {
        for m in messages { sink.sendRaw(destination: m.destination, m.bytes, atUptimeNanos: m.time.map(uptime)) }
    }

    /// When each voice comes in during the intro, as a fraction of it: the pad and sub from the
    /// start, the bass a quarter in, pulse and drums half way, motifs (the lead) once it's over.
    static let introEntry: [String: Double] = ["pad": 0, "sub": 0, "bass": 0.25, "pulse": 0.5, "drums": 0.5]

    /// Velocity factor for a note during the intro, or nil if its voice hasn't come in yet. Each
    /// voice starts softer and grows to full by the end of the intro.
    private func introGain(role: String, at time: Double) -> Double? {
        guard let i = intro else { return 1 }
        let bar = clock.beat(atTime: time) / Double(clock.beatsPerBar)
        let progress = (bar - Double(i.start)) / Double(i.bars)
        guard progress < 1 else { return 1 }
        let entry = Self.introEntry[role] ?? 1
        guard progress >= entry else { return nil }
        return 0.55 + 0.45 * min((progress - entry) / max(1 - entry, 0.01), 1)
    }

    /// The intro bar playing now (1…) and its length, or nil once the piece is going.
    public var introStatus: (bar: Int, of: Int)? {
        guard let i = intro else { return nil }
        return (min(Int((clock.beat / Double(clock.beatsPerBar)).rounded(.down)) - i.start + 1, i.bars), i.bars)
    }

    /// The musical position now, in beats. Call on `queue`.
    public var currentBeat: Double { clock.beat }

    /// Pause or resume the music. Call on `queue`.
    public func setPaused(_ on: Bool) {
        guard on != paused else { return }
        paused = on
        pauseApplied = false
        if !on {
            firstTick = true // strike the chord again straight away
            if params.bool("conductor.introAfterPause") { introPending = true }
            log("▶︎ playing")
        } else {
            log("⏸ paused")
        }
    }

    /// One tick while paused: release everything once, keep signals and the status flowing.
    private func holdWhilePaused(t: Double, horizon: Double) {
        if !pauseApplied {
            pauseApplied = true
            scheduler.panic()
            send(clockOut.stopAll())
            sink.transport(TransportState(bpm: clock.bpm, beat: clock.beat, uptimeNanos: uptime(now),
                                          beatsPerBar: clock.beatsPerBar, playing: false))
        }
        clock.hold(at: horizon)
        _ = bus.drainEvents()
        let total = bus.value("net.total.bytesPerSec") ?? 0
        if let onStatus, t - lastPublish >= statusInterval {
            lastPublish = t
            onStatus(status(at: t, harmony: conductor.harmony(params), total: total))
        }
    }

    /// Send Stop, then Start again on the next bar line, to every clocked destination. Call on `queue`.
    public func restartClock() { send(clockOut.restart()) }

    fileprivate func status(at t: Double, harmony: HarmonyContext, total: Double) -> EngineStatus {
        var signals: [String: Double] = [:]
        for (id, keyed) in bus.streams {
            for (key, v) in keyed { signals[key.isEmpty ? id : "\(id)#\(key)"] = v }
        }
        let apps = (bus.streams["net.app.bytesPerSec"] ?? [:]).sorted { $0.value > $1.value }.prefix(8)
            .map { EngineStatus.AppRate(app: $0.key, bytesPerSecond: $0.value) }
        var values: [String: Double] = [:]
        for id in params.order { values[id] = params.value(id) }
        var status = EngineStatus(
            time: t, beat: clock.beat, bpm: clock.bpm, mood: conductor.mood.rawValue,
            chordDegree: harmony.chordDegree,
            chord: harmony.chordDegrees.map { harmony.pitchName(harmony.note(degree: $0)) },
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
                             notes: tones.map { harmony.pitchName($0) },
                             steps: c.chordDegrees.map { $0 % harmony.scaleSteps.count + 1 },
                             pitchClasses: tones.map { (($0 % 12) + 12) % 12 })
            },
            chordHistory: chordHistory,
            scalePitchClasses: harmony.scalePitchClasses.sorted(),
            chordPitchClasses: harmony.chordPitchClasses.sorted(),
            root: harmony.root, scaleSteps: harmony.scaleSteps, chordSize: harmony.chordSize,
            apps: appInfos(), motifs: motif.designs, netEvents: netEvents, capture: capture,
            drums: drums.status(params: params),
            variation: .init(log: variation.log, nextIn: nextVariationIn, pending: variation.pendingReason ?? (pendingHome ? "back home" : nil)),
            clock: .init(destinations: clockOut.targets.sorted(), started: clockOut.started.sorted()),
            style: .init(applied: appliedStyle, pending: styleRequested || params.int("style.name") != appliedStyle)
        )
        status.paused = paused
        status.intro = introStatus.map { [$0.bar, $0.of] }
        return status
    }
}

extension String {
    func padding(_ width: Int) -> String {
        count >= width ? self : self + String(repeating: " ", count: width - count)
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
