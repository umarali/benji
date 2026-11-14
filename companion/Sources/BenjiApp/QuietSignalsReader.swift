import AppKit
import CoreAudio
import CoreGraphics
import CoreMediaIO
import BenjiCore

/// Reads what the Mac says about calls, for the quiet check (D-173). Public APIs only, nothing that
/// needs a permission, nothing captured or recorded:
///  - Core Audio process objects: which other apps have the microphone open for input;
///  - Core Media IO: whether any camera is running somewhere (not which app: macOS doesn't say);
///  - NSWorkspace: the running apps;
///  - the window list: owner and, when macOS gives them, the titles of windows on screen. Titles of
///    other apps' windows come back empty unless Screen Recording is on for Benji; this reader never
///    asks for it. Without titles only a FaceTime window is recognised as a meeting.
/// Run on demand, just before an unasked cue; a few property reads.
enum QuietSignalsReader {
    static func read() -> QuietSignals {
        QuietSignals(microphoneUsers: microphoneUsers(), cameraRunning: cameraRunning(),
                     runningApps: runningApps(), windows: windows())
    }

    private static func microphoneUsers() -> Set<String> {
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard let processes: [AudioObjectID] = SystemAudio.array(system, kAudioHardwarePropertyProcessObjectList) else { return [] }
        let me = getpid()
        var users = Set<String>()
        for process in processes {
            guard let pid: pid_t = SystemAudio.value(process, kAudioProcessPropertyPID), pid != me,
                  let running: UInt32 = SystemAudio.value(process, kAudioProcessPropertyIsRunningInput), running != 0 else { continue }
            if let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier { users.insert(id) }
        }
        return users
    }

    private static func cameraRunning() -> Bool {
        var address = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
                                                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        guard CMIOObjectGetPropertyDataSize(system, &address, 0, nil, &size) == 0, size > 0 else { return false }
        var devices = [CMIODeviceID](repeating: 0, count: Int(size) / MemoryLayout<CMIODeviceID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &address, 0, nil, size, &used, &devices) == 0 else { return false }
        for device in devices {
            var running = UInt32(0)
            var runningAddress = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
            var runningSize = UInt32(MemoryLayout<UInt32>.size), got: UInt32 = 0
            if CMIOObjectGetPropertyData(device, &runningAddress, 0, nil, runningSize, &got, &running) == 0, running != 0 {
                return true
            }
            runningSize = 0
        }
        return false
    }

    private static func runningApps() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.compactMap(\.bundleIdentifier))
    }

    private static func windows() -> [QuietSignals.Window] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        var out: [QuietSignals.Window] = []
        for info in list {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let owner = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier else { continue }
            out.append(.init(owner: owner, title: info[kCGWindowName as String] as? String ?? ""))
        }
        return out
    }
}
