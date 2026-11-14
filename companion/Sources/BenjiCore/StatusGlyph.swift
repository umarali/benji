import Foundation

/// Which template glyph the menu-bar item shows (D-137): the two elbows while Benji is at rest,
/// the halves closed into one rounded square while it is busy with a turn. A swap on a real
/// state change, never an animation.
public enum StatusGlyph: Equatable, Sendable {
    case idle
    case working

    /// Busy means listening, transcribing, working, speaking or waiting on an approval. An error
    /// is a finished turn, so it shows the idle glyph again.
    public static func glyph(for phase: CompanionPhase) -> StatusGlyph {
        switch phase {
        case .idle, .error: return .idle
        case .listening, .transcribing, .thinking, .speaking, .awaitingApproval: return .working
        }
    }

    /// The SVG's name in the app bundle's Resources (copied there by build.sh).
    public var resourceName: String {
        switch self {
        case .idle: return "MenuBarGlyph"
        case .working: return "MenuBarGlyphWorking"
        }
    }
}
