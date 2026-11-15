import AppKit
import BenjiCore

/// The connected displays as `DisplayAnchors` and `CaptureDisplay` read them.
enum DisplayInventory {
    static func id(of screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    static func descriptor(of screen: NSScreen) -> DisplayDescriptor? {
        guard let id = id(of: screen) else { return nil }
        let notch = PanelGeometry.hardwareNotch(screenFrame: screen.frame, leftArea: screen.auxiliaryTopLeftArea,
                                                rightArea: screen.auxiliaryTopRightArea,
                                                safeAreaTop: screen.safeAreaInsets.top)
        return DisplayDescriptor(id: id, frame: screen.frame, notch: notch, name: screen.localizedName)
    }

    static func current() -> [DisplayDescriptor] { NSScreen.screens.compactMap(descriptor(of:)) }

    static func screen(_ id: UInt32?) -> NSScreen? {
        guard let id else { return nil }
        return NSScreen.screens.first { Self.id(of: $0) == id }
    }
}

/// The quiet bar on each display Benji isn't on and that has no hardware notch (`DisplayAnchors`):
/// 48 × 5 pt drawn at the top centre, in a 96 × 24 pt target. Hovering it (with the notch's own
/// rest rule, run by `CompanionPanel`) brings Benji's one panel to that display as a peek; clicking
/// it opens the panel there. A bar never takes the keyboard, never activates Benji and is left out
/// of Benji's screenshots with every other Benji window.
final class DisplayBars {
    /// A click (or VoiceOver's press) on the bar of a display.
    var onPress: ((UInt32) -> Void)?
    private var windows: [UInt32: DisplayBarWindow] = [:]
    private var accessibility = NotchAccessibility.system
    private var hot: UInt32?
    private var observer: NSObjectProtocol?
    private var screenOn = false

    func setScreenOn(_ on: Bool) {
        screenOn = on
        for window in windows.values { window.barView.screenOn = on }
    }

    /// A window on another Space or hidden by a full-screen app must not leave a live hover target.
    func isVisible(_ display: UInt32) -> Bool {
        guard let window = windows[display] else { return false }
        return window.isVisible && window.occlusionState.contains(.visible)
    }

    init() {
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.accessibility = .system
            for window in self.windows.values { window.barView.a = self.accessibility }
        }
    }

    deinit { observer.map(NSWorkspace.shared.notificationCenter.removeObserver) }

    /// Puts a bar on every `.bar` anchor and takes away the rest (hot plug, the panel moving).
    func update(_ anchors: [DisplayAnchor]) {
        accessibility = .system
        let bars = anchors.filter { $0.kind == .bar }
        for id in windows.keys where !bars.contains(where: { $0.display == id }) {
            windows.removeValue(forKey: id)?.orderOut(nil)
        }
        for bar in bars {
            let window = windows[bar.display] ?? DisplayBarWindow(display: bar.display) { [weak self] in
                self?.onPress?(bar.display)
            }
            windows[bar.display] = window
            window.barView.hot = bar.display == hot
            window.barView.a = accessibility
            window.barView.screenOn = screenOn
            window.setFrame(bar.zone, display: true)
            window.orderFrontRegardless()
        }
    }

    /// The bar under the pointer shows that it can be used; the others rest.
    func setHot(_ id: UInt32?) {
        guard id != hot else { return }
        hot = id
        for (display, window) in windows { window.barView.hot = display == id }
    }
}

final class DisplayBarWindow: NSPanel {
    let barView: DisplayBarView

    init(display: UInt32, press: @escaping () -> Void) {
        barView = DisplayBarView(press: press)
        super.init(contentRect: CGRect(origin: .zero, size: DisplayBar.hitSize),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)   // the panel's own level
        // Not over a full-screen app: the bar is for the desktop's menu bar.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        ignoresMouseEvents = false   // the full 96 × 24 pt window is the intended click target
        hasShadow = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        animationBehavior = .none
        contentView = barView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// The bar itself: a muted capsule that turns deep mint while the pointer is on its target. Under
/// Increase Contrast it is solid black with a white edge; under Reduce Transparency it is opaque.
final class DisplayBarView: NSView {
    var screenOn = false { didSet { if screenOn != oldValue { needsDisplay = true } } }
    var hot = false { didSet { if hot != oldValue { needsDisplay = true } } }
    var a = NotchAccessibility() { didSet { if a != oldValue { needsDisplay = true } } }
    private let press: () -> Void

    init(press: @escaping () -> Void) {
        self.press = press
        super.init(frame: CGRect(origin: .zero, size: DisplayBar.hitSize))
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Benji")
        setAccessibilityHelp("Opens Benji on this display.")
        toolTip = "Benji"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// `benji-mint-deep` and a grey that reads on light and dark menu bars.
    static let deepMint = NSColor(srgbRed: 0x08 / 255, green: 0x96 / 255, blue: 0x8e / 255, alpha: 1)
    static let rest = NSColor(srgbRed: 0x58 / 255, green: 0x69 / 255, blue: 0x67 / 255, alpha: 1)

    override func draw(_ dirtyRect: NSRect) {
        if screenOn {
            NSColor.systemPurple.setFill()
            let bar = DisplayBar.barFrame(inHit: bounds.size)
            NSBezierPath(ovalIn: CGRect(x: bar.minX - 12, y: bar.midY - 3.5, width: 7, height: 7)).fill()
        }
        let rect = DisplayBar.barFrame(inHit: bounds.size)
        let path = NSBezierPath(roundedRect: rect, xRadius: DisplayBar.cornerRadius, yRadius: DisplayBar.cornerRadius)
        if a.increaseContrast {
            (hot ? Self.deepMint : NSColor.black).setFill()
            path.fill()
            NSColor.white.setStroke()
            path.lineWidth = 1
            path.stroke()
            return
        }
        (hot ? Self.deepMint : Self.rest).setFill()
        path.fill()
        if !hot {
            // The dark fill reads on light menu bars; an inset light edge keeps the resting bar
            // visible over dark ones too, without enlarging its 48 × 5 pt footprint.
            NSColor.white.withAlphaComponent(a.reduceTransparency ? 1 : 0.8).setStroke()
            let edge = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 2, yRadius: 2)
            edge.lineWidth = 1
            edge.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) { press() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func accessibilityPerformPress() -> Bool { press(); return true }
}
