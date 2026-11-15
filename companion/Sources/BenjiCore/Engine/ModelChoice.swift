import Foundation

/// Settings › General › Model: which Claude model the engine uses. Haiku is the default and
/// sets nothing, so the engine's own default rules (and a `BENJI_MODEL` in `~/.benji.env`, which
/// the app never reads); Sonnet sets `BENJI_MODEL` in the engine's environment, the way the 3D
/// switch sets `BENJI_FIGURES`, from the next message.
public enum ModelChoice: String, CaseIterable, Sendable {
    case haiku, sonnet

    public static let defaultsKey = "modelChoice"
    public static let engineVariable = "BENJI_MODEL"

    /// The stored choice; Haiku unless Sonnet was chosen.
    public static func from(_ raw: Any?) -> ModelChoice {
        (raw as? String).flatMap(ModelChoice.init(rawValue:)) ?? .haiku
    }

    public var title: String {
        switch self {
        case .haiku: return "Haiku 5.5 (default, cheapest)"
        case .sonnet: return "Sonnet 5.5 (better figures, about 20× the price)"
        }
    }

    /// `BENJI_MODEL` for the engine; nil sets nothing.
    public var engineModel: String? {
        switch self {
        case .haiku: return nil
        case .sonnet: return "claude-sonnet-5-5"
        }
    }

    /// Whether the choice can apply: the engine talks to Anthropic (a Claude model name means
    /// nothing to another provider). Unknown until the engine has said: allowed.
    public static func applies(provider: String?) -> Bool {
        guard let provider, !provider.isEmpty else { return true }
        return provider == "claude" || provider.lowercased() == "anthropic"
    }

    /// What `BENJI_MODEL` should become. `current` is the app's environment now; `setByApp` is
    /// what the app set there itself (nil: nothing). The app only ever clears its own value, so a
    /// `BENJI_MODEL` the app was started with is left alone while the choice is the default.
    /// nil: leave it as it is.
    public func environmentChange(current: String?, setByApp: String?) -> EnvironmentChange? {
        if let model = engineModel {
            return current == model ? nil : .set(model)
        }
        guard let mine = setByApp, current == mine else { return nil }
        return .clear
    }

    public enum EnvironmentChange: Equatable, Sendable {
        case set(String)
        case clear
    }

    /// The status line after the choice changes.
    public var notice: String {
        switch self {
        case .haiku: return "Haiku 5.5 from your next message."
        case .sonnet: return "Sonnet 5.5 from your next message."
        }
    }
}
