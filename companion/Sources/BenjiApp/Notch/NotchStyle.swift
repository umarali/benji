import AppKit
import SwiftUI
import BenjiCore

/// The accessibility settings the notch object honours. Read from the system and kept current;
/// set by hand only for offscreen renders.
struct NotchAccessibility: Equatable {
    var reduceMotion = false
    var reduceTransparency = false
    var increaseContrast = false

    static var system: NotchAccessibility {
        let w = NSWorkspace.shared
        return NotchAccessibility(reduceMotion: w.accessibilityDisplayShouldReduceMotion,
                                  reduceTransparency: w.accessibilityDisplayShouldReduceTransparency,
                                  increaseContrast: w.accessibilityDisplayShouldIncreaseContrast)
    }
}

/// Colour tokens for the notch object (tokens.json). The body is black in both appearances and
/// its contents render in the dark appearance, so the state colours are the system colours
/// resolved dark (`.environment(\.colorScheme, .dark)` on the content).
enum NotchPalette {
    /// `notch-black`.
    static let body = Color.black
    /// `notch-raised`: dark-appearance systemGray6.
    static let raised = Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255)
    /// `notch-label`.
    static let label = Color.white.opacity(0.85)

    /// `notch-label-secondary`; Increase Contrast uses `notch-label`.
    static func secondary(_ a: NotchAccessibility) -> Color {
        a.increaseContrast ? label : Color.white.opacity(0.55)
    }

    /// `notch-hairline`, 0.12, rising to 0.25 under Increase Contrast.
    static func hairline(_ a: NotchAccessibility) -> Color {
        Color.white.opacity(a.increaseContrast ? 0.25 : 0.12)
    }

    static func tint(_ t: NotchTint, _ a: NotchAccessibility) -> Color {
        switch t {
        case .mint: return .mint                       // benji-mint
        case .listening: return .orange                // state-listening
        case .listeningDimmed: return .orange.opacity(0.6)
        case .secondary: return secondary(a)
        case .looking: return .purple                  // state-looking
        case .approval: return .yellow                 // state-approval
        case .done: return .green                      // state-done
        case .error: return .red                       // state-error
        }
    }

    /// `shadow-notch-open`: 0.30 over a light desktop, 0.55 over a dark one.
    static func shadowOpacity(_ scheme: ColorScheme) -> Double { scheme == .dark ? 0.55 : 0.30 }
}

/// Type tokens: macOS text styles, plus SF Pro Rounded for Benji's own short lines.
enum NotchFont {
    static let peekLine = Font.system(.body, design: .rounded).weight(.medium)
    static let peekStatus = Font.system(.subheadline, design: .rounded).weight(.semibold)
    static let greeting = Font.system(.title2, design: .rounded).weight(.semibold)
    static let mono = Font.system(.callout, design: .monospaced)
}

/// The motion tokens as SwiftUI animations (Motion.md, Tokens).
enum NotchMotion {
    static func spring(_ token: SpringToken) -> Animation { .smooth(duration: token.duration) }
    static let content = spring(MotionTokens.content)
    static let fadeIn = Animation.easeOut(duration: MotionTokens.fadeDuration)
    static let fadeOut = Animation.easeIn(duration: MotionTokens.fadeDuration)
    static let reduce = Animation.easeInOut(duration: MotionTokens.reduceDuration)

    /// Changes inside one size; under Reduce Motion a crossfade.
    static func content(_ a: NotchAccessibility) -> Animation { a.reduceMotion ? reduce : content }
}

/// The notch object's outline (Motion.md, "The notch object's shape"): a flat top flush with
/// the screen, concave shoulders flaring into the menu bar, straight sides and continuous bottom
/// corners. Width, height and both radii animate together, so one spring moves the whole shape.
/// The body is centred horizontally in the rect with its top on the rect's top edge.
struct NotchOutline: Shape {
    var width: CGFloat
    var height: CGFloat
    var bottomRadius: CGFloat
    var shoulderRadius: CGFloat

    init(width: CGFloat, height: CGFloat, bottomRadius: CGFloat, shoulderRadius: CGFloat) {
        self.width = width
        self.height = height
        self.bottomRadius = bottomRadius
        self.shoulderRadius = shoulderRadius
    }

    init(_ shape: NotchShape) {
        self.init(width: shape.frame.width, height: shape.frame.height,
                  bottomRadius: shape.bottomRadius, shoulderRadius: shape.shoulderRadius)
    }

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(width, height), AnimatablePair(bottomRadius, shoulderRadius)) }
        set {
            (width, height) = (newValue.first.first, newValue.first.second)
            (bottomRadius, shoulderRadius) = (newValue.second.first, newValue.second.second)
        }
    }

    func path(in rect: CGRect) -> Path {
        let x0 = rect.midX - width / 2, x1 = rect.midX + width / 2
        let top = rect.minY, bottom = rect.minY + height
        let s = max(min(shoulderRadius, height / 2), 0)
        // A continuous corner starts 1.4 r from the corner. With the controls 0.225 × that from the
        // corner, the curve's midpoint sits where a circular corner of radius r would put it.
        let k = max(min(1.4 * bottomRadius, width / 2, height - s), 0)
        let d = 0.225 * k
        var p = Path()
        p.move(to: CGPoint(x: x0 - s, y: top))
        p.addLine(to: CGPoint(x: x1 + s, y: top))
        p.addQuadCurve(to: CGPoint(x: x1, y: top + s), control: CGPoint(x: x1, y: top))
        p.addLine(to: CGPoint(x: x1, y: bottom - k))
        p.addCurve(to: CGPoint(x: x1 - k, y: bottom),
                   control1: CGPoint(x: x1, y: bottom - d), control2: CGPoint(x: x1 - d, y: bottom))
        p.addLine(to: CGPoint(x: x0 + k, y: bottom))
        p.addCurve(to: CGPoint(x: x0, y: bottom - k),
                   control1: CGPoint(x: x0 + d, y: bottom), control2: CGPoint(x: x0, y: bottom - d))
        p.addLine(to: CGPoint(x: x0, y: top + s))
        p.addQuadCurve(to: CGPoint(x: x0 - s, y: top), control: CGPoint(x: x0, y: top))
        p.closeSubpath()
        return p
    }
}
