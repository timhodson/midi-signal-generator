import CoreMIDI
import Foundation

/// A MIDI destination this Mac knows about, connected or not, for pickers and listings.
public struct MIDIDestinationInfo: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, CaseIterable {
        case bluetooth, usb, network, iac, app, other

        public var title: String {
            switch self {
            case .bluetooth: "Bluetooth"
            case .usb: "USB"
            case .network: "Network"
            case .iac: "IAC buses (between apps on this Mac)"
            case .app: "Other apps' inputs"
            case .other: "Other devices"
            }
        }
    }

    /// What goes in a voice's `destination`: the endpoint's display name ("Tim's iPad Bluetooth"),
    /// which, unlike its bare name ("Bluetooth"), tells devices apart.
    public var address: String
    public var device: String?
    public var kind: Kind
    /// Present and usable now. Offline ones (a paired Bluetooth device that's out of range, an
    /// unplugged USB interface) still work as destinations: they connect when they come back.
    public var online: Bool

    public var id: String { address }
}

extension CoreMIDISink {
    /// Every destination in the system, including offline devices CoreMIDI remembers (previously
    /// paired Bluetooth MIDI, unplugged USB) and other apps' virtual inputs.
    public static func systemDestinations() -> [MIDIDestinationInfo] {
        var out: [MIDIDestinationInfo] = []
        var seen = Set<String>()
        func add(_ info: MIDIDestinationInfo) {
            guard !info.address.isEmpty, seen.insert(info.address).inserted else { return }
            out.append(info)
        }
        for i in 0..<MIDIGetNumberOfDevices() {
            let device = MIDIGetDevice(i)
            let kind = kind(driver: string(device, kMIDIPropertyDriverOwner))
            let deviceOffline = integer(device, kMIDIPropertyOffline) != 0
            for e in 0..<MIDIDeviceGetNumberOfEntities(device) {
                let entity = MIDIDeviceGetEntity(device, e)
                for d in 0..<MIDIEntityGetNumberOfDestinations(entity) {
                    let endpoint = MIDIEntityGetDestination(entity, d)
                    add(MIDIDestinationInfo(address: address(endpoint), device: string(device, kMIDIPropertyName), kind: kind,
                                            online: !deviceOffline && integer(endpoint, kMIDIPropertyOffline) == 0))
                }
            }
        }
        // Virtual destinations published by other apps belong to no device.
        for i in 0..<MIDIGetNumberOfDestinations() {
            let endpoint = MIDIGetDestination(i)
            var entity: MIDIEntityRef = 0
            if MIDIEndpointGetEntity(endpoint, &entity) == noErr, entity != 0 { continue }
            add(MIDIDestinationInfo(address: address(endpoint), device: nil, kind: .app, online: true))
        }
        return out.sorted { ($0.kind.rawValue, $0.online ? 0 : 1, $0.address) < ($1.kind.rawValue, $1.online ? 0 : 1, $1.address) }
    }

    static func kind(driver: String?) -> MIDIDestinationInfo.Kind {
        switch driver ?? "" {
        case let d where d.contains("Bluetooth"): .bluetooth
        case let d where d.contains("USB"): .usb
        case let d where d.contains("Network") || d.contains("RTP"): .network
        case let d where d.contains("IAC"): .iac
        default: .other
        }
    }

    static func address(_ endpoint: MIDIEndpointRef) -> String {
        string(endpoint, kMIDIPropertyDisplayName) ?? string(endpoint, kMIDIPropertyName) ?? ""
    }

    static func string(_ object: MIDIObjectRef, _ property: CFString) -> String? {
        var value: Unmanaged<CFString>?
        guard MIDIObjectGetStringProperty(object, property, &value) == noErr, let v = value?.takeRetainedValue() else { return nil }
        return v as String
    }

    static func integer(_ object: MIDIObjectRef, _ property: CFString) -> Int32 {
        var value: Int32 = 0
        MIDIObjectGetIntegerProperty(object, property, &value)
        return value
    }
}
