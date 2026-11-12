import AppKit
import AUHost
import Dispatch
import Engine
import Foundation
import MIDIOut
import Params
import Router
import Sources

let usage = """
msg-spike — turn this Mac's network traffic into MIDI.

USAGE: msg-spike [options]

  --source nettop|synthetic|replay:<file>
                              Data source (default: nettop = real per-app traffic).
                              replay plays back a --record file with its original timing.
  --record <file.jsonl>       Also record every incoming signal to this file.
  --speed <x>                 Replay speed (default 1; 4 = four times faster).
  --loop                      Loop the replay.
  --scene <file.json>         Load a scene (default: built-in; see scenes/default.json).
  --set <id=value>            Override a parameter or macro. Repeatable.
                              e.g. --set macro.faithfulness=0.2 --set harmony.scale=4
  --dest <name>               Send every voice to this MIDI destination instead of the
                              scene's. "virtual" = this app's own port, "network" =
                              Apple's network MIDI session (iPad), or any name from
                              --list-destinations (e.g. "IAC Driver Bus 1").
  --au <role>=<synth>[@preset]
                              Play a role on a hosted Audio Unit instrument, e.g.
                              --au pad="Synth One J6@2025: Space Trip". Repeatable.
  --network-session           Let devices (iPad) join this Mac's network MIDI session.
  --dry-run                   Print notes; send no MIDI.
  --verbose                   Print every note while sending MIDI.
  --duration <seconds>        Stop after this long (default: run until Ctrl-C).
  --list-params               Print every tunable parameter and exit.
  --list-destinations         Print MIDI destinations on this Mac and exit.
  --list-instruments          Print Audio Unit instruments on this Mac and exit.
  --list-options <param>      Print every option of a choice param (e.g. au.pad.preset).
  --dump-scene                Print the effective scene as JSON and exit.
  -h, --help                  Show this help.
"""

struct Options {
    var source = "nettop"
    var record: String?
    var speed = 1.0
    var loop = false
    var scenePath: String?
    var sets: [(String, Double)] = []
    var dest: String?
    var au: [(role: String, component: String, preset: String?)] = []
    var listInstruments = false
    var listOptions: String?
    var networkSession = false
    var dryRun = false
    var verbose = false
    var duration: Double?
    var listParams = false
    var listDestinations = false
    var dumpScene = false
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

func parse(_ args: [String]) -> Options {
    var o = Options()
    var it = args.makeIterator()
    func value(_ flag: String) -> String {
        guard let v = it.next() else { fail("\(flag) needs a value") }
        return v
    }
    while let a = it.next() {
        switch a {
        case "--source": o.source = value(a)
        case "--record": o.record = value(a)
        case "--speed":
            guard let v = Double(value(a)), v > 0 else { fail("--speed needs a positive number") }
            o.speed = v
        case "--loop": o.loop = true
        case "--scene": o.scenePath = value(a)
        case "--set":
            let kv = value(a).split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2, let v = Double(kv[1]) else { fail(ParamError.malformed(kv.joined(separator: "=")).description) }
            o.sets.append((kv[0], v))
        case "--dest": o.dest = value(a)
        case "--au":
            let kv = value(a).split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { fail("--au needs role=synth[@preset]") }
            let parts = kv[1].split(separator: "@", maxSplits: 1).map(String.init)
            o.au.append((kv[0], parts[0], parts.count > 1 ? parts[1] : nil))
        case "--list-instruments": o.listInstruments = true
        case "--list-options": o.listOptions = value(a)
        case "--network-session": o.networkSession = true
        case "--dry-run": o.dryRun = true
        case "--verbose": o.verbose = true
        case "--duration":
            guard let d = Double(value(a)) else { fail("--duration needs a number of seconds") }
            o.duration = d
        case "--list-params": o.listParams = true
        case "--list-destinations": o.listDestinations = true
        case "--dump-scene": o.dumpScene = true
        case "-h", "--help": print(usage); exit(0)
        default: fail("unknown option \(a)\n\n\(usage)")
        }
    }
    return o
}

let options = parse(Array(CommandLine.arguments.dropFirst()))

var scene = Scene.default
if let path = options.scenePath {
    do { scene = try Scene.load(URL(fileURLWithPath: path)) } catch { fail("could not load scene \(path): \(error)") }
}
if let dest = options.dest {
    scene.voices = scene.voices.map { var v = $0; v.destination = dest; return v }
}
for au in options.au {
    guard let i = scene.voices.firstIndex(where: { $0.role == au.role }) else {
        fail("--au: no voice with role \"\(au.role)\" (roles: \(scene.voices.map(\.role).joined(separator: ", ")))")
    }
    scene.instruments.removeAll { $0.id == au.role }
    scene.instruments.append(InstrumentConfig(id: au.role, component: au.component, preset: au.preset))
    scene.voices[i].destination = "au:\(au.role)"
}
for (id, value) in options.sets { scene.params[id] = value }

if options.listInstruments {
    print("Audio Unit instruments on this Mac (use with --au or a scene's \"instruments\"):")
    for c in AUHostSink.availableInstruments() { print("  \(c.manufacturerName): \(c.name)") }
    exit(0)
}

/// Run an async operation from top-level code, servicing the main run loop meanwhile
/// (AVAudioUnit delivers instantiation on the main queue).
final class ResultBox<T>: @unchecked Sendable { var result: Result<T, Error>? }

func blocking<T>(_ op: @escaping () async throws -> T) throws -> T {
    let box = ResultBox<T>()
    nonisolated(unsafe) let work = op
    Task { @MainActor in
        do { box.result = .success(try await work()) } catch { box.result = .failure(error) }
    }
    while box.result == nil { RunLoop.main.run(until: Date() + 0.02) }
    return try box.result!.get()
}

if options.listDestinations {
    let sink = CoreMIDISink()
    do { try sink.start(destinations: [], enableNetworkSession: options.networkSession) } catch { fail("\(error)") }
    print("MIDI destinations on this Mac (use with --dest or a voice's \"destination\"):")
    print("  virtual  (this app's own virtual source, \"MIDI Signal Generator\")")
    print(CoreMIDISink.networkSessionDestinationID() == nil
        ? "  network  (Apple network MIDI session — currently DISABLED; enable it in Audio MIDI Setup → Network)"
        : "  network  (Apple network MIDI session — enabled)")
    for name in sink.availableDestinations() { print("  \(name)") }
    exit(0)
}

let sink: MIDISink
var coreMIDI: CoreMIDISink?
let quiet = options.dryRun || options.dumpScene

// Audio Unit plugins talk to AppKit (ViewBridge) even without showing a UI, so a hosting
// process needs an NSApplication and a running main run loop. No Dock icon or menu bar.
if !scene.instruments.isEmpty {
    NSApplication.shared.setActivationPolicy(.prohibited)
}

// Hosted instruments: loaded for real runs, and for listings so their params show up.
let auHost: AUHostSink? = {
    guard !scene.instruments.isEmpty, !quiet else { return nil }
    let configs = scene.instruments
    do {
        let host = try blocking { try await AUHostSink.load(configs) }
        for i in configs { print("→ AU: \(i.id) = \(i.component)\(i.preset.map { " (\($0))" } ?? "")") }
        return host
    } catch { fail("could not load instruments: \(error)") }
}()

if quiet || options.listParams || options.listOptions != nil {
    sink = CompositeSink(routes: auHost.map { [.init(claims: { $0.hasPrefix(InstrumentConfig.destinationPrefix) }, sink: $0)] } ?? [],
                         fallback: PrintSink { _ in }) // notes are logged by the engine instead
} else {
    let external = Set(scene.voices.map(\.destination).filter { !$0.hasPrefix(InstrumentConfig.destinationPrefix) })
    var fallback: MIDISink = PrintSink { _ in }
    if !external.isEmpty {
        let c = CoreMIDISink()
        do { try c.start(destinations: external, enableNetworkSession: options.networkSession) } catch { fail("MIDI start failed: \(error)") }
        coreMIDI = c
        fallback = c
    }
    sink = CompositeSink(routes: auHost.map { [.init(claims: { $0.hasPrefix(InstrumentConfig.destinationPrefix) }, sink: $0)] } ?? [],
                         fallback: fallback)
}

let engine: Engine
do { engine = try Engine(scene: scene, sink: sink) } catch { fail("\(error)") }

if options.listParams {
    for id in engine.params.order {
        let s = engine.params.specs[id]!
        let range = s.kind == .choice && s.options.count > 16
            ? "0…\(s.options.count - 1): \(s.options.count) options, see --list-options \(id)"
            : s.kind == .choice
            ? s.options.enumerated().map { "\($0.offset)=\($0.element)" }.joined(separator: " ")
            : "\(s.range.lowerBound)…\(s.range.upperBound)\(s.unit.isEmpty ? "" : " \(s.unit)")"
        let mod = s.modulatable ? " [mod]" : ""
        print("\(id) = \(engine.params.baseValue(id))  (\(range))\(mod)\n    \(s.help)")
    }
    exit(0)
}

if let id = options.listOptions {
    guard let s = engine.params.specs[id], s.kind == .choice else { fail("\(id) is not a choice param") }
    for (i, o) in s.options.enumerated() { print("\(i)\t\(o)") }
    exit(0)
}

if options.dumpScene {
    var effective = scene
    // Macros are left out (their effect is already in the target values) so the dump
    // round-trips; route depths go back into the routes themselves.
    effective.params = engine.params.baseValues.filter { !$0.key.hasPrefix("mod.") && !$0.key.hasPrefix("macro.") }
    // Instruments aren't loaded for a dump, so keep the scene's own au.* values.
    for (id, v) in scene.params where id.hasPrefix("au.") { effective.params[id] = v }
    for i in effective.routes.indices { effective.routes[i].amount = engine.params.baseValue("mod.\(i).amount") }
    print(String(decoding: try! effective.encoded(), as: UTF8.self))
    exit(0)
}

if let c = coreMIDI {
    for (name, ok) in c.connectedDestinations().sorted(by: { $0.key < $1.key }) {
        if ok {
            print("→ MIDI: \(name)")
        } else if name == CoreMIDISink.networkDestination {
            print("⚠︎ Network MIDI session is disabled. Enable it in Audio MIDI Setup → Window → Show MIDI Studio → Network, then restart.")
        } else {
            print("⚠︎ MIDI destination \"\(name)\" not found yet — will connect when it appears. Try --list-destinations.")
        }
    }
}

engine.logNotes = options.dryRun || options.verbose
switch options.source {
case "nettop": engine.add(NettopSource())
case "synthetic": engine.add(SyntheticSource(seed: scene.seed))
case let s where s.hasPrefix("replay:"):
    let path = String(s.dropFirst("replay:".count))
    do {
        let replay = try ReplaySource(url: URL(fileURLWithPath: path), speed: options.speed, loop: options.loop)
        print(String(format: "▶︎ replaying %@: %d batches, %.0f s (recorded %@ from %@)", path, replay.batches.count,
                     replay.duration, replay.header.recorded.formatted(), replay.header.sources.joined(separator: ", ")))
        engine.add(replay)
    } catch { fail("\(error)") }
default: fail("unknown source \(options.source)")
}
if let path = options.record {
    do {
        engine.recorder = try SignalRecorder(url: URL(fileURLWithPath: path), sources: [options.source])
        print("● recording signals to \(path)")
    } catch { fail("could not record: \(error)") }
}

do { try engine.start() } catch { fail("could not start: \(error)") }
print("Running \"\(scene.name)\". Ctrl-C to stop.")

func shutdown() -> Never {
    engine.stop()
    auHost?.stop()
    print("\nstopped, all notes off.")
    exit(0)
}

signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigint.setEventHandler { shutdown() }
sigint.resume()
let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigterm.setEventHandler { shutdown() }
sigterm.resume()
if let d = options.duration {
    DispatchQueue.main.asyncAfter(deadline: .now() + d) { shutdown() }
}
if let host = auHost {
    if options.verbose {
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            let db = 20 * log10(max(Double(host.takePeak()), 1e-6))
            print(String(format: "· audio peak %.1f dBFS", db))
        }
    }
    NSApplication.shared.run()
} else {
    dispatchMain()
}
