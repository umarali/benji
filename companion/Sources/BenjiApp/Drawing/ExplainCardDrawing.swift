import AppKit
import BenjiCore
import CoreText

/// The handwriting-style face for an explanation card's words: Kalam (OFL, bundled in
/// Resources/Fonts, credited in THIRD_PARTY_NOTICES), registered on first use. If it fails to
/// load the card falls back to the Mac's own Noteworthy, then the system font. No other app's
/// typefaces are used.
enum CardFont {
    /// PostScript names of the bundled face, regular and bold, in the order tried.
    static let bundled = ["Kalam-Regular", "Kalam-Bold"]
    static let fallback = ["Noteworthy-Light", "Noteworthy-Bold"]
    /// Extra folders to look in (the render tool points this at the repo's Resources/Fonts).
    static var searchFolders: [URL] = []
    private static let registered: Void = {
        var folders = searchFolders
        if let res = Bundle.main.resourceURL { folders.append(res.appendingPathComponent("Fonts")) }
        for folder in folders {
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for f in files where ["ttf", "otf"].contains(f.pathExtension.lowercased()) {
                CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil)
            }
        }
    }()

    static func handwriting(_ size: CGFloat, bold: Bool = false) -> NSFont {
        _ = registered
        let i = bold ? 1 : 0
        return NSFont(name: bundled[i], size: size) ?? NSFont(name: fallback[i], size: size)
            ?? .systemFont(ofSize: size, weight: bold ? .semibold : .regular)
    }

    /// Which face the card is drawn in (for the notes and the renders' captions).
    static var inUse: String { handwriting(12).fontName }

    static func font(_ style: ExplainTextStyle) -> NSFont {
        switch style {
        case .title: return .systemFont(ofSize: style.size, weight: .semibold)
        case .chip: return .systemFont(ofSize: style.size, weight: .medium)
        case .number: return .monospacedDigitSystemFont(ofSize: style.size, weight: .semibold)
        case .heading, .label: return handwriting(style.size, bold: true)
        case .note, .point, .takeaway: return handwriting(style.size)
        }
    }
}

/// Measures card text with the fonts it is drawn in (the layout in BenjiCore asks).
struct CardMeasure: ExplainTextMeasuring {
    func lineHeight(_ style: ExplainTextStyle) -> CGFloat {
        let f = CardFont.font(style)
        return ceil(f.ascender - f.descender + f.leading)
    }

    func size(_ text: String, _ style: ExplainTextStyle, width: CGFloat) -> CGSize {
        let r = (text as NSString).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                                options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                attributes: ExplainCardDrawing.attributes(style, colour: .white, centred: false))
        return CGSize(width: ceil(r.width), height: ceil(r.height))
    }
}

/// The card and its chips, drawn the same way in the live panel and the offscreen renders:
/// Benji's black card (`notch-black`, `radius-card`, a `notch-hairline` edge) with a raised
/// title bar, a faint grid on the board, mint strokes and icons, white handwriting. All
/// coordinates are the layout's: top-left origin, y down (draw into a flipped context).
enum ExplainCardDrawing {
    static let mint = NSColor(srgbRed: 0x66 / 255.0, green: 0xd4 / 255.0, blue: 0xcf / 255.0, alpha: 1)   // benji-mint
    static let board = NSColor(srgbRed: 0x0b / 255.0, green: 0x0c / 255.0, blue: 0x0d / 255.0, alpha: 1)
    static let raised = NSColor(srgbRed: 0x1c / 255.0, green: 0x1c / 255.0, blue: 0x1e / 255.0, alpha: 1)  // notch-raised
    static let titleBar = NSColor(srgbRed: 0x15 / 255.0, green: 0x15 / 255.0, blue: 0x17 / 255.0, alpha: 1)
    static let hairline = NSColor(white: 1, alpha: 0.12)                                                   // notch-hairline
    static let gridLine = NSColor(white: 1, alpha: 0.045)
    static let label = NSColor(white: 1, alpha: 0.92)
    static let secondary = NSColor(white: 1, alpha: 0.6)                                                   // notch-label-secondary

    static func attributes(_ style: ExplainTextStyle, colour: NSColor, centred: Bool) -> [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle()
        p.alignment = centred ? .center : .left
        p.lineBreakMode = .byWordWrapping
        return [.font: CardFont.font(style), .foregroundColor: colour, .paragraphStyle: p]
    }

    static func colour(_ style: ExplainTextStyle) -> NSColor {
        switch style {
        case .heading: return .white
        case .label, .takeaway: return label
        case .title: return NSColor(white: 1, alpha: 0.75)
        case .note, .point: return secondary
        case .chip: return NSColor(white: 1, alpha: 0.9)
        case .number: return mint
        }
    }

    static func draw(_ t: ExplainCardLayout.Text, alpha: CGFloat = 1) {
        guard alpha > 0 else { return }
        let attrs = attributes(t.style, colour: colour(t.style).withAlphaComponent(colour(t.style).alphaComponent * alpha),
                               centred: t.centred)
        (t.text as NSString).draw(with: t.frame.insetBy(dx: 0, dy: -1),
                                  options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine],
                                  attributes: attrs)
    }

    // MARK: the card

    /// The whole card at moment `t` of `reveal` (nil: fully drawn), chips included when `chips`.
    static func drawCard(_ layout: ExplainCardLayout, reveal: ExplainCardReveal? = nil, at t: Double = 0,
                         chips: Bool = true, hoveredChip: Int? = nil, hoveredClose: Bool = false) {
        let r = reveal ?? ExplainCardReveal(items: layout.nodes.count, hasTakeaway: layout.takeaway != nil, reduceMotion: true)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let card = layout.card
        let shape = NSBezierPath(roundedRect: card, xRadius: ExplainCardMetrics.radius, yRadius: ExplainCardMetrics.radius)
        ctx.saveGState()
        ctx.setAlpha(CGFloat(r.card(at: t)))
        board.setFill()
        shape.fill()
        // The title bar and the grid, inside the card's corners.
        ctx.saveGState()
        shape.addClip()
        titleBar.setFill()
        layout.titleBar.fill()
        drawGrid(in: layout.board)
        hairline.setFill()
        CGRect(x: card.minX, y: layout.titleBar.maxY - 1, width: card.width, height: 1).fill()
        ctx.restoreGState()
        hairline.setStroke()
        let edge = NSBezierPath(roundedRect: card.insetBy(dx: 0.5, dy: 0.5), xRadius: ExplainCardMetrics.radius - 0.5,
                                yRadius: ExplainCardMetrics.radius - 0.5)
        edge.lineWidth = 1
        edge.stroke()
        drawClose(in: layout.close, hovered: hoveredClose)
        draw(layout.title)

        if let h = layout.heading {
            let a = CGFloat(r.heading(at: t))
            draw(h, alpha: a)
            if let rule = layout.headingRule { stroke(rule, colour: mint.withAlphaComponent(a), width: 2.5) }
        }
        for d in layout.dividers { dashed(d) }
        for (i, arrow) in layout.arrows.enumerated() {
            drawArrow(arrow, progress: CGFloat(r.arrow(i, at: t)))
        }
        for (i, node) in layout.nodes.enumerated() {
            drawNode(node, alpha: CGFloat(r.item(i, at: t)))
        }
        if let k = layout.takeaway {
            let a = CGFloat(r.takeaway(at: t))
            if a > 0 {
                mint.withAlphaComponent(a).setFill()
                NSBezierPath(roundedRect: CGRect(x: k.frame.minX - 14, y: k.frame.minY + 3, width: 3, height: k.frame.height - 6),
                             xRadius: 1.5, yRadius: 1.5).fill()
                draw(k, alpha: a)
            }
        }
        ctx.restoreGState()
        if chips {
            let a = CGFloat(r.chips(at: t))
            for (i, c) in layout.chips.enumerated() { drawChip(c, hovered: hoveredChip == i, alpha: a) }
        }
    }

    static func drawGrid(in rect: CGRect) {
        gridLine.setFill()
        let g = ExplainCardMetrics.grid
        var x = rect.minX + g
        while x < rect.maxX { CGRect(x: x, y: rect.minY, width: 1, height: rect.height).fill(); x += g }
        var y = rect.minY + g
        while y < rect.maxY { CGRect(x: rect.minX, y: y, width: rect.width, height: 1).fill(); y += g }
    }

    static func drawNode(_ n: ExplainCardLayout.Node, alpha: CGFloat) {
        guard alpha > 0 else { return }
        if let box = n.box {
            let path = NSBezierPath(roundedRect: box.insetBy(dx: 0.75, dy: 0.75), xRadius: 7, yRadius: 7)
            NSColor(white: 1, alpha: 0.04 * alpha).setFill()
            path.fill()
            path.lineWidth = 1.5
            mint.withAlphaComponent(0.85 * alpha).setStroke()
            path.stroke()
        }
        if let b = n.badge {
            let circle = NSBezierPath(ovalIn: b.insetBy(dx: 0.75, dy: 0.75))
            board.withAlphaComponent(alpha).setFill()
            circle.fill()
            circle.lineWidth = 1.5
            mint.withAlphaComponent(alpha).setStroke()
            circle.stroke()
            if let k = n.number {
                let h = CardMeasure().lineHeight(.number)
                draw(.init(text: "\(k)", style: .number, frame: CGRect(x: b.minX, y: b.midY - h / 2, width: b.width, height: h),
                           centred: true), alpha: alpha)
            }
        }
        if let icon = n.icon {
            if n.box == nil, n.rule == nil {   // a list row's tile
                let tile = NSBezierPath(roundedRect: icon, xRadius: 8, yRadius: 8)
                NSColor(white: 1, alpha: 0.06 * alpha).setFill()
                tile.fill()
                tile.lineWidth = 1
                hairline.withAlphaComponent(0.12 * alpha).setStroke()
                tile.stroke()
                drawSymbol(n.iconName, in: icon.insetBy(dx: 8, dy: 8), alpha: alpha)
            } else {
                drawSymbol(n.iconName, in: icon, alpha: alpha)
            }
        }
        if let rule = n.rule { stroke(rule, colour: mint.withAlphaComponent(alpha), width: 2) }
        for b in n.bullets {
            stroke([CGPoint(x: b.x, y: b.y), CGPoint(x: b.x + 9, y: b.y)], colour: mint.withAlphaComponent(alpha), width: 2)
        }
        for t in n.texts { draw(t, alpha: alpha) }
    }

    /// An SF Symbol in mint, or a small mint ring when the Mac has no symbol by that name.
    static func drawSymbol(_ name: String?, in rect: CGRect, alpha: CGFloat) {
        let config = NSImage.SymbolConfiguration(pointSize: rect.height * 0.86, weight: .regular)
            .applying(.init(paletteColors: [mint]))
        if let name, let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
            // Fit the symbol's own aspect inside the rect, centred.
            let s = image.size, k = min(rect.width / s.width, rect.height / s.height)
            let fit = CGRect(x: rect.midX - s.width * k / 2, y: rect.midY - s.height * k / 2, width: s.width * k, height: s.height * k)
            image.draw(in: fit, from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)
        } else {
            let d = min(rect.width, rect.height) * 0.5
            let ring = NSBezierPath(ovalIn: CGRect(x: rect.midX - d / 2, y: rect.midY - d / 2, width: d, height: d))
            ring.lineWidth = 2
            mint.withAlphaComponent(alpha).setStroke()
            ring.stroke()
        }
    }

    static func stroke(_ points: [CGPoint], colour: NSColor, width: CGFloat) {
        guard let first = points.first else { return }
        let p = NSBezierPath()
        p.move(to: first)
        points.dropFirst().forEach { p.line(to: $0) }
        p.lineWidth = width
        p.lineCapStyle = .round
        p.lineJoinStyle = .round
        colour.setStroke()
        p.stroke()
    }

    static func dashed(_ points: [CGPoint]) {
        guard points.count == 2 else { return }
        let p = NSBezierPath()
        p.move(to: points[0])
        p.line(to: points[1])
        p.lineWidth = 1
        p.setLineDash([4, 5], count: 2, phase: 0)
        NSColor(white: 1, alpha: 0.18).setStroke()
        p.stroke()
    }

    /// The arrow's shaft drawn to `progress` like a pen stroke; the head once it arrives.
    static func drawArrow(_ points: [CGPoint], progress: CGFloat) {
        guard progress > 0, points.count >= 2 else { return }
        var lengths: [CGFloat] = []
        for (a, b) in zip(points, points.dropFirst()) { lengths.append(hypot(b.x - a.x, b.y - a.y)) }
        var left = lengths.reduce(0, +) * progress
        var drawn = [points[0]]
        for (i, len) in lengths.enumerated() {
            let a = points[i], b = points[i + 1]
            if left >= len { drawn.append(b); left -= len; continue }
            let f = len > 0 ? left / len : 0
            drawn.append(CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f))
            break
        }
        stroke(drawn, colour: mint, width: 2)
        guard progress >= 1, let tip = points.last else { return }
        let from = points[points.count - 2]
        let angle = atan2(tip.y - from.y, tip.x - from.x), barb: CGFloat = 9, spread: CGFloat = 0.5
        stroke([CGPoint(x: tip.x - barb * cos(angle - spread), y: tip.y - barb * sin(angle - spread)), tip,
                CGPoint(x: tip.x - barb * cos(angle + spread), y: tip.y - barb * sin(angle + spread))],
               colour: mint, width: 2)
    }

    static func drawClose(in r: CGRect, hovered: Bool = false) {
        (hovered ? NSColor(white: 1, alpha: 0.18) : raised).setFill()
        NSBezierPath(ovalIn: r).fill()
        let x = NSBezierPath()
        let c = CGPoint(x: r.midX, y: r.midY), d: CGFloat = 3.6
        x.move(to: CGPoint(x: c.x - d, y: c.y - d)); x.line(to: CGPoint(x: c.x + d, y: c.y + d))
        x.move(to: CGPoint(x: c.x + d, y: c.y - d)); x.line(to: CGPoint(x: c.x - d, y: c.y + d))
        x.lineWidth = 1.5
        x.lineCapStyle = .round
        (hovered ? NSColor.white : secondary).setStroke()
        x.stroke()
    }

    static func drawChip(_ c: ExplainCardLayout.Text, hovered: Bool, alpha: CGFloat) {
        guard alpha > 0 else { return }
        let f = c.frame
        let pill = NSBezierPath(roundedRect: f.insetBy(dx: 0.5, dy: 0.5), xRadius: f.height / 2, yRadius: f.height / 2)
        (hovered ? NSColor(srgbRed: 0x26 / 255.0, green: 0x2a / 255.0, blue: 0x2b / 255.0, alpha: alpha)
                 : NSColor(srgbRed: 0x14 / 255.0, green: 0x15 / 255.0, blue: 0x16 / 255.0, alpha: alpha)).setFill()
        pill.fill()
        pill.lineWidth = 1
        mint.withAlphaComponent((hovered ? 0.9 : 0.45) * alpha).setStroke()
        pill.stroke()
        let h = CardMeasure().lineHeight(.chip)
        draw(.init(text: c.text, style: .chip,
                   frame: CGRect(x: f.minX + ExplainCardMetrics.chipPadding, y: f.midY - h / 2,
                                 width: f.width - 2 * ExplainCardMetrics.chipPadding, height: h), centred: true), alpha: alpha)
    }
}
