// Renders explanation cards offscreen (D-125): each reply in tools/card-render/replies is parsed
// with the app's own parser, laid out by BenjiCore, drawn by the app's own ExplainCardDrawing and
// placed by ExplainCardPlacement on a synthetic screen (a page full of text, never a capture of
// the real screen), with the busy map measured from that screen's pixels the way the app measures
// a screenshot. Writes each card close up at 2×, each screen at 1×, and the placements to
// placements.txt. Run with tools/card-render/render.sh <output dir>.
import AppKit
import BenjiCore

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let repliesDir = URL(fileURLWithPath: CommandLine.arguments[2])
CardFont.searchFolders = [URL(fileURLWithPath: CommandLine.arguments[3])]

let screen = CGSize(width: 1512, height: 982)                     // 14-inch MacBook Pro, in points
let menuBar: CGFloat = 33
let visible = CGRect(x: 0, y: menuBar, width: screen.width, height: screen.height - menuBar)
let notch = CGRect(x: 661, y: 0, width: 190, height: 32)
let panel = CGRect(x: 556, y: 0, width: 400, height: 150)        // Benji's open notch panel

/// Our own filler: a made-up page of notes, long enough to fill a window with text.
let filler = """
The garden plan for spring starts with the soil. Turn the beds in March, once the ground is dry enough to crumble in \
your hand, and work in a barrow of compost for every square metre. Leave the far bed fallow this year; it grew potatoes \
twice and needs the rest. Peas go in first, along the fence where they can climb, then lettuce in short rows every two \
weeks so there is always some ready. Beans wait for May, when the nights stay warm. Mark each row with a stick and the \
date, because by June nobody remembers what was sown where. Water in the morning, not at night, and water the roots, \
not the leaves. Slugs are the main worry after rain: a ring of grit around the young plants helps more than anything \
sold for the purpose. The tomatoes stay in the greenhouse until the last frost has passed, then harden off on the step \
for a week before planting out. Pinch out the side shoots as they appear and tie the main stem to its cane as it grows. \
Keep notes as the season goes: what came up, what failed, which variety tasted best. Next year's plan starts from them.
"""

func drawText(_ s: String, in r: CGRect, size: CGFloat, weight: NSFont.Weight = .regular, colour: NSColor) {
    let p = NSMutableParagraphStyle()
    p.lineSpacing = 4
    (s as NSString).draw(with: r, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                         attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: colour,
                                      .paragraphStyle: p])
}

/// The synthetic screen: wallpaper, a light page of text (the whole width, or the left part),
/// the menu bar, the notch and Benji's panel with the spoken line.
func drawScreen(pageWidth: CGFloat, spoken: String) {
    let all = CGRect(origin: .zero, size: screen)
    NSGradient(starting: NSColor(srgbRed: 0.30, green: 0.42, blue: 0.58, alpha: 1),
               ending: NSColor(srgbRed: 0.62, green: 0.52, blue: 0.62, alpha: 1))!.draw(in: all, angle: 70)
    let window = CGRect(x: 28, y: 48, width: pageWidth, height: screen.height - 70)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowBlurRadius = 24
    shadow.shadowColor = NSColor(white: 0, alpha: 0.35)
    shadow.set()
    NSColor.white.setFill()
    NSBezierPath(roundedRect: window, xRadius: 12, yRadius: 12).fill()
    NSGraphicsContext.restoreGraphicsState()
    NSColor(white: 0.95, alpha: 1).setFill()
    NSBezierPath(roundedRect: CGRect(x: window.minX, y: window.minY, width: window.width, height: 40), xRadius: 12, yRadius: 12).fill()
    for (i, c) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
        c.setFill()
        NSBezierPath(ovalIn: CGRect(x: window.minX + 16 + CGFloat(i) * 20, y: window.minY + 14, width: 12, height: 12)).fill()
    }
    drawText("garden-notes.md", in: CGRect(x: window.midX - 80, y: window.minY + 12, width: 160, height: 18), size: 13,
             weight: .medium, colour: NSColor(white: 0.35, alpha: 1))
    let body = window.insetBy(dx: 48, dy: 0)
    drawText("Spring plan", in: CGRect(x: body.minX, y: window.minY + 66, width: body.width, height: 40), size: 28,
             weight: .bold, colour: NSColor(white: 0.1, alpha: 1))
    var y = window.minY + 120
    var k = 0
    while y < window.maxY - 120 {
        let para = String(filler.dropFirst((k * 97) % 300))
        drawText(para, in: CGRect(x: body.minX, y: y, width: body.width, height: 150), size: 15, colour: NSColor(white: 0.18, alpha: 1))
        y += 172
        k += 1
    }
    // Menu bar, notch, Benji's panel.
    NSColor(white: 0, alpha: 0.3).setFill()
    CGRect(x: 0, y: 0, width: screen.width, height: menuBar).fill()
    drawText("Notes    File    Edit    View", in: CGRect(x: 18, y: 8, width: 400, height: 18), size: 13, colour: .white)
    drawText("Sun 1 Nov  09:41", in: CGRect(x: screen.width - 140, y: 8, width: 130, height: 18), size: 13, colour: .white)
    NSColor.black.setFill()
    NSBezierPath(roundedRect: panel, xRadius: 22, yRadius: 22).fill()
    CGRect(x: panel.minX, y: 0, width: panel.width, height: 30).fill()
    drawText(spoken, in: CGRect(x: panel.minX + 20, y: panel.maxY - 66, width: panel.width - 40, height: 54), size: 13,
             colour: NSColor(white: 1, alpha: 0.88))
}

/// Draws into a flipped bitmap of `size` points at `scale`.
func bitmap(_ size: CGSize, scale: CGFloat, _ draw: () -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    ctx.cgContext.translateBy(x: 0, y: size.height)   // the context already maps points to pixels
    ctx.cgContext.scaleBy(x: 1, y: -1)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx.cgContext, flipped: true)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

/// Brightness of each pixel, as the app reads a screenshot.
func luma(_ rep: NSBitmapImageRep) -> [UInt8] {
    let w = rep.pixelsWide, h = rep.pixelsHigh
    var out = [UInt8](repeating: 0, count: w * h)
    let space = CGColorSpaceCreateDeviceGray()
    out.withUnsafeMutableBytes { buf in
        let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: space,
                            bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.draw(rep.cgImage!, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    return out
}

func write(_ rep: NSBitmapImageRep, _ name: String) {
    try! rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
}

func drawPlaced(_ layout: ExplainCardLayout, at origin: CGPoint) {
    guard let ctx = NSGraphicsContext.current?.cgContext else { return }
    ctx.saveGState()
    ctx.translateBy(x: origin.x, y: origin.y)
    // The panel's shadow: the window server draws it under the opaque card.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowBlurRadius = 28
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.shadowColor = NSColor(white: 0, alpha: 0.55)
    shadow.set()
    NSColor.black.setFill()
    NSBezierPath(roundedRect: layout.card, xRadius: ExplainCardMetrics.radius, yRadius: ExplainCardMetrics.radius).fill()
    NSGraphicsContext.restoreGraphicsState()
    ExplainCardDrawing.drawCard(layout)
    ctx.restoreGState()
}

var log = "Explanation card renders (D-125). Handwriting face in use: \(CardFont.inUse)\n\n"
let names = (try! FileManager.default.contentsOfDirectory(atPath: repliesDir.path)).filter { $0.hasSuffix(".txt") }.sorted()
for file in names {
    let name = String(file.dropLast(4))
    let reply = try! String(contentsOf: repliesDir.appendingPathComponent(file), encoding: .utf8)
    let (spoken, card) = ExplainCardGrammar.parse(reply)
    guard let card else { print("no card in \(file)"); exit(1) }
    let layout = ExplainCardLayout.make(card, measure: CardMeasure())
    write(bitmap(layout.size, scale: 2) { ExplainCardDrawing.drawCard(layout) }, "card-\(name).png")
    // Two screens: a page of text across the whole display, and one across two thirds of it.
    for (variant, pageWidth) in [("busy", screen.width - 56), ("half", 900)] as [(String, CGFloat)] {
        let background = bitmap(screen, scale: 1) { drawScreen(pageWidth: pageWidth, spoken: spoken) }
        let start = DispatchTime.now()
        let map = BusyMap.measure(luma: luma(background), width: background.pixelsWide, height: background.pixelsHigh,
                                  pointsWide: screen.width)!
        let measured = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6
        let placeStart = DispatchTime.now()
        let placed = ExplainCardPlacement.place(size: layout.size, visible: visible,
                                                prefer: CGPoint(x: panel.midX, y: panel.maxY + 16), avoid: [panel], busy: map)
        let placing = Double(DispatchTime.now().uptimeNanoseconds - placeStart.uptimeNanoseconds) / 1e6
        let image = NSImage(size: screen)
        image.addRepresentation(background)
        write(bitmap(screen, scale: 1) {
            image.draw(in: CGRect(origin: .zero, size: screen), from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
            drawPlaced(layout, at: placed.frame.origin)
        }, "screen-\(name)-\(variant).png")
        let busyTiles = map.density.filter { $0 >= BusyMap.busyTile }.count
        log += String(format: "%@ %@: card %.0f×%.0f at (%.0f, %.0f); %.0f%% of the card over busy tiles (%@); "
                      + "%d of %d tiles busy; busy map %.1f ms, placement %.1f ms\n",
                      name, variant, layout.size.width, layout.size.height, placed.frame.minX, placed.frame.minY,
                      placed.busyCover * 100, placed.overBusySpace ? "busy space, opaque card" : "calm space",
                      busyTiles, map.density.count, measured, placing)
    }
}
try! log.write(to: out.appendingPathComponent("placements.txt"), atomically: true, encoding: .utf8)
print(log)
