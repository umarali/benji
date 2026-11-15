import AppKit
import BenjiCore

/// The explanation card on screen: a non-activating panel of Benji's own that holds the
/// card and its follow-up chips. It never takes key or focus from the app in front; it takes the
/// mouse so it can be dragged by its body, closed, and its chips tapped. It goes on calm space
/// when the screenshot shows some (`ExplainCardPlacement`), otherwise over busy space as an opaque
/// card, and stays up through the next turn like a drawn picture, until Escape, the close button, a
/// newer card, or two minutes untouched. On by default; `defaults write com.emerssive.heybenji.app
/// explainCards -bool NO` turns it off (the engine is then never told it can show cards).
///
/// Drawn as Benji speaks: the card opens on its `card:` line with its title and
/// heading, grows downward as parts come (moved back only if it would leave the screen), and
/// each part appears on the sentence that talks about it (`CardBeat`): timed by the voice's word
/// marks when the turn is spoken, by an estimate when it isn't. Cut off, the rest is drawn at once.
final class ExplainCardStage: NSObject, ExplainCardShowing {
    static let defaultsKey = "explainCards"
    static let shared = ExplainCardStage()
    static var isOn: Bool { (UserDefaults.standard.object(forKey: defaultsKey) as? Bool) ?? true }
    /// How long a card stays up untouched (the same hold as a drawn picture).
    static let hold = PointingSequence.drawingHold

    /// The display to use when no screenshot came with the turn, and the windows to keep clear of
    /// (Benji's panel, a figure card); set by the app.
    var screen: () -> NSScreen? = { NSScreen.main }
    var avoid: () -> [CGRect] = { [] }
    /// A chip was tapped: its words go to the model as the user's next message.
    var onChip: ((String) -> Void)?

    private var panel: ExplainCardPanel?
    private var cardView: ExplainCardView?
    private var holdTimer: Timer?
    private var beatTimer: Timer?
    private var monitors: [Any] = []
    private var generation = 0
    private let placeQueue = DispatchQueue(label: "benji.card-place", qos: .userInitiated)
    private let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    /// The card being drawn: its script, its clock, what it looks like now, and where it may go.
    private var script: CardScript?
    /// The run whose card is up (or being placed).
    private var cardRun: Int?
    private var beat: CardBeat?
    private var layout: ExplainCardLayout?
    private var openedAt = 0.0
    private var visible: CGRect = .zero
    /// The coming turn is read aloud (set as each turn starts): the voice is the card's clock.
    private var turnSpeaks = false
    /// What the voice has said of the current answer, kept for a card that opens after it began.
    private var heardText = ""
    private var heardMarks: [SpokenProgress.Mark] = []
    private var heardEndedAt: Double?

    private static func now() -> Double { ProcessInfo.processInfo.systemUptime }

    var isShowing: Bool { panel?.isVisible == true }
    var frame: CGRect? { isShowing ? panel?.frame : nil }

    // MARK: the voice

    /// A turn starts (`speaks`: it will be read aloud). A card still waiting on the last answer's
    /// voice is finished now.
    func turnStarts(speaks: Bool) {
        if let cardRun { hurry(run: cardRun) }
        turnSpeaks = speaks
        heardText = ""
        heardMarks = []
        heardEndedAt = nil
    }

    /// The voice's text so far (`SpeechText.plain`, as given to it) and new word marks.
    func heard(spoken: String, marks: [SpokenProgress.Mark]) {
        if !spoken.hasPrefix(heardText) {
            heardMarks = []
            heardEndedAt = nil
        }
        heardText = spoken
        heardMarks += marks
        beat?.lines.heard(spoken: spoken, marks: marks)
        tick()
    }

    /// The voice stopped (finished, cut off, failed): sentences not yet heard are past.
    func speechEnded() {
        let t = Self.now()
        if !heardMarks.isEmpty, heardEndedAt == nil { heardEndedAt = t }
        beat?.lines.speechEnded(at: t)
        tick()
    }

    // MARK: ExplainCardShowing

    /// Lays the card out as it is so far, finds its place off the main thread (for the size it is
    /// likely to reach: three parts), then shows it, replacing any card.
    func open(_ script: CardScript, run: Int, busy: ExplainBusyScreen?, targets: [PointingTarget]) {
        guard let draft = script.draft else { return }
        dismiss()
        cardRun = run
        let gen = generation
        let display = busy?.screen ?? screen() ?? NSScreen.main
        guard let display else { return }
        let frame = display.frame, visible = display.visibleFrame
        // Everything in the display's own points, top-left origin, y down.
        func local(_ r: CGRect) -> CGRect { CGRect(x: r.minX - frame.minX, y: frame.maxY - r.maxY, width: r.width, height: r.height) }
        var keepOut = avoid().filter { $0.intersects(frame) }.map(local)
        if let busy, busy.pixelSize.width > 0 {
            let k = frame.width / busy.pixelSize.width
            keepOut += targets.filter { $0.shape.edit == nil }.map {
                let p = ExplainCardPlacement.pixelBounds(of: $0.shape)
                return CGRect(x: p.minX * k, y: p.minY * k, width: p.width * k, height: p.height * k)
            }
        }
        let vis = local(visible)
        let panelBelow = keepOut.first.map { CGPoint(x: $0.midX, y: $0.maxY + ExplainCardPlacement.margin) }
        let prefer = panelBelow ?? CGPoint(x: vis.midX, y: vis.minY + 40)
        let map = busy?.map
        let likely = Self.likelySize(draft)
        self.script = script
        var beat = CardBeat(clock: turnSpeaks ? .voice : .estimate)
        beat.lines.heard(spoken: heardText, marks: heardMarks)
        if let end = heardEndedAt { beat.lines.speechEnded(at: end) }
        self.beat = beat
        self.visible = visible
        placeQueue.async { [weak self] in
            let placed = ExplainCardPlacement.place(size: likely, visible: vis, prefer: prefer, avoid: keepOut, busy: map)
            DispatchQueue.main.async {
                guard let self, gen == self.generation else { return }
                let r = placed.frame
                self.present(topLeft: CGPoint(x: frame.minX + r.minX, y: frame.maxY - r.minY))
            }
        }
    }

    func update(_ script: CardScript, run: Int) {
        guard self.script != nil, run == cardRun else { return }
        self.script = script
        guard panel?.isVisible == true else { return }   // still being placed: present() lays it out
        relayout()
        tick()
    }

    func withdraw(run: Int) {
        guard script != nil, run == cardRun else { return }
        dismiss()
    }

    func hurry(run: Int) {
        guard beat != nil, run == cardRun else { return }
        beat?.cutOff(now: Self.now())
        tick()
    }

    /// The card up now, by title and its items' labels: what the model is told it has on the
    /// screen.
    var shownCard: (title: String, items: [String])? {
        guard panel?.isVisible == true, let draft = script?.draft else { return nil }
        return (draft.header.title, draft.items.map(\.label))
    }

    func dismiss() {
        generation += 1
        holdTimer?.invalidate(); holdTimer = nil
        beatTimer?.invalidate(); beatTimer = nil
        monitors.forEach(NSEvent.removeMonitor); monitors = []
        panel?.orderOut(nil)
        script = nil
        cardRun = nil
        beat = nil
        layout = nil
    }

    /// The card's size with three parts of a few words: where a card is placed when it opens.
    static func likelySize(_ draft: ExplainCardDraft) -> CGSize {
        var likely = draft
        while likely.items.count < 3 {
            _ = likely.add(ExplainCard.Item(label: "A few words", note: "a short note of a few words", icon: "circle"))
        }
        return ExplainCardLayout.make(likely.card, measure: CardMeasure()).size
    }

    // MARK: presenting

    private func present(topLeft: CGPoint) {
        makePanelIfNeeded()
        guard let panel, let cardView, let script, let card = script.draft?.card else { return }
        panel.sharingType = DrawingCapture.shown(from: UserDefaults.standard.object(forKey: DrawingCapture.defaultsKey))
            ? .readOnly : .none
        let layout = ExplainCardLayout.make(card, measure: CardMeasure())
        self.layout = layout
        openedAt = Self.now()
        panel.setFrame(fitted(CGRect(x: topLeft.x, y: topLeft.y - layout.size.height, width: layout.size.width,
                                     height: layout.size.height)), display: false)
        cardView.frame = CGRect(origin: .zero, size: layout.size)
        beat?.sync(script, now: openedAt)
        cardView.show(card, layout: layout, reveal: reveal())
        panel.orderFrontRegardless()
        watchEscape()
        restartHold()
        tick()
    }

    /// The card with what has come since: the panel keeps its top-left corner (wherever it was
    /// dragged) and grows down and right, moved back only as far as it would leave the screen.
    private func relayout() {
        guard let panel, let cardView, let script, let card = script.draft?.card else { return }
        beat?.sync(script, now: Self.now())
        let next = ExplainCardLayout.make(card, measure: CardMeasure())
        guard next != layout else { return }
        layout = next
        let old = panel.frame
        panel.setFrame(fitted(CGRect(x: old.minX, y: old.maxY - next.size.height, width: next.size.width,
                                     height: next.size.height)), display: false)
        cardView.frame = CGRect(origin: .zero, size: next.size)
        cardView.show(card, layout: next, reveal: reveal(), keepingTime: true)
    }

    /// `r` moved (not resized) just enough to stay on the visible part of the display.
    private func fitted(_ r: CGRect) -> CGRect {
        guard visible.width > 0 else { return r }
        var f = r
        if f.maxX > visible.maxX { f.origin.x = visible.maxX - f.width }
        if f.minX < visible.minX { f.origin.x = visible.minX }
        if f.minY < visible.minY { f.origin.y = visible.minY }
        if f.maxY > visible.maxY { f.origin.y = visible.maxY - f.height }
        return f
    }

    private func reveal() -> ExplainCardReveal {
        let items = layout?.nodes.count ?? 0
        guard let beat else {
            return ExplainCardReveal(items: items, hasTakeaway: layout?.takeaway != nil, reduceMotion: true)
        }
        return ExplainCardReveal(beats: .init(opened: openedAt, items: (0..<items).map(beat.itemSlot),
                                              takeaway: beat.takeawaySlot, chips: beat.chipsAt),
                                 hasTakeaway: layout?.takeaway != nil, reduceMotion: reduceMotion)
    }

    /// Releases what is due, redraws, and comes back when the next part is due or while
    /// something is still drawing.
    private func tick() {
        guard var beat, let cardView, panel?.isVisible == true else { return }
        let t = Self.now()
        beat.advance(now: t)
        self.beat = beat
        let reveal = reveal()
        cardView.update(reveal: reveal, at: t)
        beatTimer?.invalidate()
        beatTimer = nil
        let drawing = reveal.beats.map { b in
            (b.items.compactMap { $0 } + [b.takeaway].compactMap { $0 }).contains { t < $0.end + ExplainCardReveal.fade }
                || b.chips.map { t < $0 + ExplainCardReveal.fade } ?? false
                || t < b.opened + ExplainCardReveal.land + ExplainCardReveal.headingAt + ExplainCardReveal.fade
        } ?? false
        let wake: Double? = drawing ? t + 1.0 / 60 : [beat.nextDue(now: t), beat.chipsAt].compactMap { $0 }.filter { $0 > t }.min()
            ?? (beat.track.isDone && beat.ended ? nil : t + 0.25)   // waiting on the voice or more lines
        guard let wake else { return }
        let timer = Timer(timeInterval: max(wake - t, 1.0 / 120), repeats: false) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        beatTimer = timer
    }

    private func restartHold() {
        holdTimer?.invalidate()
        holdTimer = Timer.scheduledTimer(withTimeInterval: Self.hold, repeats: false) { [weak self] _ in self?.dismiss() }
    }

    private func makePanelIfNeeded() {
        guard panel == nil else { return }
        let p = ExplainCardPanel(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        let view = ExplainCardView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        view.onClose = { [weak self] in self?.dismiss() }
        view.onChip = { [weak self] text in
            self?.restartHold()
            self?.onChip?(text)
        }
        view.onTouched = { [weak self] in self?.restartHold() }
        p.contentView = view
        panel = p
        cardView = view
    }

    /// Escape dismisses: observed, never consumed, so the front app still gets it (as the overlay does).
    private func watchEscape() {
        guard monitors.isEmpty else { return }
        let handler: (NSEvent) -> Void = { [weak self] e in if e.keyCode == 53 { self?.dismiss() } }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handler) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { handler($0); return $0 }) { monitors.append(m) }
    }
}

/// A turn's screenshot, measured for busy space, with the display it shows.
struct ExplainBusyScreen {
    let map: BusyMap
    let screen: NSScreen
    let pixelSize: CGSize

    /// Reads the screenshot at `path` at one pixel per point of `screen`, in brightness only.
    static func measure(path: String, screen: NSScreen) -> ExplainBusyScreen? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        return measure(source: source, screen: screen)
    }

    /// The same from the screenshot's bytes (read before its file is deleted).
    static func measure(data: Data, screen: NSScreen) -> ExplainBusyScreen? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return measure(source: source, screen: screen)
    }

    private static func measure(source: CGImageSource, screen: NSScreen) -> ExplainBusyScreen? {
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let w = max(1, Int(screen.frame.width)), h = max(1, Int((CGFloat(image.height) * CGFloat(w) / CGFloat(image.width)).rounded()))
        var luma = [UInt8](repeating: 0, count: w * h)
        let drawn = luma.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn, let map = BusyMap.measure(luma: luma, width: w, height: h, pointsWide: screen.frame.width) else { return nil }
        return ExplainBusyScreen(map: map, screen: screen, pixelSize: CGSize(width: image.width, height: image.height))
    }
}

final class ExplainCardPanel: NSPanel {
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
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        ignoresMouseEvents = false
    }
}

/// The card and its chips in one flipped view: dragging the card's body moves the panel, the
/// close button and each chip are clicked in place, and the space between chips lets clicks
/// through (a fully clear pixel is not the panel's).
final class ExplainCardView: NSView {
    var onClose: (() -> Void)?
    var onChip: ((String) -> Void)?
    var onTouched: (() -> Void)?
    var revealTime: Double = .infinity { didSet { needsDisplay = true } }

    private var card: ExplainCard?
    private var layout: ExplainCardLayout?
    private var reveal: ExplainCardReveal?
    private var hoveredChip: Int?
    private var hoveredClose = false
    private var pressed: Target?
    private var dragFrom: NSPoint?
    private var chipElements: [CardButtonElement] = []
    private var closeElement: CardButtonElement?

    private enum Target: Equatable { case close, chip(Int), body }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// `keepingTime`: the same card grown (the reveal clock and hover go on as they were).
    func show(_ card: ExplainCard, layout: ExplainCardLayout, reveal: ExplainCardReveal, keepingTime: Bool = false) {
        self.card = card
        self.layout = layout
        self.reveal = reveal
        if !keepingTime {
            hoveredChip = nil
            hoveredClose = false
            revealTime = 0
        }
        setAccessibilityLabel(card.spokenSummary)
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
        closeElement = CardButtonElement(label: "Close card", parent: self) { [weak self] in self?.onClose?() }
        chipElements = layout.chips.map { chip in
            CardButtonElement(label: "Ask: \(chip.text)", parent: self) { [weak self] in self?.onChip?(chip.text) }
        }
        updateChipAccessibility()
        needsDisplay = true
    }

    /// The beats moved on, or the clock did.
    func update(reveal: ExplainCardReveal, at t: Double) {
        let chipsWere = chipsReady
        self.reveal = reveal
        revealTime = t
        if chipsReady != chipsWere { updateChipAccessibility() }
    }

    private var chipsReady: Bool {
        guard let reveal else { return false }
        return revealTime >= reveal.chipsAt
    }

    private func updateChipAccessibility() {
        guard let layout else { return }
        var children: [Any] = []
        if let closeElement {
            closeElement.setAccessibilityFrameInParentSpace(layout.close)
            children.append(closeElement)
        }
        if chipsReady {
            for (e, c) in zip(chipElements, layout.chips) {
                e.setAccessibilityFrameInParentSpace(c.frame)
                children.append(e)
            }
        }
        setAccessibilityChildren(children)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let layout else { return }
        ExplainCardDrawing.drawCard(layout, reveal: reveal, at: revealTime, chips: true, hoveredChip: hoveredChip,
                                    hoveredClose: hoveredClose)
    }

    private func target(at p: NSPoint) -> Target? {
        guard let layout else { return nil }
        if layout.close.insetBy(dx: -4, dy: -4).contains(p) { return .close }
        if chipsReady, let i = layout.chips.firstIndex(where: { $0.frame.contains(p) }) { return .chip(i) }
        if layout.card.contains(p) { return .body }
        return nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Outside the card and the chips the panel lets the click through to what is under it.
        guard let p = superview.map({ convert(point, from: $0) }) ?? Optional(point), target(at: p) != nil else { return nil }
        return self
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let t = target(at: p)
        let chip: Int? = { if case .chip(let i)? = t { return i }; return nil }()
        let close = t == .close
        if chip != hoveredChip || close != hoveredClose {
            hoveredChip = chip
            hoveredClose = close
            needsDisplay = true
        }
        (chip != nil || close ? NSCursor.pointingHand : NSCursor.arrow).set()
    }

    override func mouseExited(with event: NSEvent) {
        hoveredChip = nil
        hoveredClose = false
        needsDisplay = true
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        pressed = target(at: p)
        dragFrom = pressed == .body ? NSEvent.mouseLocation : nil
        onTouched?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let from = dragFrom, let window else { return }
        let now = NSEvent.mouseLocation
        window.setFrameOrigin(NSPoint(x: window.frame.minX + now.x - from.x, y: window.frame.minY + now.y - from.y))
        dragFrom = now
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        defer { pressed = nil; dragFrom = nil }
        guard let pressed, pressed == target(at: p) else { return }
        switch pressed {
        case .close: onClose?()
        case .chip(let i): if let layout { onChip?(layout.chips[i].text) }
        case .body: break
        }
    }
}

/// The close button or a chip, for VoiceOver: a button that presses like a click.
final class CardButtonElement: NSAccessibilityElement {
    private let press: () -> Void

    init(label: String, parent: Any, press: @escaping () -> Void) {
        self.press = press
        super.init()
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
        setAccessibilityParent(parent)
    }

    override func accessibilityPerformPress() -> Bool {
        press()
        return true
    }
}
