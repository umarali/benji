import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// The sizes of the notch object (Motion.md, "The notch object's shape"). `card` sits between
/// peek and open: room for an offer without taking over as the panel does (D-187).
public enum NotchSize: CaseIterable, Sendable {
    case closed, peek, card, open
}

/// Everything needed to draw the notch object at one size. `frame` is the body in AppKit global
/// coordinates (bottom-left origin): its top edge is the top of the display. The shoulders flare
/// outward by `shoulderRadius` on each side of the top edge, outside `frame`.
public struct NotchShape: Equatable, Sendable {
    public var frame: CGRect
    public var bottomRadius: CGFloat
    public var shoulderRadius: CGFloat
    /// 0 for the closed size on a display without a hardware notch (it is invisible there).
    public var opacity: CGFloat

    public init(frame: CGRect, bottomRadius: CGFloat, shoulderRadius: CGFloat, opacity: CGFloat) {
        self.frame = frame
        self.bottomRadius = bottomRadius
        self.shoulderRadius = shoulderRadius
        self.opacity = opacity
    }

    /// `shadow-notch-open` follows the height: (h − peek) / (open − peek), clamped to 0…1.
    public var shadowOpacity: CGFloat {
        let peek = PanelGeometry.peekSize.height, open = PanelGeometry.openSize.height
        return min(max((frame.height - peek) / (open - peek), 0), 1)
    }

    /// The frame including both shoulders, which a window must cover to draw them.
    public var outerFrame: CGRect {
        frame.insetBy(dx: -shoulderRadius, dy: 0)
    }

    /// One shape for one spring: every value moves together (`t` 0 → self, 1 → `other`).
    /// The top edge stays put and the width stays centred, so this only ever grows from the notch.
    public func interpolated(to other: NotchShape, _ t: CGFloat) -> NotchShape {
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * t }
        let w = mix(frame.width, other.frame.width), h = mix(frame.height, other.frame.height)
        let midX = mix(frame.midX, other.frame.midX), top = mix(frame.maxY, other.frame.maxY)
        return NotchShape(frame: CGRect(x: midX - w / 2, y: top - h, width: w, height: h),
                          bottomRadius: mix(bottomRadius, other.bottomRadius),
                          shoulderRadius: mix(shoulderRadius, other.shoulderRadius),
                          opacity: mix(opacity, other.opacity))
    }
}

extension PanelGeometry {
    /// `notch-closed-width` × `notch-height`: the closed size where there is no hardware notch to copy.
    public static let closedSize = CGSize(width: 185, height: 32)
    /// `notch-peek-width` × `notch-peek-height` (D-63).
    public static let peekSize = CGSize(width: 360, height: 60)
    /// `notch-card-width` × `notch-card-height` (D-187): a line, three rows and the answers.
    public static let cardSize = CGSize(width: 420, height: 214)
    /// `notch-open-width` × `notch-open-height`.
    public static let openSize = CGSize(width: 460, height: 380)
    /// The open size while Settings is showing: room for its sidebar and cards.
    public static let settingsSize = CGSize(width: 640, height: 460)
    /// The expanded open size (D-133): the conversation with a sidebar of recent ones. Settings
    /// shows at this size too while the panel is expanded (it is larger than `settingsSize`).
    public static let expandedSize = CGSize(width: 720, height: 560)
    /// The expanded panel's conversation sidebar, from the panel's left edge.
    public static let sidebarWidth: CGFloat = 208
    /// The UserDefaults key the Expand / Shrink choice is remembered under.
    public static let expandedKey = "panelExpanded"

    /// The open size: expanded wins (it has room for settings too), then settings, then the usual.
    public static func openSize(settings: Bool, expanded: Bool) -> CGSize {
        expanded ? expandedSize : settings ? settingsSize : openSize
    }

    /// Where the sidebar's icon column starts: the band's left edge, so its icons sit under Home
    /// and New conversation.
    public static let sidebarIconColumn: CGFloat = BandLayout.edge
    /// While Screen is On the closed notch grows by this much on each side, so the purple dot
    /// left of the hardware notch is always visible.
    public static let indicatorWing: CGFloat = 22
    /// The hover hot zone is the closed notch grown by this much on every side.
    public static let hotZoneMargin: CGFloat = 8

    /// Bottom corner radius per size: `radius-notch-closed`, `-peek`, `-open`.
    public static func bottomRadius(_ size: NotchSize) -> CGFloat {
        switch size { case .closed: return 10; case .peek: return 18; case .card: return 22; case .open: return 26 }
    }

    /// Shoulder radius per size. Closed (6 pt) is assumed until the hardware is measured.
    public static func shoulderRadius(_ size: NotchSize) -> CGFloat {
        switch size { case .closed: return 6; case .peek: return 8; case .card: return 10; case .open: return 12 }
    }

    /// The notch object at `size`. `notch` is the hardware notch in AppKit global coordinates
    /// (from `NSScreen.auxiliaryTopLeftArea` / `auxiliaryTopRightArea`), nil on a display without
    /// one; `screenFrame` is that display's `frame`. Closed is exactly the notch. Peek and open are
    /// centred on it, flush with the top of the display, never narrower than the notch and never
    /// wider than the display. With `indicator` (Screen is On), closed grows by `indicatorWing`
    /// on each side and is visible even without a hardware notch. With `settings`, open is
    /// `settingsSize`; with `expanded`, `expandedSize` (`openSize(settings:expanded:)`).
    public static func notchShape(_ size: NotchSize, notch: CGRect?, screenFrame: CGRect,
                                  indicator: Bool = false, settings: Bool = false,
                                  expanded: Bool = false) -> NotchShape {
        let closed = closedFrame(notch: notch, screenFrame: screenFrame)
        let frame: CGRect
        switch size {
        case .closed:
            frame = indicator ? closed.insetBy(dx: -indicatorWing, dy: 0) : closed
        case .peek, .card, .open:
            let s = size == .peek ? peekSize : size == .card ? cardSize : openSize(settings: settings, expanded: expanded)
            let w = min(max(s.width, closed.width), screenFrame.width)
            let h = min(max(s.height, closed.height), screenFrame.height)
            frame = CGRect(x: closed.midX - w / 2, y: screenFrame.maxY - h, width: w, height: h)
        }
        let invisible = size == .closed && notch == nil && !indicator
        return NotchShape(frame: frame, bottomRadius: bottomRadius(size),
                          shoulderRadius: shoulderRadius(size), opacity: invisible ? 0 : 1)
    }

    /// Where a resting pointer opens the peek: the closed notch plus `hotZoneMargin` on every side
    /// (it reaches past the top edge so a pointer pinned there still counts).
    public static func hotZone(notch: CGRect?, screenFrame: CGRect) -> CGRect {
        closedFrame(notch: notch, screenFrame: screenFrame).insetBy(dx: -hotZoneMargin, dy: -hotZoneMargin)
    }

    static func closedFrame(notch: CGRect?, screenFrame: CGRect) -> CGRect {
        if let notch, !notch.isEmpty {
            // Flush with the top of the display whatever the reported rect's top is.
            return CGRect(x: notch.minX, y: screenFrame.maxY - notch.height, width: notch.width, height: notch.height)
        }
        return CGRect(x: screenFrame.midX - closedSize.width / 2, y: screenFrame.maxY - closedSize.height,
                      width: closedSize.width, height: closedSize.height)
    }
}

/// The open panel's band: the row at notch height, split by the hardware notch (D-133). Left of
/// it, one group from the panel's left edge: Home, New conversation (Stop while busy) and
/// Settings. Right of it, the status word in space of its own, then Expand / Shrink and Collapse,
/// ending at the right edge. Every glyph sits in the same square slot at the same symbol size, so
/// the two groups line up; the word's room is what the right group leaves, never shared with it.
public enum BandLayout {
    /// Every band glyph's frame (and click target).
    public static let slot: CGFloat = 22
    /// Every band glyph's symbol size.
    public static let symbolSize: CGFloat = 13
    /// Benji's arrow in the peek's glyph slot (ready and working): its 20 pt drawing at this size,
    /// so the visible dart is about as large as a 13 pt symbol.
    public static let arrowSize: CGFloat = 18
    /// Between glyphs in a group (`space-1`).
    public static let spacing: CGFloat = 4
    /// From the panel's edge to the outermost glyph (`space-3`).
    public static let edge: CGFloat = 12
    /// From the hardware notch to the nearest glyph or the word, in the peek and the open panel.
    public static let notchGap: CGFloat = 10
    /// The least room between the word and the right group.
    public static let wordGap: CGFloat = 6
    /// The word's room in the peek (no controls there).
    public static let peekWordWidth: CGFloat = 70
    /// The mic meter's width (four 3 pt bars, 2 pt apart), in the composer's talk control.
    public static let meterWidth: CGFloat = 18
    /// The longest status word at the wing font (11 pt semibold rounded): "Transcribing", 69.3 pt.
    public static let widestWord: CGFloat = 69.3
    /// A word longer than its room shrinks to at most this before it would truncate.
    public static let minimumWordScale: CGFloat = 0.7

    /// Expand / Shrink and Collapse.
    public static let rightGroupWidth: CGFloat = slot * 2 + spacing

    /// One side of the notch, in the open panel.
    public static func wing(openWidth: CGFloat, notchWidth: CGFloat) -> CGFloat {
        max(0, (openWidth - notchWidth) / 2)
    }

    /// The status word's own room in the open band.
    public static func wordWidth(wing: CGFloat) -> CGFloat {
        max(0, wing - notchGap - wordGap - rightGroupWidth - edge)
    }

    /// The left group's glyphs: Home, New conversation and Settings.
    public static let leftGlyphs = 3

    /// The left group's width from the panel's edge: the edge margin and its glyphs.
    public static func leftGroupWidth(glyphs: Int = leftGlyphs) -> CGFloat {
        edge + slot * CGFloat(glyphs) + spacing * CGFloat(max(0, glyphs - 1))
    }

    /// What the left wing needs: the left group from the edge, then the gap to the notch (wider
    /// while the Screen On dot sits there).
    public static func leftNeeded(screenOn: Bool) -> CGFloat {
        leftGroupWidth() + (screenOn ? PanelGeometry.indicatorWing + 2 : notchGap)
    }
}

/// One optical size and stroke for every glyph in the open panel's band and the sidebar's icon
/// column (D-135). SF Symbols at one point size differ in how much of the em they fill (a bare
/// chevron is short, the outline square is small, the pencil large), so each symbol gets a scale on
/// the band's point size, measured so every visible box is about `targetBox` across. Measured at
/// semibold with `NSImage(systemSymbolName:)`: see the band-icons implementation note and
/// chilly-band-v2.md.
public enum BandGlyph {
    /// The visible box every outline glyph aims for, in points.
    public static let targetBox: CGFloat = 14

    /// Scale on `BandLayout.symbolSize`, per symbol.
    public static let scales: [String: CGFloat] = [
        "square.and.pencil": 1.10,
        "bubble.left": 1.00,
        "house": 1.00,
        "gearshape": 1.07,
        // Wider than tall (about 14.1 x 11.1 pt): the sidebar box, one glyph for show and hide.
        "sidebar.left": 0.93,
        // Collapse and Back share weight and long side (about 11.4 pt): `chevron.up` is 11.4 x 6.6,
        // `chevron.backward` 7.3 x 11.4.
        "chevron.up": 1.00,
        "chevron.backward": 1.00,
        // A solid square reads heavier than an outline of the same box: about 11 pt, not 14.
        "stop.fill": 1.05,
    ]

    public static func scale(for symbol: String) -> CGFloat { scales[symbol] ?? 1 }

    /// The font size that gives `symbol` its band box.
    public static func fontSize(for symbol: String) -> CGFloat { BandLayout.symbolSize * scale(for: symbol) }
}
