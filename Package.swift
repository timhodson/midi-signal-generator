// swift-tools-version: 6.0
import Foundation
import PackageDescription

let appInfoPlist = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("Sources/msg-app/Info.plist").path

let package = Package(
    name: "MIDISignalGenerator",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "msg-spike", targets: ["msg-spike"]),
        .executable(name: "msg-app", targets: ["msg-app"]),
        .executable(name: "msg-pcap", targets: ["msg-pcap"]),
        .library(name: "MSGEngine", targets: ["Engine"]),
    ],
    dependencies: [
        .package(url: "https://github.com/AudioKit/Tonic.git", from: "2.1.2"),
        .package(url: "https://github.com/orchetect/swift-midi-io.git", from: "1.1.0"),
        .package(url: "https://github.com/AudioKit/Controls.git", from: "1.1.4"),
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
        // Minimal OSC codec; signals travel between processes as OSC (ADR 0008).
        .target(name: "OSC", dependencies: ["SignalBus"]),
        // Data sources (nettop process traffic, synthetic, OSC in).
        .target(name: "Sources", dependencies: ["SignalBus", "OSC"]),
        // Packet decoding and musical features (DNS, handshakes, LAN chatter). Pure Swift, no libpcap.
        .target(name: "PacketFeatures", dependencies: ["SignalBus"]),
        // libpcap, as shipped with macOS.
        .systemLibrary(name: "CPcap"),
        // The packet capture helper: needs capture permission, sends features to the engine as OSC (ADR 0015).
        .executableTarget(name: "msg-pcap", dependencies: ["CPcap", "PacketFeatures", "OSC", "SignalBus"]),
        // Wires everything together and owns the clock.
        .target(name: "Engine", dependencies: ["Params", "SignalBus", "Music", "Router", "MIDIOut", "Sources"]),
        // Builds a session (hosted synths + MIDI + engine + source); shared by CLI and app.
        .target(name: "Runtime", dependencies: ["Engine", "AUHost", "MIDIOut", "Music", "Router", "SignalBus", "Sources"]),
        .executableTarget(name: "msg-spike", dependencies: ["Runtime", "Engine", "AUHost"]),
        // The Mac app: SwiftUI panels generated from ParamSpecs, scopes, synth editors.
        .executableTarget(name: "msg-app", dependencies: [
            "Runtime", "Engine", "AUHost", "MIDIOut", "Music", "Params", "Router", "Sources",
            .product(name: "Controls", package: "Controls"),
        ], exclude: ["Info.plist"], resources: [.copy("Skin")], linkerSettings: [
            // An embedded Info.plist, so macOS lets the unbundled app use Bluetooth (pairing
            // Bluetooth MIDI devices) and shows the reason.
            .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", appInfoPlist]),
        ]),

        .testTarget(name: "ParamsTests", dependencies: ["Params"]),
        .testTarget(name: "MusicTests", dependencies: ["Music", "Params", "SignalBus"]),
        .testTarget(name: "RouterTests", dependencies: ["Router", "Music", "Params"]),
        .testTarget(name: "SourcesTests", dependencies: ["Sources", "SignalBus", "OSC"]),
        .testTarget(name: "PacketFeaturesTests", dependencies: ["PacketFeatures", "SignalBus"]),
        .testTarget(name: "MIDIOutTests", dependencies: ["MIDIOut", "Router", "Params"]),
        .testTarget(name: "EngineTests", dependencies: ["Engine", "MIDIOut", "Music"]),
        .testTarget(name: "AUHostTests", dependencies: ["AUHost", "Params", "Router"]),
    ]
)
