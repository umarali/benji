import Foundation

/// The answer text as the panel shows it: inline Markdown only (bold, italic, `code`,
/// strikethrough), line breaks kept. Block syntax (headings, lists, tables, code fences) stays
/// as typed; the panel prompt asks the model not to use it. Links and images become their
/// plain text: nothing in an answer can be clicked through, since an answer may repeat text
/// from a web page or a file.
public enum PanelMarkdown {
    public static func attributed(_ text: String) -> AttributedString {
        #if canImport(Darwin)
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible)
        guard var out = try? AttributedString(markdown: text, options: options) else {
            return AttributedString(text)
        }
        for run in out.runs where run.link != nil || run.imageURL != nil {
            out[run.range].link = nil
            out[run.range].imageURL = nil
        }
        return out
        #else
        return AttributedString(text)
        #endif
    }

    /// The same text without any markup, for VoiceOver.
    public static func plain(_ text: String) -> String {
        String(attributed(text).characters)
    }
}
