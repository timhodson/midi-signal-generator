# Architecture

The MIDI Signal Generator turns data (network traffic first, then sensors) into ambient MIDI
streams for one or more synths. Think of 90s modem handshake sounds, re-imagined for today's networks.

## The core idea: three separate jobs

| Job | Question it answers | Where |
|---|---|---|
| **Sensing** | What is happening in the world? | `Sources` (nettop, OSC in) and the `msg-pcap` helper; MQTT later |
| **Interpretation** | What does it *mean* musically? | `SignalBus`, `Params` (mod matrix), `Music` (Conductor, generators, quantiser) |
| **Rendering** | Which note, on which device, when? | `Router`, `MIDIOut` |

Keeping these apart is what lets the same data be played back faithfully or turned into
something pleasant: only interpretation changes.

## Pipeline

```
 ┌───────────── SOURCES ──────────────┐   today: in-process, behind `SignalSource`
 │ NettopSource  (per-app bytes/s)    │   out of process, over OSC (ADR 0008):
 │ SyntheticSource (fake apps)        │   msg-pcap ──udp 57121──▶ OSCSource
 │ OSCSource  (anything speaking OSC) │   (later: MQTT bridge, Pi on a mirror port)
 └─────────────────┬──────────────────┘
                   │  SignalSample (.stream / .event)
 ┌─────────────────▼──────────────────────────── ENGINE (serial queue, 5 ms tick) ─┐
 │ SignalBus      latest stream values per (id, key) + pending events             │
 │ ModMatrix      signal → param routes (scale, curve, smoothing, depth)           │
 │ ParamStore     base values + modulation offsets; every musical decision         │
 │ MusicalClock   tempo-integrated beats, 50 ms lookahead                          │
 │ ActivityTracker per-app idle→active detection (threshold, cooldown)             │
 │ Conductor      smoothed traffic → mood → progression; chord changes on bars;    │
 │                activation flurries → cadence gesture                            │
 │ Generators     Drone (pad), Motif (lead, one per app), Pulse (pulse)            │
 │                  → NoteIntent (role, raw pitch or chord tone, intensity, time)  │
 │ Quantiser      density gate → pitch (raw→scale→chord) → time (grid) → velocity  │
 │ VoiceRouter    role → destination / channel / range fold / transpose / latency  │
 │ NoteScheduler  time-ordered on/off/CC queue, note ledger, polyphony, panic      │
 └─────────────────┬──────────────────────────────────────────────────────────────┘
                   │
 ┌─────────────────▼──────────────────────────────┐
 │ CompositeSink                                  │
 │  ├ "au:<id>" → AUHostSink (AVAudioEngine)      │  Synth One J6, King of FM 2… in-app,
 │  │                                             │  plugin params = mod-matrix targets
 │  └ else → CoreMIDISink (swift-midi-io)         │  "virtual" port · "network" session (iPad)
 │            PrintSink (--dry-run, tests)        │  · any named destination (IAC, hardware)
 └────────────────────────────────────────────────┘
```

## Modules

| Target | Depends on | Holds |
|---|---|---|
| `Params` | – | `ParamSpec`, `ParamStore`, `ModRoute`, `ModMatrix`, `Macro` |
| `SignalBus` | – | `SignalSample`, `SignalSource` protocol, `SignalBus` |
| `Music` | Params, SignalBus, Tonic | `HarmonyContext`, `ScaleCatalogue`, `MusicalClock`, `Quantiser`, `Conductor`, `ActivityTracker`, generators, `SeededRandom` |
| `Router` | Params, Music | `VoiceConfig`, `VoiceRouter`, range folding |
| `MIDIOut` | Router, Params, SwiftMIDIIO | `NoteScheduler`, `MIDISink`, `ParameterisedSink`, `CompositeSink`, `CoreMIDISink`, `PrintSink` |
| `AUHost` | MIDIOut, Router, Params, AVFoundation | `AUHostSink`: hosted Audio Unit instruments, their params, output meter |
| `OSC` | SignalBus | `OSCMessage` codec, `SignalSample` ↔ OSC, `OSCSender` |
| `Sources` | SignalBus, OSC | `NettopParser`, `NettopSource`, `SyntheticSource`, `OSCSource`, recorder / replay |
| `PacketFeatures` | SignalBus | `PacketDecoder`, `DNSMessage`, `TLSClientHello`, `FeatureExtractor` (pure Swift) |
| `msg-pcap` | CPcap (system libpcap), PacketFeatures, OSC | the capture helper (ADR 0015) |
| `Engine` | Params, SignalBus, Music, Router, MIDIOut, Sources | `Engine` (tick loop, `onStatus`), `Scene` (JSON), `EngineStatus` |
| `Runtime` | Engine, AUHost, MIDIOut, Sources | `Session`: builds synths + sinks + engine + source + recorder |
| `msg-spike` | Runtime | CLI |
| `msg-app` | Runtime | SwiftUI app (ADR 0012) |

`Params`, `SignalBus`, `Music` and `Router` contain no I/O, so the future SwiftUI app and the tests use the same code.

## Signals today

| Id | Kind | Key | From |
|---|---|---|---|
| `net.total.bytesPerSec` | stream | – | nettop / synthetic |
| `net.app.bytesPerSec` | stream | app name | nettop / synthetic |

| `net.pkt.perSec`, `net.flows.tcp` | stream | – | msg-pcap |
| `net.proto.bytesPerSec` | stream | tcp / quic / dns / lan / udp / other | msg-pcap |
| `net.dns.query`, `net.tls.hello` | event | name | msg-pcap |
| `net.tcp.open`, `net.quic.open` | event | server name; value = round trip (s) | msg-pcap |
| `net.tcp.close` | event | server name; value 1 = reset | msg-pcap |
| `net.lan.announce` | event | mDNS / SSDP name | msg-pcap |

Mod routes address keyed streams as `id#key`, e.g. `net.app.bytesPerSec#Spotify`.

## Musical layers and timescales

| Timescale | Signal | Drives |
|---|---|---|
| Event (ms–s) | app activation | Motif on `lead` |
| Event (ms–s) | lookup / handshake / close / LAN announcement | Pickup, call-and-answer, falling figure, twinkle (`gen.packets`, pulse by default) |
| Stream (s) | total bytes/s | Pulse density, pad CC74, pad level (via mod matrix); bass fills and dynamics |
| State (10 s–min) | mood: quiet / calm / busy / focused | Choice of progression (and so the pad, bass and sub notes) |
| Combination | ≥ N activations in a window ("flurry") | Cadence gesture inserted ahead of the progression |

## Voices (roles)

| Role | Generator | What it plays | Default MIDI ch |
|---|---|---|---|
| `pad` | Drone | the current chord, sustained | 1 |
| `lead` | Motif | each app's own motif when it wakes: generated from its name, or a design (ADR 0014) | 2 |
| `pulse` | Pulse | sparse grid notes, density follows traffic | 3 |
| `bass` | Bass | chord root in a pattern (hold / beats / root–fifth / walk), fills when busy | 4 |
| `sub` | Sub drone | very low tonic pedal or chord root, long | 5 |

A generator whose role has no voice in the scene logs a warning once and stays silent.

## Threading

Everything musical runs on one serial `DispatchQueue` in `Engine`, driven by a 5 ms strict
timer. Sources call back from any thread and hop onto that queue to post samples. Engine
types are `@unchecked Sendable` because the queue is their isolation. There are no locks on the hot path.

## The app

`msg-app` sits on `Runtime.Session`. It reads `EngineStatus` about 10× a second and sets params
through the session. Its parameter panels are generated from `ParamSpec`. See
[ADR 0012](decisions/0012-mac-app-generated-from-params.md).
