import AppKit
import Engine
import Music
import SwiftUI

/// Generators → Network events: is capture running, what's on the wire, and what each recent
/// event played (or why it didn't).
struct NetworkEventsCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let roleIndex = min(max(Int(model.base("gen.packets.role")), 0), PacketGenerator.roles.count - 1)
        let role = PacketGenerator.roles[roleIndex]
        VStack(spacing: 10) {
            VisualCard(title: "Packet capture") {
                CaptureStatus()
                ProtocolMix()
            }
            VisualCard(title: "Recent network events",
                       caption: "Newest first. Bright rows played a figure on the \(role) voice; dim rows were skipped, with the reason. Each site keeps its own note.") {
                EventFeed()
            }
            RoleLane(role: role)
        }
    }
}

/// Capturing, waiting, or how to give permission.
struct CaptureStatus: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let status = model.status
        let live = status?.capture.map { (status?.time ?? 0) - $0.lastSeen < 4 } ?? false
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(live ? Color.green : model.packetHint != nil ? .orange : .secondary)
                .frame(width: 9, height: 9)
                .shadow(color: live ? .green : .clear, radius: 3)
            VStack(alignment: .leading, spacing: 6) {
                if !model.packetCapture {
                    Text("Packet events are off for this session (started with --no-packets).")
                } else if live, let c = status?.capture {
                    Text("Capturing on \(c.interface) · \(Int(c.packetsPerSecond.rounded())) packets/s · \(status?.signals["net.flows.tcp"].map { "\(Int($0)) open connections" } ?? "")")
                } else if let hint = model.packetHint {
                    Text("Not capturing yet").font(.callout.weight(.semibold))
                    Text(hint).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    if let command = Self.command(in: hint) {
                        Button("Copy sudo command") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(command, forType: .string)
                        }
                        .controlSize(.small)
                    }
                } else if model.isRunning {
                    Text("Waiting for msg-pcap on udp \(model.session?.options.packets.map { String($0.port) } ?? "?")…").foregroundStyle(.secondary)
                } else {
                    Text("Start the engine to listen for packet events.").foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// The first "sudo …" command in a hint, up to the next double space.
    static func command(in hint: String) -> String? {
        guard let start = hint.range(of: "sudo ") else { return nil }
        let rest = hint[start.lowerBound...]
        let end = rest.range(of: "  ")?.lowerBound ?? rest.endIndex
        return String(rest[..<end])
    }
}

/// Share of bytes by protocol over the last second, as one stacked bar.
struct ProtocolMix: View {
    @Environment(AppModel.self) private var model
    static let colors: [String: Color] = ["tcp": .blue, "quic": .purple, "dns": .orange, "lan": .green, "udp": .teal, "other": .gray]
    static let labels: [String: String] = ["tcp": "TCP", "quic": "QUIC", "dns": "DNS", "lan": "LAN chatter", "udp": "other UDP", "other": "other"]

    var body: some View {
        let cats = ["tcp", "quic", "dns", "lan", "udp", "other"]
        let values = cats.map { max(model.status?.signals["net.proto.bytesPerSec#\($0)"] ?? 0, 0) }
        let total = values.reduce(0, +)
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                HStack(spacing: 1) {
                    if total <= 0 {
                        Rectangle().fill(.quaternary)
                    } else {
                        ForEach(Array(zip(cats, values)), id: \.0) { cat, v in
                            if v > 0 {
                                Rectangle().fill(Self.colors[cat] ?? .gray)
                                    .frame(width: max(geo.size.width * v / total - 1, 1))
                            }
                        }
                    }
                }
            }
            .frame(height: 12)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            HStack(spacing: 12) {
                ForEach(Array(zip(cats, values)), id: \.0) { cat, v in
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2).fill(Self.colors[cat] ?? .gray).frame(width: 9, height: 9)
                        Text("\(Self.labels[cat] ?? cat) \(Format.rate(v))").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Text("Signals for Modulation: net.pkt.perSec, net.flows.tcp, net.proto.bytesPerSec#tcp / quic / dns / lan…")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }
}

/// The last events, newest first.
struct EventFeed: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let events = Array((model.status?.netEvents ?? []).suffix(14).reversed())
        let now = model.status?.time ?? 0
        if events.isEmpty {
            Text("No network events yet. They appear when an app looks up a name or opens a connection.")
                .font(.callout).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(events) { e in
                    HStack(spacing: 8) {
                        Image(systemName: Self.icon(e.kind)).frame(width: 16)
                            .foregroundStyle(e.played ? RoleStyle.color("pulse") : .secondary)
                        Text(Self.kindLabel(e)).frame(width: 128, alignment: .leading)
                        Text(e.name).fontWeight(e.played ? .medium : .regular).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text(e.played ? "played" : e.reason).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Text("\(Int(max(now - e.time, 0)))s").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                            .frame(width: 34, alignment: .trailing)
                    }
                    .font(.callout)
                    .opacity(e.played ? 1 : 0.55)
                    .help(e.reason)
                }
            }
        }
    }

    static func icon(_ kind: String) -> String {
        switch kind {
        case "net.dns.query": "magnifyingglass"
        case "net.tcp.open", "net.quic.open": "arrow.left.arrow.right"
        case "net.tcp.close": "xmark.circle"
        case "net.lan.announce": "antenna.radiowaves.left.and.right"
        case "net.tls.hello": "lock"
        default: "circle"
        }
    }

    static func kindLabel(_ e: EngineStatus.NetEvent) -> String {
        switch e.kind {
        case "net.dns.query": "Lookup"
        case "net.tcp.open": "TCP open · \(Int((e.value * 1000).rounded())) ms"
        case "net.quic.open": "QUIC open · \(Int((e.value * 1000).rounded())) ms"
        case "net.tcp.close": e.value >= 0.5 ? "Reset" : "Closed"
        case "net.lan.announce": "LAN announce"
        case "net.tls.hello": "TLS hello"
        default: e.kind
        }
    }
}
