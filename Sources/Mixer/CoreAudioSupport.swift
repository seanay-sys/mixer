import AudioToolbox
import CoreAudio
import Foundation

struct CoreAudioError: Error, CustomStringConvertible {
    let status: OSStatus
    let context: String
    var description: String { "\(context) failed (OSStatus \(status))" }
}

func check(_ status: OSStatus, _ context: @autoclosure () -> String) throws {
    guard status == noErr else { throw CoreAudioError(status: status, context: context()) }
}

func propertyAddress(
    _ selector: AudioObjectPropertySelector,
    _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
    _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
}

extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let unknown = AudioObjectID(kAudioObjectUnknown)

    func has(_ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        return AudioObjectHasProperty(self, &address)
    }

    func isSettable(_ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(self, &address, &settable) == noErr && settable.boolValue
    }

    func get<T>(_ address: AudioObjectPropertyAddress, initial: T) throws -> T {
        var address = address
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        try check(AudioObjectGetPropertyData(self, &address, 0, nil, &size, &value), "Read property \(address.mSelector)")
        return value
    }

    func getArray<T>(_ address: AudioObjectPropertyAddress, initial: T) throws -> [T] {
        var address = address
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size), "Read size of \(address.mSelector)")
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        var values = [T](repeating: initial, count: count)
        try values.withUnsafeMutableBytes { buffer in
            try check(AudioObjectGetPropertyData(self, &address, 0, nil, &size, buffer.baseAddress!), "Read \(address.mSelector)")
        }
        return Array(values.prefix(Int(size) / MemoryLayout<T>.stride))
    }

    func getString(_ address: AudioObjectPropertyAddress) throws -> String {
        var address = address
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(AudioObjectGetPropertyData(self, &address, 0, nil, &size, &value), "Read string \(address.mSelector)")
        return (value?.takeRetainedValue() as String?) ?? ""
    }

    func set<T>(_ address: AudioObjectPropertyAddress, value: T) throws {
        var address = address
        var value = value
        try check(AudioObjectSetPropertyData(self, &address, 0, nil, UInt32(MemoryLayout<T>.size), &value), "Write \(address.mSelector)")
    }
}

/// Keeps Core Audio property listeners alive and removes them on demand.
final class PropertyListenerBag {
    private struct Entry {
        let object: AudioObjectID
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }

    private var entries: [Entry] = []

    func add(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, handler: @escaping () -> Void) {
        var address = address
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        if AudioObjectAddPropertyListenerBlock(object, &address, DispatchQueue.main, block) == noErr {
            entries.append(Entry(object: object, address: address, block: block))
        }
    }

    func removeAll() {
        for var entry in entries {
            AudioObjectRemovePropertyListenerBlock(entry.object, &entry.address, DispatchQueue.main, entry.block)
        }
        entries.removeAll()
    }

    deinit { removeAll() }
}

// MARK: - Audio client processes

struct AudioProcess {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String?
    let isRunningOutput: Bool
}

enum AudioProcessList {
    static func current() -> [AudioProcess] {
        let ids = (try? AudioObjectID.system.getArray(
            propertyAddress(kAudioHardwarePropertyProcessObjectList), initial: AudioObjectID.unknown)) ?? []
        return ids.compactMap { id in
            guard let pid = try? id.get(propertyAddress(kAudioProcessPropertyPID), initial: pid_t(-1)), pid > 0 else {
                return nil
            }
            let bundleID = try? id.getString(propertyAddress(kAudioProcessPropertyBundleID))
            let running = (try? id.get(propertyAddress(kAudioProcessPropertyIsRunningOutput), initial: UInt32(0))) ?? 0
            return AudioProcess(objectID: id, pid: pid, bundleID: bundleID, isRunningOutput: running != 0)
        }
    }
}

// MARK: - Process ownership

enum ProcessOwnership {
    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t

    private static let responsibleFn: ResponsibleFn? = {
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        guard let symbol = dlsym(rtldDefault, "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: ResponsibleFn.self)
    }()

    /// The process macOS considers responsible for `pid` (e.g. a browser for its helper processes).
    static func responsiblePID(for pid: pid_t) -> pid_t? {
        guard let fn = responsibleFn else { return nil }
        let result = fn(pid)
        return result > 0 ? result : nil
    }

    static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let parent = info.kp_eproc.e_ppid
        return parent > 1 ? parent : nil
    }

    /// Candidate owner PIDs in order of preference.
    static func candidates(for pid: pid_t) -> [pid_t] {
        var result: [pid_t] = []
        if let responsible = responsiblePID(for: pid) { result.append(responsible) }
        result.append(pid)
        var current = pid
        for _ in 0..<6 {
            guard let parent = parentPID(of: current) else { break }
            result.append(parent)
            current = parent
        }
        return result
    }
}
