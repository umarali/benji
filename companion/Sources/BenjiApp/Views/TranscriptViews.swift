import SwiftUI
import BenjiCore

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
                        // The reply as it streams: replaced by the answer's own line.
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

/// A thin line with the day between turns from different days.
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
