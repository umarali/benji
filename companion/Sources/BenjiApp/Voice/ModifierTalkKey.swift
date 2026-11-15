import AppKit
import Carbon.HIToolbox
import BenjiCore

/// Hold a single modifier key (Right Option by default) to talk and let go to send, or
/// tap it to start or stop talking. Carbon hotkeys can't register a lone modifier, so
/// this uses an event tap (idea credited in THIRD_PARTY_NOTICES.md). It's an
/// active tap rather than listen-only: on macOS 26 a listen-only tap is created even
/// without permission but receives nothing unless Input Monitoring is on, while an
/// active tap is covered by Accessibility and fails to create without it, so
/// "installed" means "working". It passes every event through unchanged, only reads
/// modifier changes and key-down timing to tell a clean tap or hold from a chord like
/// ⌥E, and never records or blocks keystrokes. A hold begins only after
/// `ModifierTapDetector.holdDelay` with nothing else pressed, so typing ⌥-characters
/// never starts listening.
///
/// Configure with:  defaults write com.emerssive.heybenji.app talkKey rightOption   # or "off"
final class ModifierTalkKey {
    var onTap: (() -> Void)?
    var onHoldBegan: (() -> Void)?
    var onHoldEnded: (() -> Void)?

    let displayString = "Right ⌥"
    private var detector = ModifierTapDetector()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var retryTimer: Timer?
    private var revokeWatch: Timer?
    private var onStateChange: ((Bool) -> Void)?

    static var isEnabled: Bool {
        UserDefaults.standard.string(forKey: "talkKey")?.lowercased() != "off"
    }

    static var hasPermission: Bool { Permissions.isGranted(.accessibility) }

    /// Starts listening if Accessibility is granted. Otherwise it keeps checking, so it starts as soon as the
    /// user allows it; the permission setup window is the one place that asks, so macOS's own prompt never
    /// appears on top of it. If Accessibility is turned off later, the tap is removed and it waits again.
    func start(onStateChange: @escaping (Bool) -> Void) {
        self.onStateChange = onStateChange
        if installAndWatch() { return }
        waitForPermission()
    }

    private func waitForPermission() {
        onStateChange?(false)
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard let self, self.installAndWatch() else { return }
            timer.invalidate()
        }
    }

    private func installAndWatch() -> Bool {
        guard install() else { return false }
        onStateChange?(true)
        revokeWatch?.invalidate()
        revokeWatch = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, !Self.hasPermission else { return }
            self.removeTap()
            self.waitForPermission()
        }
        return true
    }

    /// Takes the tap out of the event stream. A hold in progress ends, so the mic isn't left open.
    private func removeTap() {
        revokeWatch?.invalidate()
        revokeWatch = nil
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        if let event = detector.reset() { deliver(event) }
    }

    private func install() -> Bool {
        guard tap == nil else { return true }
        guard Self.hasPermission else { return false }
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, userInfo in
                if let userInfo {
                    Unmanaged<ModifierTalkKey>.fromOpaque(userInfo).takeUnretainedValue().handle(type, event)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: selfPtr
        ) else { return false }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        return true
    }

    // Device-dependent modifier bits (IOKit NX_DEVICE*KEYMASK): tell right ⌥ from left ⌥.
    private static let rightOptionBit: UInt64 = 0x40
    private static let leftOptionBit: UInt64 = 0x20

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if Self.hasPermission {
                if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            } else {
                DispatchQueue.main.async {
                    guard self.tap != nil else { return }
                    self.removeTap()
                    self.waitForPermission()
                }
            }
        case .keyDown:
            detector.keyPressed()
        case .flagsChanged:
            let raw = event.flags.rawValue
            let flags = event.flags
            let rightDown = raw & Self.rightOptionBit != 0
            let othersDown = flags.contains(.maskCommand) || flags.contains(.maskControl)
                || flags.contains(.maskShift) || flags.contains(.maskSecondaryFn)
                || raw & Self.leftOptionBit != 0
            let now = ProcessInfo.processInfo.systemUptime
            if let result = detector.change(targetDown: rightDown, othersDown: othersDown, at: now) {
                DispatchQueue.main.async { self.deliver(result) }
            } else if rightDown {
                // No event arrives while the key is held, so check back once the hold delay is up.
                DispatchQueue.main.asyncAfter(deadline: .now() + ModifierTapDetector.holdDelay + 0.01) {
                    if let result = self.detector.holdCheck(at: ProcessInfo.processInfo.systemUptime) {
                        self.deliver(result)
                    }
                }
            }
        default:
            break
        }
    }

    private func deliver(_ event: ModifierKeyEvent) {
        switch event {
        case .tap: onTap?()
        case .holdBegan: onHoldBegan?()
        case .holdEnded: onHoldEnded?()
        }
    }
}
