import SwiftUI
import BenjiCore

/// The notch object (D-60): one black shape continuous with the hardware notch, in four sizes.
/// Closed draws nothing but black; the peek shows a glyph wing, a state word and one line; the card
/// shows an offer (D-187); open is the full panel (transcript, disclosure, composer). Sizes and timing come from
/// `NotchPresenter`; this view only draws them.
struct CompanionView: View {
    @ObservedObject var model: CompanionModel
    @ObservedObject var presenter: NotchPresenter
    var onOpen: () -> Void
    /// The desktop's appearance (before the contents are forced dark): picks the shadow strength.
    @Environment(\.colorScheme) private var desktopScheme

    var body: some View {
        let a = presenter.accessibility
        let layout = presenter.layout
        let current = layout.shape(presenter.size)
        let outline = NotchOutline(current)
        let open = layout.shape(.open).frame.size

        // The window is often smaller than the open layout (closed and peek); overlays never size
        // their parent, so the oversized content hangs from the top edge instead of being centred.
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .top) {
                if presenter.size != .closed || layout.hasHardwareNotch { notchBody(outline, current, a) }
            }
            .overlay(alignment: .top) {
                if presenter.size != .closed || layout.hasHardwareNotch {
                    content(a, layout: layout)
                        .frame(width: open.width, height: open.height, alignment: .top)
                        .modifier(ClipUnlessReduced(outline: outline, reduce: a.reduceMotion))
                }
            }
            .contentShape(outline)
        .gesture(TapGesture().onEnded { onOpen() }, including: presenter.size == .peek ? .all : .subviews)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private func notchBody(_ outline: NotchOutline, _ shape: NotchShape, _ a: NotchAccessibility) -> some View {
        let shadow = NotchPalette.shadowOpacity(desktopScheme) * Double(shape.shadowOpacity)
        let body = outline
            .fill(NotchPalette.body)
            .shadow(color: .black.opacity(shadow), radius: 20, x: 0, y: 18)
            .opacity(Double(shape.opacity))
            .animation(NotchMotion.fadeIn, value: shape.opacity)
            .accessibilityHidden(true)
        if a.reduceMotion {
            // Geometry changes instantly underneath a 0.20 s crossfade.
            body.id(presenter.size).transition(.opacity)
        } else {
            body
        }
    }

    /// The open band's buttons, drawn by the wings so one layout owns the whole row.
    private var bandControls: BandControls {
        // Home from a conversation or the list, back to the conversation from home (⇧⌘H both
        // ways); from Settings it goes back to the page underneath (D-138). Nowhere to go (home
        // with nothing said): disabled.
        let home = model.settingsOpen ? model.panelPage
            : HomeView.toggleTarget(from: model.panelPage, hasLines: !model.state.lines.isEmpty)
        // Listening isn't "busy" here: the composer's mic stops it, and Stop would end the conversation.
        return BandControls(busy: model.state.isBusy && model.state.phase != .listening && model.state.phase != .transcribing,
                            speaking: model.state.phase == .speaking,
                            canStartNew: model.canStartNewConversation,
                            home: home, canGoHome: home != nil && (model.settingsOpen || model.canSwitchConversation),
                            settingsOpen: model.settingsOpen,
                            expanded: model.panelExpanded,
                            goHome: {
                                guard let home else { return }
                                if model.settingsOpen { model.closeSettings(); return }
                                model.showPage(home)
                            },
                            stop: { model.cancel() },
                            newConversation: { model.newConversation() },
                            settings: { model.settingsOpen ? model.closeSettings() : model.openSettings() },
                            toggleExpanded: { model.setPanelExpanded(!model.panelExpanded) },
                            collapse: { model.setExpanded(false) })
    }

    @ViewBuilder
    private func content(_ a: NotchAccessibility, layout: NotchLayoutInfo) -> some View {
        let notch = layout.notch.size
        let open = layout.shape(.open).frame.size
        let peek = layout.shape(.peek).frame.size
        ZStack(alignment: .top) {
            if presenter.layers.contains(.wings) {
                NotchWings(status: presenter.status, micLevel: model.micLevel, doneBounce: presenter.doneBounce,
                           a: a, notchWidth: notch.width, width: open.width, height: notch.height,
                           screenOn: model.screenModeInForce == .on,
                           controls: presenter.size == .open ? bandControls : nil)
                    .transition(.opacity)
            }
            if model.screenModeInForce == .on {
                // In every size, in the strip the closed notch grows by while On.
                ScreenOnDot(provider: model.providerID)
                    .offset(x: -(notch.width + PanelGeometry.indicatorWing) / 2)
                    .frame(width: open.width, height: notch.height)
                    .transition(.opacity)
            }
            if presenter.layers.contains(.line) {
                PeekLine(status: presenter.status, a: a)
                    .frame(width: peek.width - 32, height: peek.height - notch.height)
                    .padding(.top, notch.height)
                    .transition(.opacity)
            }
            if presenter.layers.contains(.offer), let offer = presenter.offerOnCard {
                let card = layout.shape(.card).frame.size
                AppOfferCard(offer: offer, a: a) { model.answerAppOffer($0, example: $1) }
                    .frame(width: card.width - 32, height: card.height - notch.height - 18, alignment: .top)
                    .padding(.top, notch.height + 8)
                    .transition(.opacity)
            }
            if presenter.layers.contains(.panel) {
                OpenPanel(model: model, presenter: presenter, a: a, bandHeight: notch.height)
                    .frame(width: open.width, height: open.height, alignment: .top)
                    .transition(.opacity)
            }
        }
        .accessibilityElement(children: presenter.size == .peek ? .combine : .contain)
        .accessibilityLabel(presenter.size == .peek
                            ? "Benji, \(presenter.status.word). \(presenter.status.line)" : "Benji")
        .accessibilityAddTraits(presenter.size == .peek ? .isButton : [])
        .accessibilityAction(named: "Open") { onOpen() }
    }
}

/// Content rides the shape's spring by sharing its clip; under Reduce Motion it is laid out
/// inside each size already and only crossfades.
private struct ClipUnlessReduced: ViewModifier {
    let outline: NotchOutline
    let reduce: Bool

    func body(content: Content) -> some View {
        if reduce { content } else { content.clipShape(outline) }
    }
}

// MARK: - Peek: wings and line

/// The open band's buttons (only in the open panel).
struct BandControls {
    /// Benji is working, speaking or waiting: the second slot is Stop, not New Conversation.
    var busy: Bool
    var speaking: Bool
    var canStartNew: Bool
    /// Where Home goes (home, or back to the conversation from home); nil: nowhere yet.
    var home: PanelPage?
    var canGoHome: Bool
    var settingsOpen: Bool
    /// The panel is at its expanded size: the control is Shrink.
    var expanded: Bool
    let goHome: () -> Void
    let stop: () -> Void
    let newConversation: () -> Void
    let settings: () -> Void
    let toggleExpanded: () -> Void
    let collapse: () -> Void
}

/// The band either side of the hardware notch (D-133). In the peek, the state glyph hugs the notch
/// on the left (with the mic meter while listening) and the state word sits right of it. In the
/// open panel the left wing holds navigation from the panel's left edge (Home, New conversation
/// or Stop, Settings) and the right wing the word, then Expand / Shrink and Collapse, ending at
/// the right edge (`BandLayout`). Every glyph shares one slot, symbol size and grey.
struct NotchWings: View {
    let status: NotchStatusInfo
    let micLevel: Float
    let doneBounce: Int
    let a: NotchAccessibility
    let notchWidth: CGFloat
    let width: CGFloat
    let height: CGFloat
    /// The Screen On dot sits next to the notch; the peek's glyph moves out past it.
    var screenOn = false
    /// Open panel only: the band's navigation and window controls.
    var controls: BandControls? = nil

    var body: some View {
        let wing = BandLayout.wing(openWidth: width, notchWidth: notchWidth)
        let tint = NotchPalette.tint(status.tint, a)
        HStack(spacing: 0) {
            ZStack {
                if let controls {
                    HStack(spacing: BandLayout.spacing) {
                        navigation(controls)
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, BandLayout.edge)
                    .transition(.opacity)
                } else {
                    HStack(spacing: BandLayout.spacing) {
                        Spacer(minLength: 0)
                        leading(tint)
                    }
                    .padding(.trailing, screenOn ? PanelGeometry.indicatorWing + 2 : BandLayout.notchGap)
                    .transition(.opacity)
                }
            }
            .frame(width: wing)
            .animation(a.reduceMotion ? nil : NotchMotion.fadeIn, value: status.status == .listening)

            Color.clear.frame(width: notchWidth)

            HStack(spacing: 0) {
                StatusWordLabel(word: status.word, tint: tint, reduceMotion: a.reduceMotion)
                    .frame(width: controls == nil ? BandLayout.peekWordWidth : BandLayout.wordWidth(wing: wing),
                           alignment: .leading)
                Spacer(minLength: BandLayout.wordGap)
                if let controls {
                    HStack(spacing: BandLayout.spacing) {
                        BandGlyphButton(symbol: "sidebar.left",
                                        label: controls.expanded ? "Hide recent conversations" : "Show recent conversations",
                                        help: controls.expanded ? "Hide recent conversations" : "Show recent conversations",
                                        a: a, toggled: controls.expanded, action: controls.toggleExpanded)
                        BandGlyphButton(symbol: "chevron.up", label: "Collapse panel", help: "Collapse", a: a,
                                        action: controls.collapse)
                    }
                    .padding(.trailing, BandLayout.edge)
                }
            }
            .padding(.leading, BandLayout.notchGap)
            .frame(width: wing)
        }
        .frame(width: width, height: height)
    }

    @ViewBuilder
    private func navigation(_ controls: BandControls) -> some View {
        HomeBandButton(target: controls.home, inSettings: controls.settingsOpen, a: a, action: controls.goHome)
            .disabled(!controls.canGoHome)
        if controls.busy {
            BandGlyphButton(symbol: "stop.fill", label: controls.speaking ? "Stop speaking" : "Stop",
                            help: controls.speaking ? "Stop speaking (Escape)" : "Stop (Escape)", a: a,
                            action: controls.stop)
        } else {
            BandGlyphButton(symbol: "square.and.pencil", label: "New conversation",
                            help: "New conversation: forget what was said so far", a: a,
                            action: controls.newConversation)
                .keyboardShortcut("n", modifiers: [.command])
                .disabled(!controls.canStartNew)
        }
        // Open Settings is drawn as selected, not as a back button; clicking it again closes it.
        BandGlyphButton(symbol: "gearshape", label: "Settings", help: controls.settingsOpen ? "Close Settings" : "Settings",
                        a: a, selected: controls.settingsOpen, action: controls.settings)
    }

    private var listening: Bool { status.status == .listening }

    /// The peek's glyph by the notch, with the mic meter while listening.
    private func leading(_ tint: Color) -> some View {
        HStack(spacing: 4) {
            StateGlyph(status: status, tint: tint, doneBounce: doneBounce, a: a)
            if listening {
                MicMeter(level: micLevel, reduceMotion: a.reduceMotion)
                    .transition(.opacity)
            }
        }
    }
}

/// Slot 1 in the band: the house from a conversation or the list, the back chevron to the
/// conversation from home and from Settings (to the page underneath, D-138); ⇧⌘H both ways, as
/// Finder's Home.
struct HomeBandButton: View {
    let target: PanelPage?
    var inSettings = false
    let a: NotchAccessibility
    let action: () -> Void

    var body: some View {
        let back = inSettings || target == .conversation
        let place = target == .conversation ? "the conversation" : target == .home ? "Home" : "the list"
        BandGlyphButton(symbol: back ? "chevron.backward" : "house", label: back ? "Back to \(place)" : "Home",
                        help: back ? "Back to \(place) (⇧⌘H)" : "Home: recent conversations (⇧⌘H)",
                        a: a, action: action)
            .keyboardShortcut("h", modifiers: [.command, .shift])
    }
}

extension BandGlyph {
    /// The font for a band or sidebar symbol: its scaled size at the band's weight.
    static func font(for symbol: String) -> Font {
        .system(size: fontSize(for: symbol), weight: .semibold)
    }
}

/// The state word: one label that fades the old word out before the new one fades in
/// (`StatusWordSwap`), so two words are never drawn on top of each other. Under Reduce Motion
/// it simply changes.
struct StatusWordLabel: View {
    let word: String
    let tint: Color
    let reduceMotion: Bool
    @State private var swap: StatusWordSwap
    @State private var shownTint: Color
    /// The newest word's tint, read when a fade-out finishes.
    @State private var latestTint: Color

    init(word: String, tint: Color, reduceMotion: Bool) {
        self.word = word
        self.tint = tint
        self.reduceMotion = reduceMotion
        _swap = State(initialValue: StatusWordSwap(word))
        _shownTint = State(initialValue: tint)
        _latestTint = State(initialValue: tint)
    }

    var body: some View {
        Text(swap.shown)
            .font(NotchFont.peekStatus)
            .tracking(0.2)
            .foregroundStyle(shownTint)
            .lineLimit(1)
            .minimumScaleFactor(BandLayout.minimumWordScale)   // only "Transcribing" ever needs it
            .truncationMode(.tail)
            .contentTransition(.identity)
            .opacity(swap.visible ? 1 : 0)
            .onChange(of: word) { _, new in change(to: new) }
            .onChange(of: tint) { _, new in
                latestTint = new
                if swap.pending == nil && swap.shown == word { shownTint = new }
            }
    }

    private func change(to new: String) {
        latestTint = tint
        var next = swap
        switch next.request(new, reduceMotion: reduceMotion) {
        case .none:
            swap = next
        case .show:
            var t = Transaction(animation: reduceMotion ? nil : NotchMotion.fadeIn)
            t.disablesAnimations = reduceMotion
            withTransaction(t) { swap = next; shownTint = tint }
        case .fadeOut:
            withAnimation(.easeIn(duration: MotionTokens.fadeDuration / 1.5)) { swap = next } completion: {
                // The old word is invisible now. The text itself changes without a transition
                // (`.identity`), so only the new word fades in.
                var after = swap
                after.fadedOut()
                var plain = Transaction()
                plain.disablesAnimations = true
                withTransaction(plain) { shownTint = latestTint }
                withAnimation(NotchMotion.fadeIn) { swap = after }
            }
        }
    }
}

/// The state's SF Symbol. Changes with the system's replace effect; Done nods once.
struct StateGlyph: View {
    let status: NotchStatusInfo
    let tint: Color
    let doneBounce: Int
    let a: NotchAccessibility

    /// Ready and working are Benji's own states: its arrow. Every other state keeps its symbol and
    /// semantic colour (listening, looking, approval, speaking, done, error).
    static func showsArrow(_ status: NotchStatus) -> Bool { status == .ready || status == .working }

    var body: some View {
        ZStack {
            if Self.showsArrow(status.status) {
                BenjiArrowMark(size: BandLayout.arrowSize, solid: a.increaseContrast || a.reduceTransparency)
                    .transition(.opacity)
            } else {
                Image(systemName: status.symbol)
                    .font(.system(size: BandLayout.symbolSize, weight: .semibold))
                    .foregroundStyle(tint)
                    .contentTransition(a.reduceMotion ? .opacity : .symbolEffect(.replace))
                    .symbolEffect(.bounce.up, options: .nonRepeating, value: doneBounce)
                    .symbolEffectsRemoved(a.reduceMotion)
                    .transition(.opacity)
            }
        }
        .frame(width: BandLayout.slot, height: BandLayout.slot)
        .animation(NotchMotion.content(a), value: status.symbol)
        .animation(NotchMotion.content(a), value: Self.showsArrow(status.status))
        .accessibilityHidden(true)
    }
}

/// The one `peek-line` below the notch. Live words keep their newest end visible; the working
/// step carries the shimmer while the assistant runs.
struct PeekLine: View {
    let status: NotchStatusInfo
    let a: NotchAccessibility

    var body: some View {
        Text(status.line)
            .font(NotchFont.peekLine)
            .foregroundStyle(color)
            .lineLimit(1)
            .truncationMode(status.status == .listening ? .head : .tail)
            // Swaps at once: a cross-fade drew the old and new line on top of each other.
            .contentTransition(.identity)
            .modifier(Shimmer(active: status.status == .working && !a.reduceMotion))
            .frame(maxWidth: .infinity)
    }

    private var color: Color {
        switch status.status {
        case .working, .transcribing: return NotchPalette.secondary(a)
        case .error: return NotchPalette.tint(.error, a)
        default: return NotchPalette.label
        }
    }
}

/// One sweep across the step words (1.4 s), then 0.6 s of rest; only while Working.
private struct Shimmer: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        if active {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                let cycle = MotionTiming.shimmerSweep + MotionTiming.shimmerRest
                let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycle)
                content.overlay {
                    if t < MotionTiming.shimmerSweep {
                        GeometryReader { geo in
                            let band = geo.size.width * 0.3
                            LinearGradient(colors: [.clear, .white.opacity(0.55), .clear],
                                           startPoint: .leading, endPoint: .trailing)
                                .frame(width: band)
                                .offset(x: -band + (geo.size.width + band) * t / MotionTiming.shimmerSweep)
                        }
                        .mask(content)
                    }
                }
            }
        } else {
            content
        }
    }
}

/// Four bars beside the mic glyph, from the real input level (0…1), in `state-listening`.
/// Under Reduce Motion the level updates at most four times a second.
struct MicMeter: View {
    let level: Float
    let reduceMotion: Bool
    @State private var shown: Float = 0
    @State private var shownAt = Date.distantPast
    private let profile: [Float] = [0.55, 1.0, 0.8, 0.5]

    var body: some View {
        let l = reduceMotion ? shown : level
        HStack(alignment: .center, spacing: 2) {
            ForEach(profile.indices, id: \.self) { i in
                Capsule()
                    .fill(Color.orange)
                    .frame(width: 3, height: 3 + CGFloat(max(min(l, 1), 0) * profile[i]) * 11)
            }
        }
        .frame(height: 14)
        .transaction { $0.animation = nil }
        .onChange(of: level) { _, new in
            guard reduceMotion, Date().timeIntervalSince(shownAt) >= 1 / MotionTiming.reduceMotionMeterHz else { return }
            shown = new
            shownAt = Date()
        }
        .accessibilityLabel("Microphone level")
        .accessibilityValue("\(Int(level * 100)) percent")
    }
}

// MARK: - Open

/// The full panel below the notch band: one quiet status line, the conversation (or home, or the
/// list), any card, then the composer. Expanded (D-133), a sidebar of recent conversations sits
/// left of all that. On the settings page, the band and the page.
struct OpenPanel: View {
    @ObservedObject var model: CompanionModel
    @ObservedObject var presenter: NotchPresenter
    let a: NotchAccessibility
    let bandHeight: CGFloat

    var body: some View {
        Group {
            if model.settingsOpen {
                VStack(alignment: .leading, spacing: 10) {
                    band
                    SettingsPage(model: model.settings, a: a) { model.closeSettings() }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
                .transition(.opacity)
            } else if model.panelExpanded {
                VStack(spacing: 0) {
                    band
                    HStack(spacing: 0) {
                        ConversationSidebar(model: model, a: a)
                            .frame(width: PanelGeometry.sidebarWidth)
                        conversation
                            .padding(.top, 10)
                            .padding(.leading, 20)
                            .padding(.trailing, 24)
                            .padding(.bottom, 20)
                    }
                }
                .transition(.opacity)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    band
                    conversation
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
                .transition(.opacity)
            }
        }
        .animation(NotchMotion.content(a), value: model.settingsOpen)
        .animation(NotchMotion.content(a), value: model.panelExpanded)
    }

    private var conversation: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let job = model.job {
                JobRowView(model: model, job: job, a: a)
                    .transition(.opacity)
            }
            if let line = statusLine {
                Text(line)
                    .font(.system(.callout, design: .rounded))
                    .foregroundStyle(NotchPalette.secondary(a))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity)
                    // Swaps at once: a cross-fade drew "Go on." over the longer conversation line.
                    .contentTransition(.identity)
                    .accessibilityLabel("Status: \(line)")
            }
            switch model.panelPage {
            case .conversation: NotchTranscript(model: model, a: a)
            case .home: HomePage(model: model, a: a).transition(.opacity)
            case .list: ConversationListPage(model: model, a: a).transition(.opacity)
            }
            QuietNotices(model: model, a: a)
            if model.pendingScreenSend != nil {
                ScreenSendCardView(question: ScreenCapturePolicy.confirmQuestion(provider: model.providerID,
                                                                                 display: model.captureTarget?.name),
                                   a: a) { model.decideScreenSend($0) }
                    .transition(a.reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
            }
            if let req = model.state.pendingApproval {
                // The card runs its own entrance, so it rises whether the panel was open already or
                // is fading in for this approval; out, it fades and the rows close the gap.
                ApprovalCardView(request: req, a: a, timeout: model.cardTimeout) { model.decideApproval($0, request: req.id) }
                    .id(req.id)
                    .transition(.asymmetric(insertion: .identity, removal: .opacity))
            }
            if model.panelDisplay?.name != nil && model.screenModeInForce != .off && model.pendingScreenSend == nil {
                DisplayChoiceRow(model: model, a: a)
            }
            Composer(model: model, a: a)
        }
        .animation(NotchMotion.content(a), value: model.includeOnce)
        .animation(NotchMotion.content(a), value: model.state.pendingApproval)
        .animation(NotchMotion.content(a), value: model.pendingScreenSend)
        .animation(NotchMotion.content(a), value: model.job == nil)
        .animation(NotchMotion.content(a), value: statusLine == nil)
        .animation(NotchMotion.content(a), value: model.panelPage)
    }

    /// The current step, how to stop listening, or why listening stopped; never the live words
    /// (they show in the transcript) or what a row or card already says.
    private var statusLine: String? {
        let info = NotchStatusInfo.make(model.state, doneHolding: presenter.isDoneHolding,
                                        conversation: model.conversationOn, note: model.statusNote)
        return NotchStatusInfo.openLine(info, state: model.state)
    }

    /// The band's row: its glyphs, the word and the buttons are drawn by `NotchWings`.
    private var band: some View {
        Color.clear.frame(height: bandHeight)
    }
}

/// The expanded panel's sidebar (D-133): "Recent" conversations (the open one highlighted, each a
/// click from being open; disabled while a turn runs) and "All conversations…". New conversation
/// and Settings live in the band in both sizes. Its icon column lines up with the band's glyphs.
struct ConversationSidebar: View {
    @ObservedObject var model: CompanionModel
    let a: NotchAccessibility

    var body: some View {
        let recents = HomeView.sidebar(model.history.summaries, now: Date())
        VStack(alignment: .leading, spacing: 2) {
            Text("RECENT")
                .font(.caption2.weight(.semibold))
                .tracking(0.3)
                .foregroundStyle(NotchPalette.secondary(a))
                .padding(.bottom, 4)
                .accessibilityAddTraits(.isHeader)
            if recents.rows.isEmpty {
                Text(HomeView.emptyLine(saving: model.history.saving))
                    .font(.caption)
                    .foregroundStyle(NotchPalette.secondary(a))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.trailing, 4)
            }
            VStack(spacing: 2) {
                ForEach(recents.rows) { row in
                    let current = row.id == model.history.currentID
                    ConversationSidebarRow(symbol: "bubble.left", title: row.title, detail: row.when, current: current, a: a,
                               help: current ? "Open now" : "Open this conversation and continue it") {
                        model.openConversation(row.id)
                    }
                    .accessibilityLabel(row.accessibilityLabel + (current ? ", open now" : ""))
                }
            }
            .disabled(!model.canSwitchConversation)
            Button { model.showPage(.list) } label: {
                Text(recents.more > 0 ? "All conversations (\(recents.rows.count + recents.more))…" : "All conversations…")
                    .font(.callout)
                    .foregroundStyle(NotchPalette.secondary(a))
                    .padding(.leading, BandLayout.slot + 8)
                    .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Every saved conversation, to open or delete")
            Spacer(minLength: 0)
        }
        .padding(.top, 10)
        .padding(.bottom, 16)
        .padding(.leading, PanelGeometry.sidebarIconColumn)
        .padding(.trailing, 8)
        .frame(maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .trailing) {
            Rectangle().fill(NotchPalette.hairline(a)).frame(width: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Conversations")
    }
}

/// One sidebar row: an icon in the band's slot, the title, and a quiet detail; a soft fill under
/// the pointer, and on the open conversation.
struct ConversationSidebarRow: View {
    let symbol: String
    let title: String
    let detail: String?
    let current: Bool
    let a: NotchAccessibility
    let help: String
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(BandGlyph.font(for: symbol))
                    .foregroundStyle(current ? Color.mint : NotchPalette.secondary(a))
                    .frame(width: BandLayout.slot)
                Text(title)
                    .font(.body)
                    .foregroundStyle(NotchPalette.label)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if let detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(NotchPalette.secondary(a))
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .padding(.trailing, 8)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(current || (hovering && isEnabled) ? NotchPalette.raised : .clear))
            .opacity(isEnabled || current ? 1 : 0.5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(isEnabled ? help : "Nothing to clear yet, or Benji is busy")
        .accessibilityLabel(title)
    }
}

/// One glyph button in the band: the band's slot and symbol size, no fill, no outline, the
/// secondary label colour (dimmed when disabled). `selected` draws the page it opens as current:
/// full label strength on a faint rounded fill. `toggled` is for a button that flips a state
/// (the sidebar): it is the on state, exposed to accessibility.
struct BandGlyphButton: View {
    let symbol: String
    let label: String
    let help: String
    let a: NotchAccessibility
    var selected = false
    var toggled: Bool? = nil
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(BandGlyph.font(for: symbol))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(selected ? NotchPalette.label : NotchPalette.secondary(a))
                .compositingGroup()
                .frame(width: BandLayout.slot, height: BandLayout.slot)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(selected ? Color.white.opacity(0.14) : .clear))
                .contentShape(Rectangle())
                .opacity(isEnabled ? 1 : 0.35)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected || toggled == true ? .isSelected : [])
        .accessibilityValue(toggled.map { $0 ? "On" : "Off" } ?? "")
    }
}

/// A control inside the open object: Liquid Glass on macOS 26, a `notch-raised` fill on 14–15
/// and under Reduce Transparency.
struct NotchIconButton: View {
    let symbol: String
    var tint: Color? = nil
    let label: String
    let help: String
    let a: NotchAccessibility
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint ?? NotchPalette.label)
                .frame(width: 16, height: 16)
        }
        .notchControlStyle(a)
        .help(help)
        .accessibilityLabel(label)
    }
}

extension View {
    @ViewBuilder
    func notchControlStyle(_ a: NotchAccessibility, prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *), !a.reduceTransparency {
            if prominent {
                self.buttonStyle(.glassProminent).buttonBorderShape(.circle).controlSize(.small)
            } else {
                self.buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.small)
            }
        } else {
            self.buttonStyle(RaisedButtonStyle(prominent: prominent))
        }
    }
}

/// Only the label, dimmed while pressed: no bezel, focus ring or hover plate of the system's own.
struct BareButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// The fallback for Liquid Glass: a plain `notch-raised` circle (mint for the send button).
struct RaisedButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(5)
            .background(Circle().fill(prominent ? Color.mint : NotchPalette.raised))
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
    }
}

// MARK: - Transcript

struct NotchTranscript: View {
    @ObservedObject var model: CompanionModel
    let a: NotchAccessibility
    /// One stable identity for the streaming line, so SwiftUI updates it in place.
    static let streamingID = UUID()
    private static let space = "transcript-viewport"
    /// The end marker's bottom edge in the visible area's own space: how far the latest line is
    /// below what shows is this minus the visible height.
    @State private var endY: CGFloat = 0

    var body: some View {
        GeometryReader { viewport in
            transcript(showsScrollButton: ScrollToLatest.shows(distanceFromBottom: endY - viewport.size.height))
        }
        .coordinateSpace(name: Self.space)
    }

    private func transcript(showsScrollButton: Bool) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    let rows = PanelTranscript.rows(model.state.lines, turns: model.state.turns,
                                                    busy: !model.canSendTyped)
                    if rows.isEmpty && model.partialTranscript.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Hey. What are we sorting?")
                                .font(NotchFont.greeting)
                                .foregroundStyle(NotchPalette.label)
                            if !hint.isEmpty {
                                Text(hint)
                                    .font(.callout)
                                    .foregroundStyle(NotchPalette.secondary(a))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.top, 4)
                    }
                    ForEach(TranscriptDays.items(rows, now: Date())) { item in
                        switch item {
                        case .dateLine(_, let title):
                            DateLine(title: title, a: a)
                                .transition(.opacity)
                        case .row(let row):
                            VStack(alignment: .leading, spacing: 4) {
                                TranscriptRow(line: row.line, a: a, screen: row.screen,
                                              thumbnail: row.screen?.attachmentID.flatMap { model.thumbnail(for: $0) },
                                              heard: row.heard)
                                if let footer = row.footer {
                                    TurnFooterView(footer: footer, a: a) { model.retry() }
                                        .transition(.opacity)
                                }
                            }
                            .transition(a.reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 6)))
                        }
                    }
                    if !model.streamingText.isEmpty {
                        // The reply as it streams (D-118): replaced by the answer's own line.
                        TranscriptRow(line: TranscriptLine(role: .assistant, text: model.streamingText,
                                                           id: NotchTranscript.streamingID), a: a)
                            .id("streaming")
                            .accessibilityAddTraits(.updatesFrequently)
                    } else if model.state.showsThinking {
                        ThinkingDots(a: a)
                            .id("thinking")
                            .transition(.opacity)
                    }
                    if !model.partialTranscript.isEmpty {
                        // What the on-device recogniser has heard so far; replaced by the sent line.
                        Text(model.partialTranscript)
                            .font(.body)
                            .italic()
                            .foregroundStyle(NotchPalette.secondary(a))
                            .accessibilityLabel("Heard so far: \(model.partialTranscript)")
                    }
                    Color.clear.frame(height: 1).id("bottom")
                        .background(GeometryReader { g in
                            Color.clear.preference(key: TranscriptEndKey.self, value: g.frame(in: .named(Self.space)).maxY)
                        })
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(NotchMotion.content(a), value: model.state.lines.count)
                .animation(NotchMotion.content(a), value: model.state.turns)
                .animation(NotchMotion.content(a), value: model.state.showsThinking)
            }
            .scrollIndicators(.automatic)
            .frame(maxHeight: .infinity)
            .onPreferenceChange(TranscriptEndKey.self) { endY = $0 }
            .overlay(alignment: .bottomTrailing) {
                if showsScrollButton {
                    ScrollToLatestButton(a: a) {
                        withAnimation(NotchMotion.content(a)) { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                    .padding(.bottom, 4)
                    .transition(.opacity)
                }
            }
            .animation(a.reduceMotion ? NotchMotion.reduce : (showsScrollButton ? NotchMotion.fadeIn : NotchMotion.fadeOut),
                       value: showsScrollButton)
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: model.partialTranscript) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: model.streamingText) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: model.state.lines.count) { _, _ in
                withAnimation(NotchMotion.content(a)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: model.state.turns) { _, _ in
                withAnimation(NotchMotion.content(a)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    private var hint: String {
        model.conversationOn ? "I'm listening. Say “that's all” when you're done, or type below." : model.pttHint
    }
}

private struct TranscriptEndKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// A thin line with the day between turns from different days (D-133).
struct DateLine: View {
    let title: String
    let a: NotchAccessibility

    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(NotchPalette.hairline(a)).frame(height: 1)
            Text(title)
                .font(.caption2)
                .foregroundStyle(NotchPalette.secondary(a))
                .lineLimit(1)
                .fixedSize()
            Rectangle().fill(NotchPalette.hairline(a)).frame(height: 1)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Bottom right of the transcript while scrolled up: back to the latest line.
struct ScrollToLatestButton: View {
    let a: NotchAccessibility
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.down")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(NotchPalette.label)
                .frame(width: 28, height: 28)
                .background(Circle().fill(NotchPalette.raised))
                .overlay(Circle().strokeBorder(NotchPalette.hairline(a)))
                .shadow(color: .black.opacity(0.45), radius: 6, y: 4)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Scroll to the latest")
        .accessibilityLabel("Scroll to the latest")
    }
}

/// One line of the conversation (TranscriptRow component).
struct TranscriptRow: View {
    let line: TranscriptLine
    let a: NotchAccessibility
    /// A screen picture went with this message: a small purple mark, the picture on click.
    var screen: PanelScreenMark? = nil
    var thumbnail: NSImage? = nil
    /// Your message reached the engine: a small check after it, like a read receipt.
    var heard = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            lead.frame(width: 12, height: 16)
            Text(displayText)
                .font(font)
                .foregroundStyle(textColor)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("\(accessibilityRole): \(line.role == .assistant ? PanelMarkdown.plain(line.text) : line.text)")
                .accessibilityValue(heard ? "Received" : "")
            if let screen {
                ScreenMark(mark: screen, thumbnail: thumbnail, a: a)
            }
            if heard {
                Image(systemName: "checkmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(NotchPalette.secondary(a))
                    .opacity(0.7)
                    .frame(height: 16)
                    .help("Benji has your message")
                    .accessibilityHidden(true)
                    .transition(.opacity)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
    }

    /// Answers render inline Markdown; everything else (the user's words, tools, errors) as typed.
    private var displayText: AttributedString {
        line.role == .assistant ? PanelMarkdown.attributed(line.text) : AttributedString(line.text)
    }

    @ViewBuilder private var lead: some View {
        switch line.role {
        case .user: glyph("chevron.right", NotchPalette.secondary(a))
        case .assistant: Circle().fill(Color.mint).frame(width: 6, height: 6)
        case .tool: glyph("circle.dotted", NotchPalette.secondary(a))
        case .system:
            if line.text.hasPrefix("Approved") { glyph("checkmark", .green) }
            else { glyph("xmark", NotchPalette.secondary(a)) }
        case .error: glyph("exclamationmark.triangle.fill", .red)
        case .attachment: glyph("viewfinder", .purple)
        }
    }

    private func glyph(_ name: String, _ color: Color) -> some View {
        Image(systemName: name).font(.system(size: 9, weight: .bold)).foregroundStyle(color)
    }

    private var font: Font {
        switch line.role {
        case .user, .assistant, .error: return .body
        case .tool: return NotchFont.mono
        case .system: return .callout
        case .attachment: return .caption
        }
    }

    private var textColor: Color {
        switch line.role {
        case .user, .assistant, .system: return NotchPalette.label
        case .tool, .attachment: return NotchPalette.secondary(a)
        case .error: return .red
        }
    }

    private var accessibilityRole: String {
        switch line.role {
        case .user: return "You"
        case .tool: return "Step"
        case .assistant: return "Benji"
        case .system: return "Note"
        case .error: return "Error"
        case .attachment: return "Attachment"
        }
    }
}

/// The sign that a picture of the screen went with a message. Its tooltip says what was sent and
/// to whom; a click shows the thumbnail (kept in memory only).
struct ScreenMark: View {
    let mark: PanelScreenMark
    let thumbnail: NSImage?
    let a: NotchAccessibility
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: {
            Image(systemName: "viewfinder")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(ScreenModeColors.on)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 1)
        .help(mark.summary)
        .accessibilityLabel("Sent with a picture of your screen")
        .accessibilityValue(mark.summary)
        .accessibilityHint(thumbnail == nil ? "" : "Shows the picture")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 240)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .accessibilityLabel("The picture of your screen that was sent")
                }
                Text(mark.summary).font(.caption).foregroundStyle(.secondary)
            }
            .padding(10)
        }
    }
}

// MARK: - Disclosure, approval, composer

/// Asked at send time when Screen is Ask: nothing is captured until Send. There is no
/// default button; only a deliberate click sends. In-panel Escape cancels the pending message
/// and restores its words only if the composer is empty.
/// Screen status and a one-message choice, shown only while more than one display is connected
/// (Off and a model that can't read images show nothing). Display names stay in the confirmation
/// and attachment details; the routine status row only says what will be sent.
struct DisplayChoiceRow: View {
    @ObservedObject var model: CompanionModel
    let a: NotchAccessibility

    var body: some View {
        let recording = model.state.micActive || model.state.phase == .transcribing
        let spokenName = recording ? model.voiceDisplay?.name : nil
        let name = model.panelDisplay?.name ?? "This display"
        HStack(spacing: 8) {
            if model.screenModeInForce == .on {
                Circle().fill(ScreenModeColors.on).frame(width: 6, height: 6).accessibilityHidden(true)
                Text("Screen on").fixedSize()
                    .foregroundStyle(NotchPalette.secondary(a))
                    .accessibilityLabel("Screen is On: this message sends a picture of \(spokenName ?? name)")
                Spacer(minLength: 0)
            } else if model.includeOnce != nil {
                Circle().fill(ScreenModeColors.on).frame(width: 6, height: 6).accessibilityHidden(true)
                Text("Included with next message").fixedSize()
                    .foregroundStyle(NotchPalette.label)
                Spacer(minLength: 8)
                Button("Don't include") { model.clearIncludeOnce() }
                    .buttonStyle(.plain).foregroundStyle(NotchPalette.tint(.mint, a)).fixedSize()
                    .help("Your next message asks first, as usual")
            } else {
                Text("Asks first").fixedSize()
                    .foregroundStyle(NotchPalette.secondary(a))
                Spacer(minLength: 8)
                Button("Include this display once") { model.includeDisplayOnce() }
                    .buttonStyle(.plain).foregroundStyle(NotchPalette.tint(.mint, a)).fixedSize()
                    .help("Send one picture of \(name) with your next message, without asking again")
                    .accessibilityHint("Your next message sends one picture of \(name). Later messages ask as usual.")
            }
        }
        .font(.callout)
        .lineLimit(1)
        .padding(.horizontal, 4)
    }
}

struct ScreenSendCardView: View {
    let question: String
    let a: NotchAccessibility
    let decide: (ScreenSendChoice) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "viewfinder").foregroundStyle(Color.purple)
                Text(question).font(.headline).foregroundStyle(NotchPalette.label)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(ScreenCapturePolicy.confirmDetail).font(.callout)
                .foregroundStyle(NotchPalette.secondary(a))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                choice("Cancel", .cancel, help: "Don't send the message")
                choice("Send without screen", .withoutScreen, help: "Send only your words")
                choice("Send screen", .send, help: "Capture this display once and send it with your message")
            }
            .padding(.top, 4)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(NotchPalette.raised))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(question)
    }

    private func choice(_ title: String, _ value: ScreenSendChoice, help: String) -> some View {
        Button { decide(value) } label: {
            Text(title).font(.system(size: 13, weight: .semibold)).padding(.horizontal, 4)
                .foregroundStyle(value == .send ? Color.white : NotchPalette.label)
        }
        .approvalButtonStyle(a, prominent: value == .send)
        .help(help)
        .accessibilityHint(help)
    }
}

/// Asks before Benji changes, sends or deletes anything (components/ApprovalCard): the action,
/// its target, and No / Adjust / Yes. Return and Escape mean No and ⌘Return means Yes; the panel
/// handles those keys (`CompanionPanel.sendEvent`), so none of these buttons is the default.
struct ApprovalCardView: View {
    let request: ApprovalRequest
    let a: NotchAccessibility
    /// After this long without an answer the card says No by itself.
    let timeout: TimeInterval
    let decide: (ApprovalChoice) -> Void
    @State private var shown = false
    /// The whole target is open (a long command or script); closed, it shows the first lines.
    @State private var targetOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "hand.raised.fill").foregroundStyle(NotchPalette.tint(.approval, a))
                Text(request.action).font(.headline).foregroundStyle(NotchPalette.label)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !request.target.isEmpty {
                if targetOpen {
                    ScrollView {
                        Text(request.target).font(NotchFont.mono).foregroundStyle(NotchPalette.secondary(a))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 220)
                } else {
                    Text(request.target).font(NotchFont.mono).foregroundStyle(NotchPalette.secondary(a))
                        .lineLimit(ApprovalPolicy.collapsedTargetLines).truncationMode(.tail)
                        .textSelection(.enabled)
                }
                if ApprovalPolicy.targetNeedsOpening(request.target) {
                    Button(targetOpen ? "Show less" : "Show all") { targetOpen.toggle() }
                        .buttonStyle(.plain).font(.caption.weight(.semibold))
                        .foregroundStyle(NotchPalette.label)
                        .help("Read the whole thing before you answer")
                }
            }
            HStack(spacing: 8) {
                Text(ApprovalPolicy.expiryLine(timeout: timeout))
                    .font(.caption).foregroundStyle(NotchPalette.secondary(a))
                    .lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                choice("No", .no, help: "Don't do it (Return or Escape)")
                choice("Adjust", .adjust, help: "Don't do it yet; edit the request in the message field")
                choice("Yes", .yes, help: "Do it (⌘Return)")
            }
            .padding(.top, 4)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(NotchPalette.raised))
        .overlay(alignment: .top) {
            // The thin state-approval top edge.
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(NotchPalette.tint(.approval, a), lineWidth: 2)
                .mask(VStack(spacing: 0) { Rectangle().frame(height: 3); Spacer(minLength: 0) })
        }
        // Rises 8 pt and fades in with motion-content; under Reduce Motion it only fades.
        .opacity(shown ? 1 : 0)
        .offset(y: shown || a.reduceMotion ? 0 : 8)
        .onAppear { withAnimation(NotchMotion.content(a)) { shown = true } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Benji needs approval: \(request.action). \(request.target). "
                            + ApprovalPolicy.expiryLine(timeout: timeout))
    }

    private func choice(_ title: String, _ value: ApprovalChoice, help: String) -> some View {
        Button { decide(value) } label: {
            Text(title).font(.system(size: 13, weight: .semibold)).padding(.horizontal, 4)
                .foregroundStyle(value == .yes ? Color.white : NotchPalette.label)
        }
        .approvalButtonStyle(a, prominent: value == .yes)
        .help(help)
        .accessibilityHint(help)
    }
}

/// The notch's offer of a skill for the app in front (D-187): three things to try, and the same
/// row of answers as an approval card, No first and the yes last. Never takes the keyboard.
struct AppOfferCard: View {
    let offer: AppOffer
    let a: NotchAccessibility
    let answer: (AppOfferAnswer, String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(offer.title).font(NotchFont.peekLine).foregroundStyle(NotchPalette.label).lineLimit(1)
            VStack(spacing: 2) {
                ForEach(offer.examples, id: \.self) { example in
                    Button { answer(.tryIt, example) } label: {
                        Text(example).font(.callout).foregroundStyle(NotchPalette.label)
                            .lineLimit(1).truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(NotchPalette.raised))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(AppOfferCopy.tryHelp)
                }
            }
            HStack(spacing: 8) {
                Text(AppOfferCopy.caption).font(.caption).foregroundStyle(NotchPalette.secondary(a))
                    .lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                choice("No", .no, help: AppOfferCopy.noHelp)
                choice("Not now", .notNow, help: AppOfferCopy.notNowHelp)
                choice("Try it", .tryIt, help: AppOfferCopy.tryHelp)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(offer.title)
    }

    private func choice(_ title: String, _ value: AppOfferAnswer, help: String) -> some View {
        Button { answer(value, nil) } label: {
            Text(title).font(.system(size: 13, weight: .semibold)).padding(.horizontal, 4)
                .foregroundStyle(value == .tryIt ? Color.white : NotchPalette.label)
        }
        .approvalButtonStyle(a, prominent: value == .tryIt)
        .help(help)
        .accessibilityHint(help)
    }
}

extension View {
    /// Capsules (`radius-pill`): No and Adjust neutral, Yes in the user's accent colour. Liquid
    /// Glass on macOS 26; filled capsules on 14–15 and under Reduce Transparency.
    @ViewBuilder
    func approvalButtonStyle(_ a: NotchAccessibility, prominent: Bool) -> some View {
        if #available(macOS 26.0, *), !a.reduceTransparency {
            if prominent {
                self.buttonStyle(.glassProminent).buttonBorderShape(.capsule).tint(.accentColor)
            } else {
                self.buttonStyle(.glass).buttonBorderShape(.capsule)
            }
        } else {
            self.buttonStyle(CapsuleChoiceStyle(prominent: prominent))
        }
    }
}

struct CapsuleChoiceStyle: ButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(prominent ? Color.accentColor : Color.white.opacity(0.10)))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// The composer (D-133): the talk control, then the field. Empty, the control is a capsule that
/// names the talk key; once there is text it shrinks to a round mic, and read aloud and Send sit
/// inside the field. While Benji listens the control keeps its look: the glyph turns orange and
/// it reads "Stop listening" (D-134).
struct Composer: View {
    @ObservedObject var model: CompanionModel
    let a: NotchAccessibility
    @FocusState private var focused: Bool

    private var canSend: Bool {
        !model.composerText.trimmingCharacters(in: .whitespaces).isEmpty && model.canSendTyped
    }

    var body: some View {
        let shape = ComposerTalk.shape(text: model.composerText)
        HStack(alignment: .bottom, spacing: 8) {
            TalkControl(shape: shape, key: model.talkKeyName, needsSetup: model.talkKeyNeedsSetup, startsOnTap: model.talkStartsOnTap,
                        listening: model.state.phase == .listening, a: a) { model.toggleMicFromPanel() }
                .disabled(!ComposerTalk.enabled(phase: model.state.phase))
            HStack(alignment: .bottom, spacing: 6) {
                TextField("Ask Benji…", text: $model.composerText,
                          prompt: Text("Ask Benji…").foregroundStyle(NotchPalette.secondary(a)), axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .font(.body)
                    .foregroundStyle(NotchPalette.label)
                    .focused($focused)
                    .padding(.vertical, 7)
                    .onSubmit { model.submit() }
                    .accessibilityLabel("Message to Benji")
                if shape == .round {
                    ReadAloudToggle(on: model.readAloud, a: a) { model.setReadAloud(!model.readAloud) }
                        .padding(.bottom, 5)
                        .transition(.opacity)
                    Button { model.submit() } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color.black)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(Color.mint))
                            .opacity(canSend ? 1 : 0.4)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(!canSend)
                    .padding(.bottom, 5)
                    .help("Send")
                    .accessibilityLabel("Send message")
                    .transition(.opacity)
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, shape == .round ? 5 : 12)
            .frame(minHeight: 32)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(NotchPalette.raised))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(focused ? Color.mint.opacity(0.6) : NotchPalette.hairline(a)))
        }
        .animation(NotchMotion.content(a), value: shape)
        .onAppear { focused = true }
    }
}

/// The composer's talk control: a capsule ("Hold Right ⌥ to talk") beside the empty field, a
/// round mic while typing. A click starts listening; while listening only the glyph is orange and
/// the words read "Stop listening", a click stops it. No fill, border or meter changes (D-134).
struct TalkControl: View {
    let shape: ComposerTalk.Shape
    let key: String?
    var needsSetup: String? = nil
    let startsOnTap: Bool
    let listening: Bool
    let a: NotchAccessibility
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let tint = listening ? NotchPalette.tint(.listening, a) : Color.mint   // the glyph only
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: listening ? "mic.fill" : "mic")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
                    .contentTransition(a.reduceMotion ? .opacity : .symbolEffect(.replace))
                if shape == .capsule {
                    Text(ComposerTalk.title(key: key, needsSetup: needsSetup, listening: listening))
                        .font(.system(size: 12))
                        .foregroundStyle(NotchPalette.label)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .padding(.leading, shape == .capsule ? 12 : 0)
            .padding(.trailing, shape == .capsule ? 14 : 0)
            .frame(minWidth: 32, minHeight: 32)
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(Capsule())
        }
        .buttonStyle(BareButtonStyle())
        .background(Capsule().fill(NotchPalette.raised))
        .overlay(Capsule().strokeBorder(NotchPalette.hairline(a)).allowsHitTesting(false))
        .clipShape(Capsule())
        .help(ComposerTalk.help(key: key, needsSetup: needsSetup, startsOnTap: startsOnTap, listening: listening))
        .accessibilityLabel(ComposerTalk.accessibilityLabel(listening: listening))
        .accessibilityHint(ComposerTalk.help(key: key, needsSetup: needsSetup, startsOnTap: startsOnTap, listening: listening))
    }
}

// MARK: - Signs of life (D-98)

/// Under a finished turn: one quiet line of what Benji did, and, when the turn ended without an
/// answer, "Cut off before it finished." with Retry. Indented to the text column.
struct TurnFooterView: View {
    let footer: PanelTurnFooter
    let a: NotchAccessibility
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let activity = footer.activity {
                Text(activity)
                    .font(.caption)
                    .foregroundStyle(NotchPalette.secondary(a))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("What Benji did: \(activity)")
            }
            if footer.cutOff {
                HStack(spacing: 10) {
                    Text(footer.cutOffText)
                        .font(.callout)
                        .foregroundStyle(NotchPalette.secondary(a))
                        .fixedSize(horizontal: false, vertical: true)
                    if footer.canRetry {
                        Button(action: retry) {
                            Label("Retry", systemImage: "arrow.clockwise")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(NotchPalette.label)
                                .padding(.horizontal, 2)
                        }
                        .approvalButtonStyle(a, prominent: false)
                        .controlSize(.small)
                        .help("Send this message again")
                        .accessibilityHint("Sends your last message again")
                    }
                }
            }
        }
        .padding(.leading, 20)   // the rows' 12 pt lead and 8 pt gap
        .accessibilityElement(children: .contain)
    }
}

/// Three soft dots where the answer will be, while Benji works and nothing has arrived. They
/// breathe in a slow wave; under Reduce Motion they hold still.
struct ThinkingDots: View {
    let a: NotchAccessibility
    private static let period = 1.2

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Circle().fill(Color.mint.opacity(0.5)).frame(width: 6, height: 6)
                .frame(width: 12, height: 16)
            if a.reduceMotion {
                dots { _ in 0.55 }
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate / Self.period
                    dots { i in 0.3 + 0.5 * max(0, sin(2 * .pi * (t - Double(i) * 0.18))) }
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Benji is thinking")
    }

    private func dots(_ opacity: @escaping (Int) -> Double) -> some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(NotchPalette.label)
                    .frame(width: 5, height: 5)
                    .opacity(opacity(i))
            }
        }
        .frame(height: 16)
    }
}

/// "Read answers aloud", inside the composer's field beside Send: a plain speaker, mint when on.
/// Off still speaks answers to what you said (`ReadAloud`).
struct ReadAloudToggle: View {
    let on: Bool
    let a: NotchAccessibility
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Image(systemName: on ? "speaker.wave.2.fill" : "speaker")
                .font(.system(size: BandLayout.symbolSize, weight: .semibold))
                .foregroundStyle(on ? Color.mint : NotchPalette.secondary(a))
                .contentTransition(a.reduceMotion ? .opacity : .symbolEffect(.replace))
                .frame(width: BandLayout.slot, height: BandLayout.slot)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(ReadAloud.help(on: on))
        .accessibilityLabel("Read answers aloud")
        .accessibilityValue(on ? "On" : "Off")
        .accessibilityHint(on ? "Reads only answers to what you say" : "Reads every answer aloud")
        .accessibilityAddTraits(.isToggle)
    }
}
