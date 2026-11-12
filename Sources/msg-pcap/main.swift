import CPcap
import Darwin
import Foundation
import OSC
import PacketFeatures
import SignalBus

/// msg-pcap — the packet capture helper (docs/decisions/0015-packet-capture-helper.md).
///
/// Captures packet *headers* on one interface, turns them into features (DNS lookups,
/// connection handshakes with their round trip, closes, LAN announcements, protocol rates)
/// and sends those to the engine as OSC. Nothing else leaves this process.
///
///   msg-pcap [-i <interface>] [--osc host:port] [--print] [--parent-pid N]
///   msg-pcap -r <file.pcap> --print          decode a capture file (no permission needed)
///   msg-pcap --list-interfaces
///
/// Capturing needs read access to /dev/bpf*: run with sudo (it drops back to your user right
/// after opening the device), or let Wireshark's ChmodBPF give the access_bpf group access.

let args = Array(CommandLine.arguments.dropFirst())
func arg(_ name: String, _ short: String? = nil) -> String? {
    guard let i = args.firstIndex(where: { $0 == name || $0 == short }), i + 1 < args.count else { return nil }
    return args[i + 1]
}
func flag(_ name: String) -> Bool { args.contains(name) }

if flag("--help") || flag("-h") {
    print("""
    msg-pcap — packet features for the MIDI signal generator

      -i, --interface <name>   interface to capture (default: the one with the default route)
      -r, --read <file.pcap>   read a capture file instead of a live interface
      --osc <host:port>        where to send features (default 127.0.0.1:\(57121))
      --print                  print features instead of (or as well as, with --osc) sending them
      --parent-pid <pid>       exit when this process exits (used when the engine starts the helper)
      --list-interfaces        list capture interfaces

    Live capture needs /dev/bpf access: `sudo msg-pcap` (drops privileges after opening), or
    `sudo launchctl kickstart -k system/org.wireshark.ChmodBPF` if Wireshark's ChmodBPF is installed.
    """)
    exit(0)
}

var errbuf = [CChar](repeating: 0, count: Int(PCAP_ERRBUF_SIZE))

if flag("--list-interfaces") {
    var devs: UnsafeMutablePointer<pcap_if_t>?
    guard pcap_findalldevs(&devs, &errbuf) == 0 else { fatal(text(errbuf)) }
    var d = devs
    while let dev = d {
        let up = dev.pointee.flags & UInt32(PCAP_IF_UP) != 0
        let desc = dev.pointee.description.map { " — " + String(cString: $0) } ?? ""
        print("\(String(cString: dev.pointee.name))\(up ? "" : " (down)")\(desc)")
        d = dev.pointee.next
    }
    pcap_freealldevs(devs)
    exit(0)
}

/// A NUL-terminated C buffer as a String.
func text(_ buffer: [CChar]) -> String {
    String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

func fatal(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("msg-pcap: \(message)\n".utf8))
    exit(code)
}

/// The interface carrying the default route ("en0" on most Macs; "utun3" behind a VPN).
func defaultInterface() -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/sbin/route")
    p.arguments = ["-n", "get", "default"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return "en0" }
    p.waitUntilExit()
    let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    for line in out.split(separator: "\n") {
        let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count == 2, parts[0] == "interface" { return parts[1] }
    }
    return "en0"
}

// MARK: - Open

let file = arg("--read", "-r")
let interface = arg("--interface", "-i") ?? defaultInterface()
let printing = flag("--print")
let handle: OpaquePointer

if let file {
    guard let h = pcap_open_offline(file, &errbuf) else { fatal(text(errbuf)) }
    handle = h
} else {
    guard let h = pcap_create(interface, &errbuf) else { fatal(text(errbuf)) }
    pcap_set_snaplen(h, 2048)       // headers + DNS + a TLS ClientHello's first segment
    pcap_set_promisc(h, 0)          // this Mac's own traffic only
    pcap_set_timeout(h, 200)
    pcap_set_immediate_mode(h, 1)
    pcap_set_buffer_size(h, 4 << 20)
    let status = pcap_activate(h)
    if status == PCAP_ERROR_PERM_DENIED || status == PCAP_ERROR {
        let detail = String(cString: pcap_geterr(h))
        fatal("""
            cannot capture on \(interface): \(detail)
            Capture needs read access to /dev/bpf*. Either:
              sudo \(CommandLine.arguments[0]) \(args.joined(separator: " "))
            or, with Wireshark's ChmodBPF installed (it gives the access_bpf group access):
              sudo launchctl kickstart -k system/org.wireshark.ChmodBPF
            """, code: 77)
    } else if status < 0 {
        fatal("cannot capture on \(interface): \(String(cString: pcap_statustostr(status)))")
    }
    handle = h
}

// Opened: if we were started with sudo, go back to being the user who ran it.
if getuid() == 0, let gid = ProcessInfo.processInfo.environment["SUDO_GID"].flatMap(gid_t.init),
   let uid = ProcessInfo.processInfo.environment["SUDO_UID"].flatMap(uid_t.init) {
    guard setgid(gid) == 0, setuid(uid) == 0 else { fatal("could not drop privileges") }
}

// MARK: - Output

final class Output {
    let extractor = FeatureExtractor()
    let sender: OSCSender?
    let printing: Bool
    let linkType: Int32
    let interface: String
    let offline: Bool
    var sent = 0

    init(sender: OSCSender?, printing: Bool, linkType: Int32, interface: String, offline: Bool) {
        self.offline = offline
        self.sender = sender
        self.printing = printing
        self.linkType = linkType
        self.interface = interface
    }

    func emit(_ samples: [SignalSample], at time: Double) {
        for s in samples {
            sender?.send(s.oscMessage)
            sent += 1
            if printing {
                let value = s.id.hasSuffix(".open") ? String(format: "%.1f ms", s.value * 1000) : String(format: "%g", s.value)
                print(String(format: "%10.3f ", time) + "\(s.kind == .event ? "●" : "~") \(s.id)\(s.key.map { " [\($0)]" } ?? "") \(value)")
            }
        }
    }

    func tick(_ time: Double) {
        var streams = extractor.streams(at: time)
        if !streams.isEmpty { streams.append(.stream("net.capture.active", key: interface, 1)) }
        emit(streams, at: time)
    }
}

let destination = arg("--osc")
let sender: OSCSender?
if destination != nil || !printing {
    let target = destination ?? "127.0.0.1:57121"
    guard let colon = target.lastIndex(of: ":"), let port = UInt16(target[target.index(after: colon)...]) else {
        fatal("--osc expects host:port, got \(target)")
    }
    do { sender = try OSCSender(host: String(target[..<colon]), port: port) } catch { fatal("\(error)") }
} else {
    sender = nil
}
let output = Output(sender: sender, printing: printing, linkType: pcap_datalink(handle),
                    interface: file.map { URL(fileURLWithPath: $0).lastPathComponent } ?? interface, offline: file != nil)
if printing { setvbuf(stdout, nil, _IOLBF, 0) }

guard [0, 1, 12, 101, 108].contains(output.linkType) else {
    fatal("unsupported link type \(output.linkType) (\(String(cString: pcap_datalink_val_to_name(output.linkType)))) on \(interface)")
}

let callback: pcap_handler = { user, header, bytes in
    guard let user, let header, let bytes else { return }
    let out = Unmanaged<Output>.fromOpaque(user).takeUnretainedValue()
    let h = header.pointee
    let time = Double(h.ts.tv_sec) + Double(h.ts.tv_usec) / 1e6
    let buffer = Bytes(UnsafeRawBufferPointer(start: bytes, count: Int(h.caplen)))
    out.emit(out.extractor.process(buffer, wireLength: Int(h.len), linkType: out.linkType, time: time), at: time)
    if out.offline { out.tick(time) } // offline: streams follow the file's clock
}

// Stop cleanly on Ctrl-C / when the engine terminates us.
nonisolated(unsafe) var activeHandle: OpaquePointer? = handle
signal(SIGINT) { _ in if let h = activeHandle { pcap_breakloop(h) } }
signal(SIGTERM) { _ in if let h = activeHandle { pcap_breakloop(h) } }
let parent = arg("--parent-pid").flatMap(pid_t.init)

if !printing || destination != nil {
    FileHandle.standardError.write(Data("msg-pcap: capturing on \(output.interface), sending features to \(destination ?? "127.0.0.1:57121")\n".utf8))
}

let context = Unmanaged.passUnretained(output).toOpaque()
while true {
    let n = pcap_dispatch(handle, -1, callback, context.assumingMemoryBound(to: UInt8.self))
    if n == PCAP_ERROR_BREAK || n == PCAP_ERROR { break }
    if file != nil, n == 0 { break } // end of file
    if file == nil { output.tick(Date().timeIntervalSince1970) }
    if let parent, kill(parent, 0) != 0 { break }
}
pcap_close(handle)
