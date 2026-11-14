import Combine
import Foundation
import BenjiCore

/// The user's screen mode (Off / Ask / On), saved between launches. A fresh install starts On;
/// a saved choice is kept and On stays On (D-133, `ScreenModeState`).
final class ScreenModeStore: ObservableObject {
    @Published private(set) var mode: ScreenMode

    private var state: ScreenModeState
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        state = ScreenModeState(saved: defaults.string(forKey: ScreenModeState.defaultsKey))
        mode = state.mode
        defaults.set(mode.rawValue, forKey: ScreenModeState.defaultsKey)
    }

    func choose(_ mode: ScreenMode) {
        state.choose(mode)
        if self.mode != state.mode { self.mode = state.mode }
        defaults.set(state.mode.rawValue, forKey: ScreenModeState.defaultsKey)
    }
}
