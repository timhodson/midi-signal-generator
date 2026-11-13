import AUHost
import Engine
import Music
import Foundation
import MIDIOut
import Router
import SignalBus
import Sources

/// Where signals come from.
public enum SourceChoice: Sendable, Equatable {
    case nettop
    case synthetic
    case replay(URL, speed: Double, loop: Bool)

    /// Parses the CLI form: "nettop", "synthetic", "replay:<path>".
    public init?(_ text: String, speed: Double = 1, loop: Bool = false) {
        switch text {
        case "nettop": self = .nettop
        case "synthetic": self = .synthetic
        case let s where s.hasPrefix("replay:"):
            self = .replay(URL(fileURLWithPath: String(s.dropFirst("replay:".count))), speed: speed, loop: loop)
        default: return nil
        }
    }

    public var isReplay: Bool {
        if case .replay = self { true } else { false }
    }

    public var label: String {
        switch self {
        case .nettop: "Live traffic (this Mac)"
        case .synthetic: "Synthetic"
        case .replay(let url, let speed, let loop):
            "Replay \(url.lastPathComponent)\(speed != 1 ? " ×\(speed.formatted())" : "")\(loop ? " (loop)" : "")"
        }
    }
}

public struct SessionOptions: Sendable {
    public enum Output: Sendable {
        /// Hosted synths and MIDI destinations, for real.
        case live
        /// Load hosted synths (so their params exist) but send nothing anywhere.
        case listing
        /// Load nothing, send nothing (dry run, scene dump).
        case silent
    }

    /// Packet-level events (DNS, handshakes…) from the capture helper, over OSC.
    public struct Packets: Sendable, Equatable {
        public var port: UInt16
        /// Start msg-pcap ourselves when this user may capture.
        public var startHelper: Bool
        public var interface: String?
        public init(port: UInt16 = OSCSource.defaultPort, startHelper: Bool = true, interface: String? = nil) {
            self.port = port
            self.startHelper = startHelper
            self.interface = interface
        }
    }

    public var source: SourceChoice
    public var output: Output
    public var record: URL?
    public var networkSession: Bool
    /// Listen for packet events (ignored when replaying: a recording already holds them).
    public var packets: Packets?

    public init(source: SourceChoice = .nettop, output: Output = .live, record: URL? = nil, networkSession: Bool = false,
                packets: Packets? = nil) {
        self.packets = packets
        self.source = source
        self.output = output
        self.record = record
        self.networkSession = networkSession
    }
}

/// One running (or ready-to-run) configuration: hosted synths + MIDI outputs + engine +
/// source. Shared by the CLI and the app so both build sessions the same way.
public final class Session: @unchecked Sendable {
    public let scene: Scene
    public let options: SessionOptions
    public let engine: Engine
    public let auHost: AUHostSink?
    public let coreMIDI: CoreMIDISink?
    public let replay: ReplaySource?
    /// The capture helper, when this session started it.
    public private(set) var packetHelper: Process?
    /// Set when packet capture is wanted but not running: how to get it going.
    public private(set) var packetHint: String?
    /// Human-readable notes about setup (loaded synths, missing destinations…).
    public private(set) var notes: [String] = []

    /// Build a session. Must be awaited on the main actor: Audio Units are delivered there.
    @MainActor
    public static func make(scene: Scene, options: SessionOptions) async throws -> Session {
        var notes: [String] = []
        var auHost: AUHostSink?
        if !scene.instruments.isEmpty, options.output != .silent {
            let host = try await AUHostSink.load(scene.instruments)
            for i in scene.instruments { notes.append("→ AU: \(i.id) = \(i.component)\(i.preset.map { " (\($0))" } ?? "")") }
            auHost = host
        }

        var coreMIDI: CoreMIDISink?
        var fallback: MIDISink = PrintSink { _ in } // the engine logs notes itself
        let external = Set(scene.voices.map(\.destination).filter { !$0.hasPrefix(InstrumentConfig.destinationPrefix) })
        // Live sessions always get CoreMIDI, so a voice can be moved to a device while running.
        if options.output == .live {
            let c = CoreMIDISink()
            try c.start(destinations: external, enableNetworkSession: options.networkSession)
            for (name, ok) in c.connectedDestinations().sorted(by: { $0.key < $1.key }) {
                if ok {
                    notes.append("→ MIDI: \(name)")
                } else if name == CoreMIDISink.networkDestination {
                    notes.append("⚠︎ Network MIDI session is disabled. Enable it in Audio MIDI Setup → Window → Show MIDI Studio → Network, then restart.")
                } else {
                    notes.append("⚠︎ MIDI destination \"\(name)\" not found yet — will connect when it appears.")
                }
            }
            coreMIDI = c
            fallback = c
        }
        let sink = CompositeSink(
            routes: auHost.map { [.init(claims: { $0.hasPrefix(InstrumentConfig.destinationPrefix) }, sink: $0)] } ?? [],
            fallback: fallback
        )
        let engine = try Engine(scene: scene, sink: sink)

        var replay: ReplaySource?
        switch options.source {
        case .nettop: engine.add(NettopSource())
        case .synthetic: engine.add(SyntheticSource(seed: scene.seed))
        case .replay(let url, let speed, let loop):
            let r = try ReplaySource(url: url, speed: speed, loop: loop)
            notes.append(String(format: "▶︎ replaying %@: %d batches, %.0f s (recorded %@ from %@)", url.lastPathComponent,
                                r.batches.count, r.duration, r.header.recorded.formatted(),
                                r.header.sources.joined(separator: ", ")))
            engine.add(r)
            replay = r
        }
        var helper: Process?
        var packetHint: String?
        if let po = options.packets, options.output != .listing, !options.source.isReplay {
            do {
                engine.add(try OSCSource(port: po.port))
                let exe = PacketHelper.locate()
                if po.startHelper, let exe, PacketHelper.canCapture {
                    helper = try PacketHelper.launch(exe, port: po.port, interface: po.interface) { [engine] status in
                        if status != 0, status != 15 { engine.queue.async { engine.log("⚠︎ msg-pcap exited (\(status))") } }
                    }
                    notes.append("→ packets: msg-pcap capturing\(po.interface.map { " on \($0)" } ?? ""), features on udp \(po.port)")
                } else if exe == nil {
                    packetHint = "msg-pcap wasn't found next to this app. Build it with `swift build`, then run it with sudo."
                    notes.append("⚠︎ \(packetHint!)")
                } else {
                    packetHint = PacketHelper.permissionHint(helper: exe, port: po.port)
                    notes.append("⚠︎ \(packetHint!) (listening on udp \(po.port) meanwhile)")
                }
            } catch {
                packetHint = "\(error)"
                notes.append("⚠︎ packets: \(error)")
            }
        }

        if let url = options.record {
            engine.recorder = try SignalRecorder(url: url, sources: [options.source.label])
            notes.append("● recording signals to \(url.path)")
        }

        let session = Session(scene: scene, options: options, engine: engine, auHost: auHost, coreMIDI: coreMIDI, replay: replay)
        session.notes = notes
        session.packetHelper = helper
        session.packetHint = packetHint
        return session
    }

    private init(scene: Scene, options: SessionOptions, engine: Engine, auHost: AUHostSink?,
                 coreMIDI: CoreMIDISink?, replay: ReplaySource?) {
        self.scene = scene
        self.options = options
        self.engine = engine
        self.auHost = auHost
        self.coreMIDI = coreMIDI
        self.replay = replay
    }

    public func start() throws { try engine.start() }

    /// Stop sources, release notes, let synth tails ring for `tail` seconds, stop audio.
    public func stop(tail: TimeInterval = 1.5) {
        if let h = packetHelper, h.isRunning { h.terminate() }
        engine.stop()
        auHost?.stop(tail: tail)
    }

    /// The scene including every tweak made since it was loaded.
    public func currentScene() -> Scene { engine.queue.sync { engine.currentScene() } }

    /// How often the engine publishes status (e.g. slower while the UI is hidden), from any thread.
    public func setStatusInterval(_ seconds: Double) {
        engine.queue.async { [engine] in engine.statusInterval = seconds }
    }

    /// Replace the motif designs (live), from any thread.
    public func setMotifs(_ designs: [MotifDesign]) {
        engine.queue.async { [engine] in engine.setMotifs(designs) }
    }

    /// Send a voice to another destination ("virtual", "network", "au:<id>" of a loaded synth, or a
    /// MIDI destination's display name), from any thread.
    public func setDestination(_ role: String, _ destination: String) {
        engine.queue.async { [engine, coreMIDI] in
            if !destination.hasPrefix(InstrumentConfig.destinationPrefix) {
                do { try coreMIDI?.connect(destination) } catch { engine.log("⚠︎ could not connect to \(destination): \(error)") }
            }
            engine.setVoiceDestination(role, destination)
        }
    }

    /// Which external destinations currently reach a device. Blocks briefly on the engine queue.
    public func destinationStatus() -> [String: Bool] {
        engine.queue.sync { coreMIDI?.connectedDestinations() ?? [:] }
    }

    /// Vary the piece at the next chord change, from any thread.
    public func randomise() { engine.queue.async { [engine] in engine.randomiseNow() } }

    /// Back to the home settings at the next chord change, from any thread.
    public func returnHome() { engine.queue.async { [engine] in engine.returnHome() } }

    /// Make what's playing the new home, from any thread.
    public func makeHome() { engine.queue.async { [engine] in engine.makeHome() } }

    /// MIDI clock: Stop now, Start again on the next bar line, from any thread.
    public func restartClock() { engine.queue.async { [engine] in engine.restartClock() } }

    /// Replace the edited drum grooves (live), from any thread.
    public func setGrooves(_ grooves: [DrumGroove]) {
        engine.queue.async { [engine] in engine.setGrooves(grooves) }
    }

    /// Play an app's motif now, from any thread.
    public func previewMotif(for app: String) {
        engine.queue.async { [engine] in engine.previewMotif(for: app) }
    }

    /// Hear a chord now, from any thread.
    public func auditionChord(_ degree: Int) {
        engine.queue.async { [engine] in engine.auditionChord(degree) }
    }

    /// Replace a mood's (or gesture's) chord progression, from any thread.
    public func setProgression(_ mood: String, _ degrees: [Int]) {
        engine.queue.async { [engine] in engine.setProgression(mood, degrees) }
    }

    /// Set a param from any thread.
    public func set(_ id: String, _ value: Double) {
        engine.queue.async { [engine] in try? engine.setParam(id, value) }
    }
}
