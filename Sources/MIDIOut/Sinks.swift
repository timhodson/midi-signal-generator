import CoreMIDI
import Foundation
import SwiftMIDIIO

/// Prints MIDI instead of sending it (`--dry-run`), and is the sink used by tests.
public final class PrintSink: MIDISink {
    public typealias Log = (String) -> Void
    private let log: Log
    public init(log: @escaping Log = { print($0) }) { self.log = log }

    public func noteOn(destination: String, channel: Int, note: Int, velocity: Int) {
        log("on  \(destination) ch\(channel + 1) \(noteName(note)) v\(velocity)")
    }

    public func noteOff(destination: String, channel: Int, note: Int) {
        log("off \(destination) ch\(channel + 1) \(noteName(note))")
    }

    public func controlChange(destination: String, channel: Int, controller: Int, value: Int) {
        log("cc  \(destination) ch\(channel + 1) cc\(controller)=\(value)")
    }

    public func allNotesOff() { log("all notes off") }
}

public func noteName(_ n: Int) -> String {
    let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    return "\(names[((n % 12) + 12) % 12])\(n / 12 - 1)"
}

/// Real CoreMIDI output via SwiftMIDIIO.
///
/// - "virtual" publishes a virtual MIDI source named `virtualName`, visible to DAWs, AUM, etc.
/// - "network" sends to Apple's network MIDI session (whatever it is named), which iPad apps join.
/// - Any other destination name connects to an existing MIDI destination with that name,
///   e.g. "Network Session 1" for Apple's network MIDI (which iPad apps join).
public final class CoreMIDISink: MIDISink, @unchecked Sendable {
    public static let virtualDestination = "virtual"
    public static let networkDestination = "network"

    private let manager: MIDIManager
    private let virtualName: String
    private var destinations: Set<String> = []

    public init(clientName: String = "MIDISignalGenerator", virtualName: String = "MIDI Signal Generator") {
        manager = MIDIManager(clientName: clientName, model: "msg-spike", manufacturer: "midi-signal-generator")
        self.virtualName = virtualName
    }

    /// - Parameter enableNetworkSession: let other devices (e.g. an iPad) join this Mac's
    ///   network MIDI session without an invitation.
    public func start(destinations names: Set<String>, enableNetworkSession: Bool) throws {
        try manager.start()
        if enableNetworkSession { setMIDINetworkSession(policy: .anyone) }
        for name in names {
            if name == Self.virtualDestination {
                try manager.addOutput(name: virtualName, tag: name, uniqueID: .userDefaultsManaged(key: virtualName))
            } else if name == Self.networkDestination {
                guard let id = Self.networkSessionDestinationID() else { continue } // reported by connectedDestinations()
                try manager.addOutputConnection(to: .inputs(matching: [.uniqueID(id)]), tag: name)
            } else {
                try manager.addOutputConnection(to: .inputs(matching: [.name(name)]), tag: name)
            }
        }
        destinations = names
    }

    /// Unique ID of the network session's destination endpoint, if the session is enabled.
    public static func networkSessionDestinationID() -> MIDIIdentifier? {
        let endpoint = MIDINetworkSession.default().destinationEndpoint()
        guard endpoint != 0 else { return nil }
        var id: MIDIUniqueID = 0
        guard MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &id) == noErr else { return nil }
        return id
    }

    /// Names of MIDI destinations currently in the system (what `destination` may be set to).
    public func availableDestinations() -> [String] {
        manager.endpoints.inputs.map(\.name).sorted()
    }

    /// Destinations from the scene that currently resolve to at least one real endpoint.
    public func connectedDestinations() -> [String: Bool] {
        var out: [String: Bool] = [:]
        for name in destinations {
            out[name] = name == Self.virtualDestination
                || !(manager.managedOutputConnections[name]?.endpoints.isEmpty ?? true)
        }
        return out
    }

    private func send(_ destination: String, _ event: MIDIEvent) {
        if destination == Self.virtualDestination {
            try? manager.managedOutputs[destination]?.send(event: event)
        } else {
            try? manager.managedOutputConnections[destination]?.send(event: event)
        }
    }

    public func noteOn(destination: String, channel: Int, note: Int, velocity: Int) {
        send(destination, .noteOn(UInt7(note), velocity: .midi1(UInt7(velocity)), channel: UInt4(channel)))
    }

    public func noteOff(destination: String, channel: Int, note: Int) {
        send(destination, .noteOff(UInt7(note), velocity: .midi1(0), channel: UInt4(channel)))
    }

    public func controlChange(destination: String, channel: Int, controller: Int, value: Int) {
        send(destination, .cc(UInt7(controller), value: .midi1(UInt7(value)), channel: UInt4(channel)))
    }

    public func allNotesOff() {
        for d in destinations {
            for ch in 0..<16 {
                send(d, .cc(123, value: .midi1(0), channel: UInt4(ch)))
            }
        }
    }
}
