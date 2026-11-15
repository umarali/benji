import SwiftUI
import BenjiCore

/// The composer: the talk control, then the field. Empty, the control is a capsule that
/// names the talk key; once there is text it shrinks to a round mic, and read aloud and Send sit
/// inside the field. While Benji listens the control keeps its look: the glyph turns orange and
/// it reads "Stop listening".
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
/// the words read "Stop listening", a click stops it. No fill, border or meter changes.
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
