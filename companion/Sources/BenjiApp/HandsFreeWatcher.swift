import AppKit
import Carbon.HIToolbox
import BenjiCore

/// Ends a hands-free conversation when the user steps away or says stop without words:
/// Escape (anywhere; observed, never consumed), the screen locking, the session switching,
/// or the Mac going to sleep. Watches only while a conversation is on.
final class HandsFreeWatcher {
    var onEnd: ((HandsFreeEndReason) -> Void)?
    /// Escape answers a waiting card (No, D-88) instead of ending the conversation.
    var escapeBelongsToCard: () -> Bool = { false }

    private var monitors: [Any] = []
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    func start() {
        guard monitors.isEmpty && observers.isEmpty else { return }
        // Global key monitoring needs Accessibility (the talk key has it); without it only
        // Escape inside Benji's own panel is seen.
        let escape: (NSEvent) -> Void = { [weak self] e in
            guard let self, e.keyCode == UInt16(kVK_Escape), !self.escapeBelongsToCard() else { return }
            self.onEnd?(.escape)
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: escape) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { escape($0); return $0 }) {
            monitors.append(m)
        }
        let ws = NSWorkspace.shared.notificationCenter
        observe(ws, NSWorkspace.willSleepNotification, .sleep)
        observe(ws, NSWorkspace.screensDidSleepNotification, .sleep)
        observe(ws, NSWorkspace.sessionDidResignActiveNotification, .locked)
        observe(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsLocked"), .locked)
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        observers.forEach { $0.0.removeObserver($0.1) }
        observers = []
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ reason: HandsFreeEndReason) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            self?.onEnd?(reason)
        }
        observers.append((center, token))
    }
}
