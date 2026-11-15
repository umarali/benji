import AppKit
import Combine
import SwiftUI
import BenjiCore

/// The borderless, non-activating window the notch object is drawn in, its top edge at the top
/// of the display and centred on the notch, above the menu bar. Non-activating so it never steals
/// focus; it takes the keyboard only when the user opens it, clicks into the composer, or an
/// approval needs an answer.
/// The window is sized to the largest shape it has to show (grown at once, shrunk once a morph
/// settles); the shape itself animates inside it.
final class CompanionPanel: NSPanel {
    let presenter: NotchPresenter
    private let model: CompanionModel
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var approvalWatch: AnyCancellable?
    private var screenModeWatch: AnyCancellable?
    private var settingsWatch: AnyCancellable?
    private var expandedWatch: AnyCancellable?
    /// The approval took the keyboard from another app; hand it back once answered.
    private var returnKeyboardAfterApproval = false
    /// The display the one panel is on now, and Benji's home (`DisplayAnchors.home`). The panel visits
    /// another display when the user rests on or clicks its bar, and goes home once it has closed.
    private(set) var hostDisplayID: UInt32?
    private var homeDisplayID: UInt32?
    private let bars = DisplayBars()
    private var anchors: [DisplayAnchor] = []
    private var anchorRest = HoverRestDetector()
    private var anchorUnder: UInt32?
    private var anchorCheck: DispatchWorkItem?
    /// A newly restored entry point under the pointer must be left before another peek can open.
    private var suppressedAnchor: UInt32?
    /// The panel moved to another display, or the displays changed (names, count).
    var onHostChanged: ((UInt32?) -> Void)?

    /// Room for `shadow-notch-open` (0 18 40) around the open size.
    private static let shadowMargin = NSEdgeInsets(top: 0, left: 40, bottom: 60, right: 40)

    init(model: CompanionModel) {
        self.model = model
        let screen = Self.notchScreen()
        presenter = NotchPresenter(model: model, layout: screen.map(NotchLayoutInfo.init(screen:))
            ?? NotchLayoutInfo(notch: nil, screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900)))
        super.init(
            contentRect: presenter.layout.shape(.closed).outerFrame,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        // Above the menu bar, so the object is continuous with the hardware notch.
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false   // the open size draws its own, following the height
        isMovableByWindowBackground = false
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        animationBehavior = .none
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = true

        let hosting = NSHostingView(rootView: CompanionView(model: model, presenter: presenter,
                                                            onOpen: { [weak self] in self?.openAndFocus() }))
        hosting.sizingOptions = []   // the window's size is ours, not the content's
        hosting.autoresizingMask = [.width, .height]
        contentView = hosting

        hostDisplayID = screen.flatMap(DisplayInventory.id(of:))
        homeDisplayID = hostDisplayID
        presenter.onWindowSize = { [weak self] size in self?.cover(size) }
        presenter.onClosed = { [weak self] in
            self?.returnKeyboard()
            self?.returnHome()
        }
        bars.onPress = { [weak self] display in self?.open(onDisplay: display) }
        presenter.panelFocused = { [weak self] in self?.isKeyWindow ?? false }
        installMonitors()
        refreshAnchors()
        screenModeWatch = model.screenMode.$mode.combineLatest(model.$visionUnavailable)
            .map { mode, noVision in mode == .on && noVision == nil }.removeDuplicates()
            .sink { [weak self] on in DispatchQueue.main.async {
                self?.presenter.setScreenOn(on)
                self?.bars.setScreenOn(on)
            } }
        settingsWatch = model.$settingsOpen.removeDuplicates()
            .sink { [weak self] on in DispatchQueue.main.async { self?.presenter.setSettingsOn(on) } }
        expandedWatch = model.$panelExpanded.removeDuplicates()
            .sink { [weak self] on in DispatchQueue.main.async { self?.presenter.setExpandedOn(on) } }
        approvalWatch = model.$state.map { $0.pendingApproval != nil }.removeDuplicates().dropFirst()
            .sink { [weak self] pending in
                guard !pending else { return }
                DispatchQueue.main.async { self?.approvalEnded() }
            }
    }

    deinit {
        monitors.forEach(NSEvent.removeMonitor)
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    // Allow typing in the composer when clicked, without activating the app on show.
    override var canBecomeKey: Bool { true }

    // Never let AppKit push the window below the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    /// Escape: stop an answer and fold, or close when idle.
    /// Escape on the settings page goes back to the conversation, and from the list of
    /// conversations back home.
    override func cancelOperation(_ sender: Any?) {
        presenter.escape()
    }

    /// While an approval waits, Return and Escape mean No and ⌘Return means Yes, wherever focus
    /// is in the panel (the composer's field would otherwise take Return).
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, model.state.pendingApproval != nil {
            let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
            if let choice = ApprovalPolicy.choice(keyCode: event.keyCode, command: flags.contains(.command),
                                                  otherModifiers: !flags.subtracting(.command).isEmpty) {
                if !event.isARepeat { model.decideApproval(choice) }
                return
            }
        }
        super.sendEvent(event)
    }

    override func resignKey() {
        super.resignKey()
        presenter.panelResignedFocus()
    }

    // A menu-bar-only app has no Edit menu, so ⌘X/C/V/A/Z never reach the text
    // field. Route them to the first responder (the composer's field editor).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let action = Self.editAction(for: event), NSApp.sendAction(action, to: nil, from: self) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private static func editAction(for event: NSEvent) -> Selector? {
        guard event.type == .keyDown else { return nil }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        switch (flags, event.charactersIgnoringModifiers?.lowercased()) {
        case ([.command], "x"): return #selector(NSText.cut(_:))
        case ([.command], "c"): return #selector(NSText.copy(_:))
        case ([.command], "v"): return #selector(NSText.paste(_:))
        case ([.command], "a"): return #selector(NSText.selectAll(_:))
        case ([.command], "z"): return Selector(("undo:"))
        case ([.command, .shift], "z"): return Selector(("redo:"))
        default: return nil
        }
    }

    /// Benji lives on the display with the hardware notch; without one, on the menu-bar display.
    static func notchScreen() -> NSScreen? {
        DisplayInventory.screen(DisplayAnchors.home(DisplayInventory.current())?.id) ?? NSScreen.screens.first
    }

    // MARK: showing

    /// Puts the object on screen (closed: it is the notch, nothing else is drawn).
    func show() {
        cover(.closed)
        orderFrontRegardless()
    }

    /// The menu item: open the panel and take the keyboard, or close it. `display`: the display whose
    /// menu bar it was chosen from, where the panel opens.
    func toggleOpen(onDisplay display: UInt32? = nil) {
        if presenter.size == .open { presenter.fold() } else if let display { open(onDisplay: display) } else { openAndFocus() }
    }

    /// A bar's click, or the menu on that display's menu bar: the one panel opens there. It moves
    /// even when open elsewhere, but never away from a card waiting for an answer.
    func open(onDisplay display: UInt32) {
        if DisplayAnchors.mayMove(target: presenter.targetSize, userOpened: model.expanded, cardWaiting: cardWaiting,
                                  explicit: true) {
            move(to: display)
        }
        openAndFocus()
    }

    func openAndFocus() {
        if !isVisible { show() }
        presenter.open()
        makeKey()
    }

    /// Words were just put in the message box (an app offer's Try it): open with the caret after them.
    func openForTyping() {
        openAndFocus()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, self.isKeyWindow else { return }
            (self.firstResponder as? NSTextView)?.moveToEndOfDocument(nil)
        }
    }

    /// An approval arrived: the notch opens (NotchPresence) and the panel takes the keyboard,
    /// without activating Benji, so it works over whatever app is in front.
    func presentApproval() {
        if !isVisible { show() }
        if !isKeyWindow { returnKeyboardAfterApproval = true }
        makeKey()
        if ProcessInfo.processInfo.environment["BENJI_DEBUG"] == "1" {
            let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil"
            FileHandle.standardError.write(Data(
                "[approval] panelKey=\(isKeyWindow) appActive=\(NSApp.isActive) front=\(front)\n".utf8))
        }
    }

    /// Answered, timed out or cancelled: give the keyboard back unless the user is now using the
    /// panel (Adjust, or they opened it).
    private func approvalEnded() {
        let restore = returnKeyboardAfterApproval
        returnKeyboardAfterApproval = false
        if model.expanded {
            // Adjust filled the composer: put the caret at the end so typing edits the action
            // instead of replacing it (after SwiftUI has pushed the text into the field).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self, self.isKeyWindow, !self.model.composerText.isEmpty else { return }
                (self.firstResponder as? NSTextView)?.moveToEndOfDocument(nil)
            }
        } else if restore {
            returnKeyboard()
        }
    }

    /// Size the window for `size`: its outer frame (with the shoulders), plus the open shadow.
    private func cover(_ size: NotchSize) {
        var frame = presenter.layout.shape(size).outerFrame
        if size >= .card {
            let m = Self.shadowMargin
            frame = CGRect(x: frame.minX - m.left, y: frame.minY - m.bottom,
                           width: frame.width + m.left + m.right, height: frame.height + m.bottom)
        }
        ignoresMouseEvents = size == .closed
        if ProcessInfo.processInfo.environment["BENJI_DEBUG"] == "1" {
            FileHandle.standardError.write(Data("[panel] size=\(size) frame=\(frame)\n".utf8))
        }
        setFrame(frame, display: true, animate: false)
        refreshAnchors()
    }

    /// A key panel that closes would keep the keyboard while invisible; hand it back.
    /// A screen step is about to type: the app in front gets the keyboard back.
    func giveBackKeyboard() { returnKeyboard() }

    private func returnKeyboard() {
        guard isKeyWindow else { return }
        orderOut(nil)
        orderFrontRegardless()
    }

    // MARK: other displays

    /// An approval or the Ask card waits on the panel where it is.
    private var cardWaiting: Bool { model.state.pendingApproval != nil || model.pendingScreenSend != nil }

    /// The panel's shapes move to `display` and the window follows; the bars follow the panel.
    private func move(to display: UInt32) {
        guard display != hostDisplayID, let screen = DisplayInventory.screen(display) else { return }
        hostDisplayID = display
        presenter.setLayout(NotchLayoutInfo(screen: screen))
        refreshAnchors()
        onHostChanged?(display)
    }

    /// Closed on another display: back to the notch, so that display only ever keeps its quiet bar.
    private func returnHome() {
        guard let home = homeDisplayID, hostDisplayID != home, presenter.size == .closed else { return }
        move(to: home)
    }

    private func refreshAnchors() {
        let next = DisplayAnchors.anchors(displays: DisplayInventory.current(), host: hostDisplayID,
                                         panelClosed: presenter.targetSize == .closed)
        guard next != anchors else { return }
        anchors = next
        anchorCheck?.cancel()
        anchorCheck = nil
        anchorUnder = nil
        suppressedAnchor = DisplayAnchors.anchor(at: NSEvent.mouseLocation, in: anchors)?.display
        _ = anchorRest.sample(.zero, at: 0, zone: .null)   // whatever was under the pointer has moved
        bars.update(anchors)
    }

    /// Every pointer move, before the presenter's own hover: resting on another display's bar (or on
    /// home's notch while Benji is away) brings the panel there as a peek, by the notch's rest rule.
    private func anchorPointerMoved(to point: CGPoint, at time: TimeInterval) {
        let hit = DisplayAnchors.anchor(at: point, in: anchors)
        let anchor = hit.flatMap { a in a.kind != .bar || bars.isVisible(a.display) ? a : nil }
        bars.setHot(anchor?.kind == .bar ? anchor?.display : nil)
        if let suppressedAnchor, anchor?.display == suppressedAnchor { return }
        suppressedAnchor = nil
        if anchor?.display != anchorUnder {
            _ = anchorRest.sample(point, at: time, zone: .null)
            anchorUnder = anchor?.display
            anchorCheck?.cancel()
        }
        guard let anchor else { return }
        if anchorRest.sample(point, at: time, zone: anchor.restZone) {
            anchorRested(anchor.display)
        } else {
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.anchorUnder == anchor.display else { return }
                if self.anchorRest.check(at: ProcessInfo.processInfo.systemUptime) { self.anchorRested(anchor.display) }
            }
            anchorCheck?.cancel()
            anchorCheck = work
            DispatchQueue.main.asyncAfter(deadline: .now() + anchorRest.rest + 0.005, execute: work)
        }
    }

    private func anchorRested(_ display: UInt32) {
        guard suppressedAnchor != display, let anchor = anchors.first(where: { $0.display == display }),
              anchor.kind != .bar || bars.isVisible(display) else { return }
        guard DisplayAnchors.mayMove(target: presenter.targetSize, userOpened: model.expanded,
                                     cardWaiting: cardWaiting) else { return }
        move(to: display)
        presenter.revealHover()   // the pointer already rested; no keyboard, no capture
    }

    // MARK: pointer and display changes

    private func installMonitors() {
        // Mouse-moved monitors need no permission (only key monitoring does).
        let handle: (NSEvent) -> Void = { [weak self] event in
            let point = NSEvent.mouseLocation
            self?.anchorPointerMoved(to: point, at: event.timestamp)
            // A flat closed display is reached only through its visible bar, not the presenter's
            // synthetic notch-sized layout zone. Once revealed, the usual panel hover takes over.
            if let self, self.presenter.layout.hasHardwareNotch || self.presenter.targetSize != .closed {
                self.presenter.pointerMoved(to: point, at: event.timestamp)
            }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: handle) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: {
            handle($0)
            return $0
        }) {
            monitors.append(local)
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Plugged, unplugged, rearranged or rescaled: home is found again, and a panel whose
            // display has gone (or that is closed anyway) goes home.
            guard let self else { return }
            let displays = DisplayInventory.current()
            self.homeDisplayID = DisplayAnchors.home(displays)?.id
            if self.presenter.size == .closed || !displays.contains(where: { $0.id == self.hostDisplayID }) {
                self.hostDisplayID = self.homeDisplayID
            }
            if let screen = DisplayInventory.screen(self.hostDisplayID) ?? Self.notchScreen() {
                self.presenter.setLayout(NotchLayoutInfo(screen: screen))
            }
            self.refreshAnchors()
            self.onHostChanged?(self.hostDisplayID)
        })
    }
}
