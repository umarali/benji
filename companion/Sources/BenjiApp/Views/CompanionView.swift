import SwiftUI
import BenjiCore

/// The notch object: one black shape continuous with the hardware notch, in four sizes.
/// Closed draws nothing but black; the peek shows a glyph wing, a state word and one line; the card
/// shows an offer; open is the full panel (transcript, disclosure, composer). Sizes and timing come
/// from `NotchPresenter`; this view only draws them.
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
        // ways); from Settings it goes back to the page underneath. Nowhere to go (home
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
