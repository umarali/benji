import SwiftUI
import BenjiCore

/// What the settings page shows and does: a snapshot read from the app, and changes handed back
/// to it. After each change the snapshot is read again, so the page always shows what the app
/// actually did (a permission the system refused stays as it was).
final class SettingsModel: ObservableObject {
    @Published private(set) var snapshot: SettingsSnapshot
    @Published var section: SettingsSection = .general {
        didSet { memoryShown = false }
    }
    /// The Memory page is showing instead of `section` (it isn't a `SettingsSection`).
    @Published var memoryShown = false

    var pane: SettingsPane { memoryShown ? .memory : .section(section) }

    func select(_ pane: SettingsPane) {
        switch pane {
        case .section(let s): section = s
        case .memory: memoryShown = true
        }
    }

    var load: () -> SettingsSnapshot
    var apply: (SettingsChange) -> Void

    init(load: @escaping () -> SettingsSnapshot = { SettingsSnapshot() },
         apply: @escaping (SettingsChange) -> Void = { _ in }) {
        self.load = load
        self.apply = apply
        snapshot = load()
    }

    func refresh() {
        let fresh = load()
        if fresh != snapshot { snapshot = fresh }
    }

    func change(_ change: SettingsChange) {
        apply(change)
        refresh()
    }

    func toggle(_ value: KeyPath<SettingsSnapshot, Bool>, _ make: @escaping (Bool) -> SettingsChange) -> Binding<Bool> {
        Binding(get: { self.snapshot[keyPath: value] }, set: { self.change(make($0)) })
    }
}

/// The settings page inside the open notch: sections down the left, the chosen one's cards on the
/// right. Drawn like the rest of the open object (notch palette, dark appearance); every control
/// here is plain SwiftUI, so it renders offscreen too (tools/settings-render).
struct SettingsPage: View {
    @ObservedObject var model: SettingsModel
    let a: NotchAccessibility
    /// Off only for offscreen renders, which can't draw a scroll view.
    var scrolls = true
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            sidebar
                .frame(width: 150)
            Rectangle().fill(NotchPalette.hairline(a)).frame(width: 1)
                .padding(.trailing, 16)
            if model.memoryShown {
                MemorySettingsView(model: model, a: a, scrolls: scrolls)
            } else {
                SettingsSectionView(model: model, section: model.section, a: a, scrolls: scrolls)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings")
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsPane.all) { pane in
                SidebarRow(pane: pane, selected: pane == model.pane, a: a) {
                    model.select(pane)
                }
            }
            Spacer(minLength: 8)
            Button(action: onClose) {
                Label("Back", systemImage: "chevron.left")
                    .font(.callout)
                    .foregroundStyle(NotchPalette.secondary(a))
            }
            .buttonStyle(.plain)
            .help("Back to the conversation (Escape)")
            if !model.snapshot.version.isEmpty {
                Text(model.snapshot.version)
                    .font(.caption)
                    .foregroundStyle(NotchPalette.secondary(a))
                    .padding(.top, 6)
            }
        }
        .padding(.trailing, 12)
        .padding(.top, 2)
    }
}

private struct SidebarRow: View {
    let pane: SettingsPane
    let selected: Bool
    let a: NotchAccessibility
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: pane.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)
                Text(pane.title)
                    .font(.body.weight(selected ? .semibold : .regular))
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? NotchPalette.label : NotchPalette.secondary(a))
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? NotchPalette.raised : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// One section: its title, a line under it, and cards of rows.
struct SettingsSectionView: View {
    @ObservedObject var model: SettingsModel
    let section: SettingsSection
    let a: NotchAccessibility
    var scrolls = true

    private var s: SettingsSnapshot { model.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(section.title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(NotchPalette.label)
                .accessibilityAddTraits(.isHeader)
            Text(section.subtitle)
                .font(.callout)
                .foregroundStyle(NotchPalette.secondary(a))
            if scrolls {
                ScrollView(.vertical, showsIndicators: false) { cards }
            } else {
                cards
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var cards: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch section {
            case .general: general
            case .voice: voice
            case .screen: screen
            case .browser: browser
            case .shortcuts: shortcuts
            case .permissions: permissions
            }
        }
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    @ViewBuilder private var general: some View {
        SettingsCard(header: "Answers", a: a) {
            SettingsRow(title: "Draw things in 3D",
                        detail: "When you ask how something is built, Benji also shows it as a labelled 3D figure. Applies from your next message.",
                        a: a) {
                SwitchControl(title: "Draw things in 3D", isOn: model.toggle(\.figures, SettingsChange.figures))
            }
            SettingsRow(title: "Read answers aloud",
                        detail: "Typed messages too. Spoken ones are always answered out loud.", a: a) {
                SwitchControl(title: "Read answers aloud", isOn: model.toggle(\.readAloud, SettingsChange.readAloud))
            }
        }
        SettingsCard(header: "Background jobs", a: a, footer: JobCopy.schedulesFooter) {
            SettingsRow(title: "Run repeating jobs", detail: JobCopy.schedulesDetail, a: a) {
                SwitchControl(title: "Run repeating jobs", isOn: model.toggle(\.schedulesOn, SettingsChange.schedules))
            }
        }
        SettingsCard(header: "Model", a: a, footer: modelFooter) {
            ForEach(ModelChoice.allCases, id: \.self) { choice in
                RadioRow(title: choice.title, caption: nil, selected: choice == s.model, a: a) {
                    model.change(.model(choice))
                }
            }
        }
        .disabled(!s.modelApplies)
        .opacity(s.modelApplies ? 1 : 0.6)
        SettingsCard(header: "Drawings", a: a) {
            SettingsRow(title: "Show drawings in screenshots",
                        detail: "Screenshots and recordings can include Benji's marks. What Benji sends to the model never does.",
                        a: a) {
                SwitchControl(title: "Show drawings in screenshots",
                              isOn: model.toggle(\.drawingsInScreenshots, SettingsChange.drawingsInScreenshots))
            }
            SettingsRow(title: PointerCompanion.settingTitle, detail: PointerCompanion.settingCaption, a: a) {
                SwitchControl(title: PointerCompanion.settingTitle,
                              isOn: model.toggle(\.pointerCompanion, SettingsChange.pointerCompanion))
            }
        }
        SettingsCard(header: "Starting up", a: a) {
            SettingsRow(title: "Open Benji at login", detail: s.openAtLoginCaption, a: a) {
                SwitchControl(title: "Open Benji at login", isOn: model.toggle(\.openAtLogin, SettingsChange.openAtLogin))
            }
        }
        SettingsCard(header: "Your API key", a: a, footer: s.keyMoveNote ?? KeyCopy.footer) {
            SettingsRow(title: "Where it is kept", detail: s.keyStorage.line, a: a) {
                if s.keyStorage.offersMove {
                    Button("Move to the Keychain") { model.change(.moveKeysToKeychain) }
                        .buttonStyle(CapsuleButtonStyle())
                        .help("Copies your key into the macOS Keychain, checks it, and takes it out of ~/.benji.env. Nothing moves until you press this.")
                }
            }
        }
        SettingsCard(header: BenjiFolderCopy.header, a: a, footer: s.homeNote ?? BenjiFolderCopy.footer) {
            SettingsRow(title: BenjiFolderCopy.title, detail: BenjiFolderCopy.detail, a: a) {
                Button(BenjiFolderCopy.button) { model.change(.showBenjiFolder) }
                    .buttonStyle(CapsuleButtonStyle())
                    .help(BenjiFolderCopy.help)
            }
        }
        SettingsCard(header: "Diagnostics", a: a, footer: s.diagnostics.note) {
            SettingsRow(title: DiagnosticsCopy.title, detail: DiagnosticsCopy.detail, a: a) {
                Button(s.diagnostics == .working ? "Working…" : "Copy") { model.change(.copyDiagnostics) }
                    .buttonStyle(CapsuleButtonStyle())
                    .disabled(s.diagnostics == .working)
                    .help("Puts a short report of the last 24 hours on the clipboard. It holds no message text.")
            }
        }
    }

    private var modelFooter: String {
        let sends = s.modelDestination.isEmpty ? "" : "Your messages go to \(s.modelDestination). "
        guard s.modelApplies else {
            let inUse = s.modelInUse.isEmpty ? "" : "Model: \(s.modelInUse). "
            return sends + inUse + "Model sources added in Guided setup are kept in app settings and take precedence over BENJI_PROVIDER, BENJI_MODEL and BENJI_BASE_URL in ~/.benji.env."
        }
        let inUse = s.modelInUse.isEmpty ? "" : "In use: \(s.modelInUse). "
        return sends + inUse + "A change applies from your next message."
    }

    @ViewBuilder private var voice: some View {
        SettingsCard(header: "Conversation", a: a,
                     footer: s.handsFreeAvailable ? nil : "A conversation needs on-device transcription.") {
            SettingsRow(title: "Listen while Benji is open",
                        detail: s.keepListeningWhenClosed
                            ? "Opening Benji starts a conversation. It goes on until you say “that's all” or go quiet."
                            : "The mic stays on until you close Benji, say “that's all”, or go quiet.", a: a) {
                SwitchControl(title: "Listen while Benji is open",
                              isOn: model.toggle(\.listenWhileOpen, SettingsChange.listenWhileOpen))
            }
            SettingsRow(title: "Keep listening when the panel closes",
                        detail: "A conversation goes on in the notch after you close the panel. Closing never starts one; hiding Benji or the talk key ends it.", a: a) {
                SwitchControl(title: "Keep listening when the panel closes",
                              isOn: model.toggle(\.keepListeningWhenClosed, SettingsChange.keepListeningWhenClosed))
            }
            SettingsRow(title: "Hold back words heard over other apps' sound",
                        detail: "While another app plays out loud, what the mic hears may not be you.", a: a) {
                SwitchControl(title: "Hold back words heard over other apps' sound",
                              isOn: model.toggle(\.holdBack, SettingsChange.holdBack))
            }
            SettingsRow(title: "Talk over Benji to interrupt", detail: s.bargeInCaption, a: a) {
                ChoiceControl(choices: BargeInMode.allCases, selected: s.bargeIn, label: \.title, spoken: \.title, a: a) {
                    model.change(.bargeIn($0))
                }
            }
            SettingsRow(title: "Stop listening after quiet", detail: nil, a: a) {
                ChoiceControl(choices: s.idleTimeoutChoices, selected: s.idleTimeout,
                              label: { "\(Int($0 / 60)) min" }, spoken: SettingsSnapshot.minutes, a: a) {
                    model.change(.idleTimeout($0))
                }
            }
        }
        .disabled(!s.handsFreeAvailable)
        .opacity(s.handsFreeAvailable ? 1 : 0.6)
        SettingsCard(header: "Speech", a: a, footer: s.voiceStatus.caption) {
            SettingsRow(title: "Transcription", detail: nil, a: a) { ValueText(s.transcription, a: a) }
            if s.voiceStatus == .kokoro {
                SettingsRow(title: "Voice", detail: s.voice, a: a) { EmptyView() }
                SettingsRow(title: "Speed", detail: nil, a: a) {
                    ChoiceControl(choices: KokoroSpeed.choices, selected: s.voiceSpeed, label: KokoroSpeed.label,
                                  spoken: KokoroSpeed.label, a: a) {
                        model.change(.kokoroSpeed($0))
                    }
                }
            } else {
                SettingsRow(title: "Voice", detail: s.voice, a: a) {
                    Button("Better voices…") { model.change(.downloadVoices) }
                        .buttonStyle(CapsuleButtonStyle())
                        .help("Opens Spoken Content in System Settings, where Manage Voices downloads Enhanced and Premium voices.")
                }
            }
        }
        SettingsCard(header: "Sounds", a: a, footer: CueCopy.footer) {
            SettingsRow(title: "Play quiet cues", detail: CueCopy.detail, a: a) {
                SwitchControl(title: "Play quiet cues", isOn: model.toggle(\.cuesOn, SettingsChange.cues))
            }
        }
        SettingsCard(header: "App offers", a: a, footer: AppOfferCopy.footer) {
            SettingsRow(title: "Offer help in apps", detail: AppOfferCopy.detail, a: a) {
                SwitchControl(title: "Offer help in apps", isOn: model.toggle(\.appOffersOn, SettingsChange.appOffers))
            }
            if !s.appOffersDeclined.isEmpty {
                SettingsRow(title: "Turned down", detail: s.appOffersDeclined.joined(separator: ", "), a: a) {
                    Button("Ask again") { model.change(.resetAppOffers) }
                        .buttonStyle(CapsuleButtonStyle())
                        .help("Benji may offer these apps again")
                }
            }
        }
        if s.voiceStatus == .kokoro { voicePicker }
    }

    /// Kokoro's voices, female then male, each with a Preview.
    @ViewBuilder private var voicePicker: some View {
        let female = s.voiceChoices.filter { $0.kind == .female }
        let male = s.voiceChoices.filter { $0.kind == .male }
        if !female.isEmpty {
            SettingsCard(header: "Female voices", a: a) {
                ForEach(female) { voice in voiceRow(voice) }
            }
        }
        if !male.isEmpty {
            SettingsCard(header: "Male voices", a: a, footer: voiceFooter) {
                ForEach(male) { voice in voiceRow(voice) }
            }
        }
    }

    private func voiceRow(_ voice: KokoroVoice) -> some View {
        VoiceChoiceRow(voice: voice, selected: voice.id == s.voiceChosen, a: a,
                       choose: { model.change(.kokoroVoice(voice.id)) },
                       preview: { model.change(.previewVoice(voice.id)) })
    }

    private var voiceFooter: String {
        s.voiceNote ?? "A new voice speaks from Benji's next answer; one already playing finishes in its voice. Everything stays on this Mac."
    }

    @ViewBuilder private var screen: some View {
        SettingsCard(header: "Let Benji see your screen", a: a,
                     footer: s.screenUnavailable.map { ScreenCapturePolicy.noVisionNote(model: $0) }
                        ?? "Benji looks only at the display you're working on, for the message you send. While Screen is On, a purple dot shows beside the notch.") {
            ForEach(ScreenMode.allCases, id: \.self) { mode in
                RadioRow(title: mode.title, caption: s.screenCaptions[mode], selected: mode == s.screenMode, a: a) {
                    model.change(.screenMode(mode))
                }
            }
            .disabled(s.screenUnavailable != nil)
            .opacity(s.screenUnavailable != nil ? 0.6 : 1)
        }
        SettingsCard(header: "Acting on your screen", a: a, footer: ScreenAutonomy.settingsFooter) {
            RadioRow(title: ScreenAutonomy.simpleTitle, caption: ScreenAutonomy.simpleCaption,
                     selected: s.screenSimpleSteps, a: a) { model.change(.screenSimpleSteps(true)) }
            RadioRow(title: ScreenAutonomy.askTitle, caption: ScreenAutonomy.askCaption,
                     selected: !s.screenSimpleSteps, a: a) { model.change(.screenSimpleSteps(false)) }
        }
    }

    /// Browser reach for background jobs (D-143, D-171): off until the user turns it on; each browser is
    /// its own opt-in, and reading, acting and the "always allow reading" list are separate things.
    @ViewBuilder private var browser: some View {
        SettingsCard(header: "Browser", a: a, footer: s.browserError ?? BrowserCopy.footer) {
            SettingsRow(title: "Let background jobs use my browser", detail: BrowserCopy.switchDetail, a: a) {
                SwitchControl(title: "Let background jobs use my browser",
                              isOn: model.toggle(\.browserOn, SettingsChange.browser))
            }
            if s.browserOn {
                SettingsRow(title: "Connection", detail: BrowserCopy.connectionDetail(s.browserStatus), a: a) {
                    ValueText(s.browserStatus.word, a: a)
                }
            }
        }
        if s.browserOn {
            SettingsCard(header: "Browsers", a: a, footer: BrowserCopy.browsersFooter) {
                if s.browsers.isEmpty {
                    SettingsRow(title: "No supported browser found", detail: "Chrome, Chrome Beta, Brave, Edge and Arc are supported.", a: a) { EmptyView() }
                }
                ForEach(s.browsers) { row in
                    SettingsRow(title: row.browser.name,
                                detail: [row.registered ? BrowserSetup.steps(for: row.browser) : nil, row.browser.caveat]
                                    .compactMap { $0 }.joined(separator: " "), a: a) {
                        SwitchControl(title: "Use Benji in \(row.browser.name)",
                                      isOn: Binding(get: { row.registered },
                                                    set: { model.change(.browserUse(row.browser.id, $0)) }))
                    }
                }
                SettingsRow(title: "Benji's extension", detail: BrowserCopy.setupDetail, a: a) {
                    Button("Show folder") { model.change(.showBrowserExtension) }
                        .buttonStyle(CapsuleButtonStyle())
                        .help("Shows the browser-extension folder in Finder.")
                }
            }
            SettingsCard(header: BrowserCopy.alwaysTitle, a: a, footer: BrowserCopy.alwaysFooter) {
                SettingsRow(title: BrowserCopy.alwaysTitle, detail: BrowserCopy.alwaysDetail, a: a) { EmptyView() }
                ForEach(s.browserAlways, id: \.self) { origin in
                    SettingsRow(title: BrowserAlways.line(origin), detail: nil, a: a) {
                        Button("Remove") { model.change(.browserAlwaysRemove(origin)) }
                            .buttonStyle(CapsuleButtonStyle())
                            .accessibilityLabel("Stop always allowing \(BrowserAlways.line(origin))")
                    }
                }
                AlwaysAllowAdd(a: a) { model.change(.browserAlwaysAdd($0)) }
            }
        }
    }

    @ViewBuilder private var shortcuts: some View {
        SettingsCard(header: "Talk", a: a,
                     footer: "Tap to start talking and again to send, or hold the talk key while you speak.") {
            SettingsRow(title: "Talk key", detail: nil, a: a) { KeyCap(s.talkKey ?? "Off", a: a) }
        }
    }

    @ViewBuilder private var permissions: some View {
        SettingsCard(header: "macOS permissions", a: a) {
            ForEach(s.permissions) { row in
                SettingsRow(title: row.permission.title,
                            detail: row.permission.purpose.prefix(1).uppercased() + row.permission.purpose.dropFirst() + ".",
                            a: a) {
                    if row.granted {
                        Label("Allowed", systemImage: "checkmark.circle.fill")
                            .font(.callout)
                            .foregroundStyle(NotchPalette.secondary(a))
                    } else {
                        Button("Allow…") { model.change(.requestPermission(row.permission)) }
                            .buttonStyle(CapsuleButtonStyle(prominent: true))
                    }
                }
            }
        }
        HStack {
            Spacer()
            Button("Guided setup…") { model.change(.openPermissionSetup) }
                .buttonStyle(CapsuleButtonStyle())
        }
    }
}

// MARK: - Parts

/// A small uppercase header over a `notch-raised` card of rows, with hairlines between them.
struct SettingsCard<Content: View>: View {
    let header: String
    let a: NotchAccessibility
    var footer: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(header.uppercased())
                .font(.caption.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(NotchPalette.secondary(a))
                .padding(.leading, 4)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                _VariadicView.Tree(Separated(a: a)) { content }
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(NotchPalette.raised))
            if let footer {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(NotchPalette.secondary(a))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }
}

/// Puts a hairline between the rows of a card.
private struct Separated: _VariadicView_MultiViewRoot {
    let a: NotchAccessibility

    func body(children: _VariadicView.Children) -> some View {
        let last = children.last?.id
        ForEach(children) { child in
            child
            if child.id != last {
                Rectangle().fill(NotchPalette.hairline(a)).frame(height: 1).padding(.leading, 12)
            }
        }
    }
}

/// One choice of several: a mint check when chosen, an empty circle otherwise.
struct RadioRow: View {
    let title: String
    let caption: String?
    let selected: Bool
    let a: NotchAccessibility
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.mint : NotchPalette.secondary(a))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body).foregroundStyle(NotchPalette.label)
                    if let caption, !caption.isEmpty {
                        Text(caption).font(.callout).foregroundStyle(NotchPalette.secondary(a))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// A voice to choose, with a Preview button at the right that says one sentence in it.
struct VoiceChoiceRow: View {
    let voice: KokoroVoice
    let selected: Bool
    let a: NotchAccessibility
    let choose: () -> Void
    let preview: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            RadioRow(title: voice.name, caption: voice.character, selected: selected, a: a, choose: choose)
                .padding(.trailing, -12)
            Button("Preview", action: preview)
                .buttonStyle(CapsuleButtonStyle())
                .accessibilityLabel("Preview \(voice.name)")
                .help("Says one sentence in \(voice.name)'s voice")
                .padding(.trailing, 12)
        }
    }
}

/// A title, an optional line under it, and a control at the right.
struct SettingsRow<Control: View>: View {
    let title: String
    let detail: String?
    let a: NotchAccessibility
    @ViewBuilder let control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body).foregroundStyle(NotchPalette.label)
                if let detail, !detail.isEmpty {
                    Text(detail).font(.callout).foregroundStyle(NotchPalette.secondary(a))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            control
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

/// An on/off switch: mint when on (Benji's own colour), drawn here so it matches the notch.
struct SwitchControl: View {
    let title: String
    @Binding var isOn: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button { isOn.toggle() } label: {
            Capsule()
                .fill(isOn ? Color.mint : Color.white.opacity(0.18))
                .frame(width: 34, height: 20)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle().fill(Color.white).frame(width: 16, height: 16).padding(2)
                        .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                }
                .animation(.snappy(duration: 0.18), value: isOn)
                .opacity(isEnabled ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }
}

/// A row of capsules, one chosen.
struct ChoiceControl<Value: Hashable>: View {
    let choices: [Value]
    let selected: Value
    let label: (Value) -> String
    let spoken: (Value) -> String
    let a: NotchAccessibility
    let choose: (Value) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(choices, id: \.self) { value in
                let on = value == selected
                Button { choose(value) } label: {
                    Text(label(value))
                        .font(.callout.weight(on ? .semibold : .regular))
                        .lineLimit(1)
                        .fixedSize()
                        .foregroundStyle(on ? NotchPalette.label : NotchPalette.secondary(a))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(on ? Color.white.opacity(0.2) : .clear))
                        .overlay(Capsule().strokeBorder(NotchPalette.hairline(a), lineWidth: on ? 0 : 1))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(spoken(value))
                .accessibilityAddTraits(on ? [.isSelected] : [])
            }
        }
        .fixedSize()
    }
}

/// A capsule button on the notch: `notch-raised` grey, or the accent for the one thing to do.
struct CapsuleButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .foregroundStyle(prominent ? Color.black : NotchPalette.label)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Capsule().fill(prominent ? Color.mint : Color.white.opacity(0.14)))
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
            .contentShape(Capsule())
    }
}

private struct ValueText: View {
    let text: String
    let a: NotchAccessibility
    init(_ text: String, a: NotchAccessibility) { self.text = text; self.a = a }

    var body: some View {
        Text(text).font(.callout).foregroundStyle(NotchPalette.secondary(a)).lineLimit(1).truncationMode(.middle)
    }
}

private struct KeyCap: View {
    let text: String
    let a: NotchAccessibility
    init(_ text: String, a: NotchAccessibility) { self.text = text; self.a = a }

    var body: some View {
        Text(text)
            .font(.callout.weight(.medium))
            .foregroundStyle(NotchPalette.label)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.12)))
    }
}


/// A text field and an Add button for a site to always allow reading (D-171). The app and the engine
/// both check what is typed; a name that isn't an exact https site is not added.
struct AlwaysAllowAdd: View {
    let a: NotchAccessibility
    let add: (String) -> Void
    @State private var text = ""

    var body: some View {
        HStack(spacing: 8) {
            TextField("example.com", text: $text)
                .textFieldStyle(.plain)
                .font(.body)
                .foregroundStyle(NotchPalette.label)
                .onSubmit(commit)
                .accessibilityLabel("A site to always allow reading")
            Button("Add", action: commit)
                .buttonStyle(CapsuleButtonStyle(prominent: true))
                .disabled(BrowserAlways.origin(from: text) == nil)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private func commit() {
        guard BrowserAlways.origin(from: text) != nil else { return }
        add(text)
        text = ""
    }
}
