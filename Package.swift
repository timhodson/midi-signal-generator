// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MIDISignalGenerator",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "msg-spike", targets: ["msg-spike"]),
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
            "Router",
            .product(name: "SwiftMIDIIO", package: "swift-midi-io"),
        ]),
        // Data sources (nettop process traffic, synthetic).
        .target(name: "Sources", dependencies: ["SignalBus"]),
        // Wires everything together and owns the clock.
        .target(name: "Engine", dependencies: ["Params", "SignalBus", "Music", "Router", "MIDIOut", "Sources"]),
        .executableTarget(name: "msg-spike", dependencies: ["Engine"]),

        .testTarget(name: "ParamsTests", dependencies: ["Params"]),
        .testTarget(name: "MusicTests", dependencies: ["Music", "Params", "SignalBus"]),
        .testTarget(name: "RouterTests", dependencies: ["Router", "Music", "Params"]),
        .testTarget(name: "SourcesTests", dependencies: ["Sources", "SignalBus"]),
        .testTarget(name: "MIDIOutTests", dependencies: ["MIDIOut", "Router"]),
    ]
)
