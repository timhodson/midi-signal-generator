# 0004 — Local traffic via `nettop` on a pseudo-terminal

- **Status:** accepted for the spike; pcap helper to follow
- **Date:** 2026-11-12

## Context

Scope for now is **this Mac's own traffic**; the whole LAN comes later. Options:

| Option | Privileges | Gives |
|---|---|---|
| libpcap / BPF | root or ChmodBPF | packets, protocols, flows, DNS/TLS/SYN/FIN |
| NetworkExtension | entitlements, signing | flows per app |
| `nettop` | none for your own processes | **bytes per process** |

## Decision

Start with `nettop -P -d -L 0 -s 1 -J bytes_in,bytes_out -x`, which gives per-process byte
deltas once a second without root.

Things we found that shaped the implementation (`Sources/Sources/Nettop.swift`):

- **nettop block-buffers when stdout is a pipe**, so nothing arrives for minutes. It is run on
  a **pseudo-terminal** (`openpty`), which makes it flush once per sample.
- A one-shot `nettop -L 1` takes about 5 s, so polling is not an option.
- The first CSV block is totals since boot and is skipped. Later blocks are deltas.
- Process names are truncated (~15 chars, e.g. `Brave Browser H`) and may contain dots
  (`2.1.322.32467`), so the pid is split at the last dot. Helpers with the same name are summed.
- A block is complete only when the next header arrives, so data is about 1 interval late. That's fine for ambient music.

## Consequences

- Per-**app** voices become possible. This is the local-Mac version of per-device leitmotifs on a LAN.
- No packet-level detail yet (protocol mix, DNS before connect, handshakes). That needs the
  privileged pcap helper, run as a separate process that sends *features, not packets* (ADR 0008).
- Always-on daemons (mDNSResponder, apsd…) are filtered by the scene's `ignoreApps` while
  `activity.ignore` is on.
