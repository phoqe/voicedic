import CoreAudio
import Observation

struct Microphone: Identifiable, Hashable, Sendable {
    /// Core Audio's device UID, stable across reconnects and restarts (unlike its AudioDeviceID).
    let uid: String
    let name: String
    let isBuiltIn: Bool

    var id: String { uid }
}

/// Audio input devices, kept current as they connect and disconnect.
@MainActor
@Observable
final class Microphones {
    /// Saved selection meaning "follow the system default input". An empty selection means automatic.
    static let systemDefaultSelection = "system-default"

    private(set) var all: [Microphone] = []
    private(set) var systemDefault: Microphone?

    /// What automatic records from: the Mac's own microphone, so connecting AirPods or another headset
    /// doesn't move dictation onto it. Falls back to the system default on Macs without one.
    var automatic: Microphone? { all.first(where: \.isBuiltIn) ?? systemDefault }

    init() {
        refresh()
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice] {
            var address = Self.address(selector)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
    }

    func refresh() {
        let devices = Self.inputDevices()
        all = devices.map(\.microphone)
        let defaultID = Self.uint32(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice)
        systemDefault = devices.first { $0.id == defaultID }?.microphone
    }

    /// The device to record from for a saved selection: a device UID, empty for automatic, or
    /// `systemDefaultSelection`. A disconnected device falls back to automatic. nil means the system
    /// default input.
    static func deviceID(for selection: String) -> AudioDeviceID? {
        guard selection != systemDefaultSelection else { return nil }
        let devices = inputDevices()
        if let chosen = devices.first(where: { $0.microphone.uid == selection }) { return chosen.id }
        return devices.first(where: \.microphone.isBuiltIn)?.id
    }

    // MARK: - Core Audio

    private static func inputDevices() -> [(id: AudioDeviceID, microphone: Microphone)] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }

        return ids.compactMap { id in
            guard hasInput(id), uint32(id, kAudioDevicePropertyIsHidden) != 1,
                let uid = string(id, kAudioDevicePropertyDeviceUID),
                let name = string(id, kAudioObjectPropertyName)
            else { return nil }
            let isBuiltIn = uint32(id, kAudioDevicePropertyTransportType) == kAudioDeviceTransportTypeBuiltIn
            return (id, Microphone(uid: uid, name: name, isBuiltIn: isBuiltIn))
        }
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var address = address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func uint32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func address(
        _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
}
