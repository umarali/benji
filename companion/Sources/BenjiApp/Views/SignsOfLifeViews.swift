import SwiftUI
import BenjiCore

// MARK: - Signs of life

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
