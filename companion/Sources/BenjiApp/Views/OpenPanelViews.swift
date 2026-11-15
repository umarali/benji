import SwiftUI
import BenjiCore

// MARK: - Open

/// The full panel below the notch band: one quiet status line, the conversation (or home, or the
/// list), any card, then the composer. Expanded, a sidebar of recent conversations sits
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
                    // Swaps at once: a cross-fade would draw "Go on." over the longer conversation line.
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

/// Only the label, dimmed while pressed: no bezel, focus ring or hover plate of the system's own.
struct BareButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.7 : 1)
    }
}
