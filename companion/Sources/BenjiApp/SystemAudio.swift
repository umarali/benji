import CoreAudio
import Foundation
import BenjiCore

/// What Core Audio says about other apps' sound: whether one is playing, and where the Mac's
/// sound comes out. Reads public properties only (no tap, no recording, nothing captured), so it
/// needs no permission. Used by the conversation to hold back words heard over another app.
enum SystemAudio {
    /// Any process other than Benji has output running; nil when the Mac can't say.
    static func otherAppPlaying() -> Bool? {
        guard let processes: [AudioObjectID] = array(AudioObjectID(kAudioObjectSystemObject),
                                                     kAudioHardwarePropertyProcessObjectList) else { return nil }
        let me = getpid()
        for process in processes {
            guard let pid: pid_t = value(process, kAudioProcessPropertyPID), pid != me else { continue }
            if let running: UInt32 = value(process, kAudioProcessPropertyIsRunningOutput), running != 0 { return true }
        }
        return false
    }

    /// Whether the default output is muted and how loud it is (0...1), for "check before speaking"
    /// (D-173). Reads two public properties; changes nothing. Nil when the Mac can't say.
    static func outputState() -> OutputState? {
        guard let device: AudioDeviceID = value(AudioObjectID(kAudioObjectSystemObject),
                                                kAudioHardwarePropertyDefaultOutputDevice),
              device != kAudioObjectUnknown else { return nil }
        let out = kAudioObjectPropertyScopeOutput
        // Mute and volume live on the main element on most devices, on the channels on some.
        var mutes: [Bool] = []
        for element in [kAudioObjectPropertyElementMain, 1, 2] {
            if let m: UInt32 = value(device, kAudioDevicePropertyMute, scope: out, element: element) { mutes.append(m != 0) }
        }
        var volumes: [Double] = []
        for element in [kAudioObjectPropertyElementMain, 1, 2] {
            if let v: Float32 = value(device, kAudioDevicePropertyVolumeScalar, scope: out, element: element) { volumes.append(Double(v)) }
        }
        if mutes.isEmpty && volumes.isEmpty { return nil }
        return OutputState(muted: !mutes.isEmpty && mutes.allSatisfy { $0 }, volume: volumes.max())
    }

    /// The default output device's route.
    static func outputRoute() -> OutputRoute {
        guard let device: AudioDeviceID = value(AudioObjectID(kAudioObjectSystemObject),
                                                kAudioHardwarePropertyDefaultOutputDevice),
              device != kAudioObjectUnknown else { return .unknown }
        let transport: UInt32? = value(device, kAudioDevicePropertyTransportType)
        let source: UInt32? = value(device, kAudioDevicePropertyDataSource, scope: kAudioObjectPropertyScopeOutput)
        return OutputRoute.from(builtIn: transport == kAudioDeviceTransportTypeBuiltIn, dataSource: source)
    }

    /// The default output's route for barge-in: as `outputRoute()`, and an external output whose
    /// name says headphones (AirPods and the like) counts as headphones.
    static func bargeInRoute() -> OutputRoute {
        guard let device: AudioDeviceID = value(AudioObjectID(kAudioObjectSystemObject),
                                                kAudioHardwarePropertyDefaultOutputDevice),
              device != kAudioObjectUnknown else { return .unknown }
        let transport: UInt32? = value(device, kAudioDevicePropertyTransportType)
        let source: UInt32? = value(device, kAudioDevicePropertyDataSource, scope: kAudioObjectPropertyScopeOutput)
        return OutputRoute.classify(builtIn: transport == kAudioDeviceTransportTypeBuiltIn, dataSource: source,
                                    name: name(device))
    }

    /// The default input device's name ("MacBook Pro Microphone"), for remembering where echo
    /// cancellation failed (D-119). Nil when there is none.
    static func defaultInputName() -> String? {
        guard let device: AudioDeviceID = value(AudioObjectID(kAudioObjectSystemObject),
                                                kAudioHardwarePropertyDefaultInputDevice),
              device != kAudioObjectUnknown else { return nil }
        return name(device)
    }

    private static func name(_ device: AudioDeviceID) -> String? {
        var addr = address(kAudioObjectPropertyName, scope: kAudioObjectPropertyScopeGlobal)
        guard AudioObjectHasProperty(device, &addr) else { return nil }
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &name) == noErr, let name else { return nil }
        return name.takeRetainedValue() as String
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope,
                                element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func value<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                         element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> T? {
        var addr = address(selector, scope: scope, element: element)
        guard AudioObjectHasProperty(object, &addr) else { return nil }
        var size = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, pointer) == noErr,
              size == UInt32(MemoryLayout<T>.size) else { return nil }
        return pointer.pointee
    }

    static func array<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [T]? {
        var addr = address(selector, scope: kAudioObjectPropertyScopeGlobal)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr else { return nil }
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: count)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, pointer) == noErr else { return nil }
        return Array(UnsafeBufferPointer(start: pointer, count: Int(size) / MemoryLayout<T>.stride))
    }
}
