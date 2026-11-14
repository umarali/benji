import AppKit
import ApplicationServices
import Carbon.HIToolbox
import BenjiCore

/// How one screen step ended, and the screen after it when it was done.
struct ScreenStepOutcome {
    let status: ScreenStepResult.Status
    let text: String
    let shot: CapturedScreen?

    static func refused(_ why: ScreenRefusal) -> ScreenStepOutcome { .init(status: .refused, text: why.text, shot: nil) }
}

/// Does one approved screen step (D-123): rings the target, then acts through Accessibility where
/// it can (AXPress on a control, text inserted at the caret of a native field) and synthetic
/// events where it can't (clicks, drags, the scroll wheel, keys). It refuses secure input, password
/// fields, password managers and Benji's own windows; stops the moment the user moves the mouse,
/// clicks, scrolls, types or presses Esc; waits for the screen to settle and takes a fresh
/// screenshot for the model. The decisions are BenjiCore's (ScreenAction.swift); this is AppKit.
final class ScreenActuator {
    /// Carried by every event Benji posts (kCGEventSourceUserData), so the take-over watch
    /// knows its own clicks and keys from the user's.
    static let marker: Int64 = 0x4348_494C   // "CHIL"
    private static let ownPID = ProcessInfo.processInfo.processIdentifier
    // How long the target is ringed before Benji acts: ScreenAutonomy.ringTime (a quiet step's
    // beat is longer).
    /// After the ring is taken down, before looking at what's under the point.
    static let clearTime: Double = 0.25

    /// Ring the step's target (the pointer overlay), and take it down.
    var showTarget: ((PointingPlan) -> Void)?
    var hideTarget: (() -> Void)?
    /// Benji gets out of the way: the panel collapses and gives the keyboard back, drawings go.
    var makeWay: (() -> Void)?
    /// Benji's panel has the keyboard (typing would land in it).
    var benjiHasKeyboard: (() -> Bool)?
    /// A fresh screenshot of a display, as for a message.
    var capture: ((NSScreen, @escaping (Result<CapturedScreen, Error>) -> Void) -> Void)?
    /// A small sample of a display, to tell when it has settled.
    var sample: ((UInt32?, @escaping ([UInt8]?) -> Void) -> Void)?

    private final class Running {
        let step: ScreenStep
        let shot: CapturedScreen
        let approvedPID: Int32?
        /// The app the card named where a drag lets go; nil when it named no other.
        let approvedEndPID: Int32?
        /// Free or quiet: a step nobody approved (D-126); nil: the approved one.
        let mode: ScreenStepClass?
        /// Inside a consented drive (D-170): the drive's rules look at the point, the drive-level watch
        /// (not this step's) decides when the user has taken over, and a move of the mouse only holds the step.
        let drive: Bool
        let done: (ScreenStepOutcome) -> Void
        var beat: StepBeat
        var watch: TakeOverWatch {
            get { beat.watch }
            set { beat.watch = newValue }
        }
        var monitors: [Any] = []
        var over = false
        /// Benji has started posting the step's events (a take-over now is after the step).
        var acting = false
        /// Set while a drag holds the button down: lets go. Every way a step ends runs it.
        var letGo: (() -> Void)?
        init(step: ScreenStep, shot: CapturedScreen, approvedPID: Int32?, approvedEndPID: Int32? = nil, mode: ScreenStepClass?,
             drive: Bool = false, done: @escaping (ScreenStepOutcome) -> Void) {
            self.step = step
            self.shot = shot
            self.approvedPID = approvedPID
            self.approvedEndPID = approvedEndPID
            self.mode = mode
            self.drive = drive
            self.done = done
            // A drive's steps ring for the short beat: the banner and its Esc hint are already up.
            beat = StepBeat(mode: drive ? .free : mode, pointer: NSEvent.mouseLocation)
        }
    }
    private var running: Running?
    /// Between steps of a turn that acts unasked: Esc stops the rest (D-126).
    private var turnMonitors: [Any] = []
    private var jobBeatMonitors: [Any] = []

    private static var now: Double { ProcessInfo.processInfo.systemUptime }

    // MARK: the card

    /// What the step would act on, for the approval card: the app whose window was under the
    /// point in the screenshot the model used (Benji's own windows left out: the card's panel
    /// may cover the point), or the app in front for typing and keys.
    func describe(_ step: ScreenStep, on shot: CapturedScreen?) -> ScreenTarget? {
        let pid: Int32?
        if let (x, y) = step.point {
            guard let shot, let p = ScreenActionGeometry.appKitPoint(x: x, y: y, pixelSize: shot.pixelSize,
                                                                     screenFrame: shot.screenFrame) else { return nil }
            let hit = hitTest(p)?.target.pid
            pid = ScreenActionGeometry.windowOwner(at: p, windows: shot.windows, excludingPID: Self.ownPID, hit: hit) ?? hit
        } else {
            pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        }
        guard let pid, pid != Self.ownPID else { return nil }
        let app = NSRunningApplication(processIdentifier: pid)
        return ScreenTarget(pid: pid, bundleID: app?.bundleIdentifier, appName: app?.localizedName)
    }

    /// The app where a drag would let go, for the card, found as for a click at that point.
    func describeEnd(_ step: ScreenStep, on shot: CapturedScreen?) -> ScreenTarget? {
        step.endPoint.flatMap { describe(.click(x: $0.x, y: $0.y, button: .left, count: 1, label: "end of the drag"), on: shot) }
    }

    // MARK: one step

    /// The user's mouse is moving during a drive: a step waits for it to be still (D-170); set by the app.
    var driveHold: (() -> Bool)?
    /// The longest a drive's step waits for the mouse to be still.
    private static let holdLimit: Double = 20

    /// A step inside a consented drive (D-170). `cls` free or quiet: sent unasked; nil: the one the
    /// user approved on a card. Either way the drive's rules look at the point first, and a field
    /// for a password, a card or a code is refused even if the user approved the step.
    func performDrive(_ step: ScreenStep, on shot: CapturedScreen, approvedPID: Int32?, approvedEndPID: Int32? = nil,
                      cls: DriveClass?, done: @escaping (ScreenStepOutcome) -> Void) {
        let mode: ScreenStepClass? = cls.map { $0 == .free ? .free : .quiet }
        perform(step, on: shot, approvedPID: approvedPID, approvedEndPID: approvedEndPID, mode: mode, drive: true, done: done)
    }

    /// The user handed the screen back during a drive: the step in flight stops where it is.
    func handBack() {
        guard let run = running else { return }
        stopped(run, didAct: run.acting)
    }

    /// `mode` free or quiet: a step nobody approved (D-126). Benji looks at what is there before
    /// ringing it and again after, and answers `ask` (doing nothing) when its class says so.
    func perform(_ step: ScreenStep, on shot: CapturedScreen, approvedPID: Int32?, approvedEndPID: Int32? = nil,
                 mode: ScreenStepClass? = nil, drive: Bool = false, done: @escaping (ScreenStepOutcome) -> Void) {
        cancel()
        // Nothing to look at yet: say no before ringing anything.
        if let why = ScreenActionPolicy.precheck(accessibility: AXIsProcessTrusted(),
                                                 secureInput: IsSecureEventInputEnabled()) {
            return done(.refused(why))
        }
        for (x, y) in [step.point, step.endPoint].compactMap({ $0 })
        where ScreenActionGeometry.appKitPoint(x: x, y: y, pixelSize: shot.pixelSize, screenFrame: shot.screenFrame) == nil {
            return done(.refused(.outsideScreenshot))
        }
        let run = Running(step: step, shot: shot, approvedPID: approvedPID, approvedEndPID: approvedEndPID, mode: mode,
                          drive: drive, done: done)
        running = run
        // Unasked: what is there decides before anything shows; a step that must be asked rings nothing.
        // (Benji's own window in the way is moved aside later, in resolve, and looked at again there.)
        // In a drive even the approved step is looked at, for the fields it must never type in.
        let found = (mode == nil && !drive) ? nil : look(run)
        let end = (mode == nil && !drive) ? nil : lookEnd(run)
        if (mode != nil || drive), found?.target.pid != Self.ownPID, end?.target.pid != Self.ownPID,
           let verdict = driveAwareVerdict(run, found: found, end: end) {
            running = nil
            return done(verdict)
        }
        if !drive { watch(run) }
        ring(run)
        after(run.beat.duration) { [weak self] in
            guard let self, !run.over else { return }
            if run.beat.decision(elapsed: run.beat.duration) == .stop { return self.stopped(run, didAct: false) }
            self.hideTarget?()
            self.after(Self.clearTime) { self.holdForMouse(run, since: Self.now) { self.resolve(run, retried: false) } }
        }
    }

    /// In a drive a moving mouse only holds the step; it goes on when the pointer has been still.
    private func holdForMouse(_ run: Running, since: Double, then go: @escaping () -> Void) {
        guard !run.over else { return }
        guard run.drive, driveHold?() == true else { return go() }
        if Self.now - since > Self.holdLimit {
            return finish(run, ScreenStepOutcome(status: .failed, text: "You were using the mouse, so nothing was done.", shot: nil))
        }
        after(0.2) { [weak self] in self?.holdForMouse(run, since: since, then: go) }
    }

    /// What a drive's rules (or, outside a drive, the unasked classes) say about the step at the point:
    /// an outcome to end it with (`ask` or `refused`), or nil to go ahead. An approved step is only ever refused.
    private func driveAwareVerdict(_ run: Running, found: (target: ScreenTarget, chain: [AXUIElement])?,
                                   end: (target: ScreenTarget, chain: [AXUIElement])? = nil) -> ScreenStepOutcome? {
        guard run.drive else {
            guard let why = askReason(run, found: found) else { return nil }
            return ScreenStepOutcome(status: .ask, text: why, shot: nil)
        }
        let planned: DriveClass = run.mode == .free ? .free : .quiet
        let (cls, why) = DriveClassifier.final(run.step, planned: planned, element: found?.target.element,
                                               sameApp: sameApp(run, found: found), endElement: end?.target.element,
                                               sameControl: staysOnControl(run, found: found, end: end))
        switch cls {
        case .denied:
            return ScreenStepOutcome(status: .refused, text: why.prefix(1).uppercased() + why.dropFirst() + ".", shot: nil)
        case .asked where run.mode != nil:
            return ScreenStepOutcome(status: .ask, text: why.isEmpty ? "Benji wants to ask first" : why, shot: nil)
        default:
            return nil
        }
    }

    /// Esc between the steps of a turn that acts unasked (D-126).
    func watchTurn(_ on: Bool, onEscape: @escaping () -> Void) {
        turnMonitors.forEach(NSEvent.removeMonitor)
        turnMonitors = []
        guard on else { return }
        let handle: (NSEvent) -> Void = { e in
            guard e.keyCode == KeyCodes.escape,
                  e.cgEvent?.getIntegerValueField(.eventSourceUserData) != Self.marker else { return }
            onEscape()
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handle) { turnMonitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { handle($0); return $0 }) {
            turnMonitors.append(m)
        }
    }

    /// Esc during a background job's beat, before it starts (D-130 step 1). Separate from
    /// `watchTurn`, so a job's beat and a screen turn don't take each other's monitor away.
    func watchJobBeat(_ on: Bool, onEscape: @escaping () -> Void) {
        jobBeatMonitors.forEach(NSEvent.removeMonitor)
        jobBeatMonitors = []
        guard on else { return }
        let handle: (NSEvent) -> Void = { e in
            guard e.keyCode == KeyCodes.escape,
                  e.cgEvent?.getIntegerValueField(.eventSourceUserData) != Self.marker else { return }
            onEscape()
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handle) { jobBeatMonitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { handle($0); return $0 }) {
            jobBeatMonitors.append(m)
        }
    }

    /// What is where the step acts: under the point, or the field with the keyboard.
    private func look(_ run: Running) -> (target: ScreenTarget, chain: [AXUIElement])? {
        if let (x, y) = run.step.point {
            return ScreenActionGeometry.appKitPoint(x: x, y: y, pixelSize: run.shot.pixelSize,
                                                    screenFrame: run.shot.screenFrame).flatMap(hitTest)
        }
        return focused()
    }

    /// What is where a drag lets go.
    private func lookEnd(_ run: Running) -> (target: ScreenTarget, chain: [AXUIElement])? {
        run.step.endPoint.flatMap {
            ScreenActionGeometry.appKitPoint(x: $0.x, y: $0.y, pixelSize: run.shot.pixelSize, screenFrame: run.shot.screenFrame)
        }.flatMap(hitTest)
    }

    /// A drag lets go in the app it pressed and inside the slider or split group it pressed.
    private func staysOnControl(_ run: Running, found: (target: ScreenTarget, chain: [AXUIElement])?,
                                end: (target: ScreenTarget, chain: [AXUIElement])?) -> Bool {
        guard let found, let end, found.target.pid == end.target.pid, let point = run.step.endPoint,
              let appKit = ScreenActionGeometry.appKitPoint(x: point.x, y: point.y, pixelSize: run.shot.pixelSize,
                                                            screenFrame: run.shot.screenFrame),
              let level = DriveClassifier.dragBoundsLevel(roles: found.target.roles), level < found.chain.count,
              let frame = Self.globalFrame(found.chain[level]) else { return false }
        return frame.contains(ScreenActionGeometry.globalPoint(appKit, primaryMaxY: NSScreen.screens.first?.frame.maxY ?? 0))
    }

    /// Why an unasked step must be asked after all (ScreenStepClassifier.final), or nil.
    private func askReason(_ run: Running, found: (target: ScreenTarget, chain: [AXUIElement])?) -> String? {
        guard let mode = run.mode else { return nil }
        let (cls, why) = ScreenStepClassifier.final(run.step, planned: mode, element: found?.target.element,
                                                    sameApp: sameApp(run, found: found))
        return cls == .asked ? (why.isEmpty ? "Benji wants to ask first" : why) : nil
    }

    /// The app under the point (or in front) is the one in the screenshot the model looked at.
    private func sameApp(_ run: Running, found: (target: ScreenTarget, chain: [AXUIElement])?) -> Bool {
        let shot = run.shot
        let expected: Int32?
        if let (x, y) = run.step.point {
            expected = ScreenActionGeometry.appKitPoint(x: x, y: y, pixelSize: shot.pixelSize, screenFrame: shot.screenFrame)
                .flatMap { ScreenActionGeometry.windowOwner(at: $0, windows: shot.windows, excludingPID: Self.ownPID,
                                                            hit: found?.target.pid) }
        } else {
            expected = ScreenActionGeometry.frontApp(windows: shot.windows, excludingPID: Self.ownPID)
        }
        // Benji's own window in the way isn't another app: resolve moves it aside.
        let pid = found?.target.pid
        return pid == Self.ownPID || (pid != nil && pid == expected)
    }

    /// The turn was cancelled: stop at once and say nothing.
    func cancel() {
        guard let run = running else { return }
        release(run)
        run.over = true
        stopWatching(run)
        hideTarget?()
        running = nil
    }

    private func release(_ run: Running) {
        run.letGo?()
        run.letGo = nil
    }

    private func finish(_ run: Running, _ outcome: ScreenStepOutcome) {
        guard !run.over else { return }
        release(run)
        run.over = true
        stopWatching(run)
        if running === run { running = nil }
        run.done(outcome)
    }

    private func stopped(_ run: Running, didAct: Bool) {
        // In a drive a move of the mouse only pauses (D-170): the held drag ends, the drive doesn't.
        if run.letGo != nil, run.drive, run.watch.tookOver {
            return finish(run, ScreenStepOutcome(status: .failed, text: ScreenActionPolicy.dragInterrupted, shot: nil))
        }
        let tail = run.letGo != nil ? ScreenActionPolicy.dragLetGo : didAct ? " (after the step was done)." : ", so nothing was done."
        let text = ScreenActionPolicy.tookOverLine + tail
        finish(run, ScreenStepOutcome(status: .stopped, text: text, shot: nil))
    }

    /// The ring over the target: the point for a click or scroll, the field with the keyboard
    /// for typing and keys (when Accessibility says where it is).
    private func ring(_ run: Running) {
        let shot = run.shot
        var at = run.step.point
        if at == nil, let frame = focusedFrame(), let p = ScreenActionGeometry.pixel(
            for: CGPoint(x: frame.midX, y: frame.midY), pixelSize: shot.pixelSize, screenFrame: shot.screenFrame) {
            at = p
        }
        guard let (x, y) = at else { return }
        var label: String
        switch run.step {
        case let .click(_, _, _, _, l): label = l
        case let .scroll(_, _, _, _, l): label = l
        case let .drag(_, _, _, _, l): label = l
        default: label = ""
        }
        if run.mode == .quiet { label = ScreenAutonomy.beatLabel(run.step) }
        if let plan = PointingPlan(targets: [PointingTarget(shape: .point(x: x, y: y), label: label)], text: label,
                                   speaking: false, pixelSize: shot.pixelSize, screenFrame: shot.screenFrame,
                                   displayID: shot.displayID) {
            showTarget?(plan)
        }
    }

    /// Looks at what is there now, refuses or acts. Benji's own window in the way (the panel,
    /// a drawing) or holding the keyboard is moved aside once.
    private func resolve(_ run: Running, retried: Bool) {
        guard !run.over else { return }
        if run.watch.tookOver { return stopped(run, didAct: false) }
        let step = run.step
        var found: (target: ScreenTarget, chain: [AXUIElement])?
        var appKit: CGPoint?
        if let (x, y) = step.point {
            appKit = ScreenActionGeometry.appKitPoint(x: x, y: y, pixelSize: run.shot.pixelSize,
                                                      screenFrame: run.shot.screenFrame)
            found = appKit.flatMap(hitTest)
        } else {
            if benjiHasKeyboard?() == true, !retried {
                makeWay?()
                return after(0.2) { [weak self] in self?.resolve(run, retried: true) }
            }
            found = focused()
        }
        let end = lookEnd(run)
        if found?.target.pid == Self.ownPID || end?.target.pid == Self.ownPID, !retried {
            makeWay?()
            return after(0.3) { [weak self] in self?.resolve(run, retried: true) }
        }
        if let why = ScreenActionPolicy.refusal(for: step, target: found?.target, accessibility: AXIsProcessTrusted(),
                                                secureInput: IsSecureEventInputEnabled(), ownPID: Self.ownPID,
                                                approvedPID: run.approvedPID, endTarget: end?.target,
                                                approvedEndPID: run.approvedEndPID) {
            return finish(run, .refused(why))
        }
        // Unasked: look again after the ring; what is there now must still pass (D-126). In a drive
        // the approved step is looked at too, for the fields it must never type in (D-170).
        if run.mode != nil || run.drive, let verdict = driveAwareVerdict(run, found: found, end: end) {
            return finish(run, verdict)
        }
        guard let found else { return finish(run, .refused(.nothingThere)) }
        act(run, target: found.target, chain: found.chain, at: appKit, end: end?.target)
    }

    // MARK: acting

    private func act(_ run: Running, target: ScreenTarget, chain: [AXUIElement], at appKit: CGPoint?, end: ScreenTarget?) {
        run.acting = true
        let source = CGEventSource(stateID: .hidSystemState)
        source?.userData = Self.marker
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        let doneText = ScreenStepCard.done(run.step, app: target.appName, endApp: end?.appName)
        let settle = { [weak self] in
            run.watch.benjiDone()
            self?.settle(run, text: doneText, started: Self.now, last: nil)
        }

        switch run.step {
        case let .click(_, _, button, count, _):
            guard let appKit else { return finish(run, .refused(.nothingThere)) }
            if case let .press(level) = ClickMethod.choose(for: run.step, target: target), level < chain.count,
               AXUIElementPerformAction(chain[level], kAXPressAction as CFString) == .success {
                return settle()
            }
            let p = ScreenActionGeometry.globalPoint(appKit, primaryMaxY: primaryMaxY)
            run.watch.benjiMovedPointer(to: appKit)
            run.watch.benjiActs()
            let (downType, upType, cgButton): (CGEventType, CGEventType, CGMouseButton) = button == .right
                ? (.rightMouseDown, .rightMouseUp, .right) : (.leftMouseDown, .leftMouseUp, .left)
            CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: cgButton)?
                .post(tap: .cghidEventTap)
            for click in 1...count {
                for type in [downType, upType] {
                    let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: cgButton)
                    e?.setIntegerValueField(.mouseEventClickState, value: Int64(click))
                    e?.post(tap: .cghidEventTap)
                }
            }
            after(0.05, settle)

        case let .scroll(_, _, direction, amount, _):
            guard let appKit else { return finish(run, .refused(.nothingThere)) }
            let p = ScreenActionGeometry.globalPoint(appKit, primaryMaxY: primaryMaxY)
            run.watch.benjiMovedPointer(to: appKit)
            run.watch.benjiActs()
            CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?
                .post(tap: .cghidEventTap)
            let deltas = ScreenActionGeometry.scrollDeltas(direction: direction, amount: amount,
                                                           displaySize: run.shot.screenFrame.size)
            post(deltas, run: run, every: 0.012, settle: settle) { d in
                let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                                wheel1: d.vertical, wheel2: d.horizontal, wheel3: 0)
                e?.location = p
                e?.post(tap: .cghidEventTap)
            }

        case let .typeText(text):
            if TypingMethod.choose(target: target) == .insert, let field = chain.first,
               AXUIElementSetAttributeValue(field, kAXSelectedTextAttribute as CFString, text as CFString) == .success {
                return settle()
            }
            run.watch.benjiActs(keys: [0])     // unicode key events carry virtual key 0
            post(TypingMethod.chunks(text), run: run, every: 0.01, settle: settle) { piece in
                var units = Array(piece.utf16)
                for down in [true, false] {
                    let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
                    e?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
                    e?.post(tap: .cghidEventTap)
                }
            }

        case let .pressKey(key, modifiers):
            guard let code = KeyCodes.code(for: key) else { return finish(run, .refused(.unreadable)) }
            run.watch.benjiActs(keys: [code], modifiers: !modifiers.isEmpty)
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: down)
                e?.flags = CGEventFlags(rawValue: KeyCodes.flags(modifiers))
                e?.post(tap: .cghidEventTap)
            }
            after(0.05, settle)

        case .drag:
            guard let appKit, let to = run.step.endPoint.flatMap({ ScreenActionGeometry.appKitPoint(
                x: $0.x, y: $0.y, pixelSize: run.shot.pixelSize, screenFrame: run.shot.screenFrame) }) else {
                return finish(run, .refused(.nothingThere))
            }
            run.watch.benjiActs()
            // A held button can't wait for a drive's pause: the user's move stops the drag there too.
            if run.drive { watch(run) }
            var last = appKit
            func send(_ event: DragPath.Event) {
                let type: CGEventType
                switch event {
                case .move: type = .mouseMoved
                case .down: type = .leftMouseDown
                case .dragged: type = .leftMouseDragged
                case .up: type = .leftMouseUp
                }
                let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition:
                    ScreenActionGeometry.globalPoint(event.point, primaryMaxY: primaryMaxY), mouseButton: .left)
                if type != .mouseMoved { e?.setIntegerValueField(.mouseEventClickState, value: 1) }
                if type == .leftMouseDragged {   // apps that read the movement, not the position
                    e?.setIntegerValueField(.mouseEventDeltaX, value: Int64((event.point.x - last.x).rounded()))
                    e?.setIntegerValueField(.mouseEventDeltaY, value: Int64((last.y - event.point.y).rounded()))
                }
                e?.post(tap: .cghidEventTap)
                last = event.point
            }
            var events = DragPath.events(from: appKit, to: to)
            let move = events.removeFirst()     // out with the press, so a take-over can't fall between them
            run.watch.benjiPosts(move)
            send(move)
            post(events, run: run, every: DragPath.interval, settle: settle) { [weak self] event in
                run.watch.benjiPosts(event)
                switch event {
                case .down:
                    run.letGo = {
                        let steps = DragPath.letGo(start: appKit, pointer: NSEvent.mouseLocation)
                        send(steps[0])
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { steps.dropFirst().forEach(send) }
                    }
                case .up:
                    run.letGo = nil
                    if run.drive { self?.stopWatching(run) }
                default:
                    break
                }
                send(event)
            }
        }
    }

    /// Posts `items` one at a time, `every` seconds apart, stopping the moment the user takes over.
    private func post<T>(_ items: [T], run: Running, every: Double, settle: @escaping () -> Void,
                         _ one: @escaping (T) -> Void) {
        var rest = items[...]
        func next() {
            guard !run.over else { return }
            if run.watch.tookOver { return stopped(run, didAct: true) }
            guard let item = rest.popFirst() else { return after(0.05, settle) }
            one(item)
            after(every, next)
        }
        next()
    }

    // MARK: settling and looking again

    private func settle(_ run: Running, text: String, started: Double, last: [UInt8]?) {
        guard !run.over else { return }
        if run.watch.tookOver { return stopped(run, didAct: true) }
        let elapsed = Self.now - started
        if last == nil, elapsed < ScreenSettle.firstWait {
            return after(ScreenSettle.firstWait - elapsed) { [weak self] in
                self?.settle(run, text: text, started: started, last: nil)
            }
        }
        guard let sample else { return look(run, text: text) }
        sample(run.shot.displayID) { [weak self] current in
            guard let self, !run.over else { return }
            let same = current != nil && last != nil && ScreenSettle.same(last!, current!)
            if current == nil || ScreenSettle.ready(elapsed: Self.now - started, lastTwoSame: same) {
                return self.look(run, text: text)
            }
            self.after(ScreenSettle.interval) { self.settle(run, text: text, started: started, last: current) }
        }
    }

    private func look(_ run: Running, text: String) {
        guard !run.over else { return }
        if run.watch.tookOver { return stopped(run, didAct: true) }
        guard let capture, let screen = NSScreen.screens.first(where: { Self.displayID($0) == run.shot.displayID }) else {
            return finish(run, ScreenStepOutcome(status: .done, text: text + " The display it was on is gone.", shot: nil))
        }
        capture(screen) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let shot):
                if run.over { try? FileManager.default.removeItem(at: shot.url); return }
                self.finish(run, ScreenStepOutcome(status: .done, text: text, shot: shot))
            case .failure(let error):
                self.finish(run, ScreenStepOutcome(status: .done, text: text + " Couldn't look again: \(error.localizedDescription)",
                                                   shot: nil))
            }
        }
    }

    // MARK: the user taking over

    private func watch(_ run: Running) {
        let kinds: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown,
                                            .leftMouseDragged, .rightMouseDragged, .keyDown, .flagsChanged, .scrollWheel]
        let handle: (NSEvent) -> Void = { [weak self] e in
            guard let self, !run.over else { return }
            let synthetic = e.cgEvent?.getIntegerValueField(.eventSourceUserData) == Self.marker
            // During a drag, where this event was: Benji's next one has already moved the pointer on.
            let p = run.letGo != nil
                ? e.cgEvent.map { ScreenActionGeometry.globalPoint($0.location, primaryMaxY: NSScreen.screens.first?.frame.maxY ?? 0) }
                    ?? NSEvent.mouseLocation
                : NSEvent.mouseLocation
            let input: TakeOverWatch.Input
            switch e.type {
            case .mouseMoved, .leftMouseDragged, .rightMouseDragged: input = .pointerMoved(p)
            case .keyDown: input = .keyDown(e.keyCode)
            case .flagsChanged: input = .modifiersChanged
            case .scrollWheel: input = .scroll(p)
            default: input = .mouseDown(p)
            }
            if run.watch.observe(input, synthetic: synthetic) {
                self.hideTarget?()
                if !run.acting { self.stopped(run, didAct: false) }   // during the ring or beat: at once
            }
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: kinds, handler: handle) { run.monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: kinds, handler: { handle($0); return $0 }) {
            run.monitors.append(m)
        }
    }

    private func stopWatching(_ run: Running) {
        run.monitors.forEach(NSEvent.removeMonitor)
        run.monitors = []
    }

    // MARK: Accessibility

    private static let system: AXUIElement = {
        let s = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(s, 1.0)   // a hung app can't hang Benji's main thread for long
        return s
    }()

    /// The element under an AppKit point, its app, and its parents up to a web area.
    private func hitTest(_ appKit: CGPoint) -> (target: ScreenTarget, chain: [AXUIElement])? {
        let p = ScreenActionGeometry.globalPoint(appKit, primaryMaxY: NSScreen.screens.first?.frame.maxY ?? 0)
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(Self.system, Float(p.x), Float(p.y), &element) == .success,
              let element else { return nil }
        return describe(element, typing: false)
    }

    /// The element with the keyboard in the app in front.
    private func focused() -> (target: ScreenTarget, chain: [AXUIElement])? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 1.0)
        guard let element: AXUIElement = Self.attribute(axApp, kAXFocusedUIElementAttribute) else {
            let a = NSRunningApplication(processIdentifier: app.processIdentifier)
            return (ScreenTarget(pid: app.processIdentifier, bundleID: a?.bundleIdentifier, appName: a?.localizedName), [])
        }
        return describe(element, typing: true)
    }

    private func focusedFrame() -> CGRect? {
        guard let (_, chain) = focused(), let el = chain.first, let frame = Self.globalFrame(el) else { return nil }
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(x: frame.minX, y: primaryMaxY - frame.minY - frame.height, width: frame.width, height: frame.height)
    }

    /// An element's frame as Accessibility gives it: global, origin at the top left of the primary screen.
    private static func globalFrame(_ el: AXUIElement) -> CGRect? {
        guard let posValue: AXValue = attribute(el, kAXPositionAttribute),
              let sizeValue: AXValue = attribute(el, kAXSizeAttribute) else { return nil }
        var pos = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(posValue, .cgPoint, &pos), AXValueGetValue(sizeValue, .cgSize, &size) else { return nil }
        return CGRect(origin: pos, size: size)
    }

    private func describe(_ element: AXUIElement, typing: Bool) -> (target: ScreenTarget, chain: [AXUIElement]) {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        var chain: [AXUIElement] = [], roles: [String] = [], actions: [[String]] = []
        var inWeb = false, inSheet = false
        var current: AXUIElement? = element
        // Up to the window: the first three levels (below a web area) for pressing and the class,
        // and any sheet, dialog or alert above (D-126).
        for level in 0..<40 {
            guard let el = current else { break }
            let role: String? = Self.attribute(el, kAXRoleAttribute)
            let subrole: String? = Self.attribute(el, kAXSubroleAttribute)
            if role == "AXSheet" || subrole.map(Self.dialogSubroles.contains) == true { inSheet = true }
            if role == "AXWindow" || role == "AXApplication" { break }
            if role == "AXWebArea" { inWeb = true }
            if level < 3, !inWeb {
                chain.append(el)
                roles.append(role ?? "")
                var names: CFArray?
                AXUIElementCopyActionNames(el, &names)
                actions.append(names as? [String] ?? [])
            }
            current = Self.attribute(el, kAXParentAttribute)
        }
        var settable: DarwinBoolean = false
        if typing { AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) }
        let app = NSRunningApplication(processIdentifier: pid)
        let target = ScreenTarget(pid: pid, bundleID: app?.bundleIdentifier, appName: app?.localizedName, roles: roles,
                                  subrole: Self.attribute(element, kAXSubroleAttribute), actions: actions,
                                  inWebArea: inWeb, canInsertText: settable.boolValue,
                                  element: Self.element(chain: chain, roles: roles, inSheet: inSheet, inWeb: inWeb))
        return (target, chain)
    }

    /// Window subroles (and ARIA dialogs in a web page) that make everything inside "in a dialog".
    private static let dialogSubroles: Set<String> = ["AXDialog", "AXSystemDialog", "AXApplicationDialog",
                                                      "AXApplicationAlertDialog", "AXSheet"]

    /// The control for a step's class: the first of the leaf and its two parents with a control or
    /// field role (the text inside a button names the button), with its names. Nil: nothing found.
    private static func element(chain: [AXUIElement], roles: [String], inSheet: Bool, inWeb: Bool) -> ScreenElement? {
        guard let leaf = chain.first else { return nil }
        let level = roles.firstIndex { ScreenStepClassifier.lookRoles.contains($0) || DriveClassifier.quietDragRoles.contains($0) } ?? 0
        let el = chain[level]
        func text(_ e: AXUIElement, _ name: String) -> String { (attribute(e, name) as String?) ?? "" }
        let title = text(el, kAXTitleAttribute)
        var description = text(el, kAXDescriptionAttribute)
        if description.isEmpty { description = text(el, kAXPlaceholderValueAttribute) }
        if title.isEmpty, description.isEmpty { description = text(leaf, kAXValueAttribute) }
        // What else the page or app calls it: help text and a web page's own id (read by a drive's checks).
        let hints = [text(el, kAXHelpAttribute), text(el, "AXDOMIdentifier"), text(el, "AXIdentifier")]
            .filter { !$0.isEmpty }.joined(separator: " ")
        return ScreenElement(role: roles[level], subrole: attribute(el, kAXSubroleAttribute), title: title,
                             description: description, inSheet: inSheet, inWebArea: inWeb, hints: hints)
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value else { return nil }
        return value as? T
    }

    static func displayID(_ screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    private func after(_ seconds: Double, _ action: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, seconds), execute: action)
    }
}
