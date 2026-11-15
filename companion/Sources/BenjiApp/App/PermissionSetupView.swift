import AppKit
import SwiftUI
import BenjiCore

/// What the setup window can do. The live window wires these to `Permissions`; the offscreen
/// renders use no-ops, so nothing here touches a permission API by itself.
struct PermissionSetupActions {
    var openSettings: (SetupStep) -> Void = { _ in }
    var promptAccessibility: () -> Void = {}
    var requestVoice: () -> Void = {}
    var requestScreenRecording: () -> Void = {}
    var relaunch: () -> Void = {}
    var close: () -> Void = {}
}

/// State behind the setup window: the live statuses (read through `probe`) and whether the
/// user has already asked for Screen Recording (which macOS applies after a relaunch).
@MainActor
final class PermissionSetupModel: ObservableObject {
    @Published private(set) var progress: SetupProgress
    @Published var screenRecordingAsked: Bool
    /// The user opened Accessibility Settings from setup: this window becomes a small helper beside
    /// Settings until macOS reports that Benji is on, or the user goes back to the full setup.
    @Published private(set) var helperRequested = false
    let modelSetup: ModelSetupModel?
    let actions: PermissionSetupActions
    let appIcon: NSImage
    let appURL: URL
    private let probe: () -> [CompanionPermission: PermissionStatus]
    /// Called with what VoiceOver should hear when a step ticks off.
    var onAnnounce: (String) -> Void = { _ in }
    var onComplete: () -> Void = {}
    var onIncomplete: () -> Void = {}

    init(probe: @escaping () -> [CompanionPermission: PermissionStatus],
         actions: PermissionSetupActions,
         modelSetup: ModelSetupModel? = nil,
         screenRecordingAsked: Bool = false,
         appIcon: NSImage? = nil,
         appURL: URL = Bundle.main.bundleURL) {
        self.probe = probe
        self.actions = actions
        self.modelSetup = modelSetup
        self.screenRecordingAsked = screenRecordingAsked
        self.appIcon = appIcon ?? NSApp?.applicationIconImage ?? NSImage()
        self.appURL = appURL
        progress = SetupProgress(permissions: probe(), modelDone: modelSetup?.isDone ?? false)
        modelSetup?.onChange = { [weak self] in self?.refresh() }
    }

    /// The helper shows only while Accessibility is the step being asked for; macOS reporting it on
    /// (the probe, never the drag or opening Settings) moves setup on and the full window returns.
    var showsHelper: Bool { helperRequested && progress.current == .accessibility }

    func openAccessibilitySettings() {
        actions.openSettings(.accessibility)
        helperRequested = progress.current == .accessibility
    }

    func showFullSetup() { helperRequested = false }

    func refresh() {
        let next = SetupProgress(permissions: probe(), modelDone: modelSetup?.isDone ?? false)
        guard next != progress else { return }
        let old = progress
        progress = next
        if helperRequested && next.current != .accessibility { helperRequested = false }
        if let line = next.announcement(since: old) { onAnnounce(line) }
        if next.isComplete && !old.isComplete { onComplete() }
        if !next.isComplete && old.isComplete { onIncomplete() }
    }
}

struct PermissionSetupView: View {
    @ObservedObject var model: PermissionSetupModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// `motion-content`, or `motion-reduce` under Reduce Motion.
    private var change: Animation { reduceMotion ? .easeInOut(duration: 0.20) : .smooth(duration: 0.24) }

    /// The optional list of every step; opened by the user, or when a step was turned off.
    @State private var showAll = false

    var body: some View {
        Group {
            if model.showsHelper {
                AccessibilityHelper(model: model)
            } else {
                fullSetup
            }
        }
        .animation(change, value: model.progress)
        .animation(change, value: model.screenRecordingAsked)
        .onChange(of: model.progress.deniedSteps.count) { old, new in if new > old { showAll = true } }
    }

    /// One step at a time: the current one with its actions, the rest in "All steps".
    private var fullSetup: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 8)
            if let number = model.progress.stepNumber, let current = model.progress.current {
                SetupProgressBar(progress: model.progress, number: number, current: current)
                    .padding(.horizontal, 20)
            }
            Form {
                if let current = model.progress.current {
                    Section { row(current, isCurrent: true) }
                    Section {
                        DisclosureGroup(isExpanded: $showAll) {
                            ForEach(SetupStep.allCases, id: \.self) { StepRow(step: $0, model: model, isCurrent: false) }
                        } label: {
                            Text(checklistTitle)
                                .accessibilityHint("Shows every step and what it is for.")
                        }
                    }
                } else {
                    Section { ForEach(SetupStep.allCases, id: \.self) { StepRow(step: $0, model: model, isCurrent: false) } }
                }
            }
            .formStyle(.grouped)
            .modifier(SetupFormHeight(roomy: roomy))
            footer
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
        }
        .frame(width: 520)
    }

    /// The model step's form and the open checklist get the full height (and scroll past it); a single
    /// permission step is as tall as its content.
    private var roomy: Bool { model.progress.current == .model || model.progress.current == nil || showAll }

    @ViewBuilder private func row(_ step: SetupStep, isCurrent: Bool) -> some View {
        if step == .model, let setup = model.modelSetup {
            ModelSetupRow(model: setup, isCurrent: isCurrent)
        } else {
            StepRow(step: step, model: model, isCurrent: isCurrent)
        }
    }

    private var checklistTitle: String {
        let off = model.progress.deniedSteps.count
        return off == 0 ? "All steps" : "All steps · \(off) turned off"
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            if model.progress.isComplete {
                DoneMark(reduceMotion: reduceMotion)
            } else {
                Image(nsImage: model.appIcon)
                    .resizable()
                    .frame(width: 48, height: 48)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(headline)
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(subhead)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var headline: String {
        if model.progress.isComplete { return "All set." }
        if model.progress.current == .model { return "Finish model setup." }
        if model.progress.endedWithGaps { return "That's everything I can ask for." }
        return "Hey, I'm Benji."
    }

    private var subhead: String {
        let p = model.progress
        if p.isComplete {
            return "Tap Right Option when you need me; otherwise I'll stay out of the way."
        }
        if p.current == .model {
            return "Check the model source below before your first message."
        }
        if p.endedWithGaps {
            return "Your model is configured. What you didn't allow stays off until you switch it on in System Settings."
        }
        return "I need a few permissions and a model to answer you. We'll go one at a time; permissions you skip stay off."
    }

    private var footer: some View {
        HStack {
            if !model.progress.isComplete {
                Text("Grant these to Benji itself, not to Terminal or another app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.progress.isComplete || model.progress.endedWithGaps {
                Button("Done") { model.actions.close() }
                    .keyboardShortcut(.defaultAction)
                    .benjiPrimaryButton()
            } else {
                Button("Not now") { model.actions.close() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityHint("Closes setup. You can reopen it from the Benji menu.")
            }
        }
    }
}

/// The Done checkmark: the one bounce in Benji (`motion-done`), still under Reduce Motion.
private struct DoneMark: View {
    let reduceMotion: Bool
    @State private var bounces = 0

    var body: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 40))
            .foregroundStyle(.green)
            .symbolEffect(.bounce.up, value: bounces)
            .onAppear { if !reduceMotion { bounces += 1 } }
            .accessibilityHidden(true)
    }
}

private struct StepRow: View {
    let step: SetupStep
    @ObservedObject var model: PermissionSetupModel
    let isCurrent: Bool

    private var status: PermissionStatus { model.progress.status(of: step) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: symbol)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
                    .frame(width: 20)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(step.title)
                        .font(isCurrent ? .body.weight(.semibold) : .body)
                    Text(step.purpose)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                StatusBadge(step: step, status: status)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(step.title). \(step.purpose)")
            .accessibilityValue(step.isRequired ? status.word : "Asked when needed")
            .accessibilityAddTraits(isCurrent ? .isSelected : [])

            if isCurrent {
                detail.padding(.leading, 30)
                    .transition(.opacity)
            } else if status == .denied {
                DeniedHelp(step: step, model: model).padding(.leading, 30)
            } else if step == .automation {
                Button("Review in System Settings") { model.actions.openSettings(.automation) }
                    .buttonStyle(.link)
                    .font(.callout)
                    .padding(.leading, 30)
            }
        }
        .padding(.vertical, 4)
    }

    private var symbol: String {
        switch step {
        case .accessibility: return "accessibility"
        case .voice: return "mic.fill"
        case .screenRecording: return "rectangle.dashed.badge.record"
        case .automation: return "applescript"
        case .model: return "key.fill"
        }
    }

    @ViewBuilder private var detail: some View {
        switch step {
        case .accessibility: AccessibilityDetail(model: model)
        case .voice: VoiceDetail(model: model)
        case .screenRecording: ScreenDetail(model: model)
        case .automation, .model: EmptyView()
        }
    }
}

private struct StatusBadge: View {
    let step: SetupStep
    let status: PermissionStatus

    var body: some View {
        Group {
            if !step.isRequired {
                Label("When needed", systemImage: "circle.dashed")
                    .foregroundStyle(.secondary)
            } else {
                switch status {
                case .granted:
                    Label { Text(status.word) } icon: {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                case .notYet:
                    Label(status.word, systemImage: "circle.dashed")
                        .foregroundStyle(.secondary)
                case .denied:
                    Label { Text(status.word) } icon: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.orange)
                    }
                }
            }
        }
        .font(.callout)
        .labelStyle(.titleAndIcon)
        .fixedSize()
    }
}

private struct AccessibilityDetail: View {
    @ObservedObject var model: PermissionSetupModel

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            AppDragTile(icon: model.appIcon, url: model.appURL)
                .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 8) {
                Text("Open Settings and switch Benji on in the Accessibility list. If Benji isn't listed, drag me into it.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button("Open Accessibility Settings") { model.openAccessibilitySettings() }
                        .keyboardShortcut(.defaultAction)
                        .benjiPrimaryButton()
                    Button("Ask macOS instead") { model.actions.promptAccessibility() }
                        .buttonStyle(.link)
                        .accessibilityHint("Shows the macOS Accessibility prompt for Benji.")
                }
            }
        }
    }
}

private struct VoiceDetail: View {
    @ObservedObject var model: PermissionSetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("macOS will ask twice: once for the microphone, once for speech recognition.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Button("Allow Microphone and Speech") { model.actions.requestVoice() }
                .keyboardShortcut(.defaultAction)
                .benjiPrimaryButton()
        }
    }
}

private struct ScreenDetail: View {
    @ObservedObject var model: PermissionSetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.screenRecordingAsked {
                Text("Switch Benji on under Screen & System Audio Recording. macOS applies it after Benji restarts, so relaunch once it's on.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button("Relaunch Benji") { model.actions.relaunch() }
                        .keyboardShortcut(.defaultAction)
                        .benjiPrimaryButton()
                        .accessibilityHint("Quits and reopens Benji. Setup continues where you left off.")
                    Button("Open Screen Recording Settings") { model.actions.openSettings(.screenRecording) }
                        .buttonStyle(.link)
                }
            } else {
                Text("macOS shows its purple indicator whenever I look.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Allow Screen Recording") { model.actions.requestScreenRecording() }
                    .keyboardShortcut(.defaultAction)
                    .benjiPrimaryButton()
            }
        }
    }
}

/// 500 pt with scrolling for long content; otherwise the grouped form's own height.
private struct SetupFormHeight: ViewModifier {
    let roomy: Bool
    func body(content: Content) -> some View {
        if roomy {
            content.frame(height: 500)
        } else {
            content.scrollDisabled(true).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// "Step 2 of 4" and one short capsule per required step: granted green, turned off orange, the
/// current one in the system accent colour.
private struct SetupProgressBar: View {
    let progress: SetupProgress
    let number: Int
    let current: SetupStep

    var body: some View {
        let steps = SetupProgress.requiredSteps
        HStack(spacing: 10) {
            Text("Step \(number) of \(steps.count)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 4) {
                ForEach(steps, id: \.self) { step in
                    Capsule().fill(color(step)).frame(width: 22, height: 4)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(number) of \(steps.count): \(current.title)")
        .accessibilityValue("\(steps.filter { progress.status(of: $0) == .granted }.count) done")
    }

    private func color(_ step: SetupStep) -> Color {
        if step == current { return .accentColor }
        switch progress.status(of: step) {
        case .granted: return .green
        case .denied: return .orange
        case .notYet: return Color.secondary.opacity(0.3)
        }
    }
}

/// The setup window while System Settings shows the Accessibility list: small, movable and above
/// Settings, with Benji's labelled tile to drag in if Benji is missing. It never decides that access
/// was given; the probe does, and setup then moves on by itself.
private struct AccessibilityHelper: View {
    @ObservedObject var model: PermissionSetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "accessibility")
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                Text("Switch Benji on")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                if let number = model.progress.stepNumber {
                    Text("Step \(number) of \(SetupProgress.requiredSteps.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text("In the Accessibility list, turn on the switch next to Benji. If Benji isn't listed, drag this tile into the list.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            AppDragTile(icon: model.appIcon, url: model.appURL, title: "Benji", caption: "Drag into the list if it's missing")
                .frame(height: 52)
            Label("Not on yet. This moves on by itself once macOS reports Benji is on.", systemImage: "circle.dashed")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                Button("Open Accessibility Settings") { model.openAccessibilitySettings() }
                    .keyboardShortcut(.defaultAction)
                    .benjiPrimaryButton()
                Button("Ask macOS instead") { model.actions.promptAccessibility() }
                    .buttonStyle(.link)
                    .accessibilityHint("Shows the macOS Accessibility prompt for Benji.")
            }
            Divider()
            HStack {
                Button("Back to full setup") { model.showFullSetup() }
                    .buttonStyle(.link)
                    .accessibilityHint("Shows every step again.")
                Spacer()
                Button("Not now") { model.actions.close() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityHint("Closes setup. You can reopen it from the Benji menu.")
            }
        }
        .padding(16)
        .frame(width: 320)
    }
}

private struct DeniedHelp: View {
    let step: SetupStep
    @ObservedObject var model: PermissionSetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(step.fixHint)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open System Settings") { model.actions.openSettings(step) }
                .buttonStyle(.link)
                .font(.callout)
        }
    }
}

private extension View {
    /// The primary action: Liquid Glass on macOS 26, the standard prominent button on earlier macOS.
    @ViewBuilder func benjiPrimaryButton() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - drag source

/// Benji's icon as a drag source holding the app bundle's file URL, which System Settings'
/// Accessibility list accepts as a drop. Mouse only; "Ask macOS instead" is the keyboard path.
struct AppDragTile: NSViewRepresentable {
    let icon: NSImage
    let url: URL
    /// A labelled tile (the Accessibility helper): the icon with Benji's name and a caption beside it.
    var title: String? = nil
    var caption: String? = nil

    func makeNSView(context: Context) -> AppDragSourceView {
        AppDragSourceView(icon: icon, url: url, title: title, caption: caption)
    }
    func updateNSView(_ view: AppDragSourceView, context: Context) {
        view.icon = icon
        view.url = url
    }
}

final class AppDragSourceView: NSView, NSDraggingSource {
    override var mouseDownCanMoveWindow: Bool { false }
    var icon: NSImage { didSet { needsDisplay = true } }
    var url: URL
    private let title: String?
    private let caption: String?

    init(icon: NSImage, url: URL, title: String? = nil, caption: String? = nil) {
        self.icon = icon
        self.url = url
        self.title = title
        self.caption = caption
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(title == nil ? "Benji app icon" : "Benji app tile")
        setAccessibilityHelp("Drag into the Accessibility list in System Settings if Benji isn't listed there.")
        toolTip = "Drag Benji into the Accessibility list"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Where the icon is drawn: the whole view, or the tile's left square.
    private var iconRect: CGRect {
        guard title != nil else { return bounds }
        let side = bounds.height - 12
        return CGRect(x: 8, y: 6, width: side, height: side)
    }

    override func draw(_ dirtyRect: NSRect) {
        if let title {
            let tile = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
            NSColor.controlBackgroundColor.setFill()
            tile.fill()
            NSColor.separatorColor.setStroke()
            tile.stroke()
            let x = iconRect.maxX + 10
            let name = NSAttributedString(string: title, attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold), .foregroundColor: NSColor.labelColor])
            let note = NSAttributedString(string: caption ?? "", attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.secondaryLabelColor])
            name.draw(at: CGPoint(x: x, y: bounds.midY + 1))
            note.draw(at: CGPoint(x: x, y: bounds.midY - note.size().height - 1))
        }
        icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1)
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func mouseDown(with event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(iconRect, contents: icon)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .link, .generic] : []
    }
}
