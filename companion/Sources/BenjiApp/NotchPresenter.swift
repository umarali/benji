import AppKit
import Combine
import SwiftUI
import BenjiCore

/// The notch object's sizes on one display, in AppKit global coordinates.
struct NotchLayoutInfo: Equatable {
    var shapes: [NotchSize: NotchShape]
    var hotZone: CGRect
    var screenFrame: CGRect
    var hasHardwareNotch: Bool
    /// The closed size: the hardware notch, or 185 × 32 at the top centre (never widened by
    /// the Screen On indicator).
    let notch: CGRect
    private let hardwareNotch: CGRect?
    /// Screen is On: the closed size carries the purple dot.
    private(set) var indicator: Bool
    /// Settings is showing: the open size is `PanelGeometry.settingsSize`.
    private(set) var settings: Bool
    /// The panel is expanded (D-133): the open size is `PanelGeometry.expandedSize`.
    private(set) var expanded: Bool

    init(notch: CGRect?, screenFrame: CGRect, indicator: Bool = false, settings: Bool = false, expanded: Bool = false) {
        var shapes: [NotchSize: NotchShape] = [:]
        for size in NotchSize.allCases {
            shapes[size] = PanelGeometry.notchShape(size, notch: notch, screenFrame: screenFrame, indicator: indicator,
                                                    settings: settings, expanded: expanded)
        }
        self.shapes = shapes
        self.hotZone = PanelGeometry.hotZone(notch: notch, screenFrame: screenFrame)
        self.screenFrame = screenFrame
        self.hasHardwareNotch = notch != nil
        self.notch = PanelGeometry.notchShape(.closed, notch: notch, screenFrame: screenFrame).frame
        self.hardwareNotch = notch
        self.indicator = indicator
        self.settings = settings
        self.expanded = expanded
    }

    func with(indicator: Bool, settings: Bool, expanded: Bool) -> NotchLayoutInfo {
        indicator == self.indicator && settings == self.settings && expanded == self.expanded ? self
            : NotchLayoutInfo(notch: hardwareNotch, screenFrame: screenFrame, indicator: indicator, settings: settings,
                              expanded: expanded)
    }

    init(screen: NSScreen) {
        var notch: CGRect?
        if #available(macOS 12.0, *) {
            notch = PanelGeometry.hardwareNotch(screenFrame: screen.frame,
                                                leftArea: screen.auxiliaryTopLeftArea,
                                                rightArea: screen.auxiliaryTopRightArea,
                                                safeAreaTop: screen.safeAreaInsets.top)
        }
        self.init(notch: notch, screenFrame: screen.frame)
    }

    func shape(_ size: NotchSize) -> NotchShape { shapes[size]! }
}

/// Drives the notch object from real events only: decides the size (NotchPresence), runs each
/// morph as Motion.md schedules it (NotchMorphPlan), holds Done, tracks hover, and announces
/// state changes to VoiceOver. The views only draw what this publishes.
final class NotchPresenter: ObservableObject {
    @Published private(set) var layout: NotchLayoutInfo
    /// The size the shape is drawn at (changes inside an animation transaction).
    @Published private(set) var size: NotchSize = .closed
    /// Which content layers are showing.
    @Published private(set) var layers: Set<NotchLayer> = []
    @Published private(set) var status: NotchStatusInfo
    /// Bumped once per Done, after the glyph's replace transition, to run `motion-done`.
    @Published private(set) var doneBounce = 0
    /// The offer the card draws. Kept after an answer, so the card fades out with its words on it.
    @Published private(set) var offerOnCard: AppOffer?
    @Published var accessibility: NotchAccessibility

    /// The window must cover this size now (grown at once, shrunk only once a morph settles).
    var onWindowSize: ((NotchSize) -> Void)?
    /// The object reached closed; give the keyboard back if the panel had it.
    var onClosed: (() -> Void)?
    /// Whether the panel holds the keyboard (typing in the composer keeps it open).
    var panelFocused: () -> Bool = { false }

    private let model: CompanionModel
    private var target: NotchSize = .closed
    private var settled = true
    private var morphWork: [DispatchWorkItem] = []
    private var doneHolding = false
    /// The Done hold after an answer is running (not a job's done, which has its own row).
    var isDoneHolding: Bool { doneHolding }
    private var doneWork: [DispatchWorkItem] = []
    private var errorDismissed = false
    private var hovered = false
    private var hoverSuppressed = false
    private var pointerInside = false
    private var hover = HoverRestDetector()
    private var hoverCheck: DispatchWorkItem?
    private var leaveWork: DispatchWorkItem?
    private var cancellables: Set<AnyCancellable> = []

    init(model: CompanionModel, layout: NotchLayoutInfo, accessibility: NotchAccessibility = .system) {
        self.model = model
        self.layout = layout
        self.accessibility = accessibility
        self.status = NotchStatusInfo.make(model.state)

        model.$state.combineLatest(model.$partialTranscript)
            .sink { [weak self] state, partial in
                DispatchQueue.main.async { self?.stateChanged(state, partial: partial) }
            }
            .store(in: &cancellables)
        model.$expanded.dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.reevaluate() } }
            .store(in: &cancellables)
        model.$conversationOn.dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.updateStatus() } }
            .store(in: &cancellables)
        model.$statusNote.dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.updateStatus() } }
            .store(in: &cancellables)
        model.$job.dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.updateStatus(); self?.reevaluate() } }
            .store(in: &cancellables)
        model.$jobSeen.dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.updateStatus(); self?.reevaluate() } }
            .store(in: &cancellables)
        model.$appOffer.dropFirst()
            .sink { [weak self] offer in DispatchQueue.main.async { self?.appOfferChanged(offer) } }
            .store(in: &cancellables)
        model.$doneCount.dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.beginDone() } }
            .store(in: &cancellables)
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)
            .sink { [weak self] _ in self?.accessibility = .system }
            .store(in: &cancellables)
    }

    func setLayout(_ layout: NotchLayoutInfo) {
        let layout = layout.with(indicator: screenOn, settings: settingsOn, expanded: expandedOn)
        guard layout != self.layout else { return }
        self.layout = layout
        onWindowSize?(max(size, target))
    }

    /// Screen is On: the closed notch widens to show the purple dot.
    private(set) var screenOn = false

    func setScreenOn(_ on: Bool) {
        guard on != screenOn else { return }
        screenOn = on
        withAnimation(accessibility.reduceMotion ? NotchMotion.reduce : NotchMotion.content) {
            setLayout(layout)
        }
    }

    /// Settings is showing: the open object grows to `PanelGeometry.settingsSize`.
    private(set) var settingsOn = false
    /// The panel is expanded (D-133): the open object grows to `PanelGeometry.expandedSize`.
    private(set) var expandedOn = false
    private var openSizeShrinkWork: DispatchWorkItem?

    func setSettingsOn(_ on: Bool) { setOpenSize(settings: on, expanded: expandedOn) }

    func setExpandedOn(_ on: Bool) { setOpenSize(settings: settingsOn, expanded: on) }

    /// The open size changes with settings and Expand: a larger one grows the window first, then
    /// the shape; a smaller one keeps the window until the shape has settled, so nothing is clipped.
    private func setOpenSize(settings: Bool, expanded: Bool) {
        guard settings != settingsOn || expanded != expandedOn else { return }
        let before = PanelGeometry.openSize(settings: settingsOn, expanded: expandedOn)
        let after = PanelGeometry.openSize(settings: settings, expanded: expanded)
        settingsOn = settings
        expandedOn = expanded
        openSizeShrinkWork?.cancel()
        let animation = accessibility.reduceMotion ? NotchMotion.reduce : NotchMotion.content
        if after.width >= before.width && after.height >= before.height {
            withAnimation(animation) { setLayout(layout) }
            return
        }
        let next = layout.with(indicator: screenOn, settings: settings, expanded: expanded)
        withAnimation(animation) { layout = next }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.onWindowSize?(max(self.size, self.target))
        }
        openSizeShrinkWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + MotionTokens.content.duration + 0.15, execute: work)
    }

    // MARK: state

    private var lastPhase: CompanionPhase = .idle

    private func stateChanged(_ state: CompanionState, partial: String) {
        if state.phase == .error && lastPhase != .error { errorDismissed = false }
        lastPhase = state.phase
        updateStatus()
        reevaluate()
    }

    private func updateStatus() {
        let new = NotchStatusInfo.make(model.state, partial: model.partialTranscript, doneHolding: doneHolding,
                                       conversation: model.conversationOn, note: model.statusNote, job: model.job)
        let old = status.status
        guard new != status else { return }
        status = new
        let answer = model.state.lines.last { $0.role == .assistant }?.text
        if let a = NotchStatusInfo.announcement(from: old, to: new, answer: answer) {
            announce(a.text, high: a.highPriority)
        }
    }

    private func beginDone() {
        doneWork.forEach { $0.cancel() }
        doneHolding = true
        updateStatus()
        reevaluate()
        // The checkmark nods once, after the glyph's replace transition has run.
        if !accessibility.reduceMotion {
            after(0.25, into: &doneWork) { [weak self] in self?.doneBounce += 1 }
        }
        after(NotchPresence.doneHold, into: &doneWork) { [weak self] in
            guard let self else { return }
            self.doneHolding = false
            self.updateStatus()
            self.reevaluate()
        }
    }

    private func appOfferChanged(_ offer: AppOffer?) {
        if let offer {
            offerOnCard = offer
            announce("Benji: \(offer.title)", high: false)
        }
        reevaluate()
    }

    /// The pointer is on the object now.
    var isPointerOver: Bool { pointerInside }
    /// The size the object is going to (or at, once settled).
    var targetSize: NotchSize { target }

    // MARK: size

    private func reevaluate() {
        if model.expanded && model.state.phase == .error { errorDismissed = true }
        let inputs = NotchPresenceInputs(phase: model.state.phase, userOpened: model.expanded,
                                         hovered: hovered && !hoverSuppressed,
                                         doneHolding: doneHolding, errorDismissed: errorDismissed,
                                         jobPeek: model.jobPeek, appOffer: model.appOffer != nil)
        morph(to: NotchPresence.targetSize(inputs))
    }

    private func morph(to new: NotchSize) {
        guard new != target else { return }
        let from = target
        let plan = NotchMorphPlan.plan(from: from, to: new, fromRest: settled,
                                       reduceMotion: accessibility.reduceMotion)
        morphWork.forEach { $0.cancel() }
        morphWork = []
        target = new
        settled = false
        if new > from { onWindowSize?(max(size, new)) }
        // An approval announces itself ("Benji needs approval: …"), so it isn't also "expanded".
        if new == .open && model.state.phase != .awaitingApproval { announce("Benji, expanded", high: false) }

        let reduce = accessibility.reduceMotion
        let keep = NotchLayer.layers(for: new)
        withAnimation(reduce ? NotchMotion.reduce : NotchMotion.fadeOut) {
            layers.formIntersection(keep)
        }
        let shape = plan.spring.map(NotchMotion.spring) ?? NotchMotion.reduce
        after(plan.shapeDelay, into: &morphWork) { [weak self] in
            withAnimation(shape) { self?.size = new }
        }
        after(plan.fadeInDelay, into: &morphWork) { [weak self] in
            withAnimation(reduce ? NotchMotion.reduce : NotchMotion.fadeIn) { self?.layers = keep }
        }
        after(plan.settleTime, into: &morphWork) { [weak self] in
            guard let self else { return }
            self.settled = true
            self.onWindowSize?(new)
            if new == .closed { self.onClosed?() }
        }
    }

    // MARK: user actions

    /// Click on the peek, or the menu item.
    func open() { model.setExpanded(true) }

    /// In-panel Escape keeps navigation and approval precedence, then uses the Stop button's
    /// action before folding. Listening and job Escape keep their existing scoped watchers.
    func escape() {
        if model.state.pendingApproval != nil { model.decideApproval(.no); return }
        if model.settingsOpen { model.closeSettings(); return }
        if model.panelPage == .list { model.showPage(.home); return }
        if model.pendingScreenSend != nil { model.decideScreenSend(.cancel) }
        else if model.state.phase == .thinking || model.state.phase == .speaking { model.cancel() }
        fold()
    }

    /// Hide the panel without stopping a turn, for the menu's open/close toggle.
    func fold() {
        if !model.state.isBusy {
            hoverSuppressed = true
            hovered = false
            errorDismissed = true
        }
        if model.expanded { model.setExpanded(false) } else { reevaluate() }
    }

    /// The panel lost the keyboard: if the pointer is already gone, start the close grace.
    func panelResignedFocus() {
        if !pointerInside && (hovered || model.expanded) { scheduleLeave() }
    }

    // MARK: hover

    /// Every pointer move, from the panel's mouse monitors (AppKit global coordinates).
    func pointerMoved(to point: CGPoint, at time: TimeInterval) {
        let zone = layout.hotZone
        if hover.sample(point, at: time, zone: zone) {
            hoverRested()
        } else if zone.contains(point) {
            hoverCheck?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                if self.hover.check(at: ProcessInfo.processInfo.systemUptime) { self.hoverRested() }
            }
            hoverCheck = work
            DispatchQueue.main.asyncAfter(deadline: .now() + hover.rest + 0.005, execute: work)
        }

        let region = target == .closed ? zone
            : layout.shape(target).outerFrame.insetBy(dx: -PanelGeometry.hotZoneMargin, dy: -PanelGeometry.hotZoneMargin)
        let inside = region.contains(point) || zone.contains(point)
        if inside {
            leaveWork?.cancel()
            leaveWork = nil
        } else {
            if pointerInside { scheduleLeave() }
            hoverSuppressed = false
            hover.reset()
        }
        pointerInside = inside
    }

    /// The panel was just brought to the display the pointer rested on (its bar, or home's notch):
    /// the rest already happened there, so the peek opens now. Never takes the keyboard.
    func revealHover() {
        hoverSuppressed = false
        pointerInside = true
        leaveWork?.cancel()
        leaveWork = nil
        hoverRested()
    }

    private func hoverRested() {
        guard !hoverSuppressed, !hovered else { return }
        hovered = true
        if target == .closed {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        reevaluate()
    }

    private func scheduleLeave() {
        guard leaveWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.leaveWork = nil
            guard !self.pointerInside else { return }
            if self.hovered && self.model.state.phase == .error { self.errorDismissed = true }
            self.hovered = false
            if self.model.expanded && NotchPresence.mayCloseOnLeave(
                phase: self.model.state.phase,
                composerEmpty: self.model.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                panelFocused: self.panelFocused(), conversationOn: self.model.conversationOn) {
                self.model.setExpanded(false)
            } else {
                self.reevaluate()
            }
        }
        leaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + MotionTiming.closeGrace, execute: work)
    }

    // MARK: helpers

    private func after(_ delay: Double, into list: inout [DispatchWorkItem], _ block: @escaping () -> Void) {
        let work = DispatchWorkItem(block: block)
        list.append(work)
        if delay <= 0 { DispatchQueue.main.async(execute: work) } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    private func announce(_ text: String, high: Bool) {
        let priority: NSAccessibilityPriorityLevel = high ? .high : .low
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: text,
            .priority: priority.rawValue,
        ])
    }

    /// For offscreen renders only: jump straight to a size with its content, no animation.
    func showStill(_ size: NotchSize, doneHolding: Bool = false) {
        morphWork.forEach { $0.cancel() }
        self.doneHolding = doneHolding
        status = NotchStatusInfo.make(model.state, partial: model.partialTranscript, doneHolding: doneHolding,
                                      conversation: model.conversationOn, note: model.statusNote, job: model.job)
        offerOnCard = model.appOffer
        target = size
        self.size = size
        layers = NotchLayer.layers(for: size)
        settled = true
    }
}
