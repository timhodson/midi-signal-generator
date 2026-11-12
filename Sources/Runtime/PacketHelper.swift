import Darwin
import Foundation

/// Finds and starts `msg-pcap`, the packet capture helper (docs/decisions/0015-packet-capture-helper.md).
///
/// The engine never captures packets itself. If this user can read /dev/bpf* (Wireshark's
/// ChmodBPF gives the access_bpf group that), the session starts the helper as a child that
/// exits with it. Otherwise the user runs `sudo msg-pcap` in a terminal; it drops privileges
/// after opening the device and sends features to the same port either way.
public enum PacketHelper {
    public static let chmodBPFPlist = "/Library/LaunchDaemons/org.wireshark.ChmodBPF.plist"

    /// msg-pcap next to the running executable (SwiftPM puts all products in one folder).
    public static func locate() -> URL? {
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let candidates = [
            exe.deletingLastPathComponent().appendingPathComponent("msg-pcap"),
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("msg-pcap"),
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// True if this user can open a capture device without sudo.
    public static var canCapture: Bool {
        (0..<4).contains { access("/dev/bpf\($0)", R_OK) == 0 }
    }

    public static var hasChmodBPF: Bool { FileManager.default.fileExists(atPath: chmodBPFPlist) }

    /// How to get capture working, for a note or a UI hint.
    public static func permissionHint(helper: URL?, port: UInt16) -> String {
        let path = helper?.path ?? "msg-pcap"
        var hint = "Packet capture needs permission. In a terminal run:  sudo \(path) --osc 127.0.0.1:\(port)"
        if hasChmodBPF {
            hint += "  — or, once (Wireshark's ChmodBPF is installed):  sudo launchctl kickstart -k system/org.wireshark.ChmodBPF  and restart"
        }
        return hint
    }

    /// Start the helper as a child process sending to `port`. It exits when this process does.
    public static func launch(_ helper: URL, port: UInt16, interface: String? = nil,
                              onExit: @escaping @Sendable (Int32) -> Void = { _ in }) throws -> Process {
        let p = Process()
        p.executableURL = helper
        p.arguments = ["--osc", "127.0.0.1:\(port)", "--parent-pid", String(getpid())] + (interface.map { ["-i", $0] } ?? [])
        p.standardOutput = FileHandle.nullDevice
        p.terminationHandler = { onExit($0.terminationStatus) }
        try p.run()
        return p
    }
}
