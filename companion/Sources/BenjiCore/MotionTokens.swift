import Foundation

/// A spring given as Apple's two numbers (Motion.md, Tokens): perceptual duration `d` and bounce
/// `b`. With mass 1, stiffness k = (2π / d)² and damping c = 4π(1 − b) / d, so ζ = 1 − b.
public struct SpringToken: Equatable, Sendable {
    public let duration: Double
    public let bounce: Double

    public init(duration: Double, bounce: Double) {
        self.duration = duration
        self.bounce = bounce
    }

    public var stiffness: Double { pow(2 * .pi / duration, 2) }
    public var damping: Double { 4 * .pi * (1 - bounce) / duration }
    public var dampingRatio: Double { 1 - bounce }

    /// When a critically damped spring is within 0.5% of its target: (1 + u)e^(−u) = 0.005 at
    /// u = 7.4301, and u = 2πt / d, so t = 1.1825 × d (Motion.md rounds it to 1.18).
    /// Only meaningful for `bounce == 0`.
    public var settleTime: Double { 7.4302 / (2 * .pi) * duration }

    /// When a growing morph is 65% of the way there and its content starts to fade in: 0.353 × d.
    public var contentFadeInDelay: Double { 0.353 * duration }

    /// Progress (0 → 1) of a step from rest at time `t`, for an underdamped or critically damped
    /// spring. Used by tests and by any hand-stepped animation (e.g. `motion-follow`).
    public func stepResponse(at t: Double) -> Double {
        let w = 2 * .pi / duration, z = dampingRatio
        if z >= 1 { return 1 - (1 + w * t) * exp(-w * t) }
        let wd = w * (1 - z * z).squareRoot()
        return 1 - exp(-z * w * t) * (cos(wd * t) + z * w / wd * sin(wd * t))
    }

    /// Displacement at time `t` after a velocity kick `v0` from rest (the `motion-done` impulse).
    public func impulseResponse(at t: Double, velocity v0: Double) -> Double {
        let w = 2 * .pi / duration, z = dampingRatio
        if z >= 1 { return v0 * t * exp(-w * t) }
        let wd = w * (1 - z * z).squareRoot()
        return v0 / wd * exp(-z * w * t) * sin(wd * t)
    }
}

/// A cubic-bezier timing curve (Core Animation's control points).
public struct TimingCurve: Equatable, Sendable {
    public let c1x: Double, c1y: Double, c2x: Double, c2y: Double

    public init(_ c1x: Double, _ c1y: Double, _ c2x: Double, _ c2y: Double) {
        (self.c1x, self.c1y, self.c2x, self.c2y) = (c1x, c1y, c2x, c2y)
    }

    public static let easeOut = TimingCurve(0, 0, 0.58, 1)
    public static let easeIn = TimingCurve(0.42, 0, 1, 1)
    public static let easeInOut = TimingCurve(0.42, 0, 0.58, 1)
}

/// The seven motion tokens (D-62). Every Benji animation uses one of these.
public enum MotionTokens {
    /// Closed ↔ peek. `.smooth(duration: 0.30)`.
    public static let peek = SpringToken(duration: 0.30, bounce: 0)
    /// Any morph that starts or ends at card or open. `.smooth` (0.5 s).
    public static let open = SpringToken(duration: 0.50, bounce: 0)
    /// Changes inside one size. `.smooth(duration: 0.24)`.
    public static let content = SpringToken(duration: 0.24, bounce: 0)
    /// Values retargeted while moving (the pointer ring between nearby targets).
    public static let follow = SpringToken(duration: 0.35, bounce: 0)
    /// Opacity of content entering or leaving: ease-out in, ease-in out.
    public static let fadeDuration = 0.15
    public static let fadeIn = TimingCurve.easeOut
    public static let fadeOut = TimingCurve.easeIn
    /// Only the Done checkmark: an impulse, peak +14% at 80 ms, at rest by about 450 ms.
    public static let done = SpringToken(duration: 0.45, bounce: 0.3)
    public static let doneStartVelocity = 4.25
    /// The Reduce Motion stand-in for every spatial token: a 0.20 s ease-in-out crossfade.
    public static let reduceDuration = 0.20
    public static let reduceCurve = TimingCurve.easeInOut

    /// The token for a change between two sizes: the largest size involved wins.
    public static func morph(from: NotchSize, to: NotchSize) -> SpringToken {
        from >= .card || to >= .card ? open : peek
    }
}

/// Timing constants from Motion.md ("Rules that come with the tokens", "Timing constants")
/// and Overlay.md.
public enum MotionTiming {
    /// Shrinking: content fades out first; the shape starts this much later (from rest only).
    public static let shrinkShapeDelay = 0.100

    /// Hover rest before peek: inside the hot zone, slower than this, for `hoverRest`.
    public static let hoverRest = 0.100
    public static let hoverMaxSpeed = 150.0          // pt/s
    /// Close grace after the pointer leaves (idle states only).
    public static let closeGrace = 0.7

    /// Done hold: 0.5 s + 0.25 s per word of the Done line, clamped to 1.5–4 s.
    public static func doneHold(words: Int) -> Double {
        min(max(0.5 + 0.25 * Double(max(words, 0)), 1.5), 4.0)
    }

    /// Working shimmer: 1.4 s sweep, 0.6 s rest.
    public static let shimmerSweep = 1.4
    public static let shimmerRest = 0.6

    /// Mic and speech level smoothing, and the meters that show it.
    public static let levelAttack = 0.035
    public static let levelRelease = 0.140
    public static let levelFloorDB = -50.0           // −50…0 dBFS maps to 0…1
    public static let meterMaxFPS = 48.0
    public static let meterMinChange = 0.01
    public static let reduceMotionMeterHz = 4.0

    /// Speech-paced reveal: visuals may lead the audio by up to this, never lag. Without
    /// synthesiser word timings, estimate 4.5 syllables a second, a comma as 1 and a sentence end as 2.
    public static let speechMaxLead = 0.040
    public static let syllablesPerSecond = 4.5
    public static let commaSyllables = 1.0
    public static let sentenceEndSyllables = 2.0

    /// Streaming text: each glyph fades in over 0.12 s, staggered by up to 8 ms within a chunk.
    public static let glyphFade = 0.12
    public static let glyphStagger = 0.008

    /// Pointing (Overlay.md): the ring glides between targets up to 220 pt apart with
    /// `motion-follow`; marks stay 8 s after coming to rest and at least 3 s after speech ends.
    public static let followMaxHop = 220.0
    public static let markLifetime = 8.0
    public static let markAfterSpeech = 3.0
}
