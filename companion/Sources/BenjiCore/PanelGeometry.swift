import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Geometry of one display, in AppKit global coordinates (bottom-left origin, y up).
/// `topInset` is the menu-bar / notch height measured down from the top edge.
public struct ScreenMetrics: Equatable {
    public var fullFrame: CGRect
    public var topInset: CGFloat

    public init(fullFrame: CGRect, topInset: CGFloat) {
        self.fullFrame = fullFrame
        self.topInset = topInset
    }
}

/// The two frames the panel moves between. Both share a top edge just below the
/// menu bar / notch; the expanded frame grows *downward*.
public struct PanelLayout: Equatable {
    public var idleFrame: CGRect
    public var expandedFrame: CGRect

    public init(idleFrame: CGRect, expandedFrame: CGRect) {
        self.idleFrame = idleFrame
        self.expandedFrame = expandedFrame
    }
}

public enum PanelGeometry {
    public static let defaultTopGap: CGFloat = 6
    public static let edgeMargin: CGFloat = 8

    /// Compute the idle and expanded frames for a display. Pure function so it can
    /// be unit-tested without a real screen.
    public static func layout(screen: ScreenMetrics,
                              idleSize: CGSize,
                              expandedSize: CGSize,
                              topGap: CGFloat = defaultTopGap) -> PanelLayout {
        let f = screen.fullFrame
        // Shared top edge, just below the menu bar / notch.
        let topEdgeY = f.maxY - screen.topInset - topGap
        let centerX = f.midX

        func frame(_ size: CGSize) -> CGRect {
            var x = centerX - size.width / 2
            // Clamp horizontally so it never runs off this display.
            let maxX = f.maxX - size.width - edgeMargin
            let minX = f.minX + edgeMargin
            if maxX >= minX { x = min(max(x, minX), maxX) }
            // Grow downward from the shared top edge; clamp to the display bottom.
            var y = topEdgeY - size.height
            y = max(y, f.minY + edgeMargin)
            return CGRect(x: x, y: y, width: size.width, height: size.height)
        }
        return PanelLayout(idleFrame: frame(idleSize), expandedFrame: frame(expandedSize))
    }
}
