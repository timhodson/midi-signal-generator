import AppKit
import Engine
import Foundation
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

    if let dir = arg("--snapshot") {
        Snapshot.run(model: model, directory: URL(fileURLWithPath: dir), seconds: Double(arg("--seconds") ?? "") ?? 8)
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
    static func run(model: AppModel, directory: URL, seconds: Double) {
        setvbuf(stdout, nil, _IOLBF, 0)
        NSApplication.shared.setActivationPolicy(.prohibited)
        Task { @MainActor in
            await model.start()
            if let error = model.error { print("start error: \(error)") }
            try? await Task.sleep(for: .seconds(seconds))
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for item in SidebarItem.allCases {
                let url = directory.appendingPathComponent("\(item.rawValue.lowercased()).png")
                await render(ContentView(selection: item).environment(model), to: url)
                print("wrote \(url.path)")
            }
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
