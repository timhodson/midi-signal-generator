import Foundation
import Params
import SignalBus

/// Network events from the packet capture helper, each as a short figure. This is the
/// modem-handshake idea: you hear the network *negotiate*, not just how busy it is.
///
/// - DNS lookup → a single **pickup** note just before the next beat, leading into it.
/// - Connection opens → a **call and answer**: the call when the client says hello, the answer
///   when the server replies, the real round trip slowed down so far-away servers answer later.
///   TCP adds the client's acknowledgement as a third note.
/// - Connection closes → a short **falling** figure that resolves (RST steps down more abruptly).
/// - LAN announcements (AirPlay, printers, smart speakers) → a soft, long, high **twinkle**.
///
/// Each site keeps the same pitch (a stable hash of its name, ADR 0009), so familiar servers
/// become familiar notes. A token bucket and a per-site cooldown stop a page load (dozens of
/// lookups and connections in a second) from becoming a wall of notes.
public final class PacketGenerator: Generator {
    public let id = "packets"
    public static let roles = ["pulse", "lead", "pad", "bass", "sub"]
    public static let handledEvents: Set<String> = ["net.dns.query", "net.tcp.open", "net.quic.open", "net.tcp.close",
                                                    "net.lan.announce", "net.tls.hello"]

    /// What happened to an event: played, or why not. Read by the engine for the UI.
    public struct Decision: Sendable, Equatable {
        public var id: String
        public var key: String
        public var value: Double
        public var played: Bool
        public var reason: String
    }

    private var decisions: [Decision] = []
    private var tokens: Double = 0
    private var lastRefill: Double?
    private var lastPlayed: [String: Double] = [:]

    public init() {}

    public var params: [ParamSpec] {
        [
            ParamSpec("gen.packets.enabled", kind: .toggle, default: 1,
                      help: "Network events as short figures: lookups, connections opening and closing, LAN chatter. Needs the packet capture helper (msg-pcap) running."),
            ParamSpec("gen.packets.role", kind: .choice, default: 0, options: Self.roles,
                      help: "Which voice plays network events. Pulse keeps them with the other sparkles; lead puts them up front with the app motifs."),
            ParamSpec("gen.packets.octave", kind: .integer, range: 2...7, default: 4,
                      help: "Register of the figures. Lookups and LAN twinkles sit an octave higher."),
            ParamSpec("gen.packets.intensity", default: 0.5, help: "Loudness of network-event figures."),
            ParamSpec("gen.packets.lookups", kind: .toggle, default: 1,
                      help: "DNS lookups: a pickup note just before the next beat, leading into it, as if the network is drawing breath before talking."),
            ParamSpec("gen.packets.handshakes", kind: .toggle, default: 1,
                      help: "Connections opening: a call when your Mac says hello and an answer when the server replies. TCP adds a third note for the acknowledgement."),
            ParamSpec("gen.packets.stretch", kind: .continuous, range: 1...100, default: 12, unit: "×",
                      help: "How much the handshake round trip is slowed down so you can hear it. At ×12 a 20 ms round trip leaves 0.24 s between call and answer, and a distant server answers noticeably later. Time quantise may snap it to the grid."),
            ParamSpec("gen.packets.closes", kind: .toggle, default: 1,
                      help: "Connections closing: a short falling figure that resolves. A reset (abrupt close) steps down more sharply."),
            ParamSpec("gen.packets.lan", kind: .toggle, default: 1,
                      help: "LAN announcements (AirPlay, printers, speakers advertising themselves): a soft, long, high twinkle."),
            ParamSpec("gen.packets.lanIntensity", default: 0.25, help: "Loudness of LAN twinkles; keep it low so they read as texture."),
            ParamSpec("gen.packets.maxPerSecond", kind: .continuous, range: 0.25...16, default: 3, unit: "/s",
                      help: "Most figures started per second. A page load fires dozens of lookups and connections; this keeps them from becoming a wall of notes. Events over the limit are skipped."),
            ParamSpec("gen.packets.cooldown", kind: .continuous, range: 0...120, default: 10, unit: "s",
                      help: "The same site can't play the same kind of figure again for this long. Lower = chattier; higher = you hear each site once in a while."),
            ParamSpec("gen.packets.seed", kind: .integer, range: 0...9999, default: 0, modulatable: false,
                      help: "Which note each site gets. Sites keep their note within a set; a new number deals out new ones. 0 = the original set."),
            ParamSpec("gen.packets.noteBeats", kind: .continuous, range: 0.05...4, default: 0.35, unit: "beats",
                      help: "Length of figure notes. Short = blips like a modem; long = notes ring into each other."),
        ]
    }

    /// Decisions since the last call, oldest first.
    public func drainDecisions() -> [Decision] {
        defer { decisions.removeAll(keepingCapacity: true) }
        return decisions
    }

    /// The part of a host name that identifies the site: "lb-140-82-121-4.github.com" → "github.com",
    /// "www.bbc.co.uk" → "bbc.co.uk". Addresses and single labels are returned as they are.
    public static func site(of host: String) -> String {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if h.contains(":") || h.allSatisfy({ $0.isNumber || $0 == "." }) { return h }
        let labels = h.split(separator: ".")
        guard labels.count > 2 else { return h }
        let second = labels[labels.count - 2], tld = labels[labels.count - 1]
        let take = tld.count == 2 && ["co", "com", "org", "net", "ac", "gov", "edu", "ne", "or"].contains(String(second)) ? 3 : 2
        return labels.suffix(take).joined(separator: ".")
    }

    /// The scale step a site plays on (stable across runs).
    public static func degree(for site: String, steps: Int) -> Int {
        Int(stableHash(site) % UInt64(max(steps, 1)))
    }

    public func tick(_ ctx: GeneratorContext, rng: inout SeededRandom) -> GeneratorOutput {
        var out = GeneratorOutput()
        let p = ctx.params
        let rate = p.value("gen.packets.maxPerSecond")
        // Token bucket: refills at `maxPerSecond`, holds at most one second's worth (at least one).
        tokens = lastRefill.map { min(max(1, rate), tokens + (ctx.now - $0) * rate) } ?? max(1, rate)
        lastRefill = ctx.now

        for e in ctx.events where Self.handledEvents.contains(e.id) {
            let key = e.key ?? "?"
            func decide(_ played: Bool, _ reason: String) {
                decisions.append(Decision(id: e.id, key: key, value: e.value, played: played, reason: reason))
            }
            guard p.bool("gen.packets.enabled") else { decide(false, "network events are switched off"); continue }
            let toggle: String
            switch e.id {
            case "net.dns.query": toggle = "gen.packets.lookups"
            case "net.tcp.open", "net.quic.open": toggle = "gen.packets.handshakes"
            case "net.tcp.close": toggle = "gen.packets.closes"
            case "net.lan.announce": toggle = "gen.packets.lan"
            default: decide(false, "names the server for later figures"); continue
            }
            guard p.bool(toggle) else { decide(false, "this kind is switched off"); continue }
            let site = e.id == "net.lan.announce" ? key : Self.site(of: key)
            let cooldownKey = toggle + "|" + site
            if let last = lastPlayed[cooldownKey], ctx.now - last < p.value("gen.packets.cooldown") {
                decide(false, "cooldown · \(site == key ? "" : "\(site) ")played \(Int(ctx.now - last)) s ago")
                continue
            }
            guard tokens >= 1 else { decide(false, "limit · over \(rate.formatted()) figures/s"); continue }
            tokens -= 1
            lastPlayed[cooldownKey] = ctx.now
            let notes = figure(for: e, site: site, ctx)
            out.notes += notes
            decide(true, notes.first?.why ?? "")
        }
        if lastPlayed.count > 2000 {
            let cutoff = ctx.now - p.value("gen.packets.cooldown")
            lastPlayed = lastPlayed.filter { $0.value >= cutoff }
        }
        return out
    }

    private func figure(for e: SignalSample, site: String, _ ctx: GeneratorContext) -> [NoteIntent] {
        let p = ctx.params
        let role = Self.roles[min(max(p.int("gen.packets.role"), 0), Self.roles.count - 1)]
        let octave = p.int("gen.packets.octave")
        let level = p.value("gen.packets.intensity")
        let length = p.value("gen.packets.noteBeats")
        let spb = ctx.clock.secondsPerBeat
        let seed = p.int("gen.packets.seed")
        let d = Self.degree(for: seed == 0 ? site : "\(site)#\(seed)", steps: ctx.harmony.scaleSteps.count)
        func note(_ degree: Int, octave o: Int, at t: Double, _ intensity: Double, beats: Double? = nil, _ why: String) -> NoteIntent {
            NoteIntent(role: role, pitch: .exact(ctx.harmony.note(degree: degree, octave: o)), intensity: intensity,
                       time: t, beats: beats ?? length, why: why)
        }

        switch e.id {
        case "net.dns.query":
            // A sixteenth before the next beat that is at least a sixteenth away.
            let beat = ctx.clock.beat(atTime: ctx.now)
            let target = (beat + 0.25).rounded(.up) - 0.25
            let why = "DNS lookup: \(e.key ?? site) · a pickup into the next beat"
            return [note(d, octave: octave + 1, at: ctx.clock.time(ofBeat: target), level * 0.7, beats: min(length, 0.25), why)]

        case "net.tcp.open", "net.quic.open":
            let rtt = e.value
            let gap = min(max(rtt * p.value("gen.packets.stretch"), 0.06), 2)
            let proto = e.id == "net.tcp.open" ? "TCP" : "QUIC"
            let why = "\(proto) handshake with \(e.key ?? site): \(Int((rtt * 1000).rounded())) ms round trip, heard ×\(p.value("gen.packets.stretch").formatted()) slower"
            var notes = [
                note(d, octave: octave, at: ctx.now, level, why),
                note(d + 4, octave: octave, at: ctx.now + gap, level * 0.9, why),
            ]
            if proto == "TCP" { notes.append(note(d + 7, octave: octave, at: ctx.now + gap + 0.25 * spb, level * 0.6, why)) }
            return notes

        case "net.tcp.close":
            let reset = e.value >= 0.5
            let why = reset ? "connection to \(e.key ?? site) reset" : "connection to \(e.key ?? site) closed"
            return [
                note(d + (reset ? 1 : 2), octave: octave, at: ctx.now, level * 0.5, why),
                note(d, octave: octave, at: ctx.now + 0.5 * spb, level * 0.45, why),
            ]

        case "net.lan.announce":
            let why = "LAN announcement: \(site)"
            return [note(d, octave: octave + 1, at: ctx.now, p.value("gen.packets.lanIntensity"), beats: max(length, 2), why)]

        default:
            return []
        }
    }
}
