# 0008 — Sources sit behind a protocol now and move out of process (OSC) later

- **Status:** accepted
- **Date:** 2026-11-12

## Context

Packet capture needs privileges, and the engine shouldn't run as root. Whole-LAN
capture may run on another machine (a switch mirror port, a Raspberry Pi, a router). Sensors come from
Home Assistant / Zigbee2MQTT. The spike should still be a single binary.

## Decision

- Sources implement `SignalSource` (`start(emit:)`, `stop()`) and emit `SignalSample`s.
  The engine doesn't know where they come from.
- In the spike, `NettopSource` and `SyntheticSource` run **in process**.
- Next, an `OSCSource` will listen on UDP and map OSC addresses to signal ids
  (`/net/app/bytesPerSec "Spotify" 1234.0`). The privileged pcap helper, the MQTT bridge
  and any remote Pi then speak OSC. Payloads never leave the capture process, which sends **features, not packets**.

## Consequences

- Real and recorded/replayed data are interchangeable, which makes tuning repeatable. A recorder/replayer is on the roadmap.
- TouchOSC or similar can inject fake signals by hand.
