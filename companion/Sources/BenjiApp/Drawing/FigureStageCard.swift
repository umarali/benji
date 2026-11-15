import AppKit
import BenjiCore
import SceneKit

/// The figure card on screen: a non-activating, click-through panel of Benji's own
/// (only its close button takes clicks) with the all-black card, a transparent Metal `SCNView`
/// and the labels over it. Meshes are built on a background queue; the view renders at 60 fps
/// while parts grow, 30 fps for the slow idle turn, and nothing at all under Reduce Motion once
/// the figure is complete. It stays up through the next turn like a drawn picture, until Escape,
/// the close button, a newer figure, or two minutes at rest. Meshes and the closing of gaps
/// between parts are worked out on a background queue; the main thread only builds the scene.
/// Behind the `figureStage` setting (on by default; an off switch for 3D): Settings'
/// "Draw things in 3D", or `defaults write com.emerssive.heybenji.app figureStage -bool false`.
final class FigureStage: NSObject, SCNSceneRendererDelegate {
    static let defaultsKey = FigureSetting.defaultsKey
    /// Made on first use, which only happens with the setting on.
    static let shared = FigureStage()
    static var isOn: Bool { FigureSetting.isOn(from: UserDefaults.standard.object(forKey: defaultsKey)) }
    /// How long a complete figure stays up (the same hold as a drawn picture).
    static let hold = PointingSequence.drawingHold

    /// The display to use and Benji's own panels to keep clear of; set by the app.
    var screen: () -> NSScreen? = { NSScreen.main }
    var avoid: () -> [CGRect] = { [] }

    private var panel: NSPanel?
    private var closePanel: NSPanel?
    /// Over the stage only: takes drags, scroll, pinch and double-clicks (the rest of the card,
    /// and everything around it, stays click-through).
    private var inputPanel: NSPanel?
    private var resetPanel: NSPanel?
    /// Back to the idle rate (or to rest, under Reduce Motion) a moment after the user lets go.
    private var restTimer: Timer?
    private var cardView: FigureCardView?
    private var scnView: SCNView?
    private var labelsView: FigureLabelsView?
    private var current: FigureScene?
    private var startTime: TimeInterval?
    private var holdTimer: Timer?
    private var monitors: [Any] = []
    private var generation = 0
    private let buildQueue = DispatchQueue(label: "benji.figure-build", qos: .userInitiated)
    private let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    /// Build off the main thread, then show (replacing any figure that is up).
    func show(_ figure: Figure) {
        generation += 1
        let gen = generation
        buildQueue.async { [weak self] in
            let prepared = FigureScene.prepare(figure)   // meshes and closed gaps, off the main thread
            DispatchQueue.main.async {
                guard let self, gen == self.generation else { return }
                self.present(prepared)
            }
        }
    }

    /// The card's frame while it is up (the explanation card keeps clear of it).
    var frame: CGRect? { panel?.isVisible == true ? panel?.frame : nil }

    /// The figure on the card while it is up: what the model is told it has on the screen.
    var shownFigure: Figure? { frame == nil ? nil : current?.figure }

    /// Whether the card shows in captures: while a figure is up it does unless the user turned
    /// "Show drawings in screenshots" off, so the model sees the figure it drew.
    private var shownInCaptures: Bool {
        DrawingCapture.shownWhileDrawing(from: UserDefaults.standard.object(forKey: DrawingCapture.defaultsKey))
    }

    /// The card's window number while it is up and shown in captures: Benji's own screenshot
    /// keeps it in (ScreenCapturer).
    var windowsInCaptures: Set<Int> {
        guard let panel, panel.isVisible, shownInCaptures else { return [] }
        return [panel.windowNumber]
    }

    /// The setting changed: apply it to a card that is up (it is also read for each figure).
    func refreshCaptureSharing() {
        panel?.sharingType = shownInCaptures ? .readOnly : .none
    }

    func dismiss() {
        generation += 1
        holdTimer?.invalidate(); holdTimer = nil
        restTimer?.invalidate(); restTimer = nil
        inputPanel?.orderOut(nil)
        resetPanel?.orderOut(nil)
        monitors.forEach(NSEvent.removeMonitor); monitors = []
        scnView?.isPlaying = false
        scnView?.scene = nil
        current = nil
        closePanel?.orderOut(nil)
        panel?.orderOut(nil)
    }

    // MARK: presenting

    private func present(_ prepared: FigureScene.Prepared) {
        let figure = prepared.figure
        let size = FigureCardDrawing.size
        let stage = FigureCardDrawing.stageRect(in: CGRect(origin: .zero, size: size))
        let fs = FigureScene(prepared: prepared, aspect: Double(stage.width / stage.height))
        makePanelIfNeeded()
        guard let panel, let scnView, let cardView, let labelsView, let closePanel, let inputPanel, let resetPanel else { return }
        current = fs
        startTime = nil
        cardView.title = figure.title
        labelsView.placed = []
        scnView.scene = fs.scene
        scnView.pointOfView = fs.cameraNode
        fs.apply(at: 0, reduceMotion: reduceMotion)
        let visible = (screen() ?? NSScreen.main)?.visibleFrame ?? .zero
        let frame = FigureCardPlacement.frame(cardSize: size, visible: visible, avoid: avoid())
        panel.setFrame(frame, display: false)
        refreshCaptureSharing()
        let close = FigureCardDrawing.closeRect(in: CGRect(origin: .zero, size: size))
        closePanel.setFrame(CGRect(x: frame.minX + close.minX, y: frame.maxY - close.maxY, width: close.width, height: close.height),
                            display: false)
        let reset = FigureCardDrawing.resetRect(in: CGRect(origin: .zero, size: size))
        resetPanel.setFrame(CGRect(x: frame.minX + reset.minX, y: frame.maxY - reset.maxY, width: reset.width, height: reset.height),
                            display: false)
        inputPanel.setFrame(CGRect(x: frame.minX + stage.minX, y: frame.maxY - stage.maxY, width: stage.width, height: stage.height),
                            display: false)
        panel.orderFrontRegardless()
        inputPanel.orderFrontRegardless()
        closePanel.orderFrontRegardless()
        resetPanel.orderOut(nil)   // shown once the figure has been moved by hand
        scnView.preferredFramesPerSecond = 60
        scnView.isPlaying = true
        watchEscape()
        holdTimer?.invalidate()
        holdTimer = nil
    }

    private func makePanelIfNeeded() {
        guard panel == nil else { return }
        let size = FigureCardDrawing.size
        let p = FigureCardPanel(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: true)
        p.ignoresMouseEvents = true
        let card = FigureCardView(frame: CGRect(origin: .zero, size: size))
        let stage = FigureCardDrawing.stageRect(in: card.bounds)
        let view = SCNView(frame: stage, options: [SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue])
        view.backgroundColor = .clear
        view.allowsCameraControl = false
        view.rendersContinuously = false
        view.antialiasingMode = .multisampling4X
        view.delegate = self
        view.wantsLayer = true
        view.layer?.cornerRadius = FigureCardDrawing.radius
        view.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        let labels = FigureLabelsView(frame: stage)
        card.addSubview(view)
        card.addSubview(labels)
        p.contentView = card
        let closer = FigureCardPanel(contentRect: CGRect(x: 0, y: 0, width: FigureCardDrawing.closeSize, height: FigureCardDrawing.closeSize),
                                     styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        let button = FigureCloseButton(frame: CGRect(x: 0, y: 0, width: FigureCardDrawing.closeSize, height: FigureCardDrawing.closeSize))
        button.target = self
        button.action = #selector(closeClicked)
        closer.contentView = button
        closer.level = p.level
        let resetter = FigureCardPanel(contentRect: CGRect(x: 0, y: 0, width: FigureCardDrawing.closeSize, height: FigureCardDrawing.closeSize),
                                       styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        let resetButton = FigureResetButton(frame: CGRect(x: 0, y: 0, width: FigureCardDrawing.closeSize, height: FigureCardDrawing.closeSize))
        resetButton.target = self
        resetButton.action = #selector(resetClicked)
        resetter.contentView = resetButton
        resetter.level = p.level
        let input = FigureCardPanel(contentRect: CGRect(origin: .zero, size: stage.size), styleMask: [.borderless, .nonactivatingPanel],
                                    backing: .buffered, defer: true)
        input.hasShadow = false
        input.ignoresMouseEvents = false   // set explicitly: a clear window takes clicks only when told to
        let orbit = FigureOrbitView(frame: CGRect(origin: .zero, size: stage.size))
        orbit.onDrag = { [weak self] dx, dy in self?.handle { $0.drag(dx: dx, dy: dy) } }
        orbit.onDragEnd = { [weak self] in self?.current?.handling.endDrag() }
        orbit.onScroll = { [weak self] dy in self?.handle { $0.scroll(dy: dy) } }
        orbit.onPinch = { [weak self] m in self?.handle { $0.pinch(m) } }
        orbit.onDoubleClick = { [weak self] in self?.resetClicked() }
        input.contentView = orbit
        input.level = p.level
        panel = p; closePanel = closer; resetPanel = resetter; inputPanel = input
        cardView = card; scnView = view; labelsView = labels
    }

    @objc private func closeClicked() { dismiss() }

    @objc private func resetClicked() {
        guard let fs = current else { return }
        fs.handling.reset(at: figureTime())
        resetPanel?.orderOut(nil)
        wake()
    }

    // MARK: handling by hand

    /// Seconds on the figure's own clock (the renderer's), for the idle pause.
    private func figureTime() -> Double {
        guard let start = current?.handling.start else { return 0 }
        return CACurrentMediaTime() - start
    }

    private func handle(_ change: (inout FigureOrbit) -> Void) {
        guard let fs = current else { return }
        fs.handling.handle(at: figureTime(), change)
        if fs.handling.isMoved { resetPanel?.orderFrontRegardless() } else { resetPanel?.orderOut(nil) }
        wake()
    }

    /// Render at full rate while the user handles the figure; the hold restarts; a moment after
    /// they let go, back to the idle rate (or to rest under Reduce Motion).
    private func wake() {
        scnView?.preferredFramesPerSecond = 60
        scnView?.isPlaying = true
        if holdTimer != nil {
            holdTimer?.invalidate()
            holdTimer = Timer.scheduledTimer(withTimeInterval: Self.hold, repeats: false) { [weak self] _ in self?.dismiss() }
        }
        restTimer?.invalidate()
        restTimer = Timer.scheduledTimer(withTimeInterval: FigureIdleClock.resumeAfter + 0.1, repeats: false) { [weak self] _ in
            guard let self, self.holdTimer != nil else { return }   // still growing: the reveal keeps its own pace
            if self.reduceMotion { self.scnView?.isPlaying = false } else { self.scnView?.preferredFramesPerSecond = 30 }
        }
    }

    /// Escape dismisses: observed, never consumed, so the front app still gets it (as the overlay does).
    private func watchEscape() {
        guard monitors.isEmpty else { return }
        let handler: (NSEvent) -> Void = { [weak self] e in if e.keyCode == 53 { self?.dismiss() } }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handler) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { handler($0); return $0 }) { monitors.append(m) }
    }

    // MARK: per frame (SceneKit's render thread)

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        guard let fs = current, renderer.scene === fs.scene else { return }
        if startTime == nil { startTime = time; fs.handling.start = time }
        let t = time - startTime!
        let growing = fs.apply(at: t, reduceMotion: reduceMotion)
        let stage = FigureCardDrawing.stageRect(in: CGRect(origin: .zero, size: FigureCardDrawing.size))
        let (anchors, model) = fs.labelAnchors(fs.projector(viewSize: stage.size, live: true), viewSize: stage.size, time: t)
        let placed = FigureCardDrawing.place(fs, anchors: anchors, model: model, stage: CGRect(origin: .zero, size: stage.size))
        DispatchQueue.main.async { [weak self] in
            guard let self, self.current === fs else { return }
            self.labelsView?.placed = placed
            if !growing { self.settle(fs) }
        }
    }

    /// The figure is complete: under Reduce Motion stop rendering; otherwise turn slowly at 30 fps.
    /// Either way, start the hold.
    private func settle(_ fs: FigureScene) {
        guard holdTimer == nil else { return }
        holdTimer = Timer.scheduledTimer(withTimeInterval: Self.hold, repeats: false) { [weak self] _ in self?.dismiss() }
        if fs.handling.isPaused(at: figureTime()) { wake(); return }   // being handled: rest comes after
        if reduceMotion { scnView?.isPlaying = false } else { scnView?.preferredFramesPerSecond = 30 }
    }
}

final class FigureCardPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override init(contentRect: NSRect, styleMask: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .none
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isExcludedFromWindowsMenu = true
        sharingType = .none
        hidesOnDeactivate = false
    }
}

/// The black card and its title (the stage and the labels are subviews).
final class FigureCardView: NSView {
    var title = "" { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        FigureCardDrawing.drawCard(title: title, in: bounds)
    }
}

/// Label pills and leaders over the stage, redrawn only while the figure moves.
final class FigureLabelsView: NSView {
    var placed: [FigureCardDrawing.Placed] = [] { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) { FigureCardDrawing.drawLabels(placed) }
}

final class FigureCloseButton: NSButton {
    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        title = ""
        setAccessibilityLabel("Close figure")
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) { FigureCardDrawing.drawClose(in: bounds) }
}

/// Wraps the app's backend when figures are on: takes the figure block out of each answer (so
/// the panel and the voice never see it) and hands the figure to the stage. Off, the app's
/// backend is used as it is and nothing here runs.
final class FigureStageBackend: CompanionBackend, JobForwarding {
    /// The engine adds its figure section to the prompt when this is set in its environment.
    static let engineFlag = "BENJI_FIGURES"

    static func wrap(_ inner: CompanionBackend) -> CompanionBackend {
        guard FigureStage.isOn else { return inner }
        setenv(engineFlag, "1", 1)   // inherited by the engine process, started on the first message
        return FigureStageBackend(inner, stage: { FigureStage.shared })
    }

    /// The backend for the setting as it is now (the Settings switch): `backend` itself when
    /// it already matches, otherwise wrapped or unwrapped. A change also sets or clears the
    /// engine flag and restarts a kept engine, so its next start carries the flag (or not).
    static func matching(_ backend: CompanionBackend) -> CompanionBackend {
        let wrapped = backend as? FigureStageBackend
        guard FigureStage.isOn != (wrapped != nil) else { return backend }
        let bare = wrapped?.inner ?? backend
        if !FigureStage.isOn { unsetenv(engineFlag) }
        bare.restartEngine()
        return wrap(bare)
    }

    let inner: CompanionBackend
    private let stage: () -> FigureStage?
    var onEvent: ((_ run: Int, BackendEvent) -> Void)?
    var onFinished: ((_ run: Int, Int32) -> Void)? {
        get { inner.onFinished }
        set { inner.onFinished = newValue }
    }
    var approvalTimeout: TimeInterval { inner.approvalTimeout }

    init(_ inner: CompanionBackend, stage: @escaping () -> FigureStage?) {
        self.inner = inner
        self.stage = stage
        inner.onEvent = { [weak self] run, event in
            guard let self else { return }
            self.onEvent?(run, self.taking(event))
        }
    }

    /// The event with its figure block taken out; the figure goes to the stage.
    func taking(_ event: BackendEvent) -> BackendEvent {
        switch event {
        case .answer(let raw):
            let (text, figure) = FigureGrammar.parse(raw)
            guard let figure else { return event }
            showSoon(figure)
            return .answer(text)
        case .pointedAnswer(let raw, let targets):
            let (text, figure) = FigureGrammar.parse(raw)
            guard let figure else { return event }
            showSoon(figure)
            return .pointedAnswer(text: text, targets: targets)
        default:
            return event
        }
    }

    private func showSoon(_ figure: Figure) {
        DispatchQueue.main.async { [weak self] in self?.stage()?.show(figure) }
    }

    func start(run: Int, task: String, imagePath: String?, memory: ConversationMemory, allowPointing: Bool,
               spoken: Bool, screen: ScreenshotGeometry?) {
        inner.start(run: run, task: task, imagePath: imagePath, memory: memory, allowPointing: allowPointing,
                    spoken: spoken, screen: screen)
    }
    func resolveApproval(_ approved: Bool) { inner.resolveApproval(approved) }
    func cancel() { inner.cancel() }
    func cutOff(reply: String, running: Bool) { inner.cutOff(reply: reply, running: running) }
    func reset() { inner.reset() }
    func shutdown() { inner.shutdown() }
    func restartEngine() { inner.restartEngine() }
    func setBrowser(_ on: Bool) { inner.setBrowser(on) }
    func setBrowserAlways(_ sites: [String]) { inner.setBrowserAlways(sites) }
    func stopDrive(reason: String) { inner.stopDrive(reason: reason) }
    func setSchedules(_ on: Bool) { inner.setSchedules(on) }
    func startEngineForSchedules() { inner.startEngineForSchedules() }
    func prewarm() { inner.prewarm() }
    func finishScreenStep(request: String, result: ScreenStepResult) {
        inner.finishScreenStep(request: request, result: result)
    }
}

final class FigureResetButton: NSButton {
    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        title = ""
        setAccessibilityLabel("Back to Benji's view")
        toolTip = "Back to Benji's view (or double-click the figure)"
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) { FigureCardDrawing.drawReset(in: bounds) }
}

/// The figure's own surface: dragging orbits, scroll or pinch zooms, double-click resets. It sits
/// in a clear, non-activating panel over the stage, so it never takes focus from the app in front.
final class FigureOrbitView: NSView {
    var onDrag: ((Double, Double) -> Void)?
    var onDragEnd: (() -> Void)?
    var onScroll: ((Double) -> Void)?
    var onPinch: ((Double) -> Void)?
    var onDoubleClick: (() -> Void)?
    private var last: NSPoint?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(false)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.cursorUpdate, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    // A whisper of fill so the window server counts the area as the panel's (a fully clear pixel
    // is click-through); invisible over the black card.
    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0, alpha: 0.004).setFill()
        dirtyRect.fill()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func cursorUpdate(with event: NSEvent) { NSCursor.openHand.set() }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { last = nil; onDoubleClick?(); return }
        last = event.locationInWindow
        NSCursor.closedHand.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let from = last else { return }
        let to = event.locationInWindow
        onDrag?(Double(to.x - from.x), Double(to.y - from.y))   // AppKit: y up
        last = to
    }

    override func mouseUp(with event: NSEvent) {
        if last != nil { onDragEnd?() }
        last = nil
        NSCursor.openHand.set()
    }

    override func scrollWheel(with event: NSEvent) {
        // Lines (a wheel mouse) count as about 10 points each.
        let dy = Double(event.scrollingDeltaY) * (event.hasPreciseScrollingDeltas ? 1 : 10)
        if dy != 0 { onScroll?(dy) }
    }

    override func magnify(with event: NSEvent) { onPinch?(Double(event.magnification)) }
}
