import SwiftUI
import BenjiCore

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

/// The notch's offer of a skill for the app in front: three things to try, and the same
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
