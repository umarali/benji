import AppKit
import Combine
import SwiftUI
import BenjiCore

/// The guided permission setup window. Opens once on first launch (if something is
/// missing) and from the menu; re-reads every status each second while it is showing, so a
/// step ticks off by itself and the next one is highlighted. Polls only while open.
@MainActor
final class PermissionSetupWindowController: NSObject, NSWindowDelegate {
    private static let shownKey = "permissionSetupShown"
    private static let resumeKey = "permissionSetupResumeAfterRelaunch"
    private static let screenAskedKey = "permissionSetupScreenRecordingAsked"

    private var window: NSWindow?
    private var model: PermissionSetupModel?
    private var modelSetup: ModelSetupModel?
    private var timer: Timer?
    private var activeObserver: NSObjectProtocol?
    private var closeWork: DispatchWorkItem?
    private var helperWatch: AnyCancellable?
    /// The window's top-right corner: the content sizes the window (full setup or the helper), and it
    /// grows and shrinks from this corner, which the user can move by moving the window.
    private var corner: CGPoint?
    private var cornerSize: CGSize?

    nonisolated override init() { super.init() }

    func configureModel(store: KeyStore, defaults: UserDefaults, backend: ModelSetupBackend,
                        onChange: @escaping () -> Void) {
        let setup = ModelSetupModel(store: store, defaults: defaults, backend: backend, files: QuietServices.keyFiles)
        setup.onConfigurationChanged = onChange
        modelSetup = setup
    }

    /// First launch, or right after a relaunch that setup asked for. AppKit calls these on
    /// the main thread.
    nonisolated func openOnLaunchIfNeeded() {
        MainActor.assumeIsolated { openIfNeeded() }
    }

    nonisolated func show() {
        MainActor.assumeIsolated { present() }
    }

    private func openIfNeeded() {
        let defaults = UserDefaults.standard
        let resume = defaults.bool(forKey: Self.resumeKey)
        defaults.removeObject(forKey: Self.resumeKey)
        guard resume || !defaults.bool(forKey: Self.shownKey) else { return }
        if resume { present(); return }
        // Decide with real model metadata; a probe never sends a model request or opens a window.
        if let modelSetup {
            modelSetup.checkExisting { [weak self] in
                guard let self, self.window?.isVisible != true else { return }
                let complete = SetupProgress(permissions: Permissions.statuses(), modelDone: modelSetup.isDone).isComplete
                if SetupAutoOpen.shouldOpen(alreadyShown: defaults.bool(forKey: Self.shownKey),
                                            resumeAfterRelaunch: false, isComplete: complete) {
                    self.present()
                }
            }
        } else { present() }
    }

    private func present() {
        UserDefaults.standard.set(true, forKey: Self.shownKey)
        if window == nil { makeWindow() }
        closeWork?.cancel()
        model?.refresh()
        modelSetup?.checkExisting()
        startPolling()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() {
        let model = PermissionSetupModel(
            probe: { Permissions.statuses() },
            actions: actions(),
            modelSetup: modelSetup,
            screenRecordingAsked: UserDefaults.standard.bool(forKey: Self.screenAskedKey))
        model.onAnnounce = { [weak self] line in self?.announce(line) }
        model.onComplete = { [weak self] in self?.finishSoon() }
        model.onIncomplete = { [weak self] in
            self?.closeWork?.cancel()
            self?.window?.level = .floating
            self?.startPolling()
        }
        self.model = model

        let hosting = NSHostingView(rootView: PermissionSetupView(model: model))
        let window = SetupWindow(contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
                                 styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Set Up Benji"
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        window.delegate = self
        // Stay above System Settings so the icon can be dragged into its list.
        window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        if let screen = NSScreen.main?.visibleFrame {
            let size = window.frame.size
            window.setFrameOrigin(NSPoint(x: screen.maxX - size.width - 24, y: screen.maxY - size.height - 24))
        }
        self.window = window
        // Opening Accessibility Settings turns this same window into the small helper beside it, and
        // macOS reporting Benji on (or "Back to full setup") turns it back. One window, never a second.
        helperWatch = model.$helperRequested.combineLatest(model.$progress)
            .map { requested, progress in requested && progress.current == .accessibility }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] helper in
                self?.window?.isMovableByWindowBackground = helper
                self?.window?.title = helper ? "Benji: Accessibility" : "Set Up Benji"
            }
        corner = CGPoint(x: window.frame.maxX, y: window.frame.maxY)
        cornerSize = window.frame.size
    }

    func windowDidResize(_ notification: Notification) {
        guard let window, let corner else { return }
        cornerSize = window.frame.size
        var origin = CGPoint(x: corner.x - window.frame.width, y: corner.y - window.frame.height)
        if let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
            origin.x = max(visible.minX, min(origin.x, visible.maxX - window.frame.width))
            origin.y = max(visible.minY, min(origin.y, visible.maxY - window.frame.height))
        }
        guard window.frame.origin != origin else { return }
        window.setFrameOrigin(origin)
    }

    /// Only a move at an unchanged size is the user's (a resize also moves the origin).
    func windowDidMove(_ notification: Notification) {
        guard let window, window.frame.size == cornerSize else { return }
        corner = CGPoint(x: window.frame.maxX, y: window.frame.maxY)
    }

    private func actions() -> PermissionSetupActions {
        PermissionSetupActions(
            openSettings: { step in
                // The voice step covers two panes: open the one still missing.
                if step == .voice,
                   let missing = step.permissions.first(where: { Permissions.status($0) != .granted }) {
                    Permissions.openSettings(missing)
                } else {
                    Permissions.openSettings(anchor: step.settingsAnchor)
                }
            },
            promptAccessibility: { [weak self] in
                Permissions.request(.accessibility) { self?.model?.refresh() }
            },
            requestVoice: { [weak self] in
                Permissions.request(.microphone) {
                    self?.model?.refresh()
                    Permissions.request(.speechRecognition) { self?.model?.refresh() }
                }
            },
            requestScreenRecording: { [weak self] in
                UserDefaults.standard.set(true, forKey: Self.screenAskedKey)
                self?.model?.screenRecordingAsked = true
                Permissions.request(.screenRecording) { self?.model?.refresh() }
            },
            relaunch: { [weak self] in self?.relaunch() },
            close: { [weak self] in self?.window?.close() })
    }

    private func startPolling() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.model?.refresh() }
        }
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.model?.refresh() }
        }
    }

    private func stopPolling() {
        timer?.invalidate()
        timer = nil
        if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) }
        activeObserver = nil
    }

    /// Only a real transition to Done calls this; reopening completed setup waits for Done.
    private func finishSoon() {
        stopPolling()
        window?.level = .normal
        let work = DispatchWorkItem { [weak self] in self?.window?.close() }
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    private func announce(_ line: String) {
        guard let window else { return }
        NSAccessibility.post(element: window, notification: .announcementRequested, userInfo: [
            .announcement: line,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }

    /// Screen Recording takes effect after a restart: reopen Benji and resume setup.
    private func relaunch() {
        UserDefaults.standard.set(true, forKey: Self.resumeKey)
        // Waits until this process has exited (D-173), then opens the app again; a fixed sleep could open
        // it while the old copy was still shutting down, and macOS would just bring the old one forward.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = RelaunchHelper.arguments(pid: ProcessInfo.processInfo.processIdentifier, target: Bundle.main.bundlePath)
        do {
            try task.run()
            NSApp.terminate(nil)
        } catch {
            UserDefaults.standard.removeObject(forKey: Self.resumeKey)
        }
    }

    func windowWillClose(_ notification: Notification) {
        stopPolling()
        model?.showFullSetup()
        modelSetup?.clearPaste()
        closeWork?.cancel()
        window?.level = .floating
    }
}

/// Escape closes setup, like "Not now".
private final class SetupWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) { close() }
}
