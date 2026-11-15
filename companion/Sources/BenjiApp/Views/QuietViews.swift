import SwiftUI
import BenjiCore

/// The two one-line notices under the transcript: an answer that wasn't read aloud because
/// the Mac is muted (with Copy), and a permission Benji needs just now (with a button to its pane).
/// Neither changes the volume or asks the system for anything; Copy writes the clipboard only when pressed.
struct QuietNotices: View {
    @ObservedObject var model: CompanionModel
    let a: NotchAccessibility
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let silent = model.silentAnswer {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "speaker.slash.fill").foregroundStyle(NotchPalette.secondary(a))
                    Text(silent.hint)
                        .font(.system(.callout, design: .rounded))
                        .foregroundStyle(NotchPalette.secondary(a))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button(copied ? SilentAnswer.copiedTitle : SilentAnswer.copyTitle) {
                        model.copySilentAnswer()
                        copied = true
                    }
                    .buttonStyle(CapsuleButtonStyle())
                    .help("Copies the answer to the clipboard")
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(NotchPalette.raised))
                .accessibilityElement(children: .combine)
                .onChange(of: silent) { _ in copied = false }
            }
            if let need = model.permissionAsk {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "lock.shield").foregroundStyle(NotchPalette.secondary(a))
                    Text(need.line)
                        .font(.system(.callout, design: .rounded))
                        .foregroundStyle(NotchPalette.secondary(a))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button(need.buttonTitle) {
                        Permissions.openSettings(need.permission)
                        model.dismissPermissionAsk()
                    }
                    .buttonStyle(CapsuleButtonStyle())
                    Button("Not now") { model.dismissPermissionAsk() }
                        .buttonStyle(.plain)
                        .foregroundStyle(NotchPalette.secondary(a))
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(NotchPalette.raised))
                .accessibilityElement(children: .combine)
            }
        }
    }
}
