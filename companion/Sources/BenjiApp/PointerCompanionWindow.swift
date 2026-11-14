import AppKit
import Combine
import SwiftUI
import BenjiCore

/// Benji beside the pointer (D-180, D-190): while Benji is active, Benji's arrow (`BenjiArrowMark`) and the notch's status word
/// ride just below and right of the system pointer. One small borderless, click-through, non-activating window
/// at the screen-saver level. It follows the pointer with mouse-moved monitors only while it shows; idle,
/// nothing runs at all.
final class PointerCompanionWindow {
    private var window: NSPanel?
    private var monitors: [Any] = []
    private var watch: AnyCancellable?
    private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    /// Increase Contrast or Reduce Transparency: the arrow's solid variant.
    private var solid = PointerCompanionWindow.solidFromSystem
    private static var solidFromSystem: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            || NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }
    private var phase: CompanionPhase = .idle
    private var word = ""
    private var wordOnRight = true

    /// Shows and hides it from the model's state and the setting.
    func attach(to model: CompanionModel) {
        watch = model.$state.map { ($0.phase, NotchStatusInfo.make($0).word) }
            .removeDuplicates { $0 == $1 }
            .sink { [weak self] phase, word in DispatchQueue.main.async { self?.update(phase: phase, word: word) } }
    }

    /// Settings' switch changed, or anything else that may hide it now.
    func refresh() { update(phase: phase, word: word) }

    private var enabled: Bool {
        PointerCompanion.isOn(from: UserDefaults.standard.object(forKey: PointerCompanion.defaultsKey))
    }

    private func update(phase: CompanionPhase, word: String) {
        self.phase = phase
        self.word = word
        if PointerCompanion.shows(phase: phase, enabled: enabled) { show() } else { hide() }
    }

    private func render(_ panel: NSPanel) {
        (panel.contentView as? NSHostingView<PointerCompanionView>)?.rootView =
            PointerCompanionView(word: word, breathing: phase == .thinking && !reduceMotion, wordOnRight: wordOnRight,
                                 solid: solid)
    }

    private func show() {
        reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        solid = Self.solidFromSystem
        let panel = window ?? makeWindow()
        window = panel
        panel.sharingType = DrawingCapture.shown(from: UserDefaults.standard.object(forKey: DrawingCapture.defaultsKey)) ? .readOnly : .none
        follow()
        render(panel)
        guard !panel.isVisible || panel.alphaValue < 1 else { return }
        if !panel.isVisible { panel.alphaValue = 0 }
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? MotionTokens.reduceDuration : MotionTokens.fadeDuration
            context.timingFunction = CAMediaTimingFunction(name: reduceMotion ? .easeInEaseOut : .easeOut)
            panel.animator().alphaValue = 1
        }
        guard monitors.isEmpty else { return }
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] _ in self?.follow() }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] event in
            self?.follow()
            return event
        }) {
            monitors.append(local)
        }
    }

    private func hide() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        guard let panel = window, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? MotionTokens.reduceDuration : MotionTokens.fadeDuration
            context.timingFunction = CAMediaTimingFunction(name: reduceMotion ? .easeInEaseOut : .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            // Shown again meanwhile: leave it up.
            guard let self, self.monitors.isEmpty else { return }
            panel.orderOut(nil)
        }
    }

    /// Moves the window beside the pointer, on the display the pointer is on.
    private func follow() {
        guard let panel = window else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }?.frame ?? panel.screen?.frame ?? .zero
        let placed = PointerCompanion.placement(pointer: mouse, screen: screen)
        panel.setFrame(placed.frame, display: false)
        if placed.wordOnRight != wordOnRight {
            wordOnRight = placed.wordOnRight
            render(panel)
        }
    }

    private func makeWindow() -> NSPanel {
        let panel = NSPanel(contentRect: CGRect(origin: .zero, size: PointerCompanion.panelSize),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .screenSaver
        panel.ignoresMouseEvents = true                  // click-through
        panel.hasShadow = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.animationBehavior = .none
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle, .transient]
        let host = NSHostingView(rootView: PointerCompanionView(word: word, breathing: false, wordOnRight: true))
        host.sizingOptions = []
        panel.contentView = host
        return panel
    }
}

/// Benji's arrow at 20 pt (the drawing shared with the notch's wing), and the status word in the
/// notch's black.
struct PointerCompanionView: View {
    let word: String
    let breathing: Bool
    let wordOnRight: Bool
    var solid = false

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            if !wordOnRight { label }
            arrow
            if wordOnRight { label }
        }
        .frame(width: PointerCompanion.panelSize.width, height: PointerCompanion.panelSize.height,
               alignment: wordOnRight ? .leading : .trailing)
        .environment(\.colorScheme, .dark)
        .accessibilityHidden(true)      // the notch already announces each state
    }

    private var label: some View {
        Text(word)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(0.92))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(.black.opacity(0.86)))
    }

    @ViewBuilder private var arrow: some View {
        if breathing {
            TimelineView(.animation(minimumInterval: 1.0 / 20)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                head.opacity(0.75 + 0.25 * (0.5 + 0.5 * sin(2 * .pi * t / 1.6)))
            }
        } else {
            head
        }
    }

    private var head: some View {
        BenjiArrowMark(size: PointerCompanion.size, solid: solid)
    }
}
