import Foundation

/// The kinds of text on an explanation card. Sizes are points; the app measures and draws them
/// in the handwriting font (heading, labels, notes, points, takeaway) or the system font (title,
/// chips, step numbers).
public enum ExplainTextStyle: String, Sendable, CaseIterable {
    case title, heading, label, note, point, takeaway, chip, number

    public var size: CGFloat {
        switch self {
        case .title: return 12.5
        case .heading: return 27
        case .label: return 20
        case .note, .point: return 16
        case .takeaway: return 17
        case .chip: return 13
        case .number: return 14
        }
    }

    /// The most lines the style may take before it is cut.
    public var maxLines: Int {
        switch self {
        case .title, .chip, .number: return 1
        case .heading, .label, .takeaway: return 2
        case .note, .point: return 3
        }
    }

    public var handwritten: Bool { ![.title, .chip, .number].contains(self) }
}

/// Text measurement, from the app (AppKit fonts) or a test (a fixed advance per character).
public protocol ExplainTextMeasuring {
    /// The size of `text` wrapped to `width`, all its lines (the layout clips to `maxLines`).
    func size(_ text: String, _ style: ExplainTextStyle, width: CGFloat) -> CGSize
    func lineHeight(_ style: ExplainTextStyle) -> CGFloat
}

/// Where everything on a card goes, in the card panel's own points (top-left origin, y down).
/// The panel holds the card and, under it, the follow-up chips.
public struct ExplainCardLayout: Equatable, Sendable {
    public struct Text: Equatable, Sendable {
        public var text: String
        public var style: ExplainTextStyle
        public var frame: CGRect
        public var centred: Bool

        public init(text: String, style: ExplainTextStyle, frame: CGRect, centred: Bool) {
            self.text = text
            self.style = style
            self.frame = frame
            self.centred = centred
        }
    }

    /// One item: its box (flow), badge (steps) or icon tile (list), and its words.
    public struct Node: Equatable, Sendable {
        public var box: CGRect?
        public var badge: CGRect?
        public var number: Int?
        public var icon: CGRect?
        public var iconName: String?
        public var texts: [Text]
        /// A short stroke under a compare column's label.
        public var rule: [CGPoint]?
        /// Where each point's dash goes, beside its text.
        public var bullets: [CGPoint]
    }

    public var size: CGSize
    public var card: CGRect
    public var titleBar: CGRect
    public var title: Text
    public var close: CGRect
    public var board: CGRect
    public var heading: Text?
    public var headingRule: [CGPoint]?
    public var nodes: [Node]
    /// Polylines with the head at the last point; corners kept.
    public var arrows: [[CGPoint]]
    public var dividers: [[CGPoint]]
    public var takeaway: Text?
    /// Each chip's pill; its words are centred in it.
    public var chips: [Text]
}

public enum ExplainCardMetrics {
    public static let radius: CGFloat = 14            // radius-card
    public static let titleBar: CGFloat = 34
    public static let pad: CGFloat = 26
    public static let closeSize: CGFloat = 20
    public static let minWidth: CGFloat = 340
    public static let maxWidth: CGFloat = 860
    public static let grid: CGFloat = 22              // the board's faint grid
    public static let chipHeight: CGFloat = 30
    public static let chipPadding: CGFloat = 14
    public static let chipGap: CGFloat = 8
    public static let chipsBelow: CGFloat = 10
    /// How wide the chips' row may run under a narrow card.
    public static let chipRow: CGFloat = 520
    public static let arrowGap: CGFloat = 46
    public static let iconSize: CGFloat = 28
    public static let badge: CGFloat = 30

    /// Narrower boxes for more of them, so a flow of five still fits the widest card.
    static func flowNodeWidth(_ n: Int) -> CGFloat {
        let fits = ((maxWidth - 2 * pad - CGFloat(n - 1) * arrowGap) / CGFloat(max(n, 1))).rounded(.down)
        return min(n <= 3 ? 172 : n == 4 ? 152 : 132, fits)
    }
    static let listWidth: CGFloat = 440
    static let stepsWidth: CGFloat = 440
    static func compareColumnWidth(_ n: Int) -> CGFloat { n <= 2 ? 236 : 196 }
    static let compareGap: CGFloat = 34
}

extension ExplainCardLayout {
    public static func make(_ card: ExplainCard, measure: ExplainTextMeasuring) -> ExplainCardLayout {
        LayoutBuilder(card: card, m: measure).build()
    }
}

private struct LayoutBuilder {
    let card: ExplainCard
    let m: ExplainTextMeasuring
    typealias M = ExplainCardMetrics

    /// Measured and clipped to the style's lines.
    func box(_ text: String, _ style: ExplainTextStyle, width: CGFloat) -> CGSize {
        let s = m.size(text, style, width: width)
        let cap = m.lineHeight(style) * CGFloat(style.maxLines)
        return CGSize(width: min(ceil(s.width), width), height: min(ceil(s.height), ceil(cap)))
    }

    func text(_ t: String, _ style: ExplainTextStyle, x: CGFloat, y: CGFloat, width: CGFloat,
              centred: Bool = false) -> ExplainCardLayout.Text {
        let s = box(t, style, width: width)
        let w = centred ? width : s.width
        return .init(text: t, style: style, frame: CGRect(x: x, y: y, width: w, height: s.height), centred: centred)
    }

    /// The items laid out from (0, 0): nodes, arrows, dividers and the content's size.
    func content() -> (nodes: [ExplainCardLayout.Node], arrows: [[CGPoint]], dividers: [[CGPoint]], size: CGSize) {
        // A card that has just opened, before its first part has come (chilly-beats): no body yet.
        guard !card.items.isEmpty else { return ([], [], [], .zero) }
        switch card.layout {
        case .flow: return flow()
        case .steps: return steps()
        case .list: return list()
        case .compare: return compare()
        }
    }

    /// A text column no wider than its longest line needs (labels and notes on one line), within
    /// `max` less the column's start, and never narrower than 240 points.
    func textWidth(tx: CGFloat, max limit: CGFloat) -> CGFloat {
        let room = limit - tx
        var need: CGFloat = 0
        for item in card.items {
            need = Swift.max(need, box(item.label, .label, width: room).width)
            if let note = item.note { need = Swift.max(need, m.size(note, .note, width: .greatestFiniteMagnitude).width) }
        }
        return Swift.min(room, Swift.max(240, ceil(need) + 4))
    }

    func flow() -> ([ExplainCardLayout.Node], [[CGPoint]], [[CGPoint]], CGSize) {
        let n = card.items.count, w = M.flowNodeWidth(n), inner: CGFloat = 12
        let icons = card.items.contains { $0.icon != nil }
        var nodes: [ExplainCardLayout.Node] = []
        var height: CGFloat = 0
        for (i, item) in card.items.enumerated() {
            let x = CGFloat(i) * (w + M.arrowGap)
            var y = inner + 2
            var icon: CGRect?
            if icons {
                icon = CGRect(x: x + (w - M.iconSize) / 2, y: y, width: M.iconSize, height: M.iconSize)
                y += M.iconSize + 8
            }
            var texts = [text(item.label, .label, x: x + inner, y: y, width: w - 2 * inner, centred: true)]
            y = texts[0].frame.maxY
            if let note = item.note {
                texts.append(text(note, .note, x: x + inner, y: y + 4, width: w - 2 * inner, centred: true))
                y = texts[1].frame.maxY
            }
            height = max(height, y + inner + 2)
            nodes.append(.init(box: nil, badge: nil, number: nil, icon: icon, iconName: icon == nil ? nil : item.icon,
                               texts: texts, rule: nil, bullets: []))
        }
        // Every box as tall as the tallest; the arrows meet them at the middle.
        for i in nodes.indices { nodes[i].box = CGRect(x: CGFloat(i) * (w + M.arrowGap), y: 0, width: w, height: height) }
        var arrows: [[CGPoint]] = []
        for i in 0..<max(0, n - 1) {
            let a = nodes[i].box!, b = nodes[i + 1].box!
            arrows.append([CGPoint(x: a.maxX + 7, y: a.midY), CGPoint(x: b.minX - 7, y: b.midY)])
        }
        return (nodes, arrows, [], CGSize(width: CGFloat(n) * w + CGFloat(n - 1) * M.arrowGap, height: height))
    }

    func steps() -> ([ExplainCardLayout.Node], [[CGPoint]], [[CGPoint]], CGSize) {
        let tx = M.badge + 16, tw = textWidth(tx: tx, max: M.stepsWidth), w = tx + tw, gap: CGFloat = 18
        var nodes: [ExplainCardLayout.Node] = []
        var y: CGFloat = 0
        for (i, item) in card.items.enumerated() {
            let badge = CGRect(x: 0, y: y, width: M.badge, height: M.badge)
            // The label's first line sits level with the badge's middle.
            let labelTop = y + (M.badge - m.lineHeight(.label)) / 2
            var texts = [text(item.label, .label, x: tx, y: labelTop, width: tw)]
            var bottom = texts[0].frame.maxY
            if let note = item.note {
                texts.append(text(note, .note, x: tx, y: bottom + 2, width: tw))
                bottom = texts[1].frame.maxY
            }
            nodes.append(.init(box: nil, badge: badge, number: i + 1, icon: nil, iconName: nil, texts: texts,
                               rule: nil, bullets: []))
            y = max(badge.maxY, bottom) + gap
        }
        var arrows: [[CGPoint]] = []
        for i in 0..<max(0, nodes.count - 1) {
            let a = nodes[i].badge!, b = nodes[i + 1].badge!
            arrows.append([CGPoint(x: a.midX, y: a.maxY + 5), CGPoint(x: b.midX, y: b.minY - 5)])
        }
        return (nodes, arrows, [], CGSize(width: w, height: y - gap))
    }

    func list() -> ([ExplainCardLayout.Node], [[CGPoint]], [[CGPoint]], CGSize) {
        let tile: CGFloat = 36, gap: CGFloat = 16
        let icons = card.items.contains { $0.icon != nil }
        let tx = icons ? tile + 16 : 22, tw = textWidth(tx: tx, max: M.listWidth), w = tx + tw
        var nodes: [ExplainCardLayout.Node] = []
        var y: CGFloat = 0
        for item in card.items {
            var texts = [text(item.label, .label, x: tx, y: y + (icons ? (tile - m.lineHeight(.label)) / 2 : 0), width: tw)]
            var bottom = texts[0].frame.maxY
            if let note = item.note {
                texts.append(text(note, .note, x: tx, y: bottom + 1, width: tw))
                bottom = texts[1].frame.maxY
            }
            let icon = icons ? CGRect(x: 0, y: y, width: tile, height: tile) : nil
            // Without icons each row gets a dash, level with the label's first line.
            let dash = icons ? [] : [CGPoint(x: 4, y: texts[0].frame.minY + m.lineHeight(.label) / 2)]
            nodes.append(.init(box: nil, badge: nil, number: nil, icon: icon, iconName: icon == nil ? nil : item.icon,
                               texts: texts, rule: nil, bullets: dash))
            y = max(icon?.maxY ?? 0, bottom) + gap
        }
        return (nodes, [], [], CGSize(width: w, height: y - gap))
    }

    func compare() -> ([ExplainCardLayout.Node], [[CGPoint]], [[CGPoint]], CGSize) {
        let n = card.items.count, w = M.compareColumnWidth(n), gap = M.compareGap
        let icons = card.items.contains { $0.icon != nil }
        var nodes: [ExplainCardLayout.Node] = []
        var height: CGFloat = 0
        for (i, item) in card.items.enumerated() {
            let x = CGFloat(i) * (w + gap)
            var y: CGFloat = 0
            var icon: CGRect?
            if icons {
                icon = CGRect(x: x + (w - M.iconSize) / 2, y: 0, width: M.iconSize, height: M.iconSize)
                y = M.iconSize + 8
            }
            var texts = [text(item.label, .label, x: x, y: y, width: w, centred: true)]
            y = texts[0].frame.maxY + 6
            let ruleWidth = min(box(item.label, .label, width: w).width + 12, w)
            let rule = [CGPoint(x: x + (w - ruleWidth) / 2, y: y), CGPoint(x: x + (w + ruleWidth) / 2, y: y)]
            y += 10
            if let note = item.note {
                let t = text(note, .note, x: x, y: y, width: w, centred: true)
                texts.append(t)
                y = t.frame.maxY + 8
            }
            var bullets: [CGPoint] = []
            for p in item.points {
                let t = text(p, .point, x: x + 18, y: y, width: w - 18)
                bullets.append(CGPoint(x: x + 4, y: y + m.lineHeight(.point) / 2))
                texts.append(t)
                y = t.frame.maxY + 6
            }
            height = max(height, y)
            nodes.append(.init(box: nil, badge: nil, number: nil, icon: icon, iconName: icon == nil ? nil : item.icon,
                               texts: texts, rule: rule, bullets: bullets))
        }
        var dividers: [[CGPoint]] = []
        for i in 1..<max(1, n) {
            let x = CGFloat(i) * (w + gap) - gap / 2
            dividers.append([CGPoint(x: x, y: 4), CGPoint(x: x, y: height - 4)])
        }
        return (nodes, [], dividers, CGSize(width: CGFloat(n) * w + CGFloat(n - 1) * gap, height: height))
    }

    func build() -> ExplainCardLayout {
        var (nodes, arrows, dividers, content) = content()
        let headingNeed = card.heading.map { min(box($0, .heading, width: M.maxWidth - 2 * M.pad).width, 520) } ?? 0
        let width = min(max(content.width, headingNeed) + 2 * M.pad, M.maxWidth).rounded(.up)
        let cardWidth = max(width, M.minWidth)
        let inner = cardWidth - 2 * M.pad
        var y = M.titleBar + M.pad - 4
        var heading: ExplainCardLayout.Text?
        var headingRule: [CGPoint]?
        if let h = card.heading {
            let t = text(h, .heading, x: M.pad, y: y, width: inner)
            heading = t
            let ruleWidth = min(t.frame.width * 0.6, 150)
            headingRule = [CGPoint(x: M.pad + 1, y: t.frame.maxY + 3), CGPoint(x: M.pad + 1 + ruleWidth, y: t.frame.maxY + 1)]
            y = t.frame.maxY + 22
        }
        // A flow or comparison centred across the board; steps and lists line up under the heading.
        let centred = card.layout == .flow || card.layout == .compare
        let dx = M.pad + (centred ? max(0, (inner - content.width) / 2) : 0), dy = y
        func move(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + dx, y: p.y + dy) }
        func move(_ r: CGRect) -> CGRect { r.offsetBy(dx: dx, dy: dy) }
        for i in nodes.indices {
            nodes[i].box = nodes[i].box.map(move)
            nodes[i].badge = nodes[i].badge.map(move)
            nodes[i].icon = nodes[i].icon.map(move)
            nodes[i].rule = nodes[i].rule?.map(move)
            nodes[i].bullets = nodes[i].bullets.map(move)
            for j in nodes[i].texts.indices { nodes[i].texts[j].frame = move(nodes[i].texts[j].frame) }
        }
        arrows = arrows.map { $0.map(move) }
        dividers = dividers.map { $0.map(move) }
        y += content.height
        var takeaway: ExplainCardLayout.Text?
        if let t = card.takeaway {
            let line = text(t, .takeaway, x: M.pad + 16, y: y + 22, width: inner - 16)
            takeaway = line
            y = line.frame.maxY
        }
        let cardRect = CGRect(x: 0, y: 0, width: cardWidth, height: (y + M.pad).rounded(.up))
        let titleBar = CGRect(x: 0, y: 0, width: cardWidth, height: M.titleBar)
        let close = CGRect(x: 12, y: (M.titleBar - M.closeSize) / 2, width: M.closeSize, height: M.closeSize)
        let titleText = text(card.title, .title, x: close.maxX + 10, y: (M.titleBar - m.lineHeight(.title)) / 2,
                             width: cardWidth - 2 * (close.maxX + 10), centred: true)
        // Chips under the card, left to right, wrapping at the card's width (or a little wider
        // under a narrow card, so two short questions still sit on one row).
        var chips: [ExplainCardLayout.Text] = []
        var cx: CGFloat = 0, cy = cardRect.maxY + M.chipsBelow
        let row = max(cardWidth, M.chipRow)
        for c in card.chips {
            let w = min(box(c, .chip, width: row - 2 * M.chipPadding).width + 2 * M.chipPadding, row)
            if cx > 0 && cx + w > row { cx = 0; cy += M.chipHeight + M.chipGap }
            chips.append(.init(text: c, style: .chip, frame: CGRect(x: cx, y: cy, width: w, height: M.chipHeight), centred: true))
            cx += w + M.chipGap
        }
        let height = chips.last.map { $0.frame.maxY } ?? cardRect.maxY
        let panelWidth = max(cardWidth, chips.map(\.frame.maxX).max() ?? 0)
        let board = CGRect(x: 0, y: M.titleBar, width: cardWidth, height: cardRect.height - M.titleBar)
        return ExplainCardLayout(size: CGSize(width: panelWidth, height: height), card: cardRect, titleBar: titleBar,
                                 title: titleText, close: close, board: board, heading: heading, headingRule: headingRule,
                                 nodes: nodes, arrows: arrows, dividers: dividers, takeaway: takeaway, chips: chips)
    }
}
