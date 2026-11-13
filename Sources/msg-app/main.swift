import AppKit
import Engine
import Foundation
import Music
import SwiftUI

/// msg-app [--scene <file.json>] [--source live|synthetic]
///         [--snapshot <dir> [--seconds N]]   render every screen to PNGs offscreen and exit
let args = Array(CommandLine.arguments.dropFirst())
func arg(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), args.indices.contains(i + 1) else { return nil }
    return args[i + 1]
}

var scene = Scene.default
var sceneURL: URL?
if let path = arg("--scene") {
    let url = URL(fileURLWithPath: path)
    do {
        scene = try Scene.load(url)
        sceneURL = url
    } catch {
        FileHandle.standardError.write(Data("error: could not load scene \(path): \(error)\n".utf8))
        exit(1)
    }
}

MainActor.assumeIsolated {
    let model = AppModel(scene: scene, sceneURL: sceneURL)
    if arg("--source") == "synthetic" { model.sourceKind = .synthetic }
    if CommandLine.arguments.contains("--no-packets") { model.packetCapture = false }

    if let name = arg("--profile") {
        guard let section = SidebarItem.allCases.first(where: { $0.rawValue.lowercased() == name.lowercased() }) else {
            print("unknown section \(name)"); exit(1)
        }
        Profile.run(model: model, section: section, seconds: Double(arg("--seconds") ?? "") ?? 10,
                    interact: args.contains("--drag"))
    } else if let dir = arg("--snapshot") {
        Snapshot.run(model: model, directory: URL(fileURLWithPath: dir), seconds: Double(arg("--seconds") ?? "") ?? 8,
                     height: Double(arg("--height") ?? "") ?? 860)
    } else {
        MSGApp.initialModel = model
        MSGApp.main()
    }
}

// MARK: - App

struct MSGApp: App {
    @MainActor static var initialModel: AppModel?
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = MSGApp.initialModel!

    var body: some SwiftUI.Scene {
        Window("MIDI Signal Generator", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 1050, minHeight: 700)
                .onAppear { delegate.model = model }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Scene…") { Task { await model.openScene() } }.keyboardShortcut("o")
                Button("Save Scene") { model.saveScene(askForLocation: model.sceneURL == nil) }.keyboardShortcut("s")
                Button("Save Scene As…") { model.saveScene() }.keyboardShortcut("s", modifiers: [.command, .shift])
            }
        }
        // A generator's or voice's settings in a window of their own (Open in its own window).
        WindowGroup("Panel", for: PanelID.self) { $panel in
            if let panel { PanelWindow(panel: panel).environment(model) }
        }
        .defaultSize(width: 640, height: 720)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Run from `swift run` there is no bundle, so ask to be a normal Dock app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { model?.stop() }
    }
}

// MARK: - Snapshots (headless UI check)

@MainActor
enum Snapshot {
    static func run(model: AppModel, directory: URL, seconds: Double, height: Double = 860) {
        model.forceVisualsActive = true
        model.persistsLayout = false
        if let skin = arg("--skin").flatMap({ name in SkinStyle.allCases.first { $0.rawValue.lowercased() == name.lowercased() } }) {
            model.skin = skin
        }
        model.pinned = [PanelID(page: .generators, group: "drums"), PanelID(page: .voices, group: "lead"),
                        PanelID(page: .generators, group: "pulse")]
        setvbuf(stdout, nil, _IOLBF, 0)
        NSApplication.shared.setActivationPolicy(.prohibited)
        Task { @MainActor in
            await model.start()
            if let error = model.error { print("start error: \(error)") }
            try? await Task.sleep(for: .seconds(seconds))
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for item in SidebarItem.allCases {
                let url = directory.appendingPathComponent("\(item.rawValue.lowercased()).png")
                await render(ContentView(selection: item).environment(model), to: url, size: NSSize(width: 1280, height: height))
                print("wrote \(url.path)")
            }
            // A piano roll being inspected: point at the most recent lead (motif) note.
            if let s = model.status, let n = s.recentNotes.last(where: { $0.role == "lead" && $0.time < model.engineNow() }) {
                let size = CGSize(width: 1200, height: 260), window = 16.0, ahead = 2.0
                let now = model.engineNow() + 0.8 // render() waits 0.8 s before capturing
                let leads = s.recentNotes.filter { $0.role == "lead" }.map(\.note)
                let lo = (leads.min() ?? 60) - 3, hi = max((leads.max() ?? 72) + 3, lo + 18)
                let rowH = (size.height - 18) / CGFloat(hi - lo + 1)
                let x = CGFloat((n.time + n.duration / 2 - (now - window)) / (window + ahead)) * size.width
                let y = 18 + CGFloat(hi - n.note) * rowH + rowH / 2
                await render(PianoRoll(roles: ["lead"], window: window, ahead: ahead, pitchRange: lo...hi, inspectAt: CGPoint(x: x, y: y))
                    .environment(model).frame(width: size.width, height: size.height).padding(20),
                             to: directory.appendingPathComponent("roll-inspect.png"), size: NSSize(width: 1240, height: 300))
            }
            // The motif editor needs a selection: an app, and a design customised from it.
            if let app = model.status?.apps.first(where: { !$0.ignored })?.name, let h = model.harmony {
                await render(MotifsView(selection: .app(app)).environment(model),
                             to: directory.appendingPathComponent("motifs-app.png"), size: NSSize(width: 1280, height: 700))
                let d = MotifDesign.fromGenerated(app: app, length: 4, range: 7, octave: 5, harmony: h)
                model.updateDesign(d)
                await render(MotifsView(selection: .design(d.id)).environment(model),
                             to: directory.appendingPathComponent("motifs-design.png"), size: NSSize(width: 1280, height: 1100))
                print("wrote motif pages for \(app)")
            }
            await render(NetworkEventsCard().environment(model).frame(width: 1100).padding(20),
                         to: directory.appendingPathComponent("network-events.png"), size: NSSize(width: 1140, height: 820))
            await render(DrumsCard().environment(model).frame(width: 1100).padding(20),
                         to: directory.appendingPathComponent("drums.png"), size: NSSize(width: 1140, height: 900))
            model.stop()
            exit(0)
        }
        NSApplication.shared.run()
    }

    static func render(_ view: some View, to url: URL, size: NSSize = NSSize(width: 1280, height: 860)) async {
        // Offscreen capture doesn't draw the window background, so paint it in.
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -30_000, y: -30_000), size: size),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(800)) // let SwiftUI and Charts settle
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        window.close()
    }
}

// MARK: - Profiling (headless performance check)

/// Counters bumped by views; cheap enough to leave in.
@MainActor
enum Perf {
    static var paramRowBodies = 0
    static var canvasFrames = 0
}

@MainActor
enum Profile {
    /// Show one section in an offscreen window for `seconds`, then report how often controls and
    /// visuals re-rendered and how much CPU the app used.
    static func run(model: AppModel, section: SidebarItem, seconds: Double, interact: Bool) {
        setvbuf(stdout, nil, _IOLBF, 0)
        // The offscreen window counts as hidden; --hidden measures that case instead.
        model.forceVisualsActive = true // don't let the offscreen window's occlusion state decide
        model.visualsActive = !args.contains("--hidden")
        NSApplication.shared.setActivationPolicy(.prohibited)
        Task { @MainActor in
            await model.start()
            let host = NSHostingView(rootView: ContentView(selection: section).environment(model)
                .background(Color(nsColor: .windowBackgroundColor)))
            let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 1280, height: 860),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFrontRegardless()
            try? await Task.sleep(for: .seconds(3)) // settle
            Perf.paramRowBodies = 0
            Perf.canvasFrames = 0
            let cpu0 = cpuSeconds(), wall0 = Date()
            var drags = 0
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                if interact {
                    // Simulate dragging a slider: 30 changes a second.
                    model.set("gen.pulse.density", 0.05 + 0.4 * abs(sin(Date().timeIntervalSince1970)))
                    drags += 1
                }
                try? await Task.sleep(for: .milliseconds(33))
            }
            let wall = Date().timeIntervalSince(wall0), cpu = cpuSeconds() - cpu0
            print(String(format: "PROFILE %@%@: %.0f param-row renders/s, %.0f visual frames/s, CPU %.0f%% of one core",
                         section.rawValue, interact ? " (+slider drag)" : "",
                         Double(Perf.paramRowBodies) / wall, Double(Perf.canvasFrames) / wall, 100 * cpu / wall))
            model.stop()
            exit(0)
        }
        NSApplication.shared.run()
    }

    static func cpuSeconds() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
    }
}
