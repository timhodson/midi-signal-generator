# 0011 — Record and replay signals

- **Status:** accepted
- **Date:** 2026-11-12

## Context

Every listening test used different live traffic, so it was impossible to tell whether a
parameter change helped or the network simply got quieter.

## Decision

- `--record <file.jsonl>` writes every batch of samples the engine receives, *before*
  interpretation, as JSON Lines: a header line (`format: "msg-signals"`, version, date, sources), then
  `{"t": seconds, "samples": [...]}` per batch.
- `--source replay:<file>` plays it back with the original timing. `--speed` scales the time and `--loop`
  repeats with a 1 s gap. The replay emits the same signal ids as the recorded source, so
  the rest of the engine can't tell the difference.
- Recording sits at the engine's input (`Engine.recorder`), so any source, including future
  OSC/pcap/MQTT sources, can be recorded without changes.

## Consequences

- Tuning becomes repeatable: same data, different scene.
- Recordings are deterministic *inputs*, but the output isn't bit-identical (timer jitter, RNG
  draw order). The character is the same.
- Faster replay compresses data time but not musical time: the tempo, cooldowns and hysteresis
  stay in real seconds, so a ×4 replay is denser than the original. Use 1× for judging the result.
- Recordings contain app names and traffic volumes. `recordings/` is git-ignored by default.
