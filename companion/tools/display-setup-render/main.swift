// Offscreen renders for the display and setup work, at the app's real point sizes, each at 1x and
// 2x. Every state is injected: a fake backend, a fake permission probe, a fake key store. Nothing
// here asks for a permission, captures a screen, starts the engine or reads Benji's settings.
// Build and run with tools/display-setup-render/render.sh <output dir>.
import AppKit
import BenjiCore
import SwiftUI

final class FakeBackend: CompanionBackend, JobBackend {
    var onEvent: ((_ run: Int, BackendEvent) -> Void)?
    var onFinished: ((_ run: Int, Int32) -> Void)?
    let approvalTimeout: TimeInterval = 60
    private var run = 0
    func start(run: Int, task: String, imagePath: String?, memory: ConversationMemory, allowPointing: Bool,
               spoken: Bool, screen: ScreenshotGeometry?) { self.run = run }
    func say(_ event: BackendEvent) { onEvent?(run, event) }
    func resolveApproval(_ approved: Bool) {}
    var onJob: ((JobSnapshot) -> Void)?
    var onEngineExit: (() -> Void)?
    func answerJob(_ job: String, request: String, approved: Bool) {}
    func stopJob(_ job: String) {}
    func steerJob(_ job: String, text: String) {}
    func dismissJob(_ job: String) {}
    func cancel() {}
    func reset() {}
    func shutdown() {}
}

final class MemoryKeyStore: KeyStore {
    func read(_ account: String) throws -> String? { nil }
    func write(_ value: String, account: String) throws {}
    func delete(_ account: String) throws {}
    func accounts() throws -> [String] { [] }
}

@MainActor final class NoModelBackend: ModelSetupBackend {
    var pending: [(Result<ModelSetupSource, ModelSetupFailure>) -> Void] = []
    func run(test source: ModelSetupSource?, completion: @escaping (Result<ModelSetupSource, ModelSetupFailure>) -> Void) {
        pending.append(completion)
    }
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let suite = "benji-display-setup-render-\(UUID().uuidString)"
var manifest: [String] = []

// MARK: drawing helpers

/// Draws `view` in an offscreen window (never on a display) into a bitmap of exactly `scale` pixels
/// per point.
@MainActor
func snapshot(_ view: NSView, scale: CGFloat, settle: Double = 0.3) -> NSBitmapImageRep {
    let size = CGSize(width: ceil(view.frame.width), height: ceil(view.frame.height))
    view.setFrameSize(size)
    let window = NSWindow(contentRect: CGRect(x: -30000, y: -30000, width: size.width, height: size.height),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = view
    window.orderFrontRegardless()
    RunLoop.main.run(until: Date().addingTimeInterval(settle))
    view.layoutSubtreeIfNeeded()
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    view.cacheDisplay(in: view.bounds, to: rep)
    window.orderOut(nil)
    return rep
}

@MainActor
func write(_ view: NSView, _ name: String, scales: [CGFloat] = [1, 2], note: String) {
    for scale in scales {
        let rep = snapshot(view, scale: scale)
        let file = "\(name)@\(Int(scale))x.png"
        try! rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(file))
        let line = "\(file)\t\(Int(view.frame.width))×\(Int(view.frame.height)) pt\t\(rep.pixelsWide)×\(rep.pixelsHigh) px\t\(note)"
        manifest.append(line)
        print(line)
    }
}

@MainActor
func host<V: View>(_ view: V, size: CGSize, dark: Bool = false) -> NSView {
    let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
    host.frame = CGRect(origin: .zero, size: size)
    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    return host
}

/// A desktop behind the drawing, light or dark.
struct Desktop: View {
    let dark: Bool
    var body: some View {
        LinearGradient(colors: dark ? [Color(white: 0.14), Color(red: 0.10, green: 0.13, blue: 0.18)]
                                    : [Color(red: 0.89, green: 0.93, blue: 0.92), Color(red: 0.77, green: 0.85, blue: 0.83)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

let appIcon = NSImage(contentsOfFile: "Resources/AppIcon.icns") ?? NSImage(size: NSSize(width: 64, height: 64))

// MARK: setup window

@MainActor
func setupModel(_ statuses: [CompanionPermission: PermissionStatus], model: Bool) -> PermissionSetupModel {
    var setup: ModelSetupModel?
    if model {
        let backend = NoModelBackend()
        let s = ModelSetupModel(store: MemoryKeyStore(), defaults: UserDefaults(suiteName: suite)!, backend: backend, files: [])
        s.checkExisting()
        backend.pending.forEach { $0(.failure(ModelSetupFailure(words: "No model source found."))) }
        setup = s
    }
    return PermissionSetupModel(probe: { statuses }, actions: PermissionSetupActions(), modelSetup: setup,
                                appIcon: appIcon, appURL: URL(fileURLWithPath: "/Applications/Benji.app"))
}

/// The window's content at its own size (the title bar is AppKit's and not drawn here).
@MainActor
func setupView(_ model: PermissionSetupModel, dark: Bool = false) -> NSView {
    // A window's content is drawn over the window's own background, which an offscreen snapshot of
    // the content view leaves out: paint it here, as the titled NSWindow does in the app.
    let hosting = NSHostingView(rootView: PermissionSetupView(model: model).background(Color(nsColor: .windowBackgroundColor)))
    hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let fitting = hosting.fittingSize
    hosting.sizingOptions = []   // freeze the measured size for consistent 1x/2x pixel-aligned captures
    hosting.frame = CGRect(origin: .zero, size: CGSize(width: ceil(fitting.width), height: ceil(fitting.height)))
    return hosting
}

// MARK: the notch and the panel on a flat display

@MainActor
func companion(layout: NotchLayoutInfo, size: NotchSize, a: NotchAccessibility = NotchAccessibility(),
               setUp: (CompanionModel, FakeBackend) -> Void) -> (CompanionModel, NotchPresenter) {
    let defaults = UserDefaults(suiteName: suite)!
    let backend = FakeBackend()
    let model = CompanionModel(backend: backend, screenMode: ScreenModeStore(defaults: defaults))
    model.providerID = "claude"
    model.setScreenMode(.off)
    model.talkKeyName = "Right ⌥"
    setUp(model, backend)
    model.setExpanded(size == .open)
    let presenter = NotchPresenter(model: model, layout: layout, accessibility: a)
    presenter.showStill(size)
    if size == .peek && !layout.hasHardwareNotch {
        presenter.revealHover()   // keep the real hover state alive when the queued idle event arrives
    }
    return (model, presenter)
}

@MainActor
func notchScene(layout: NotchLayoutInfo, size: NotchSize, dark: Bool, crop: CGSize, a: NotchAccessibility = NotchAccessibility(),
                setUp: (CompanionModel, FakeBackend) -> Void = { _, _ in }) -> NSView {
    let (model, presenter) = companion(layout: layout, size: size, a: a, setUp: setUp)
    let open = presenter.layout.shape(.open).frame.size
    let view = ZStack(alignment: .top) {
        Desktop(dark: dark)
        CompanionView(model: model, presenter: presenter, onOpen: {})
            .frame(width: open.width + 80, height: open.height + 60, alignment: .top)
            .frame(width: crop.width, height: crop.height, alignment: .top)
            .clipped()
    }
    .environment(\.colorScheme, dark ? .dark : .light)
    return host(view, size: crop, dark: dark)
}

/// The bar on another display's menu bar, at its real size inside a strip of that menu bar.
@MainActor
func barStrip(hot: Bool, dark: Bool, a: NotchAccessibility = NotchAccessibility()) -> NSView {
    let strip = NSView(frame: CGRect(x: 0, y: 0, width: 320, height: 40))
    strip.wantsLayer = true
    strip.layer?.backgroundColor = (dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.95, alpha: 1)).cgColor
    let menuBar = NSView(frame: CGRect(x: 0, y: 40 - 24, width: 320, height: 24))
    menuBar.wantsLayer = true
    menuBar.layer?.backgroundColor = (dark ? NSColor(white: 0.22, alpha: 1) : NSColor(white: 0.88, alpha: 1)).cgColor
    strip.addSubview(menuBar)
    let bar = DisplayBarView(press: {})
    bar.frame = CGRect(origin: CGPoint(x: (320 - DisplayBar.hitSize.width) / 2, y: 40 - DisplayBar.hitSize.height),
                       size: DisplayBar.hitSize)
    bar.hot = hot
    bar.a = a
    strip.addSubview(bar)
    return strip
}

// MARK: the scenes

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)

    // 1. Setup: one step at a time.
    let none: [CompanionPermission: PermissionStatus] = [:]
    write(setupView(setupModel(none, model: true)), "setup-01-current-accessibility",
          note: "full setup, current step Accessibility, checklist folded")
    // 2. The same window after "Open Accessibility Settings": the helper.
    let helper = setupModel(none, model: true)
    helper.openAccessibilitySettings()
    write(setupView(helper), "setup-02-helper", note: "the same window as the helper beside Settings")
    write(setupView(helper, dark: true), "setup-02-helper-dark", scales: [2], note: "helper, dark appearance")
    // 3. The model step when it is current: its form has the room it needs.
    let granted: [CompanionPermission: PermissionStatus] = [.accessibility: .granted, .microphone: .granted,
                                                            .speechRecognition: .granted, .screenRecording: .granted]
    write(setupView(setupModel(granted, model: true)), "setup-03-current-model", note: "full setup, current step Model")
    // 4. A denied step is passed over; the checklist says so.
    let denied: [CompanionPermission: PermissionStatus] = [.accessibility: .granted, .microphone: .denied,
                                                           .speechRecognition: .granted]
    write(setupView(setupModel(denied, model: true)), "setup-04-denied-voice", scales: [2],
          note: "voice denied, current Screen Recording, checklist title counts it")

    // 5. The bar on another display: resting, under the pointer, Increase Contrast.
    write(barStrip(hot: false, dark: false), "bar-01-rest-light", note: "48×5 pt bar in its 96×24 pt target, light menu bar")
    write(barStrip(hot: false, dark: true), "bar-02-rest-dark", note: "dark menu bar")
    write(barStrip(hot: true, dark: false), "bar-03-hot-light", note: "pointer on the target")
    write(barStrip(hot: false, dark: false, a: NotchAccessibility(increaseContrast: true)), "bar-04-contrast-light",
          note: "Increase Contrast")

    // 6. The panel visiting a 2560×1440 pt display left of the laptop (negative origin), no notch.
    let external = NotchLayoutInfo(notch: nil, screenFrame: CGRect(x: -2560, y: -458, width: 2560, height: 1440))
    // A flat display, including the sole/home display, has no synthetic closed notch.
    let closedStage = NSView(frame: CGRect(x: 0, y: 0, width: 440, height: 90))
    closedStage.addSubview(notchScene(layout: external, size: .closed, dark: false,
                                      crop: closedStage.frame.size, setUp: { model, _ in model.setScreenMode(.on) }))
    let closedBar = DisplayBarView(press: {})
    closedBar.screenOn = true
    closedBar.frame = CGRect(x: (440 - DisplayBar.hitSize.width) / 2, y: 90 - DisplayBar.hitSize.height,
                             width: DisplayBar.hitSize.width, height: DisplayBar.hitSize.height)
    closedStage.addSubview(closedBar)
    write(closedStage, "external-00-closed-bar", note: "flat home display closed: bar and Screen On dot, no artificial notch")
    write(notchScene(layout: external, size: .peek, dark: false, crop: CGSize(width: 440, height: 90)),
          "external-01-hover-peek", note: "hover rested on the bar: Ready peek on the flat display")
    write(notchScene(layout: external, size: .open, dark: true, crop: CGSize(width: 540, height: 440)),
          "external-02-open", scales: [2], note: "clicked: the open panel on the flat display")
    write(notchScene(layout: external, size: .open, dark: false, crop: CGSize(width: 540, height: 440), setUp: { model, _ in
        model.setScreenMode(.ask)
        model.panelDisplay = CaptureTarget(id: 2, name: "Studio Display")
        model.composerText = "What's on this chart?"
        model.submit()
    }), "external-03-ask-card", scales: [2], note: "Ask card naming the display the message started on")

    // 6b. The display row above the composer, on a flat display with two connected.
    write(notchScene(layout: external, size: .open, dark: false, crop: CGSize(width: 540, height: 440), setUp: { model, _ in
        model.setScreenMode(.ask)
        model.panelDisplay = CaptureTarget(id: 2, name: "Studio Display")
    }), "external-04-ask-include-once", scales: [1, 2], note: "Ask: the one-message action, unarmed")
    write(notchScene(layout: external, size: .open, dark: false, crop: CGSize(width: 540, height: 440), setUp: { model, _ in
        model.setScreenMode(.ask)
        model.panelDisplay = CaptureTarget(id: 2, name: "Studio Display")
        model.setExpanded(true)
        model.includeDisplayOnce()
    }), "external-05-ask-included", scales: [2], note: "Ask: included with the next message")
    write(notchScene(layout: external, size: .open, dark: true, crop: CGSize(width: 540, height: 440), setUp: { model, _ in
        model.setScreenMode(.on)
        model.panelDisplay = CaptureTarget(id: 2, name: "Studio Display")
    }), "external-06-on-label", scales: [2], note: "On: the label names the display each message sends")

    write(notchScene(layout: external, size: .open, dark: true, crop: CGSize(width: 540, height: 440), setUp: { model, _ in
        model.setScreenMode(.on)
        model.panelDisplay = CaptureTarget(id: 2, name: "Studio Display")
        model.voiceEngaged(on: CaptureTarget(id: 1, name: "Built-in Retina Display"))
        model.voiceListeningStarted()
    }), "external-07-voice-display", scales: [2], note: "an active recording names its talk-key display, even when the panel is elsewhere")

    for armed in [false, true] {
        write(notchScene(layout: external, size: .open, dark: false, crop: CGSize(width: 540, height: 440), setUp: { model, _ in
            model.setScreenMode(.ask)
            model.panelDisplay = CaptureTarget(id: 1, name: "Built-in Liquid Retina XDR Display")
            model.setExpanded(true)
            if armed { model.includeDisplayOnce() }
        }), armed ? "external-09-long-name-included" : "external-08-long-name-ask",
              note: "long display name: only the name may truncate; the action and suffix remain complete")
    }

    // 7. The arrow in the notch's wing, beside a 190 pt hardware notch.
    let laptop = NotchLayoutInfo(notch: CGRect(x: 661, y: 982 - 32, width: 190, height: 32),
                                 screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982))
    let working: (CompanionModel, FakeBackend) -> Void = { model, _ in
        model.composerText = "Plan a weekend in Lisbon"
        model.submit()
    }
    write(notchScene(layout: laptop, size: .peek, dark: false, crop: CGSize(width: 440, height: 90), setUp: working),
          "notch-01-working-peek", note: "Working: the arrow in the left wing, clear of the 190 pt notch")
    write(notchScene(layout: laptop, size: .peek, dark: true, crop: CGSize(width: 440, height: 90),
                     a: NotchAccessibility(increaseContrast: true), setUp: working),
          "notch-02-working-contrast", note: "Increase Contrast: the solid arrow")
    write(notchScene(layout: laptop, size: .peek, dark: false, crop: CGSize(width: 440, height: 90), setUp: { model, _ in
        model.voiceListeningStarted()
    }), "notch-03-listening-kept", scales: [2], note: "Listening keeps its orange mic (semantic colour unchanged)")

    // 8. Beside the pointer: the 20 pt arrow and its word, on light and dark desktops.
    for (dark, name) in [(false, "light"), (true, "dark")] {
        let view = ZStack(alignment: .topLeading) {
            Desktop(dark: dark)
            PointerCompanionView(word: "Working", breathing: false, wordOnRight: true)
                .offset(x: 30, y: 24)
        }
        write(host(view, size: CGSize(width: 180, height: 70), dark: dark), "pointer-01-\(name)",
              note: "20 pt arrow, 124×26 pt companion window")
    }
    let solid = ZStack(alignment: .topLeading) {
        Desktop(dark: false)
        PointerCompanionView(word: "Working", breathing: false, wordOnRight: true, solid: true).offset(x: 30, y: 24)
    }
    write(host(solid, size: CGSize(width: 180, height: 70)), "pointer-02-solid-light", note: "Increase Contrast / Reduce Transparency")
    let enlarged = HStack(spacing: 0) {
        ZStack { Desktop(dark: false); BenjiArrowMark(size: 160) }
        ZStack { Desktop(dark: true); BenjiArrowMark(size: 160) }
        ZStack { Desktop(dark: false); BenjiArrowMark(size: 160, solid: true) }
    }
    write(host(enlarged, size: CGSize(width: 600, height: 200)), "arrow-enlarged", scales: [1],
          note: "inspection only: the 20 pt drawing at 160 pt")

    try! (manifest.joined(separator: "\n") + "\n").write(to: out.appendingPathComponent("manifest.tsv"), atomically: true, encoding: .utf8)
    UserDefaults.standard.removePersistentDomain(forName: suite)
}
