# 0015 — Packet capture helper: features over OSC, heard as network negotiation

- **Status:** accepted
- **Date:** 2026-11-12

## Context

nettop gives per-app byte rates, which tell you *how busy* the network is. The project's idea,
90s modem handshake sounds re-imagined, is about the network *negotiating*: looking up names,
opening connections, waiting for an answer, hanging up. Hearing that needs packet headers.
Capturing them needs read access to `/dev/bpf*`, and the engine (which hosts Audio Units)
must not run as root.

## Decision

- **A separate helper, `msg-pcap`**, links the libpcap that ships with macOS. It captures this
  Mac's own traffic on one interface (default: the one with the default route; not
  promiscuous), with a 2 KB snap length. If it was started with sudo, it drops back to the
  invoking user right after opening the device.
- **Features, not packets** (ADR 0008). The pure-Swift `PacketFeatures` target turns packets into:
  - events: `net.dns.query`, `net.tcp.open` / `net.quic.open` (value = handshake round trip),
    `net.tcp.close` (1 = reset), `net.tls.hello`, `net.lan.announce` (mDNS / SSDP / LLMNR / NetBIOS)
  - streams, once a second: `net.pkt.perSec`, `net.flows.tcp`, `net.proto.bytesPerSec#tcp|quic|dns|lan|udp|other`, `net.capture.active#<interface>`

  Payloads are only read for names: DNS questions and A/AAAA answers (to name servers by
  what was looked up), the TLS ClientHello server name, mDNS/SSDP labels. Identical
  events within 2 s are merged (A + AAAA + HTTPS lookups of one name are one lookup).
- **OSC over UDP to 127.0.0.1:57121.** A minimal codec (`OSC` target): `/event/<id> [key] value`
  and `/stream/<id> [key] value`; any other path is a stream with slashes as dots. The engine's
  `OSCSource` is a normal `SignalSource`, so a Pi on a mirror port, a sensor bridge or TouchOSC
  can use the same port. Recording and replay capture these events like any other signal.
- **Starting it.** With `--packets` (CLI) or by default (app), the session listens on the port
  and, if this user can read `/dev/bpf*` (e.g. via Wireshark's ChmodBPF and the `access_bpf`
  group), starts the helper as a child that exits with the engine (`--parent-pid`).
  Otherwise it says how: `sudo msg-pcap`, or kick ChmodBPF once.
- **How it sounds: `PacketGenerator`** (`gen.packets.*`, pulse voice by default):
  - lookup → a **pickup** note a sixteenth before the next beat
  - connection → **call and answer**, the real round trip × `stretch` apart (TCP adds the ACK);
    distant servers answer later
  - close → a short **falling** figure that resolves; a reset steps down more sharply
  - LAN announcement → a soft, long, high **twinkle**

  Pitch is a stable hash of the *site* (`api.github.com` and `github.com` share one), as a
  scale step, so familiar servers become familiar notes (ADR 0009). A token bucket
  (`maxPerSecond`) and a per-site, per-kind `cooldown` keep a page load from becoming a wall of
  notes. Every event's outcome (played, or why not) is shown in the app.

## Consequences

- No root in the engine; one sudo (or one ChmodBPF kick) per boot gets packet events.
- Decoding is testable without capture: unit tests build packets byte by byte, and
  `msg-pcap -r file.pcap --print` decodes capture files.
- Not yet: per-process attribution (macOS PKTAP gives a process name per packet but needs
  root for the whole session), QUIC server names (encrypted in Initial packets), DNS over
  HTTPS (invisible by design), the whole LAN (needs a mirror port; same helper, ADR 0009).
