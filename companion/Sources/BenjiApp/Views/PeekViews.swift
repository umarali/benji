import SwiftUI
import BenjiCore

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

/// The band either side of the hardware notch. In the peek, the state glyph hugs the notch
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
/// conversation from home and from Settings (to the page underneath); ⇧⌘H both ways, as
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
            // Swaps at once: a cross-fade would draw the old and new line on top of each other.
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
