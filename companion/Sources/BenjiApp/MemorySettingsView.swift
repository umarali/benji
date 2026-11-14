import SwiftUI
import BenjiCore

/// Settings › Memory: whether conversations are saved (and deleting them), and the plain list of
/// what Benji remembers about the user, each fact changeable or forgettable. Everything that
/// deletes asks first, on the page.
struct MemorySettingsView: View {
    @ObservedObject var model: SettingsModel
    let a: NotchAccessibility
    var scrolls = true

    @State private var editing: ProfileFact?
    @State private var draft = ""
    @State private var confirming: Confirm?
    @FocusState private var draftFocused: Bool

    enum Confirm: Equatable {
        case deleteConversations
        case forget(ProfileFact)
        case forgetAll
    }

    private var s: SettingsSnapshot { model.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(SettingsPane.memory.title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(NotchPalette.label)
                .accessibilityAddTraits(.isHeader)
            Text(SettingsPane.memory.subtitle)
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
            SettingsCard(header: "Conversations", a: a, footer: MemorySettings.conversationsFooter) {
                SettingsRow(title: "Save conversations",
                            detail: "So you can open one again from home and carry on.", a: a) {
                    SwitchControl(title: "Save conversations",
                                  isOn: model.toggle(\.saveConversations, SettingsChange.saveConversations))
                }
                SettingsRow(title: MemorySettings.count(s.savedConversations), detail: nil, a: a) {
                    Button("Delete all…") { confirming = .deleteConversations }
                        .buttonStyle(CapsuleButtonStyle())
                        .disabled(s.savedConversations == 0)
                        .help("Delete every saved conversation from this Mac")
                }
            }
            if confirming == .deleteConversations {
                ConfirmStrip(question: MemorySettings.deleteAllQuestion(s.savedConversations), action: "Delete all", a: a,
                             cancel: { confirming = nil }) {
                    model.change(.deleteAllConversations)
                    confirming = nil
                }
            }
            SettingsCard(header: "What Benji remembers", a: a, footer: MemorySettings.factsFooter) {
                if s.facts.isEmpty {
                    Text(MemorySettings.noFacts)
                        .font(.callout)
                        .foregroundStyle(NotchPalette.secondary(a))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                }
                ForEach(s.facts) { fact in factRow(fact) }
            }
            if case .forget(let fact) = confirming {
                ConfirmStrip(question: "Forget “\(fact.text)”?", action: "Forget", a: a, cancel: { confirming = nil }) {
                    model.change(.forgetFact(fact))
                    confirming = nil
                }
            }
            if !s.facts.isEmpty {
                if confirming == .forgetAll {
                    ConfirmStrip(question: MemorySettings.forgetAllQuestion, action: "Forget all", a: a,
                                 cancel: { confirming = nil }) {
                        model.change(.forgetAllFacts)
                        confirming = nil
                    }
                } else {
                    HStack {
                        Spacer()
                        Button("Forget everything…") { confirming = .forgetAll }
                            .buttonStyle(CapsuleButtonStyle())
                    }
                }
            }
        }
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func factRow(_ fact: ProfileFact) -> some View {
        if editing == fact {
            HStack(spacing: 8) {
                TextField("What Benji remembers", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...3)
                    .font(.body)
                    .foregroundStyle(NotchPalette.label)
                    .focused($draftFocused)
                    .onSubmit(save)
                    .accessibilityLabel("Change what Benji remembers")
                Button("Cancel") { editing = nil }
                    .buttonStyle(CapsuleButtonStyle())
                Button("Save", action: save)
                    .buttonStyle(CapsuleButtonStyle(prominent: true))
                    .keyboardShortcut(.return, modifiers: [])
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .onAppear { draftFocused = true }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(fact.text)
                    .font(.body)
                    .foregroundStyle(NotchPalette.label)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Spacer(minLength: 4)
                glyph("pencil", label: "Change “\(fact.text)”", help: "Change it") {
                    draft = fact.text
                    editing = fact
                }
                glyph("trash", label: "Forget “\(fact.text)”", help: "Forget it") { confirming = .forget(fact) }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private func glyph(_ symbol: String, label: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(NotchPalette.secondary(a))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(label)
    }

    private func save() {
        guard let fact = editing else { return }
        editing = nil
        if draft.trimmingCharacters(in: .whitespacesAndNewlines) != fact.text {
            model.change(.editFact(fact, draft))
        }
    }
}

/// "Delete …? This can't be undone." with Cancel and the action, in place of a dialog (the notch
/// is a panel, and a sheet would cover what is being deleted).
struct ConfirmStrip: View {
    let question: String
    let action: String
    let a: NotchAccessibility
    let cancel: () -> Void
    let confirm: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Color.orange)
                .accessibilityHidden(true)
            Text(question)
                .font(.callout)
                .foregroundStyle(NotchPalette.label)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button("Cancel", action: cancel)
                .buttonStyle(CapsuleButtonStyle())
                .keyboardShortcut(.cancelAction)
            Button(action, role: .destructive, action: confirm)
                .buttonStyle(DestructiveCapsuleStyle())
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(NotchPalette.raised))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(question)
    }
}

/// A red capsule for the one destructive choice.
struct DestructiveCapsuleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.red.opacity(configuration.isPressed ? 0.7 : 0.85)))
            .contentShape(Capsule())
    }
}
