import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Benji beside the pointer: while Benji listens, works, speaks or waits for your yes, a filled mint
/// arrowhead and the notch's own status word sit just below and right of the system pointer, so you can
/// see Benji is active wherever you are looking. Pure decisions only; the app draws it and follows the pointer.
public enum PointerCompanion {
    /// The UserDefaults key for "Show Benji beside the pointer".
    public static let defaultsKey = "pointerCompanion"

    /// On unless the user turned it off.
    public static func isOn(from stored: Any?) -> Bool {
        (stored as? Bool) ?? true
    }

    /// Settings' switch: its title and the line under it.
    public static let settingTitle = "Show Benji beside the pointer"
    public static let settingCaption = "A small mint arrow and one word follow your pointer while Benji listens, works, speaks or needs your yes."

    /// Shown while Benji is doing something or waiting on you; not while idle or after an error.
    public static func shows(phase: CompanionPhase, enabled: Bool) -> Bool {
        guard enabled else { return false }
        switch phase {
        case .listening, .transcribing, .thinking, .speaking, .awaitingApproval: return true
        case .idle, .error: return false
        }
    }

    /// The arrowhead's 20 pt drawing.
    public static let size: CGFloat = BenjiArrow.box
    /// The arrowhead's tip inside its drawing, from the top-left.
    public static let tip = BenjiArrow.tip
    /// From the system pointer's hot spot to the arrowhead's tip: right and down, clear of the system arrow.
    public static let offset = CGVector(dx: 14, dy: 16)
    /// The window: the arrowhead and room for the longest status word.
    public static let panelSize = CGSize(width: 124, height: 26)

    public struct Placement: Equatable, Sendable {
        public let frame: CGRect
        /// The word reads to the right of the arrowhead, unless that would run off the display.
        public let wordOnRight: Bool
    }

    /// The window's frame in AppKit global coordinates (y up) for a pointer at `pointer`, kept inside
    /// `screen` (the display the pointer is on). Near the right edge the word moves to the arrow's left.
    public static func placement(pointer: CGPoint, screen: CGRect) -> Placement {
        let wordOnRight = pointer.x + offset.dx + panelSize.width - tip.x <= screen.maxX
        var x = wordOnRight ? pointer.x + offset.dx - tip.x : pointer.x + offset.dx - tip.x - (panelSize.width - size)
        var top = pointer.y - offset.dy + tip.y
        x = min(max(x, screen.minX), screen.maxX - panelSize.width)
        top = min(max(top, screen.minY + panelSize.height), screen.maxY)
        return Placement(frame: CGRect(x: x, y: top - panelSize.height, width: panelSize.width, height: panelSize.height),
                         wordOnRight: wordOnRight)
    }
}

/// Benji's own arrow, drawn the same beside the pointer and in the notch's wing: a dart aiming up and
/// to the left, its face lit from the top-left over a deep-mint lower edge. Points are in a 20 pt box
/// from its top-left (y down); the drawing scales them. Symmetric about the box's diagonal, so the
/// aim is exactly up-left and never turned.
public enum BenjiArrow {
    public static let box: CGFloat = 20
    public static let tip = CGPoint(x: 3.2, y: 3.2)
    public static let rightWing = CGPoint(x: 16.4, y: 8.4)
    /// Where the two wings meet behind the tip, on the diagonal.
    public static let notch = CGPoint(x: 10.6, y: 10.6)
    public static let lowerWing = CGPoint(x: 8.4, y: 16.4)
    /// The lower edge: the face's outline again, this much lower, under it.
    public static let edgeDepth: CGFloat = 1.1
    /// Corner rounding (the outline is stroked this wide with round joins).
    public static let rounding: CGFloat = 1.2

    /// The face's outline: tip, right wing, notch, lower wing.
    public static var outline: [CGPoint] { [tip, rightWing, notch, lowerWing] }

    /// The tip, right wing and notch: the top facet, drawn lighter.
    public static var topFacet: [CGPoint] { [tip, rightWing, notch] }
}
