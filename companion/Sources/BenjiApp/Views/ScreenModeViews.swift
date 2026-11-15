import BenjiCore
import SwiftUI

// The Screen On dot in the notch (the Off / Ask / On choice itself is in Settings › Screen).
// Kept apart from the rest of the panel so it can be rendered offscreen (companion/tools/overlay-render).

/// `state-looking`: the purple Benji uses for anything to do with the screen.
enum ScreenModeColors {
    static let on = Color.purple
}

/// The always-visible sign that Screen is On: a purple dot just left of the hardware notch, in
/// every size of the notch object.
struct ScreenOnDot: View {
    let provider: String?

    var body: some View {
        Circle()
            .fill(ScreenModeColors.on)
            .frame(width: 7, height: 7)
            .shadow(color: ScreenModeColors.on.opacity(0.6), radius: 3)
            .help(ScreenCapturePolicy.onIndicator(provider: provider))
            .accessibilityElement()
            .accessibilityLabel(ScreenCapturePolicy.onIndicator(provider: provider))
    }
}
