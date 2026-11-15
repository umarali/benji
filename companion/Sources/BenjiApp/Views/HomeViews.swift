import SwiftUI
import BenjiCore

/// The open panel's home (`PanelPage.home`): a time-of-day greeting, one line on how to talk, and
/// the recent saved conversations, each one click from being open again.
struct HomePage: View {
    @ObservedObject var model: CompanionModel
    let a: NotchAccessibility

    var body: some View {
        // The page takes what the panel leaves above the composer and trims its recent rows to
        // fit (HomeView.rowsFitting); the composer is never pushed past the bottom edge.
        GeometryReader { geo in
            content(height: geo.size.height)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                .clipped()
        }
    }

    private func content(height: CGFloat) -> some View {
        let now = Date()
        let all = HomeView.recents(model.history.summaries, current: model.history.currentID, now: now)
        let shown = HomeView.rowsFitting(height: Double(height), available: all.rows.count,
                                         hintLines: model.conversationOn ? 2 : 1)
        let recents = HomeRecents(rows: Array(all.rows.prefix(shown)), more: all.more + all.rows.count - shown)
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(HomeView.greeting(hour: Calendar.current.component(.hour, from: now)))
                    .font(NotchFont.greeting)
                    .foregroundStyle(NotchPalette.label)
                    .accessibilityAddTraits(.isHeader)
                if !hint.isEmpty {
                    Text(hint)
                        .font(.callout)
                        .foregroundStyle(NotchPalette.secondary(a))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if all.rows.isEmpty {
                Text(HomeView.emptyLine(saving: model.history.saving))
                    .font(.callout)
                    .foregroundStyle(NotchPalette.secondary(a))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    SectionHeader(text: "Recent", a: a)
                    VStack(spacing: 0) {
                        ForEach(recents.rows) { row in
                            ConversationRowButton(row: row, a: a) { model.openConversation(row.id) }
                        }
                    }
                    .disabled(!model.canSwitchConversation)
                    Button { model.showPage(.list) } label: {
                        Text(recents.more > 0 ? "All conversations (\(all.rows.count + all.more))…"
                                              : "All conversations…")
                            .font(.callout)
                            .foregroundStyle(NotchPalette.secondary(a))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Every saved conversation, to open or delete")
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Recent conversations")
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var hint: String {
        model.conversationOn ? "I'm listening. Say “that's all” when you're done, or type below." : model.pttHint
    }
}

/// Every saved conversation (`PanelPage.list`), newest first: open one, delete one, or delete
/// them all. Each deletion asks first, on the page itself.
struct ConversationListPage: View {
    @ObservedObject var model: CompanionModel
    let a: NotchAccessibility
    /// The row (or "all") waiting for its confirmation.
    @State private var confirming: Confirm?

    enum Confirm: Equatable {
        case one(HomeRow)
        case all
    }

    var body: some View {
        let rows = HomeView.rows(model.history.summaries, now: Date())
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Button { model.showPage(.home) } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(NotchPalette.secondary(a))
                        .frame(width: BandLayout.slot, height: BandLayout.slot)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Back to home (Escape)")
                .accessibilityLabel("Back to home")
                Text("All conversations")
                    .font(.headline)
                    .foregroundStyle(NotchPalette.label)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                if !rows.isEmpty, confirming != .all {
                    Button("Delete all…") { confirming = .all }
                        .buttonStyle(CapsuleButtonStyle())
                        .help("Delete every saved conversation from this Mac")
                }
            }
            if let confirming {
                ConfirmStrip(question: question(confirming), action: confirming == .all ? "Delete all" : "Delete", a: a,
                             cancel: { self.confirming = nil }) {
                    switch confirming {
                    case .one(let row): model.deleteConversation(row.id)
                    case .all: model.deleteAllConversations()
                    }
                    self.confirming = nil
                }
            }
            if rows.isEmpty {
                Text(HomeView.emptyLine(saving: model.history.saving))
                    .font(.callout)
                    .foregroundStyle(NotchPalette.secondary(a))
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(rows) { row in
                            HStack(spacing: 4) {
                                ConversationRowButton(row: row, a: a, current: row.id == model.history.currentID) {
                                    model.openConversation(row.id)
                                }
                                .disabled(!model.canSwitchConversation)
                                Button { confirming = .one(row) } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(NotchPalette.secondary(a))
                                        .frame(width: BandLayout.slot, height: BandLayout.slot)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(row.id == model.history.currentID && !model.canSwitchConversation)
                                .help("Delete this conversation")
                                .accessibilityLabel("Delete \(row.title)")
                            }
                        }
                    }
                }
                .scrollIndicators(.automatic)
                .frame(maxHeight: .infinity)
            }
        }
        .padding(.top, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("All conversations")
    }

    private func question(_ c: Confirm) -> String {
        switch c {
        case .one(let row): return MemorySettings.deleteOneQuestion(row.title)
        case .all: return MemorySettings.deleteAllQuestion(model.history.summaries.count)
        }
    }
}

/// One conversation: its title and when it last changed. A soft fill under the pointer.
struct ConversationRowButton: View {
    let row: HomeRow
    let a: NotchAccessibility
    var current = false
    let open: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: open) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: current ? "bubble.left.fill" : "bubble.left")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(current ? Color.mint : NotchPalette.secondary(a))
                    .frame(width: 14)
                Text(row.title)
                    .font(.body)
                    .foregroundStyle(NotchPalette.label)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Text(row.when)
                    .font(.caption)
                    .foregroundStyle(NotchPalette.secondary(a))
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hovering && isEnabled ? NotchPalette.raised : .clear))
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(isEnabled ? "Open this conversation and continue it" : "Benji is busy")
        .accessibilityLabel(row.accessibilityLabel + (current ? ", open now" : ""))
        .accessibilityHint("Opens the conversation")
    }
}

/// A small uppercase header, as over the settings cards.
struct SectionHeader: View {
    let text: String
    let a: NotchAccessibility

    var body: some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .tracking(0.6)
            .foregroundStyle(NotchPalette.secondary(a))
            .padding(.leading, 8)
            .accessibilityAddTraits(.isHeader)
    }
}
