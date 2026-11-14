import AppKit
import BenjiCore

/// Benji's figure card and its labels, drawn the same way in the live card and the offscreen
/// renders: the all-black card (`notch-black`, `radius-card`, a `notch-hairline` edge) with the
/// title in its header, and label pills with mint leader lines keylined as Overlay.md prescribes.
/// All coordinates are top-left origin, y down (draw into a flipped context).
enum FigureCardDrawing {
    static let size = CGSize(width: 600, height: 400)
    static let header: CGFloat = 40
    static let radius: CGFloat = 14              // radius-card
    static let inset: CGFloat = 12               // space-3: labels keep this far from the card's edge
    static let closeSize: CGFloat = 22

    static let mint = NSColor(srgbRed: 0x66 / 255.0, green: 0xd4 / 255.0, blue: 0xcf / 255.0, alpha: 1)   // benji-mint
    static let keyline = NSColor(white: 0, alpha: 0.6)
    static let raised = NSColor(srgbRed: 0x1c / 255.0, green: 0x1c / 255.0, blue: 0x1e / 255.0, alpha: 1)  // notch-raised
    static let hairline = NSColor(white: 1, alpha: 0.12)                                                   // notch-hairline
    static let label = NSColor(white: 1, alpha: 0.85)                                                      // notch-label
    static let secondary = NSColor(white: 1, alpha: 0.55)                                                  // notch-label-secondary

    static func stageRect(in card: CGRect) -> CGRect {
        CGRect(x: card.minX, y: card.minY + header, width: card.width, height: card.height - header)
    }

    static func closeRect(in card: CGRect) -> CGRect {
        CGRect(x: card.maxX - 12 - closeSize, y: card.minY + (header - closeSize) / 2, width: closeSize, height: closeSize)
    }

    /// Left of the close button: back to the model's view (shown once the figure was moved).
    static func resetRect(in card: CGRect) -> CGRect {
        closeRect(in: card).offsetBy(dx: -(closeSize + 8), dy: 0)
    }

    /// A circular arrow on the raised circle, in the close button's style.
    static func drawReset(in r: CGRect) {
        raised.setFill()
        NSBezierPath(ovalIn: r).fill()
        let c = CGPoint(x: r.midX, y: r.midY), rad: CGFloat = 5
        let arc = NSBezierPath()
        arc.appendArc(withCenter: c, radius: rad, startAngle: 40, endAngle: 320, clockwise: false)
        arc.lineWidth = 1.5
        arc.lineCapStyle = .round
        secondary.setStroke()
        arc.stroke()
        // The arrowhead at the arc's end (320°), pointing on round.
        let a = 320 * CGFloat.pi / 180
        let tip = CGPoint(x: c.x + rad * cos(a), y: c.y + rad * sin(a))
        let head = NSBezierPath()
        head.move(to: CGPoint(x: tip.x + 3.2, y: tip.y + 0.6))
        head.line(to: tip)
        head.line(to: CGPoint(x: tip.x + 0.6, y: tip.y + 3.4))
        head.lineWidth = 1.5
        head.lineCapStyle = .round
        head.lineJoinStyle = .round
        head.stroke()
    }

    static func drawCard(title: String, in card: CGRect) {
        let path = NSBezierPath(roundedRect: card, xRadius: radius, yRadius: radius)
        NSColor.black.setFill()
        path.fill()
        hairline.setStroke()
        let edge = NSBezierPath(roundedRect: card.insetBy(dx: 0.5, dy: 0.5), xRadius: radius - 0.5, yRadius: radius - 0.5)
        edge.lineWidth = 1
        edge.stroke()
        let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: label]
        let titleRect = CGRect(x: card.minX + 16, y: card.minY + (header - 17) / 2,
                               width: card.width - 32 - closeSize - 8, height: 17)
        (title as NSString).draw(with: titleRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
        drawClose(in: closeRect(in: card))
    }

    static func drawClose(in r: CGRect) {
        let circle = NSBezierPath(ovalIn: r)
        raised.setFill()
        circle.fill()
        secondary.setStroke()
        let x = NSBezierPath()
        let c = CGPoint(x: r.midX, y: r.midY), d: CGFloat = 4
        x.move(to: CGPoint(x: c.x - d, y: c.y - d)); x.line(to: CGPoint(x: c.x + d, y: c.y + d))
        x.move(to: CGPoint(x: c.x + d, y: c.y - d)); x.line(to: CGPoint(x: c.x - d, y: c.y + d))
        x.lineWidth = 1.5
        x.lineCapStyle = .round
        x.stroke()
    }

    // MARK: labels

    static let pillFont = NSFont.systemFont(ofSize: 12, weight: .semibold)   // callout, semibold
    static let pillHeight: CGFloat = 22
    static let pillPadding: CGFloat = 10

    static func pillSize(_ text: String) -> CGSize {
        let w = (text as NSString).size(withAttributes: [.font: pillFont]).width
        return CGSize(width: min(ceil(w) + 2 * pillPadding, FigureLabelLayout.maxWidth), height: pillHeight)
    }

    struct Placed { var text: String; var anchor: CGPoint; var frame: CGRect }

    /// Anchors and the model's box (in the stage's own points) to placed pills.
    static func place(_ scene: FigureScene, anchors: [CGPoint?], model: CGRect, stage: CGRect) -> [Placed] {
        let area = CGRect(x: inset, y: inset, width: stage.width - 2 * inset, height: stage.height - 2 * inset)
        var items: [FigureLabelLayout.Item] = []
        var which: [Int] = []
        for (i, a) in anchors.enumerated() {
            guard let a else { continue }
            let l = scene.figure.labels[i]
            items.append(.init(anchor: a, size: pillSize(l.text), side: l.side))
            which.append(i)
        }
        let frames = FigureLabelLayout.place(items, model: model, area: area)
        return zip(which, frames).compactMap { i, f in
            f.map { Placed(text: scene.figure.labels[i].text, anchor: anchors[i]!, frame: $0) }
        }
    }

    /// Leaders first (under the pills), then the pills. `origin` offsets stage points into the context.
    static func drawLabels(_ placed: [Placed], origin: CGPoint = .zero) {
        func o(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + origin.x, y: p.y + origin.y) }
        for p in placed {
            let f = p.frame.offsetBy(dx: origin.x, dy: origin.y)
            let a = o(p.anchor)
            // The pill's edge nearest the anchor.
            let end: CGPoint
            if a.x < f.minX { end = CGPoint(x: f.minX, y: f.midY) }
            else if a.x > f.maxX { end = CGPoint(x: f.maxX, y: f.midY) }
            else if a.y < f.minY { end = CGPoint(x: f.midX, y: f.minY) }
            else { end = CGPoint(x: f.midX, y: f.maxY) }
            let line = NSBezierPath()
            line.move(to: a); line.line(to: end)
            line.lineCapStyle = .round
            line.lineWidth = 4; keyline.setStroke(); line.stroke()      // 1 pt keyline each side
            line.lineWidth = 2; mint.setStroke(); line.stroke()
            keyline.setFill(); NSBezierPath(ovalIn: CGRect(x: a.x - 4, y: a.y - 4, width: 8, height: 8)).fill()
            mint.setFill(); NSBezierPath(ovalIn: CGRect(x: a.x - 2.5, y: a.y - 2.5, width: 5, height: 5)).fill()
        }
        for p in placed {
            let f = p.frame.offsetBy(dx: origin.x, dy: origin.y)
            let pill = NSBezierPath(roundedRect: f, xRadius: f.height / 2, yRadius: f.height / 2)
            raised.setFill(); pill.fill()
            let edge = NSBezierPath(roundedRect: f.insetBy(dx: 0.5, dy: 0.5), xRadius: f.height / 2 - 0.5, yRadius: f.height / 2 - 0.5)
            edge.lineWidth = 1; hairline.setStroke(); edge.stroke()
            let attrs: [NSAttributedString.Key: Any] = [.font: pillFont, .foregroundColor: NSColor.white]
            let textRect = f.insetBy(dx: pillPadding, dy: (f.height - 15) / 2)
            (p.text as NSString).draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
        }
    }
}
