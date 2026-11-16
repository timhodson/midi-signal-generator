import AppKit
import AUHost
import CoreAudioKit
import Engine
import Foundation
import MIDIOut
import Music
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
    /// Knobs (AudioKit style) or sliders for continuous settings.
    var useKnobs = true
    /// Listen for packet events from msg-pcap (and start it when allowed). Not used when replaying.
    var packetCapture = true

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
    /// How to get packet capture going, when it was wanted but couldn't start.
    var packetHint: String? { session?.packetHint }

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
            let s = try await Session.make(scene: scene, options: .init(
                source: source, output: .live, record: record,
                packets: packetCapture && sourceKind != .replay ? .init() : nil))
            let specs = s.engine.paramSpecs
            self.specs = specs
            specsByID = Dictionary(uniqueKeysWithValues: specs.map { ($0.id, $0) })
            let baseValues = s.engine.params.baseValues
            cells = Dictionary(uniqueKeysWithValues: specs.map { ($0.id, ParamCell(id: $0.id, base: baseValues[$0.id] ?? $0.defaultValue)) })
            messages = s.notes
            motifDesigns = scene.motifs
            drumGrooves = scene.grooves
            history = []
            s.engine.onStatus = { [weak self] status in
                Task { @MainActor in self?.apply(status) }
            }
            try s.start()
            session = s
            paused = false
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
            // Several routes can share a source or target: record each one once per sample, or its
            // history fills up several times faster and covers less time than the chart shows.
            var keys: [String: Double] = [:]
            for route in routes {
                keys[route.source] = s.signals[route.source] ?? 0
                keys["param:" + route.target] = s.values[route.target] ?? 0
            }
            for (key, value) in keys { trace(key, s.time, value) }
        }
        let now = Date()
        for (id, cell) in cells {
            if let v = s.values[id], abs(cell.effective - v) > 1e-9 { cell.effective = v }
            if now >= cell.localEditUntil, let b = s.bases[id], abs(cell.base - b) > 1e-9 { cell.base = b }
        }
        let known = Set(appOrder)
        let newApps = s.apps.map(\.name).filter { !known.contains($0) }.sorted()
        if !newApps.isEmpty { appOrder += newApps }
        var motifSteps: [String: Set<Int>] = [:]
        for n in s.recentNotes.suffix(80) {
            // Lit while sounding (and a beat of grace so short notes are still seen at 10 Hz).
            guard let tag = n.motif, n.time <= s.time + 0.05, s.time < n.time + max(n.duration, 0.25) + 0.15 else { continue }
            motifSteps["app:" + tag.app, default: []].insert(tag.step)
            if let d = tag.designID { motifSteps["design:" + d, default: []].insert(tag.step) }
        }
        if motifSteps != soundingMotifSteps { soundingMotifSteps = motifSteps }
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

    // MARK: - Motifs

    /// Apps in the order they were first heard. Lists use this so they don't reshuffle as
    /// traffic and wake-up counts change.
    private(set) var appOrder: [String] = []

    /// Apps heard, in stable first-heard order.
    var orderedApps: [EngineStatus.AppInfo] {
        let byName = Dictionary((status?.apps ?? []).map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        return appOrder.compactMap { byName[$0] }
    }

    /// Motif steps sounding right now, keyed "app:<name>" and "design:<id>" (for live highlighting).
    private(set) var soundingMotifSteps: [String: Set<Int>] = [:]

    /// The motif designs being edited; pushed to the engine on every change.
    var motifDesigns: [MotifDesign] = []

    func setMotifDesigns(_ designs: [MotifDesign]) {
        motifDesigns = designs
        scene.motifs = designs
        session?.setMotifs(designs)
    }

    func updateDesign(_ design: MotifDesign) {
        var all = motifDesigns
        if let i = all.firstIndex(where: { $0.id == design.id }) { all[i] = design } else { all.append(design) }
        setMotifDesigns(all)
    }

    func randomise() { session?.randomise() }

    /// Paused: the music holds, but the session (hosted synths, settings, signals) stays loaded.
    private(set) var paused = false

    /// Play / pause; starts the session first if it isn't running.
    func playPause() async {
        guard isRunning else { await start(); return }
        paused.toggle()
        session?.setPaused(paused)
    }
    func returnHome() { session?.returnHome() }
    func makeHome() { session?.makeHome() }
    func restartClock() { session?.restartClock() }
    func restyle() { session?.restyle() }

    /// Set to jump to a page (e.g. from the signal-flow inspector); ContentView follows it.
    var navigate: SidebarItem?

    // MARK: Skin

    /// The look (System or Studio). Saved per user.
    var skin: SkinStyle = SkinStyle(rawValue: UserDefaults.standard.string(forKey: "skin") ?? "") ?? .system {
        didSet { if persistsLayout { UserDefaults.standard.set(skin.rawValue, forKey: "skin") } }
    }

    // MARK: Tabletop

    /// Panels pinned to the Tabletop, in order. Saved per user (not per scene).
    var pinned: [PanelID] = AppModel.loadPinned() {
        didSet { if persistsLayout { Self.savePinned(pinned) } }
    }
    /// Off for headless snapshots, so they don't change the user's layout.
    @ObservationIgnored var persistsLayout = true

    func togglePin(_ panel: PanelID) {
        if let i = pinned.firstIndex(of: panel) { pinned.remove(at: i) } else { pinned.append(panel) }
    }

    /// Move the pinned panel with `id` to just before `target`.
    func movePin(_ id: String, before target: PanelID) {
        guard let from = pinned.firstIndex(where: { $0.id == id }), pinned[from] != target else { return }
        let panel = pinned.remove(at: from)
        pinned.insert(panel, at: pinned.firstIndex(of: target) ?? pinned.endIndex)
    }

    private static let pinnedKey = "tabletop.pinned"
    private static func loadPinned() -> [PanelID] {
        guard let data = UserDefaults.standard.data(forKey: pinnedKey) else { return [] }
        return (try? JSONDecoder().decode([PanelID].self, from: data)) ?? []
    }
    private static func savePinned(_ panels: [PanelID]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(panels), forKey: pinnedKey)
    }

    // MARK: MIDI destinations

    /// Every MIDI destination on this Mac (online or remembered), refreshed while the Voices page is open.
    private(set) var midiDestinations: [MIDIDestinationInfo] = []
    /// Which of the session's external destinations reach a device right now.
    private(set) var destinationStatus: [String: Bool] = [:]
    private(set) var networkSessionEnabled = false
    @ObservationIgnored private var bluetoothWindow: NSWindowController?

    func refreshDestinations() {
        let list = CoreMIDISink.systemDestinations()
        if list != midiDestinations { midiDestinations = list }
        let status = session?.destinationStatus() ?? [:]
        if status != destinationStatus { destinationStatus = status }
        let network = CoreMIDISink.networkSessionDestinationID() != nil
        if network != networkSessionEnabled { networkSessionEnabled = network }
    }

    func destination(of role: String) -> String {
        scene.voices.first { $0.role == role }?.destination ?? CoreMIDISink.virtualDestination
    }

    /// Send a voice somewhere else: live if running, and into the scene either way.
    /// `layer` 0 is the voice's main sound, 1… its layers.
    func setDestination(_ role: String, _ destination: String, layer: Int = 0) {
        guard let i = scene.voices.firstIndex(where: { $0.role == role }), self.destination(of: role, layer: layer) != destination else { return }
        if layer == 0 { scene.voices[i].destination = destination }
        else if scene.voices[i].layers.indices.contains(layer - 1) { scene.voices[i].layers[layer - 1].destination = destination }
        else { return }
        session?.setDestination(role, destination, layer: layer)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            self.refreshDestinations()
        }
    }

    /// Latest peak level per hosted channel (by instrument id) and "master".
    func mixLevels() -> [String: Float] { session?.auHost?.levels() ?? [:] }

    /// Hosted synths this session loaded (a voice can only move to one of these).
    var hostedInstruments: [InstrumentConfig] { session?.scene.instruments ?? [] }

    /// macOS's own Bluetooth MIDI panel: find, pair and connect Bluetooth MIDI devices.
    func showBluetoothMIDI() {
        let controller = bluetoothWindow ?? CABTLEMIDIWindowController()
        bluetoothWindow = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func openAudioMIDISetup() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Audio MIDI Setup.app"))
    }

    func deleteDesign(_ id: String) { setMotifDesigns(motifDesigns.filter { $0.id != id }) }

    /// Drum grooves edited here (replacing the built-in of the same name); pushed to the engine on every change.
    var drumGrooves: [DrumGroove] = []

    func updateGroove(_ groove: DrumGroove) {
        var all = drumGrooves.filter { $0.name != groove.name }
        if DrumGroove.builtIn.first(where: { $0.name == groove.name }) != groove { all.append(groove) }
        drumGrooves = all
        scene.grooves = all
        session?.setGrooves(all)
    }

    func resetGroove(_ name: String) {
        if let g = DrumGroove.builtIn.first(where: { $0.name == name }) { updateGroove(g) }
    }

    func previewMotif(for app: String) { session?.previewMotif(for: app) }

    /// The current harmony, rebuilt from status (for resolving motif steps to notes in the UI).
    var harmony: HarmonyContext? {
        guard let s = status else { return nil }
        return HarmonyContext(root: s.root, scaleSteps: s.scaleSteps, chordDegree: s.chordDegree, chordSize: s.chordSize)
    }

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
        panel.directoryURL = Self.lastSavedScene?.deletingLastPathComponent() ?? Self.scenesDirectory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        await openScene(url)
    }

    func openScene(_ url: URL) async {
        do {
            let loaded = try Scene.load(url)
            let wasRunning = isRunning
            stop()
            scene = loaded
            sceneURL = url
            noteRecent(url)
            if wasRunning { await start() }
        } catch {
            self.error = "Could not open \(url.lastPathComponent): \(error)"
            if !FileManager.default.fileExists(atPath: url.path) { forgetRecent(url) }
        }
    }

    // MARK: Recent scenes

    /// Scenes opened or saved, newest first (kept on this Mac only).
    private(set) var recentScenes: [URL] = AppModel.loadRecent()
    private static let recentKey = "scenes.recent"
    private static let lastSavedKey = "scenes.lastSaved"

    /// The scene saved most recently, if it's still there: the app opens it at launch.
    static var lastSavedScene: URL? {
        guard let path = UserDefaults.standard.string(forKey: lastSavedKey), FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    func noteRecent(_ url: URL) {
        recentScenes = [url] + recentScenes.filter { $0.standardizedFileURL != url.standardizedFileURL }
        recentScenes = Array(recentScenes.prefix(10))
        UserDefaults.standard.set(recentScenes.map(\.path), forKey: Self.recentKey)
    }

    func forgetRecent(_ url: URL) {
        recentScenes.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
        UserDefaults.standard.set(recentScenes.map(\.path), forKey: Self.recentKey)
    }

    func clearRecent() {
        recentScenes = []
        UserDefaults.standard.removeObject(forKey: Self.recentKey)
    }

    private static func loadRecent() -> [URL] {
        (UserDefaults.standard.stringArray(forKey: recentKey) ?? []).map { URL(fileURLWithPath: $0) }
    }

    func saveScene(askForLocation: Bool = true) {
        let current = session?.currentScene() ?? scene
        var url = sceneURL
        if askForLocation || url == nil {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.directoryURL = sceneURL?.deletingLastPathComponent() ?? Self.lastSavedScene?.deletingLastPathComponent() ?? Self.scenesDirectory
            panel.nameFieldStringValue = Self.suggestedName(for: sceneURL)
            guard panel.runModal() == .OK, let chosen = panel.url else { return }
            url = chosen
        }
        guard let url else { return }
        do {
            try current.encoded().write(to: url)
            sceneURL = url
            scene = current
            noteRecent(url)
            UserDefaults.standard.set(url.path, forKey: Self.lastSavedKey)
        } catch { self.error = "Could not save: \(error)" }
    }

    /// Save (⌘S). A scene loaded from a file isn't overwritten silently: the default is a new file,
    /// replacing is a choice (which can be made the default with "Always replace without asking").
    func saveSceneAsking() {
        guard let url = sceneURL else { saveScene(); return }
        if UserDefaults.standard.bool(forKey: Self.replaceWithoutAskingKey) { saveScene(askForLocation: false); return }
        let alert = NSAlert()
        alert.messageText = "Save over “\(url.lastPathComponent)”?"
        let varied = !(status?.variation?.log.isEmpty ?? true)
        alert.informativeText = "Saving as a new file keeps “\(url.lastPathComponent)” as it was"
            + (varied ? ", including the home that variations start from." : ".")
            + " Replacing writes everything as it plays now into that file."
        alert.addButton(withTitle: "Save as New…")
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Always replace without asking"
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            saveScene()
        case .alertSecondButtonReturn:
            if alert.suppressionButton?.state == .on { UserDefaults.standard.set(true, forKey: Self.replaceWithoutAskingKey) }
            saveScene(askForLocation: false)
        default:
            break
        }
    }

    static let replaceWithoutAskingKey = "save.replaceWithoutAsking"

    /// "evening.json" → "evening 2026-11-13 1042.json", so Save as New never offers the original's name.
    static func suggestedName(for url: URL?) -> String {
        let stem = url?.deletingPathExtension().lastPathComponent ?? "scene"
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HHmm"
        return "\(stem) \(f.string(from: Date())).json"
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
        guard let inst = session?.auHost?.plugins[instrumentID], !openingEditors.contains(instrumentID) else { return }
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
