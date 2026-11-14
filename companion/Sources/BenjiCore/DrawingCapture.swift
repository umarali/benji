import Foundation

/// Whether Benji's drawings show up in screenshots and screen recordings (the menu's "Show
/// Drawings in Screenshots"). Off by default: marks stay out of every capture, and the screenshot
/// shortcuts clear them. On: other apps' captures and the screenshot shortcuts can include them,
/// and taking a screenshot keeps them up. Benji's own captures, the ones sent to the model,
/// leave Benji's windows out either way (ScreenCapturer excludes its own process).
public enum DrawingCapture {
    public static let defaultsKey = "showDrawingsInScreenshots"

    /// The stored setting: off unless it was explicitly turned on.
    public static func shown(from raw: Any?) -> Bool {
        (raw as? Bool) ?? false
    }

    /// While a drawing (a picture, words written on the screen) is up, it shows in captures,
    /// Benji's own included, unless the user turned the setting off (chilly-whiteboard): the
    /// model then sees its own drawing in the next screenshot. Marks on things keep `shown`.
    public static func shownWhileDrawing(from raw: Any?) -> Bool {
        (raw as? Bool) ?? true
    }

    /// The screenshot shortcuts clear the marks only while they're hidden from captures; when
    /// they're shown, the user is taking the screenshot to capture them.
    public static func clearsOnScreenshot(shown: Bool) -> Bool { !shown }
}
