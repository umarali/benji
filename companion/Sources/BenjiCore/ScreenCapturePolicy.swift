import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Rules for screen context that don't depend on ScreenCaptureKit, so they can be
/// unit-tested: how big the sent image is, and what we tell the user beforehand.
public enum ScreenCapturePolicy {
    /// Long-edge cap for the image sent to the model (Anthropic recommends ≤1568px).
    public static let maxLongEdge: CGFloat = 1568
    /// Total-pixel cap. Anthropic shrinks larger images before the model sees them, and the
    /// model then answers pointing coordinates in the shrunken copy (found in a live check:
    /// off by ~15%). Staying under this keeps the model's pixels identical to ours.
    public static let maxPixels: CGFloat = 1_150_000

    /// Downscale to fit both caps, preserving aspect ratio; never upscale.
    public static func targetSize(for source: CGSize, maxLongEdge: CGFloat = maxLongEdge,
                                  maxPixels: CGFloat = maxPixels) -> CGSize {
        let longEdge = max(source.width, source.height)
        let area = source.width * source.height
        guard longEdge > 0, area > 0 else { return .zero }
        let scale = min(1, maxLongEdge / longEdge, (maxPixels / area).squareRoot())
        // Round down so rounding can never push the result back over a cap.
        return CGSize(width: (source.width * scale).rounded(.down), height: (source.height * scale).rounded(.down))
    }

    /// "claude" -> "Anthropic", "openai" -> "OpenAI"; any other name (a custom server's
    /// host, e.g. "openrouter.ai") as given; nil/empty -> a neutral phrase.
    public static func providerDisplayName(_ id: String?) -> String {
        switch id?.lowercased() {
        case "claude", "anthropic": return "Anthropic"
        case "openai": return "OpenAI"
        case nil, "": return "your model provider"
        default: return id!
        }
    }

    /// Settings › Screen when the model can't read images (D-147): Screen stays off, and why.
    public static func noVisionNote(model: String) -> String {
        "\(model) can't read images, so Benji keeps Screen off for this session and sends no picture. "
            + "Use a model that can (BENJI_MODEL in ~/.benji.env), then restart Benji."
    }

    /// The line under each choice in Settings › Screen: what it does, naming who gets the image.
    public static func modeCaption(_ mode: ScreenMode, provider: String?) -> String {
        switch mode {
        case .off: return "Benji can't see your screen."
        case .ask: return "Asks before sending your screen to \(providerDisplayName(provider))."
        case .on: return "Sends the display you're on to \(providerDisplayName(provider)) with each message."
        }
    }

    /// The On dot's help and VoiceOver label (closed notch, peek and panel).
    public static func onIndicator(provider: String?) -> String {
        "Screen is On: each message sends a picture of your screen to \(providerDisplayName(provider))"
    }

    /// Asked at send time, before anything is captured. Nothing leaves the Mac without a Yes.
    /// `display` names the display the message started on, when more than one is connected.
    public static func confirmQuestion(provider: String?, display: String? = nil) -> String {
        let what = display ?? "this screen"
        return "Send a picture of \(what) to \(providerDisplayName(provider)) with your message?"
    }

    /// The confirm card's detail line.
    public static let confirmDetail = "Only if you want Benji to look at your screen. "
        + "Benji's own windows, password managers and notifications are left out."

    /// How long the confirm card waits; no answer cancels the message and sends nothing.
    public static let confirmTimeout: TimeInterval = 60

    /// Transcript line describing what was actually sent; `leftOut` counts password-manager and
    /// private browser windows kept out of the picture.
    /// `display` names the captured display when more than one is connected.
    public static func attachmentSummary(pixelSize: CGSize, provider: String?, leftOut: Int = 0,
                                         display: String? = nil) -> String {
        let named = display.map { " · \($0)" } ?? ""
        let base = "Screen attached\(named) · \(Int(pixelSize.width))×\(Int(pixelSize.height)) · sent to \(providerDisplayName(provider))"
        switch leftOut {
        case 0: return base
        case 1: return base + " · 1 window left out"
        default: return base + " · \(leftOut) windows left out"
        }
    }
}
