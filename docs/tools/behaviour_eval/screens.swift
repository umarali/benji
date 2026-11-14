import AppKit

// Draws the behaviour eval's synthetic screenshots (no real screen is ever captured) and writes
// truth.json: each screen's file, its ScreenshotGeometry (the app's own mapping, compiled in from
// BenjiCore) and the pixel boxes of the things the eval asks Benji to mark. run.py compiles this
// with ScreenshotGeometry.swift and runs it once per eval.
//
// Every screen is what the app would send from a 14-inch MacBook Pro at its default size:
// 1512 x 982 pt, captured at 2x and downscaled by ScreenCapturePolicy to 1330 x 864.
// The notch never shows in a capture: that part of the menu bar is just menu-bar background.

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let W = 1330, H = 864
let display = CGRect(x: 0, y: 0, width: 1512, height: 982)
let hardwareNotch = CGRect(x: 656, y: 982 - 32, width: 200, height: 32)
let geometry = ScreenshotGeometry.make(pixelSize: CGSize(width: W, height: H), screenFrame: display,
                                       notch: hardwareNotch, menuBarHeight: 32, builtIn: true, displayCount: 1)!
let menuBar = CGFloat(geometry.menuBarHeight)

typealias Box = [Int]   // x1, y1, x2, y2

func box(_ r: CGRect) -> Box {
    [Int(r.minX.rounded(.down)), Int(r.minY.rounded(.down)), Int(r.maxX.rounded(.up)), Int(r.maxY.rounded(.up))]
}

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// One screen, drawn top-left origin.
final class Canvas {
    let rep: NSBitmapImageRep
    init() {
        rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
        let ctx = NSGraphicsContext(bitmapImageRep: rep)!
        ctx.cgContext.translateBy(x: 0, y: CGFloat(H))
        ctx.cgContext.scaleBy(x: 1, y: -1)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx.cgContext, flipped: true)
    }

    func fill(_ r: CGRect, _ c: NSColor, radius: CGFloat = 0) {
        c.setFill()
        NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
    }

    func stroke(_ r: CGRect, _ c: NSColor, width: CGFloat = 1, radius: CGFloat = 0) {
        c.setStroke()
        let p = NSBezierPath(roundedRect: r.insetBy(dx: width / 2, dy: width / 2), xRadius: radius, yRadius: radius)
        p.lineWidth = width
        p.stroke()
    }

    func gradient(_ r: CGRect, _ top: NSColor, _ bottom: NSColor) {
        NSGradient(starting: top, ending: bottom)!.draw(in: r, angle: 90)
    }

    /// Draws one line of text with its top-left at `at`; returns the text's box.
    @discardableResult
    func text(_ s: String, at: CGPoint, size: CGFloat, color c: NSColor = color(0x1D1D1F),
              weight: NSFont.Weight = .regular) -> CGRect {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                    .foregroundColor: c]
        let str = NSAttributedString(string: s, attributes: attrs)
        str.draw(at: at)
        return CGRect(origin: at, size: str.size())
    }

    /// Text centred in `r`.
    @discardableResult
    func centred(_ s: String, in r: CGRect, size: CGFloat, color c: NSColor = color(0x1D1D1F),
                 weight: NSFont.Weight = .regular) -> CGRect {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight)]
        let sz = NSAttributedString(string: s, attributes: attrs).size()
        return text(s, at: CGPoint(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2), size: size, color: c, weight: weight)
    }

    func button(_ title: String, _ r: CGRect, primary: Bool = false) -> CGRect {
        fill(r, primary ? color(0x0A84FF) : color(0xFFFFFF), radius: 6)
        if !primary { stroke(r, color(0xC4C4C8), radius: 6) }
        centred(title, in: r, size: 13, color: primary ? .white : color(0x1D1D1F), weight: primary ? .semibold : .regular)
        return r
    }

    /// A window with a title bar; returns its content area.
    func window(_ r: CGRect, title: String) -> CGRect {
        color(0x000000, 0.25).setFill()
        NSBezierPath(roundedRect: r.offsetBy(dx: 0, dy: 6).insetBy(dx: -4, dy: -4), xRadius: 14, yRadius: 14).fill()
        fill(r, color(0xFFFFFF), radius: 10)
        let bar = CGRect(x: r.minX, y: r.minY, width: r.width, height: 28)
        fill(bar, color(0xEDEDF0), radius: 10)
        fill(CGRect(x: r.minX, y: r.minY + 18, width: r.width, height: 10), color(0xEDEDF0))
        for (i, c) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
            fill(CGRect(x: r.minX + 12 + CGFloat(i) * 20, y: r.minY + 8, width: 12, height: 12), color(UInt32(c)), radius: 6)
        }
        centred(title, in: bar, size: 13, color: color(0x4A4A4E), weight: .semibold)
        return CGRect(x: r.minX, y: r.minY + 28, width: r.width, height: r.height - 28)
    }

    /// The menu bar, with nothing drawn where the notch is (captures never show it).
    func menu(app: String, items: [String]) {
        fill(CGRect(x: 0, y: 0, width: W, height: Int(menuBar)), color(0xE9E9ED, 0.96))
        var x: CGFloat = 16
        text("\u{F8FF}", at: CGPoint(x: x, y: 6), size: 14)
        x += 30
        for (i, item) in ([app] + items).enumerated() {
            x = text(item, at: CGPoint(x: x, y: 6), size: 13, weight: i == 0 ? .bold : .regular).maxX + 18
        }
        text("Fri 31 Oct  10:42", at: CGPoint(x: CGFloat(W) - 130, y: 6), size: 13)
        fill(CGRect(x: CGFloat(W) - 170, y: 9, width: 22, height: 11), color(0x3A3A3C), radius: 3)
    }

    func wallpaper() {
        gradient(CGRect(x: 0, y: 0, width: W, height: H), color(0x2B4F7E), color(0x7FA3C8))
    }

    func save(_ name: String) {
        NSGraphicsContext.current?.flushGraphics()
        try! rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
    }
}

var truth: [String: Any] = [:]

// 1. The desktop: a text editor asking whether to save, a Dock, and empty wallpaper on the right.
do {
    let c = Canvas()
    c.wallpaper()
    c.menu(app: "TextEdit", items: ["File", "Edit", "Format", "View", "Window", "Help"])
    let body = c.window(CGRect(x: 150, y: 80, width: 750, height: 560), title: "Notes.txt — Edited")
    for (i, line) in ["Things to sort out this week", "- book the car service", "- reply to the landlord",
                      "- pick up the dry cleaning"].enumerated() {
        c.text(line, at: CGPoint(x: body.minX + 20, y: body.minY + 16 + CGFloat(i) * 24), size: 15)
    }
    let dialog = CGRect(x: 345, y: 140, width: 360, height: 180)
    c.fill(dialog.insetBy(dx: -1, dy: -1), color(0xBDBDC2), radius: 12)
    c.fill(dialog, color(0xF6F6F8), radius: 12)
    c.fill(CGRect(x: dialog.minX + 20, y: dialog.minY + 20, width: 44, height: 44), color(0x8E8E93), radius: 9)
    c.text("Do you want to keep the changes", at: CGPoint(x: dialog.minX + 80, y: dialog.minY + 20), size: 13, weight: .bold)
    c.text("you made to “Notes.txt”?", at: CGPoint(x: dialog.minX + 80, y: dialog.minY + 38), size: 13, weight: .bold)
    c.text("Your changes will be lost if you don't save them.",
           at: CGPoint(x: dialog.minX + 80, y: dialog.minY + 66), size: 11, color: color(0x6E6E73))
    let dont = c.button("Don't Save", CGRect(x: dialog.minX + 20, y: dialog.maxY - 44, width: 92, height: 26))
    let cancel = c.button("Cancel", CGRect(x: dialog.maxX - 176, y: dialog.maxY - 44, width: 74, height: 26))
    let save = c.button("Save", CGRect(x: dialog.maxX - 94, y: dialog.maxY - 44, width: 74, height: 26), primary: true)
    let dock = CGRect(x: 420, y: CGFloat(H) - 54, width: 490, height: 48)
    c.fill(dock, color(0xFFFFFF, 0.35), radius: 14)
    for i in 0..<9 {
        let hue = [0x1E90FF, 0x34C759, 0xFF9500, 0xFF3B30, 0xAF52DE, 0x5AC8FA, 0xFFCC00, 0x8E8E93, 0x30B0C7][i]
        c.fill(CGRect(x: dock.minX + 14 + CGFloat(i) * 52, y: dock.minY + 5, width: 38, height: 38), color(UInt32(hue)), radius: 9)
    }
    c.save("desktop.png")
    truth["desktop"] = ["file": "desktop.png",
                        "targets": ["save": box(save), "cancel": box(cancel), "dont_save": box(dont),
                                    "dialog": box(dialog), "window": box(CGRect(x: 150, y: 80, width: 750, height: 560)),
                                    "empty": [930, Int(menuBar) + 10, W - 10, Int(dock.minY) - 10],
                                    // The editor's blank page under the dialog is empty too.
                                    "empty_page": [160, Int(dialog.maxY) + 10, 890, 630]]]
}

// 2. A sign-up form in a browser, with an invalid email.
do {
    let c = Canvas()
    c.fill(CGRect(x: 0, y: 0, width: W, height: H), color(0xDADDE3))
    c.menu(app: "Safari", items: ["File", "Edit", "View", "History", "Bookmarks", "Window", "Help"])
    let page = c.window(CGRect(x: 60, y: 46, width: 1210, height: 790), title: "Create account")
    let url = CGRect(x: page.midX - 220, y: page.minY + 8, width: 440, height: 26)
    c.fill(url, color(0xEDEDF0), radius: 7)
    c.centred("signup.example.test", in: url, size: 12, color: color(0x6E6E73))
    c.text("Create your account", at: CGPoint(x: 420, y: 140), size: 26, weight: .bold)
    func field(_ label: String, y: CGFloat, value: String, error: Bool = false) -> CGRect {
        c.text(label, at: CGPoint(x: 420, y: y), size: 13, weight: .semibold)
        let r = CGRect(x: 420, y: y + 22, width: 480, height: 38)
        c.fill(r, .white, radius: 7)
        c.stroke(r, error ? color(0xE5484D) : color(0xC4C4C8), width: error ? 2 : 1, radius: 7)
        c.text(value, at: CGPoint(x: r.minX + 12, y: r.minY + 10), size: 15)
        return r
    }
    let name = field("Full name", y: 200, value: "Jane Doe")
    let email = field("Email", y: 280, value: "jane.doe@example", error: true)
    let error = c.text("Please enter a valid email address.", at: CGPoint(x: 420, y: email.maxY + 8), size: 13,
                       color: color(0xE5484D))
    let password = field("Password", y: 386, value: "••••••••••")
    let cancel = c.button("Cancel", CGRect(x: 660, y: 480, width: 110, height: 40))
    let save = c.button("Save", CGRect(x: 790, y: 480, width: 110, height: 40), primary: true)
    c.save("form.png")
    truth["form"] = ["file": "form.png",
                     "targets": ["name": box(name), "email": box(email), "error": box(error),
                                 "password": box(password), "cancel": box(cancel), "save": box(save)]]
}

// 3. A document: one paragraph, six lines.
do {
    let c = Canvas()
    c.wallpaper()
    c.menu(app: "TextEdit", items: ["File", "Edit", "Format", "View", "Window", "Help"])
    let body = c.window(CGRect(x: 120, y: 60, width: 1090, height: 740), title: "River town.txt")
    let lines = ["The river town woke slowly on Saturday mornings, long before the shops opened.",
                 "Fishermen carried their nets down to the water while the bakery lit its ovens.",
                 "By eight o'clock the square was full of bicycles, dogs and half-awake children.",
                 "Nobody hurried; the clock on the old church had been ten minutes slow for years.",
                 "Visitors found this charming at first and maddening by the end of the week.",
                 "Still, most of them came back the next summer, and the summer after that."]
    let boxes = lines.enumerated().map { i, s in
        box(c.text(s, at: CGPoint(x: body.minX + 40, y: body.minY + 40 + CGFloat(i) * 34), size: 18))
    }
    c.save("document.png")
    truth["document"] = ["file": "document.png", "targets": ["lines": boxes]]
}

// 4. A setup window with a single button.
do {
    let c = Canvas()
    c.wallpaper()
    c.menu(app: "Setup Assistant", items: ["Edit", "Window"])
    let win = CGRect(x: 365, y: 200, width: 600, height: 440)
    _ = c.window(win, title: "")
    let go = c.button("Continue", CGRect(x: 600, y: 560, width: 130, height: 36), primary: true)
    c.save("single.png")
    truth["single"] = ["file": "single.png", "targets": ["continue": box(go), "window": box(win)]]
}

truth["screen"] = geometry.object
truth["size"] = [W, H]
truth["display_points"] = [Int(display.width), Int(display.height)]
let data = try! JSONSerialization.data(withJSONObject: truth, options: [.prettyPrinted, .sortedKeys])
try! data.write(to: out.appendingPathComponent("truth.json"))
print("wrote 4 screens and truth.json to \(out.path)")
