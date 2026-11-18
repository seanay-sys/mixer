import AudioToolbox
import Combine
import CoreAudio
import Foundation

struct OutputDevice: Identifiable, Hashable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let transport: UInt32

    var symbol: String {
        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: "headphones"
        case kAudioDeviceTransportTypeAirPlay: "airplayaudio"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: "tv"
        case kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeThunderbolt: "hifispeaker"
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate: "waveform"
        default: "speaker.wave.2"
        }
    }
}

/// Output devices, the system default output, and its master volume / mute.
@MainActor
final class DeviceModel: ObservableObject {
    @Published private(set) var devices: [OutputDevice] = []
    @Published private(set) var defaultDevice: OutputDevice?
    @Published private(set) var volume: Float = 0
    @Published private(set) var isMuted = false
    @Published private(set) var canSetVolume = false
    @Published private(set) var canMute = false

    private let systemListeners = PropertyListenerBag()
    private let deviceListeners = PropertyListenerBag()

    private let volumeAddress = propertyAddress(
        kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput)
    private let muteAddress = propertyAddress(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)

    init() {
        systemListeners.add(.system, propertyAddress(kAudioHardwarePropertyDevices)) { [weak self] in
            self?.reloadDevices()
        }
        systemListeners.add(.system, propertyAddress(kAudioHardwarePropertyDefaultOutputDevice)) { [weak self] in
            self?.reloadDevices()
        }
        reloadDevices()
    }

    var defaultUID: String? { defaultDevice?.uid }

    func device(uid: String?) -> OutputDevice? {
        guard let uid else { return nil }
        return devices.first { $0.uid == uid }
    }

    func reloadDevices() {
        let ids = (try? AudioObjectID.system.getArray(
            propertyAddress(kAudioHardwarePropertyDevices), initial: AudioObjectID.unknown)) ?? []
        let outputs: [OutputDevice] = ids.compactMap { id in
            let streams = propertyAddress(kAudioDevicePropertyStreams, kAudioDevicePropertyScopeOutput)
            let hidden = (try? id.get(propertyAddress(kAudioDevicePropertyIsHidden), initial: UInt32(0))) ?? 0
            guard hidden == 0,
                  let list = try? id.getArray(streams, initial: AudioObjectID.unknown), !list.isEmpty,
                  let uid = try? id.getString(propertyAddress(kAudioDevicePropertyDeviceUID)),
                  let name = try? id.getString(propertyAddress(kAudioObjectPropertyName))
            else { return nil }
            let transport = (try? id.get(propertyAddress(kAudioDevicePropertyTransportType), initial: UInt32(0))) ?? 0
            return OutputDevice(id: id, uid: uid, name: Self.activeSourceName(of: id) ?? name, transport: transport)
        }
        if outputs != devices { devices = outputs }

        let defaultID = (try? AudioObjectID.system.get(
            propertyAddress(kAudioHardwarePropertyDefaultOutputDevice), initial: AudioObjectID.unknown)) ?? .unknown
        let newDefault = outputs.first { $0.id == defaultID }
        if newDefault != defaultDevice {
            defaultDevice = newDefault
            watchDefaultDevice()
        }
        reloadVolume()
    }

    /// Some devices switch between sources (e.g. internal speakers / headphone jack on one device).
    /// When there is more than one, show the active source's name instead of the device's.
    private static func activeSourceName(of id: AudioObjectID) -> String? {
        let sourcesAddress = propertyAddress(kAudioDevicePropertyDataSources, kAudioDevicePropertyScopeOutput)
        guard let sources = try? id.getArray(sourcesAddress, initial: UInt32(0)), sources.count > 1,
              var current = try? id.get(
                propertyAddress(kAudioDevicePropertyDataSource, kAudioDevicePropertyScopeOutput), initial: UInt32(0))
        else { return nil }

        var name: Unmanaged<CFString>?
        let found: OSStatus = withUnsafeMutablePointer(to: &current) { sourcePointer in
            withUnsafeMutablePointer(to: &name) { namePointer in
                var translation = AudioValueTranslation(
                    mInputData: sourcePointer, mInputDataSize: UInt32(MemoryLayout<UInt32>.size),
                    mOutputData: namePointer, mOutputDataSize: UInt32(MemoryLayout<Unmanaged<CFString>?>.size))
                var address = propertyAddress(
                    kAudioDevicePropertyDataSourceNameForIDCFString, kAudioDevicePropertyScopeOutput)
                var size = UInt32(MemoryLayout<AudioValueTranslation>.size)
                return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &translation)
            }
        }
        guard found == noErr, let value = name?.takeRetainedValue() as String?, !value.isEmpty else { return nil }
        return value
    }

    func setDefaultDevice(_ device: OutputDevice) {
        try? AudioObjectID.system.set(propertyAddress(kAudioHardwarePropertyDefaultOutputDevice), value: device.id)
    }

    // MARK: Master volume

    private func watchDefaultDevice() {
        deviceListeners.removeAll()
        guard let id = defaultDevice?.id else { return }
        let reload: () -> Void = { [weak self] in self?.reloadVolume() }
        deviceListeners.add(id, volumeAddress, handler: reload)
        deviceListeners.add(id, muteAddress, handler: reload)
        deviceListeners.add(id, propertyAddress(kAudioDevicePropertyDataSource, kAudioDevicePropertyScopeOutput)) {
            [weak self] in self?.reloadDevices()
        }
        for element: UInt32 in [kAudioObjectPropertyElementMain, 1, 2] {
            let scalar = propertyAddress(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, element)
            if id.has(scalar) { deviceListeners.add(id, scalar, handler: reload) }
        }
    }

    func reloadVolume() {
        guard let id = defaultDevice?.id else {
            canSetVolume = false
            canMute = false
            return
        }
        var address = volumeAddress
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        let hasVolume = AudioHardwareServiceHasProperty(id, &address)
        if hasVolume, AudioHardwareServiceGetPropertyData(id, &address, 0, nil, &size, &value) == noErr {
            if abs(value - volume) > 0.0001 { volume = value }
        }
        var settable: DarwinBoolean = false
        canSetVolume = hasVolume
            && AudioHardwareServiceIsPropertySettable(id, &address, &settable) == noErr && settable.boolValue

        canMute = id.has(muteAddress) && id.isSettable(muteAddress)
        let muted = ((try? id.get(muteAddress, initial: UInt32(0))) ?? 0) != 0
        if muted != isMuted { isMuted = muted }
    }

    func setVolume(_ newValue: Float) {
        guard let id = defaultDevice?.id else { return }
        var address = volumeAddress
        var value = Float32(min(max(newValue, 0), 1))
        AudioHardwareServiceSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
        volume = value
        if isMuted, value > 0 { setMuted(false) }
    }

    func setMuted(_ muted: Bool) {
        guard let id = defaultDevice?.id, canMute else { return }
        try? id.set(muteAddress, value: UInt32(muted ? 1 : 0))
        isMuted = muted
    }
}
