import AppKit
import AUHost
import CoreAudioKit
import Engine
import Foundation
import Observation
import Params
import Router
import Runtime

/// One parameter's values. Each control observes only its own cell, so a status update re-renders
/// just the controls whose values changed, not every control on the page.
@MainActor
@Observable
final class ParamCell {
    let id: String
    var base: Double
    var effective: Double
    /// While the user drags, ignore status updates that predate the edit.
    @ObservationIgnored var localEditUntil = Date.distantPast

    init(id: String, base: Double) {
        self.id = id
        self.base = base
        effective = base
    }
}

/// Everything the UI shows and does. Main-actor only; talks to the engine through `Session`.
@MainActor
@Observable
final class AppModel {
    struct TracePoint: Identifiable {
        let id: Int
        let time: Double
        let value: Double
    }

    struct TrafficPoint: Identifiable {
        let id: Int
        let time: Double
        let total: Double
        let smoothed: Double
    }

    enum SourceKind: String, CaseIterable, Identifiable {
        case live = "Live traffic"
        case synthetic = "Synthetic"
        case replay = "Replay file"
        var id: String { rawValue }
    }

    // Configuration
    var scene: Scene
    var sceneURL: URL?
    var sourceKind: SourceKind = .live
    var replayURL: URL?
    var replaySpeed: Double = 1
    var replayLoop = true
    var recording = false
    /// Show each parameter's explanation under its control (not just as a tooltip).
    var showExplanations = true

    // Running state
    private(set) var session: Session?
    private(set) var isStarting = false
    private(set) var specs: [ParamSpec] = []
    private(set) var specsByID: [String: ParamSpec] = [:]
    private(set) var status: EngineStatus?
    /// When `status` arrived, so visuals can extrapolate engine time smoothly between updates.
    private(set) var statusReceivedAt = Date()
    /// Short histories (≈60 s at 4 Hz) of route inputs and targets, for the modulation sparklines.
    private(set) var traces: [String: [TracePoint]] = [:]
    private var lastTrace: Double = 0
    /// Per-param observable values (fine-grained, see `ParamCell`).
    private(set) var cells: [String: ParamCell] = [:]
    /// False while the window is hidden, minimised or covered: visuals pause, status slows down.
    var visualsActive = true {
        didSet {
            guard visualsActive != oldValue else { return }
            session?.setStatusInterval(visualsActive ? 0.1 : 1.0)
        }
    }
    /// Keep visuals running regardless of window visibility (headless profiling/snapshots).
    @ObservationIgnored var forceVisualsActive = false
    /// Instruments whose editor window is being opened (shows a spinner).
    private(set) var openingEditors: Set<String> = []
    private(set) var history: [TrafficPoint] = []
    private(set) var peakDB: Double = -120
    private(set) var messages: [String] = []
    var error: String?
    private var pointCounter = 0
    private var editorWindows: [String: NSWindow] = [:]

    var isRunning: Bool { session != nil }

    init(scene: Scene, sceneURL: URL? = nil) {
        self.scene = scene
        self.sceneURL = sceneURL
    }

    // MARK: - Lifecycle

    var sourceChoice: SourceChoice? {
        switch sourceKind {
        case .live: .nettop
        case .synthetic: .synthetic
        case .replay: replayURL.map { .replay($0, speed: replaySpeed, loop: replayLoop) }
        }
    }

    func start() async {
        guard session == nil, !isStarting else { return }
        guard let source = sourceChoice else {
            error = "Choose a recording to replay first."
            return
        }
        isStarting = true
        defer { isStarting = false }
        error = nil
        do {
            let record = recording ? try Self.newRecordingURL() : nil
            let s = try await Session.make(scene: scene, options: .init(source: source, output: .live, record: record))
            let specs = s.engine.paramSpecs
            self.specs = specs
            specsByID = Dictionary(uniqueKeysWithValues: specs.map { ($0.id, $0) })
            let baseValues = s.engine.params.baseValues
            cells = Dictionary(uniqueKeysWithValues: specs.map { ($0.id, ParamCell(id: $0.id, base: baseValues[$0.id] ?? $0.defaultValue)) })
            messages = s.notes
            history = []
            s.engine.onStatus = { [weak self] status in
                Task { @MainActor in self?.apply(status) }
            }
            try s.start()
            session = s
            if !visualsActive { s.setStatusInterval(1.0) }
        } catch {
            self.error = "\(error)"
        }
    }

    /// Stop, keeping every tweak in `scene` so the next start carries on where we left off.
    func stop() {
        guard let s = session else { return }
        scene = s.currentScene()
        session = nil
        s.engine.onStatus = nil
        s.stop(tail: 0.3)
        for w in editorWindows.values { w.close() }
        editorWindows.removeAll()
        status = nil
    }

    func restart() async {
        stop()
        await start()
    }

    /// Engine time now, extrapolated from the last status (for smooth scrolling visuals).
    func engineNow(at date: Date = Date()) -> Double {
        guard let s = status else { return 0 }
        return s.time + min(date.timeIntervalSince(statusReceivedAt), 0.5)
    }

    private func apply(_ s: EngineStatus) {
        guard session != nil else { return }
        status = s
        statusReceivedAt = Date()
        if s.time - lastTrace >= 0.25 {
            lastTrace = s.time
            for route in routes {
                trace(route.source, s.time, s.signals[route.source] ?? 0)
                trace("param:" + route.target, s.time, s.values[route.target] ?? 0)
            }
        }
        let now = Date()
        for (id, cell) in cells {
            if let v = s.values[id], abs(cell.effective - v) > 1e-9 { cell.effective = v }
            if now >= cell.localEditUntil, let b = s.bases[id], abs(cell.base - b) > 1e-9 { cell.base = b }
        }
        pointCounter += 1
        // One chart point per second is plenty; skip the silence before the first data arrives.
        if s.totalRate > 0 || !history.isEmpty, history.last.map({ s.time - $0.time >= 1 }) ?? true {
            history.append(.init(id: pointCounter, time: s.time, total: max(s.totalRate, 1), smoothed: max(s.smoothedRate, 1)))
            if history.count > 180 { history.removeFirst(history.count - 180) }
        }
        if let host = session?.auHost {
            let p = Double(host.takePeak())
            let db = 20 * log10(max(p, 1e-6))
            peakDB = max(db, peakDB - 3) // fall back gently
        }
    }

    private func trace(_ key: String, _ t: Double, _ v: Double) {
        pointCounter += 1
        var list = traces[key, default: []]
        list.append(.init(id: pointCounter, time: t, value: v))
        if list.count > 240 { list.removeFirst(list.count - 240) }
        traces[key] = list
    }

    // MARK: - Progressions

    func auditionChord(_ degree: Int) { session?.auditionChord(degree) }

    func setProgression(_ mood: String, _ degrees: [Int]) {
        guard !degrees.isEmpty else { return }
        session?.setProgression(mood, degrees)
    }

    // MARK: - Params

    func base(_ id: String) -> Double { cells[id]?.base ?? specsByID[id]?.defaultValue ?? 0 }
    func effective(_ id: String) -> Double { cells[id]?.effective ?? base(id) }

    func set(_ id: String, _ value: Double) {
        guard let spec = specsByID[id] else { return }
        if let cell = cells[id] {
            let v = spec.sanitise(value)
            cell.base = v
            if !spec.modulatable { cell.effective = v }
            cell.localEditUntil = Date().addingTimeInterval(0.4)
        }
        session?.set(id, value)
    }

    func specs(withPrefix prefixes: [String]) -> [ParamSpec] {
        specs.filter { s in prefixes.contains { s.id.hasPrefix($0) } }
    }

    // MARK: - Modulation routes (structural changes restart the session)

    func addRoute(_ route: ModRoute) async {
        if let s = session { scene = s.currentScene() }
        scene.routes.append(route)
        if isRunning { await restart() }
    }

    func removeRoute(at index: Int) async {
        if let s = session { scene = s.currentScene() }
        guard scene.routes.indices.contains(index) else { return }
        scene.routes.remove(at: index)
        if isRunning { await restart() }
    }

    var routes: [ModRoute] { session?.scene.routes ?? scene.routes }

    // MARK: - Scenes

    func openScene() async {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.directoryURL = Self.scenesDirectory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let loaded = try Scene.load(url)
            let wasRunning = isRunning
            stop()
            scene = loaded
            sceneURL = url
            if wasRunning { await start() }
        } catch { self.error = "Could not open \(url.lastPathComponent): \(error)" }
    }

    func saveScene(askForLocation: Bool = true) {
        let current = session?.currentScene() ?? scene
        var url = sceneURL
        if askForLocation || url == nil {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.directoryURL = Self.scenesDirectory
            panel.nameFieldStringValue = sceneURL?.lastPathComponent ?? "scene.json"
            guard panel.runModal() == .OK, let chosen = panel.url else { return }
            url = chosen
        }
        guard let url else { return }
        do {
            try current.encoded().write(to: url)
            sceneURL = url
            scene = current
        } catch { self.error = "Could not save: \(error)" }
    }

    func chooseReplayFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "jsonl") ?? .data, .json]
        panel.directoryURL = Self.recordingsDirectory
        if panel.runModal() == .OK, let url = panel.url {
            replayURL = url
            sourceKind = .replay
        }
    }

    // MARK: - Synth editors

    func openEditor(_ instrumentID: String) {
        if let w = editorWindows[instrumentID] {
            w.makeKeyAndOrderFront(nil)
            return
        }
        guard let inst = session?.auHost?.instruments[instrumentID], !openingEditors.contains(instrumentID) else { return }
        let title = "\(inst.config.component) — \(instrumentID)"
        openingEditors.insert(instrumentID)
        inst.unit.auAudioUnit.requestViewController { [weak self] vc in
            Task { @MainActor in
                self?.openingEditors.remove(instrumentID)
                guard let self, let vc else {
                    self?.error = "\(title) has no editor view."
                    return
                }
                let size = vc.preferredContentSize == .zero ? NSSize(width: 900, height: 600) : vc.preferredContentSize
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                      styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                      backing: .buffered, defer: false)
                window.contentViewController = vc
                window.setContentSize(size)
                window.title = title
                window.isReleasedWhenClosed = false
                window.center()
                window.makeKeyAndOrderFront(nil)
                self.editorWindows[instrumentID] = window
            }
        }
    }

    // MARK: - Locations

    /// `scenes/` and `recordings/` next to the working directory when run from the repo,
    /// otherwise under ~/Music/MIDI Signal Generator.
    static var baseDirectory: URL {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        if FileManager.default.fileExists(atPath: cwd.appendingPathComponent("scenes").path) { return cwd }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music/MIDI Signal Generator")
    }

    static var scenesDirectory: URL { baseDirectory.appendingPathComponent("scenes") }
    static var recordingsDirectory: URL { baseDirectory.appendingPathComponent("recordings") }

    static func newRecordingURL() throws -> URL {
        try FileManager.default.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return recordingsDirectory.appendingPathComponent("\(f.string(from: Date())).jsonl")
    }
}
