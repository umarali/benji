import AppKit
import BenjiCore

/// Watches the user's own input while a drive is on and hands it to the model, which decides
/// (`DriveHandBack`): Esc, typing, a click or a scroll end the drive, a move of the mouse pauses it.
/// Events Benji posts itself carry the app's marker (`ScreenActuator.marker`, set on the event
/// source of every click, scroll and key it posts) and are dropped here, so the app's own input never
/// counts as the user's. No new framework: the same NSEvent monitors the step watch already uses.
final class DriveMonitor {
    /// An input of the user's and when it happened (the monotonic clock).
    var onInput: ((DriveHandBack.Input, Double) -> Void)?
    private var monitors: [Any] = []

    func watch(_ on: Bool) {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        guard on else { return }
        let kinds: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .leftMouseDown,
                                            .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel]
        let handle: (NSEvent) -> Void = { [weak self] e in
            guard let self, e.cgEvent?.getIntegerValueField(.eventSourceUserData) != ScreenActuator.marker else { return }
            let input: DriveHandBack.Input
            switch e.type {
            case .mouseMoved, .leftMouseDragged, .rightMouseDragged: input = .pointerMoved(NSEvent.mouseLocation)
            case .keyDown: input = .keyDown(e.keyCode)
            case .scrollWheel: input = .scroll
            default: input = .mouseDown
            }
            self.onInput?(input, ProcessInfo.processInfo.systemUptime)
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: kinds, handler: handle) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: kinds, handler: { handle($0); return $0 }) {
            monitors.append(m)
        }
    }
}
