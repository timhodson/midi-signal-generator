# 0003 — Signals come in three timescales

- **Status:** accepted
- **Date:** 2026-11-12

## Context

A busy Mac sees thousands of packets a second, and mapping them 1:1 to notes is noise. The
modem sound was compelling because it had structure: distinct phases with their own
character. Sensor data (temperature, humidity) moves over minutes to hours.

## Decision

All data is reduced to three kinds, and each drives a different musical layer:

| Kind | Example | Musical use |
|---|---|---|
| **Event**: something happened | app woke, flow opened, motion | triggers motifs / notes |
| **Stream**: latest value wins | bytes/s, temperature | modulation via the mod matrix |
| **State**: derived and slow | mood: quiet / calm / busy / focused | harmony: progression, later mode and tempo |

Sources only send events and streams (`SignalSample`). **States are derived in the engine**
(Conductor, ActivityTracker), where their thresholds are tunable params. A source never decides what is "busy".

## Consequences

- Sources stay simple and swappable. The pcap helper and MQTT bridge will emit the same kinds of sample.
- The spike derives app activations (events) from the per-app stream rather than having
  nettop emit them, which keeps the threshold and cooldown tunable.
- Slow sensor data maps naturally to the state layer (e.g. temperature → mode), not to notes.
