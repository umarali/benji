import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// What the model is told about the screenshot sent with a message, in that screenshot's own
/// pixels (0,0 top-left): its size, which display it shows, the menu bar and the notch. The notch
/// is a hardware cutout that never appears in a capture, so without this the model can't draw
/// around it. The engine turns it into the prompt (benji/prompts.py, `screen` in a send request).
public struct ScreenshotGeometry: Equatable, Sendable {
    /// Whole pixels, x1,y1 top-left and x2,y2 bottom-right.
    public struct PixelRect: Equatable, Sendable {
        public let x1: Int, y1: Int, x2: Int, y2: Int
        public init(x1: Int, y1: Int, x2: Int, y2: Int) {
            self.x1 = x1; self.y1 = y1; self.x2 = x2; self.y2 = y2
        }
    }

    public let width: Int
    public let height: Int
    /// The hardware notch; nil on a display without one.
    public let notch: PixelRect?
    /// The menu-bar strip from the top; 0 when it is hidden.
    public let menuBarHeight: Int
    public let builtIn: Bool
    /// How many displays the Mac has.
    public let displayCount: Int

    public init(width: Int, height: Int, notch: PixelRect?, menuBarHeight: Int, builtIn: Bool, displayCount: Int) {
        self.width = width
        self.height = height
        self.notch = notch
        self.menuBarHeight = menuBarHeight
        self.builtIn = builtIn
        self.displayCount = displayCount
    }

    /// Maps the display's geometry (AppKit points, origin bottom-left) into the sent image.
    /// `pixelSize` is the image that was sent (after downscaling), `screenFrame` the captured
    /// display's frame, `notch` the hardware notch in global coordinates
    /// (`PanelGeometry.hardwareNotch`), `menuBarHeight` in points. The notch is rounded outwards
    /// so it always covers the cutout, and kept inside the image; nil when the size is empty.
    public static func make(pixelSize: CGSize, screenFrame: CGRect, notch: CGRect?, menuBarHeight: CGFloat,
                            builtIn: Bool, displayCount: Int) -> ScreenshotGeometry? {
        let w = Int(pixelSize.width.rounded(.down)), h = Int(pixelSize.height.rounded(.down))
        guard w > 0, h > 0, screenFrame.width > 0, screenFrame.height > 0 else { return nil }
        let sx = CGFloat(w) / screenFrame.width, sy = CGFloat(h) / screenFrame.height

        var notchPixels: PixelRect?
        if let n = notch?.intersection(screenFrame), !n.isNull, n.width > 0, n.height > 0 {
            let x1 = Int(((n.minX - screenFrame.minX) * sx).rounded(.down))
            let x2 = Int(((n.maxX - screenFrame.minX) * sx).rounded(.up))
            let y1 = Int(((screenFrame.maxY - n.maxY) * sy).rounded(.down))
            let y2 = Int(((screenFrame.maxY - n.minY) * sy).rounded(.up))
            notchPixels = PixelRect(x1: max(0, x1), y1: max(0, y1), x2: min(w, x2), y2: min(h, y2))
        }
        let bar = menuBarHeight > 0 ? min(Int((menuBarHeight * sy).rounded(.up)), h - 1) : 0
        return ScreenshotGeometry(width: w, height: h, notch: notchPixels, menuBarHeight: max(0, bar),
                                  builtIn: builtIn, displayCount: max(1, displayCount))
    }

    /// The `screen` object of a send request.
    public var object: [String: Any] {
        var o: [String: Any] = ["width": width, "height": height, "menu_bar": menuBarHeight,
                                "display": builtIn ? "built-in" : "external", "displays": displayCount]
        if let n = notch { o["notch"] = [n.x1, n.y1, n.x2, n.y2] }
        return o
    }

    /// `object` as one line of JSON, keys sorted.
    public func json() -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
