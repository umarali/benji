import Foundation

// The panel's small signs of life that aren't the conversation itself: the read-aloud
// toggle beside the mic, and the mic level the meter draws.

/// "Read answers aloud". Off, the default: answers to what you said are spoken,
/// typed ones are not. On, typed answers are read aloud too. A spoken message
/// is always answered aloud, so a hands-free conversation never goes quiet.
public enum ReadAloud {
    public static let defaultsKey = "readAnswersAloud"

    public static func isOn(_ stored: Any?) -> Bool { (stored as? Bool) ?? false }

    public static func speaks(setting: Bool, spoken: Bool) -> Bool { spoken || setting }

    /// The toggle's tooltip.
    public static func help(on: Bool) -> String {
        on ? "Read answers aloud · On" : "Read answers aloud · Off: only answers to what you say are spoken"
    }
}

/// Smooths the raw mic level for the meter with the level tokens: it rises fast
/// (`levelAttack`) and falls slowly (`levelRelease`), so the bars breathe instead of flicker.
public struct LevelSmoother: Equatable, Sendable {
    public private(set) var value: Float = 0
    private var lastTime: Double?

    public init() {}

    /// The smoothed level after a sample `level` (0…1) at `time` seconds. A level of exactly 0
    /// (listening stopped) clears it at once.
    public mutating func update(_ level: Float, at time: Double) -> Float {
        let target = min(max(level, 0), 1)
        guard target > 0 else { reset(); return 0 }
        let dt = lastTime.map { max(time - $0, 0) } ?? 1 / MotionTiming.meterMaxFPS
        lastTime = time
        let tau = target > value ? MotionTiming.levelAttack : MotionTiming.levelRelease
        let alpha = Float(1 - exp(-dt / tau))
        value += (target - value) * alpha
        return value
    }

    public mutating func reset() {
        value = 0
        lastTime = nil
    }
}
