import AppKit
import Combine
import CoreAudio
import Foundation

/// What the user chose for one app. Stored by bundle identifier so it survives relaunches.
struct AppSetting: Codable, Equatable {
    /// 0…2, where 1 is the app's normal level and above 1 is boost.
    var volume: Double = 1
    var muted = false
    /// nil follows the system output device; `AppSetting.airPlay` means Mixer's AirPlay destination.
    var deviceUID: String?

    static let airPlay = "mixer.airplay"
    var usesAirPlay: Bool { deviceUID == Self.airPlay }

    var isDefault: Bool { self == AppSetting() }
}

struct MixerApp: Identifiable {
    let id: String
    let pid: pid_t
    let name: String
    let icon: NSImage
    var processObjectIDs: [AudioObjectID]
    var isPlaying: Bool

    var hasAudio: Bool { !processObjectIDs.isEmpty }
}

@MainActor
final class MixerModel: ObservableObject {
    static let maxVolume = 2.0

    @Published private(set) var apps: [MixerApp] = []
    @Published private(set) var settings: [String: AppSetting] = [:]
    @Published private(set) var problem: String?

    let devices: DeviceModel

    private var taps: [String: ProcessTap] = [:]
    private var pendingTeardown: [String: DispatchWorkItem] = [:]
    private var iconCache: [pid_t: NSImage] = [:]
    private let listeners = PropertyListenerBag()
    private var cancellables: Set<AnyCancellable> = []
    private var refreshTimer: Timer?
    private let defaultsKey = "appSettings"

    init(devices: DeviceModel) {
        self.devices = devices
        loadSettings()

        listeners.add(.system, propertyAddress(kAudioHardwarePropertyProcessObjectList)) { [weak self] in
            self?.refresh()
        }

        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            center.publisher(for: name)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.refresh() }
                .store(in: &cancellables)
        }

        devices.$defaultDevice.combineLatest(devices.$devices)
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyAllTaps(rebuildForDeviceChange: true) }
            .store(in: &cancellables)

        refresh()
    }

    // MARK: Panel lifecycle

    /// Poll "is playing" state only while the panel is open.
    func panelDidOpen() {
        refresh()
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func panelDidClose() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    // MARK: Settings

    func setting(for id: String) -> AppSetting { settings[id] ?? AppSetting() }

    func setVolume(_ volume: Double, for id: String) {
        update(id) {
            $0.volume = min(max(volume, 0), Self.maxVolume)
            if volume > 0.001 { $0.muted = false }
        }
    }

    func toggleMute(_ id: String) {
        update(id) { $0.muted.toggle() }
    }

    func setDevice(_ uid: String?, for id: String) {
        update(id) { $0.deviceUID = uid }
    }

    func reset(_ id: String) {
        update(id) { $0 = AppSetting() }
    }

    private func update(_ id: String, _ change: (inout AppSetting) -> Void) {
        var setting = self.setting(for: id)
        change(&setting)
        settings[id] = setting.isDefault ? nil : setting
        saveSettings()
        applyTap(for: id)
    }

    private func loadSettings() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([String: AppSetting].self, from: data)
        else { return }
        settings = decoded
    }

    private func saveSettings() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    // MARK: App discovery

    func refresh() {
        let ownPID = getpid()
        let running = NSWorkspace.shared.runningApplications.filter { $0.processIdentifier != ownPID }
        let byPID = Dictionary(running.map { ($0.processIdentifier, $0) }, uniquingKeysWith: { first, _ in first })

        // Group audio client processes (including helpers) under the app that owns them.
        var audioByApp: [pid_t: (objects: [AudioObjectID], playing: Bool)] = [:]
        for process in AudioProcessList.current() where process.pid != ownPID {
            guard let owner = owningApp(of: process.pid, in: byPID) else { continue }
            var entry = audioByApp[owner] ?? ([], false)
            entry.objects.append(process.objectID)
            entry.playing = entry.playing || process.isRunningOutput
            audioByApp[owner] = entry
        }

        var usedIDs = Set<String>()
        var result: [MixerApp] = []
        for app in running {
            let pid = app.processIdentifier
            let audio = audioByApp[pid]
            guard app.activationPolicy == .regular || audio != nil else { continue }

            var id = app.bundleIdentifier ?? app.executableURL?.path ?? "pid-\(pid)"
            if usedIDs.contains(id) { id += "#\(pid)" }
            usedIDs.insert(id)

            result.append(MixerApp(
                id: id,
                pid: pid,
                name: app.localizedName ?? app.bundleIdentifier ?? "Unknown",
                icon: icon(for: app),
                processObjectIDs: (audio?.objects ?? []).sorted(),
                isPlaying: audio?.playing ?? false
            ))
        }

        // Stable order: apps that use audio first, then alphabetical.
        result.sort {
            if $0.hasAudio != $1.hasAudio { return $0.hasAudio }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        let livePIDs = Set(result.map(\.pid))
        iconCache = iconCache.filter { livePIDs.contains($0.key) }

        if !appsEqual(result, apps) { apps = result }
        applyAllTaps(rebuildForDeviceChange: false)
        checkForSilentTaps()
    }

    private func owningApp(of pid: pid_t, in byPID: [pid_t: NSRunningApplication]) -> pid_t? {
        var fallback: pid_t?
        for candidate in ProcessOwnership.candidates(for: pid) {
            guard let app = byPID[candidate] else { continue }
            switch app.activationPolicy {
            case .regular: return candidate
            case .accessory: fallback = fallback ?? candidate
            default: continue
            }
        }
        return fallback
    }

    private func icon(for app: NSRunningApplication) -> NSImage {
        if let cached = iconCache[app.processIdentifier] { return cached }
        let image = app.icon ?? NSWorkspace.shared.icon(for: .application)
        image.size = NSSize(width: 32, height: 32)
        iconCache[app.processIdentifier] = image
        return image
    }

    private func appsEqual(_ a: [MixerApp], _ b: [MixerApp]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy {
            $0.id == $1.id && $0.pid == $1.pid && $0.isPlaying == $1.isPlaying
                && $0.processObjectIDs == $1.processObjectIDs && $0.name == $1.name
        }
    }

    // MARK: Taps

    /// Perceptual curve: the slider position squared, so 50% sounds about half as loud.
    private func gain(for setting: AppSetting) -> Float {
        setting.muted ? 0 : Float(setting.volume * setting.volume)
    }

    private func outputUID(for setting: AppSetting) -> String? {
        if let routed = devices.device(uid: setting.deviceUID) { return routed.uid }
        return devices.defaultUID
    }

    private func applyAllTaps(rebuildForDeviceChange: Bool) {
        let liveIDs = Set(apps.map(\.id))
        for id in taps.keys where !liveIDs.contains(id) {
            tearDown(id)
        }
        for app in apps { applyTap(for: app.id) }
    }

    private func applyTap(for id: String) {
        guard let app = apps.first(where: { $0.id == id }) else {
            tearDown(id)
            return
        }
        let setting = self.setting(for: id)
        guard let targetUID = outputUID(for: setting) else {
            tearDown(id)
            return
        }
        let toAirPlay = setting.usesAirPlay
        let routedElsewhere = toAirPlay || targetUID != devices.defaultUID
        let needed = app.hasAudio && (setting.muted || abs(setting.volume - 1) > 0.001 || routedElsewhere)
        let gain = gain(for: setting)

        if let existing = taps[id] {
            let matches = existing.processObjectIDs == app.processObjectIDs && existing.outputUID == targetUID
                && existing.toAirPlay == toAirPlay
            if matches {
                existing.setGain(needed ? gain : 1)
                if needed {
                    pendingTeardown[id]?.cancel()
                    pendingTeardown[id] = nil
                } else {
                    scheduleTearDown(id)
                }
                return
            }
            tearDown(id)
        }

        guard needed else { return }
        do {
            taps[id] = try ProcessTap(
                processObjectIDs: app.processObjectIDs, outputUID: targetUID, toAirPlay: toAirPlay, gain: gain)
            if problem?.hasPrefix("Couldn't") == true { problem = nil }
        } catch {
            problem = "Couldn't control \(app.name): \(error)"
        }
    }

    /// Wait a moment before removing a tap that is back at 100%, so dragging
    /// the slider across 100% doesn't keep rebuilding audio.
    private func scheduleTearDown(_ id: String) {
        guard pendingTeardown[id] == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.pendingTeardown[id] = nil
                self?.tearDown(id)
            }
        }
        pendingTeardown[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func tearDown(_ id: String) {
        pendingTeardown[id]?.cancel()
        pendingTeardown[id] = nil
        taps[id]?.invalidate()
        taps[id] = nil
    }

    func tearDownAll() {
        for id in Array(taps.keys) { tearDown(id) }
    }

    /// If an app is playing but its tap only ever delivers silence, macOS has
    /// most likely denied the System Audio Recording permission.
    private func checkForSilentTaps() {
        let silent = apps.contains { app in
            guard app.isPlaying, let tap = taps[app.id] else { return false }
            return !tap.receivedSignal && Date().timeIntervalSince(tap.createdAt) > 3
        }
        if silent {
            problem = "Mixer isn't receiving any audio. Allow it under Privacy & Security → Screen & System Audio Recording."
        } else if problem?.hasPrefix("Mixer isn't") == true {
            problem = nil
        }
    }
}
