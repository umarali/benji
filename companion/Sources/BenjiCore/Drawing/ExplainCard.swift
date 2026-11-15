import Foundation

/// An explanation card: a diagram, a list, a comparison or a sketch of an idea that Benji
/// shows on a card of its own instead of drawing ink over the user's screen. The model writes
/// the card as card lines between its spoken sentences (`ExplainCardLine`, below); a fenced JSON
/// block marked `card` is also read, for replies that hold one. The code lays the card out
/// (rows, columns, a flow left to right), never model-typed coordinates. `card_rule()` in
/// benji/prompts.py teaches the model the grammar.
public struct ExplainCard: Equatable, Sendable {
    public enum Layout: String, Equatable, Sendable, CaseIterable {
        /// Two to five parts left to right with arrows between them (states, a pipeline).
        case flow
        /// Numbered steps down a line, two to seven (a process, a how-to).
        case steps
        /// One to six rows, each an icon, a label and a note (kinds, parts, reasons).
        case list
        /// Two or three columns side by side, each with up to four points (options, before/after).
        case compare
    }

    public struct Item: Equatable, Sendable {
        public var label: String
        public var note: String?
        /// An SF Symbol name; the app draws a plain mark when the Mac has no such symbol.
        public var icon: String?
        /// Short points under the item (a compare column's lines).
        public var points: [String]

        public init(label: String, note: String? = nil, icon: String? = nil, points: [String] = []) {
            self.label = label
            self.note = note
            self.icon = icon
            self.points = points
        }
    }

    /// The card's title bar (what it is about, a few words).
    public var title: String
    /// The handwritten line across the top of the board (the one idea to take away from it).
    public var heading: String?
    public var layout: Layout
    public var items: [Item]
    /// One closing line under the board (a verdict, a rule of thumb).
    public var takeaway: String?
    /// Up to three short next questions; a tap sends the text as the user's next message.
    public var chips: [String]

    public init(title: String, heading: String? = nil, layout: Layout, items: [Item], takeaway: String? = nil,
                chips: [String] = []) {
        self.title = title
        self.heading = heading
        self.layout = layout
        self.items = items
        self.takeaway = takeaway
        self.chips = chips
    }

    /// Everything the card says, in reading order (the panel's accessibility text).
    public var spokenSummary: String {
        var parts = [title]
        if let heading { parts.append(heading) }
        for (i, item) in items.enumerated() {
            var line = layout == .steps ? "\(i + 1). \(item.label)" : item.label
            if let note = item.note { line += ": \(note)" }
            if !item.points.isEmpty { line += ": " + item.points.joined(separator: "; ") }
            parts.append(line)
        }
        if let takeaway { parts.append(takeaway) }
        return parts.joined(separator: ". ")
    }
}

public enum ExplainCardGrammar {
    public static let maxTitle = 40
    public static let maxHeading = 60
    public static let maxLabel = 28
    public static let maxNote = 70
    public static let maxPoint = 48
    public static let maxPoints = 4
    public static let maxTakeaway = 120
    public static let maxChips = 3
    public static let maxChip = 48
    public static let maxIcon = 48
    public static let maxBlockChars = 8_000

    /// How many items each layout takes; more are dropped from the end.
    public static func itemRange(_ layout: ExplainCard.Layout) -> ClosedRange<Int> {
        switch layout {
        case .flow: return 2...5
        case .steps: return 2...7
        case .list: return 1...6
        case .compare: return 2...3
        }
    }

    /// Words the model reaches for, read as the nearest layout.
    public static let layoutAliases: [String: ExplainCard.Layout] = [
        "flow": .flow, "row": .flow, "states": .flow, "sequence": .flow, "pipeline": .flow, "cycle": .flow,
        "steps": .steps, "process": .steps, "timeline": .steps, "howto": .steps, "how-to": .steps,
        "list": .list, "column": .list, "bullets": .list, "parts": .list, "grid": .list,
        "compare": .compare, "comparison": .compare, "columns": .compare, "vs": .compare, "versus": .compare,
    ]

    // MARK: finding the block

    private static let fence = try! NSRegularExpression(
        pattern: "^[ \\t]*```[ \\t]*([A-Za-z]*)[ \\t]*\\n(.*?)\\n[ \\t]*```[ \\t]*$",
        options: [.anchorsMatchLines, .dotMatchesLineSeparators, .useUnixLineSeparators])

    /// The reply without its card block (the words before and after it joined), and the card;
    /// (text, nil) when there is no block or it fails (then the text is returned unchanged). A
    /// block marked `card` counts wherever it is; one marked `json` only at the very end, and only
    /// when it reads as a card (a figure's `json` block is left for FigureGrammar).
    public static func parse(_ text: String) -> (text: String, card: ExplainCard?) {
        let ns = text as NSString
        var found: (NSTextCheckingResult, ExplainCard)?
        for m in fence.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let info = ns.substring(with: m.range(at: 1)).lowercased()
            let atEnd = { PointingTags.parse(ns.substring(from: m.range.location + m.range.length)).text
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            guard info == "card" || (info == "json" && atEnd()),
                  let card = card(json: ns.substring(with: m.range(at: 2))) else { continue }
            found = (m, card)
        }
        guard let (m, card) = found else { return (text, nil) }
        let before = ns.substring(to: m.range.location).trimmingCharacters(in: .whitespacesAndNewlines)
        let rest = ns.substring(from: m.range.location + m.range.length).trimmingCharacters(in: .whitespacesAndNewlines)
        let joined = rest.isEmpty ? before : before.isEmpty ? rest : before + "\n" + rest
        return (joined, card)
    }

    /// The card a block's JSON describes, or nil when it has no usable items.
    public static func card(json body: String) -> ExplainCard? {
        guard body.unicodeScalars.count <= maxBlockChars,
              let value = try? JSONDecoder().decode(JSONValue.self, from: Data(body.utf8)),
              case .object(let obj) = value, obj["parts"] == nil,
              case .array(let raws)? = obj["items"] else { return nil }
        var items = raws.compactMap(item)
        guard !items.isEmpty else { return nil }
        var layout = layout(obj["layout"], items: items)
        if layout == .compare && items.count < 2 { layout = .list }
        if layout == .flow && items.count > itemRange(.flow).upperBound { layout = .steps }
        if (layout == .flow || layout == .steps) && items.count < 2 { layout = .list }
        items = Array(items.prefix(itemRange(layout).upperBound))
        let heading = optionalText(obj["heading"], maxHeading)
        let title = text(obj["title"], maxTitle)
        return ExplainCard(title: title.isEmpty ? (heading.map { clip($0, maxTitle) } ?? "Benji") : title,
                           heading: heading, layout: layout, items: items,
                           takeaway: optionalText(obj["takeaway"], maxTakeaway), chips: chips(obj["chips"]))
    }

    // MARK: values

    static func layout(_ v: JSONValue?, items: [ExplainCard.Item]) -> ExplainCard.Layout {
        if case .string(let s)? = v {
            let key = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let l = layoutAliases[key] { return l }
        }
        // No layout, or one we don't know: columns of points compare, anything else is a list.
        let pointed = items.filter { !$0.points.isEmpty }.count
        return pointed >= 2 && items.count <= 3 ? .compare : .list
    }

    static func item(_ v: JSONValue) -> ExplainCard.Item? {
        switch v {
        case .string:
            let label = text(v, maxLabel)
            return label.isEmpty ? nil : ExplainCard.Item(label: label)
        case .object(let o):
            let label = text(o["label"] ?? o["title"] ?? o["name"], maxLabel)
            guard !label.isEmpty else { return nil }
            var points: [String] = []
            if case .array(let raw)? = o["points"] {
                points = raw.map { text($0, maxPoint) }.filter { !$0.isEmpty }
            }
            return ExplainCard.Item(label: label, note: optionalText(o["note"] ?? o["text"], maxNote),
                                    icon: icon(o["icon"]), points: Array(points.prefix(maxPoints)))
        default:
            return nil
        }
    }

    /// An SF Symbol name: lowercase letters, digits and dots, nothing else.
    static func icon(_ v: JSONValue?) -> String? {
        guard case .string(let s)? = v else { return nil }
        let name = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.")
        guard !name.isEmpty, name.unicodeScalars.count <= maxIcon, name.first != ".", name.last != ".",
              name.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return name
    }

    /// Up to three distinct questions; one too long to read on a chip is dropped, not cut.
    static func chips(_ v: JSONValue?) -> [String] {
        guard case .array(let raw)? = v else { return [] }
        var out: [String] = []
        for r in raw {
            guard case .string(let s) = r else { continue }
            let chip = collapse(s)
            guard !chip.isEmpty, chip.count <= maxChip,
                  !out.contains(where: { $0.caseInsensitiveCompare(chip) == .orderedSame }) else { continue }
            out.append(chip)
            if out.count == maxChips { break }
        }
        return out
    }

    static func optionalText(_ v: JSONValue?, _ limit: Int) -> String? {
        let t = text(v, limit)
        return t.isEmpty ? nil : t
    }

    /// The string with its whitespace runs collapsed, cut to `limit` characters at a word with an
    /// ellipsis when it runs over.
    static func text(_ v: JSONValue?, _ limit: Int) -> String {
        guard case .string(let s)? = v else { return "" }
        return clip(collapse(s), limit)
    }

    static func collapse(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    static func clip(_ s: String, _ limit: Int) -> String {
        guard s.count > limit else { return s }
        let head = String(s.prefix(limit - 1))
        let cut = head.lastIndex(of: " ").map { String(head[..<$0]) } ?? head
        let base = cut.count >= limit / 2 ? cut : head
        return base.trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters)) + "…"
    }
}

// MARK: - Card lines

/// One card line of a reply: the model writes the card as lines between its spoken sentences
/// (`card:`, `item:`, `takeaway:`, `chips:`), so each part can be drawn on the sentence that talks
/// about it. The engine reads them as they stream (benji/cards.py, which this mirrors) and sends
/// them as events; a finished answer that still holds them is read the same way.
public enum ExplainCardLine: Equatable, Sendable {
    /// `card: {"title","heading","layout"}`: the card opens with no body yet.
    case open(ExplainCardHeader)
    case item(ExplainCard.Item)
    case takeaway(String)
    case chips([String])
}

/// What a `card:` line says.
public struct ExplainCardHeader: Equatable, Sendable {
    public var title: String
    public var heading: String?
    /// Nil when the line names none (or one we don't know): the card grows as a list.
    public var layout: ExplainCard.Layout?

    public init(title: String, heading: String? = nil, layout: ExplainCard.Layout? = nil) {
        self.title = title
        self.heading = heading
        self.layout = layout
    }
}

/// A card as its lines arrive: it keeps the layout its `card:` line names (a flow that outgrows
/// five parts goes on as steps) and takes parts up to the layout's limit.
public struct ExplainCardDraft: Equatable, Sendable {
    public var header: ExplainCardHeader
    public private(set) var items: [ExplainCard.Item] = []
    public var takeaway: String?
    public var chips: [String] = []

    public init(header: ExplainCardHeader) { self.header = header }

    public var layout: ExplainCard.Layout {
        let declared = header.layout ?? .list
        return declared == .flow && items.count > ExplainCardGrammar.itemRange(.flow).upperBound ? .steps : declared
    }

    /// Adds a part; false when the card is full (the part is dropped).
    public mutating func add(_ item: ExplainCard.Item) -> Bool {
        let room = max(ExplainCardGrammar.itemRange(header.layout ?? .list).upperBound,
                       header.layout == .flow ? ExplainCardGrammar.itemRange(.steps).upperBound : 0)
        guard items.count < room else { return false }
        items.append(item)
        return true
    }

    public var card: ExplainCard {
        ExplainCard(title: header.title, heading: header.heading, layout: layout, items: items, takeaway: takeaway,
                    chips: chips)
    }
}

extension ExplainCardGrammar {
    /// How one complete line of a reply reads.
    public enum LineRead: Equatable, Sendable {
        /// Spoken text.
        case text
        /// A card line that is broken: never spoken, never drawn.
        case dropped
        case card(ExplainCardLine)
    }

    /// A card line's head: the word in any case, maybe in bold, then its colon.
    static let head = try! NSRegularExpression(pattern: #"^[*_]{0,2}(card|item|takeaway|chips)[*_]{0,2}:[*_]{0,2}"#,
                                               options: [.caseInsensitive])
    /// `takeaway:` and `chips:` later in a line, after a sentence's end and a space.
    static let inline = try! NSRegularExpression(pattern: #"(?<=[.!?])["'”)]*\s+(?=[*_]{0,2}(?:takeaway|chips)[*_]{0,2}:)"#,
                                                 options: [.caseInsensitive])

    /// A line (without its newline) as benji/cards.py reads it.
    public static func line(_ raw: String) -> LineRead {
        let s = raw.trimmingCharacters(in: .whitespaces)
        let ns = s as NSString
        guard let m = head.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return .text }
        let kind = ns.substring(with: m.range(at: 1)).lowercased()
        let rest = ns.substring(from: m.range.location + m.range.length).trimmingCharacters(in: .whitespaces)
        if kind == "takeaway" {
            var said = rest
            if rest.hasPrefix("\""), case .string(let decoded)? = try? JSONDecoder().decode(JSONValue.self, from: Data(rest.utf8)) {
                said = decoded
            } else if rest.hasPrefix("\"") {
                said = rest.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
            let t = text(.string(said), maxTakeaway)
            return t.isEmpty ? .dropped : .card(.takeaway(t))
        }
        guard rest.hasPrefix(kind == "chips" ? "[" : "{") else { return .text }   // "Item: one more thing" is a sentence
        guard rest.unicodeScalars.count <= maxBlockChars,
              let value = try? JSONDecoder().decode(JSONValue.self, from: Data(rest.utf8)) else { return .dropped }
        switch (kind, value) {
        case ("chips", .array):
            return .card(.chips(chips(value)))
        case ("card", .object(let o)):
            return .card(.open(header(o)))
        case ("item", .object):
            return item(value).map { .card(.item($0)) } ?? .dropped
        default:
            return .dropped
        }
    }

    /// A complete line as its spoken words and the `takeaway:` or `chips:` card line later in it
    /// ("That's the rule. Takeaway: …"), as `inline_split` in benji/cards.py: only after a
    /// sentence's end, and only when the rest reads as a card line. Nil when there is none.
    public static func inlineSplit(_ raw: String) -> (spoken: String, card: LineRead)? {
        let ns = raw as NSString
        for m in inline.matches(in: raw, range: NSRange(location: 0, length: ns.length)) {
            let before = ns.substring(to: m.range.location)
            guard !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let read = line(ns.substring(from: m.range.location + m.range.length))
            if read != .text { return (before, read) }
        }
        return nil
    }

    /// A `card:` line's object (or a `card` event's), read leniently.
    public static func header(_ o: [String: JSONValue]) -> ExplainCardHeader {
        let heading = optionalText(o["heading"], maxHeading)
        let title = text(o["title"], maxTitle)
        var layout: ExplainCard.Layout?
        if case .string(let s)? = o["layout"] {
            layout = layoutAliases[s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()]
        }
        return ExplainCardHeader(title: title.isEmpty ? (heading.map { clip($0, maxTitle) } ?? "Benji") : title,
                                 heading: heading, layout: layout)
    }

    /// An `item:` line's object (or a `card_item` event's); nil without a label.
    public static func part(_ v: JSONValue) -> ExplainCard.Item? { item(v) }

    /// Card lines found in an event's JSON (the engine sends them parsed): nil when unusable.
    public static func line(event type: String, json: JSONValue) -> ExplainCardLine? {
        switch (type, json) {
        case ("card", .object(let o)): return .open(header(o))
        case ("card_item", _): return item(json).map { .item($0) }
        case ("card_takeaway", .string): let t = text(json, maxTakeaway); return t.isEmpty ? nil : .takeaway(t)
        case ("card_chips", .array): return .chips(chips(json))
        default: return nil
        }
    }
}
