// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MIDISignalGenerator",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "msg-spike", targets: ["msg-spike"]),
        .executable(name: "msg-app", targets: ["msg-app"]),
        .library(name: "MSGEngine", targets: ["Engine"]),
    ],
    dependencies: [
        .package(url: "https://github.com/AudioKit/Tonic.git", from: "2.1.2"),
        .package(url: "https://github.com/orchetect/swift-midi-io.git", from: "1.1.0"),
    ],
    targets: [
        // Pure, dependency-free core: every tunable value lives here.
        .target(name: "Params"),
        // Events / streams from any data source, normalised into one bus.
        .target(name: "SignalBus"),
        // Conductor, quantiser, generators: the musical "brain".
        .target(name: "Music", dependencies: [
            "Params", "SignalBus",
            .product(name: "Tonic", package: "Tonic"),
        ]),
        // Role -> device/channel/range mapping.
        .target(name: "Router", dependencies: ["Params", "Music"]),
        // Note scheduling + CoreMIDI output (virtual port, network session).
        .target(name: "MIDIOut", dependencies: [
            "Router", "Params",
            .product(name: "SwiftMIDIIO", package: "swift-midi-io"),
        ]),
        // Hosts Audio Unit instruments (e.g. Synth One J6, King of FM) as MIDI destinations.
        .target(name: "AUHost", dependencies: ["MIDIOut", "Router", "Params"]),
        // Data sources (nettop process traffic, synthetic).
        .target(name: "Sources", dependencies: ["SignalBus"]),
        // Wires everything together and owns the clock.
        .target(name: "Engine", dependencies: ["Params", "SignalBus", "Music", "Router", "MIDIOut", "Sources"]),
        // Builds a session (hosted synths + MIDI + engine + source); shared by CLI and app.
        .target(name: "Runtime", dependencies: ["Engine", "AUHost", "MIDIOut", "Router", "SignalBus", "Sources"]),
        .executableTarget(name: "msg-spike", dependencies: ["Runtime", "Engine", "AUHost"]),
        // The Mac app: SwiftUI panels generated from ParamSpecs, scopes, synth editors.
        .executableTarget(name: "msg-app", dependencies: ["Runtime", "Engine", "AUHost", "Params", "Router", "Sources"]),

        .testTarget(name: "ParamsTests", dependencies: ["Params"]),
        .testTarget(name: "MusicTests", dependencies: ["Music", "Params", "SignalBus"]),
        .testTarget(name: "RouterTests", dependencies: ["Router", "Music", "Params"]),
        .testTarget(name: "SourcesTests", dependencies: ["Sources", "SignalBus"]),
        .testTarget(name: "MIDIOutTests", dependencies: ["MIDIOut", "Router", "Params"]),
        .testTarget(name: "AUHostTests", dependencies: ["AUHost"]),
    ]
)
