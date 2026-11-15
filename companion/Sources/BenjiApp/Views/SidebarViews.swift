import SwiftUI
import BenjiCore

/// The expanded panel's sidebar: "Recent" conversations (the open one highlighted, each a
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
