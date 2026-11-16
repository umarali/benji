import AppKit
import SwiftUI
import BenjiCore

/// Settings › Phone. The app hands it in (`SettingsModel.phoneContent`), so the access key stays in
/// `RemoteControl` and never enters the settings snapshot.
struct PhoneSettingsView: View {
    @ObservedObject var control: RemoteControl
    @ObservedObject var settings: SettingsModel
    let a: NotchAccessibility

    var body: some View {
        SettingsCard(header: "Connection", a: a,
                     footer: "Use the HTTPS address from Tailscale Serve. The loopback address works only on this Mac.") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Mac HTTPS address").font(.callout.weight(.medium)).foregroundStyle(NotchPalette.label)
                TextField("https://your-mac.your-tailnet.ts.net", text: $control.address)
                    .textFieldStyle(.plain).font(.body)
                    .padding(9).background(NotchPalette.raised, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(NotchPalette.hairline(a)))
                    .accessibilityLabel("Mac HTTPS address")
                    .disabled(control.isRunning)
                HStack {
                    Button("Copy address") { copy(control.address) }
                        .buttonStyle(CapsuleButtonStyle())
                        .disabled(PhoneControl.normalizedAddress(control.address) == nil)
                    Spacer()
                    Text(control.status).font(.caption).foregroundStyle(NotchPalette.secondary(a))
                }
                Button(control.isRunning ? "Turn off and stop phone task" : "Turn on phone control") {
                    if control.isRunning { control.stop() } else { control.start() }
                }
                .buttonStyle(CapsuleButtonStyle(prominent: !control.isRunning))
                if control.isRunning {
                    Text("Turn phone control off before changing the address.")
                        .font(.caption).foregroundStyle(NotchPalette.secondary(a))
                }
            }
            .padding(12)
        }
        if !control.accessKey.isEmpty {
            SettingsCard(header: "Connect your phone", a: a,
                         footer: "Anyone with this key and network access can send tasks and answer approvals. Turning phone control off revokes the key.") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Open the address in your phone's browser and enter this access key.")
                        .font(.callout).foregroundStyle(NotchPalette.label)
                    Text(control.accessKey).font(.system(.caption, design: .monospaced))
                        .foregroundStyle(NotchPalette.label).textSelection(.enabled)
                    Button("Copy access key") { copy(control.accessKey) }.buttonStyle(CapsuleButtonStyle())
                }
                .padding(12)
            }
        }
        SettingsCard(header: "Approvals", a: a, footer: PhoneCopy.approvalsFooter) {
            SettingsRow(title: PhoneCopy.approvalsTitle, detail: PhoneCopy.approvalsDetail, a: a) {
                SwitchControl(title: PhoneCopy.approvalsTitle,
                              isOn: settings.toggle(\.phoneApprovals, SettingsChange.phoneApprovals))
            }
        }
        DisclosureGroup("Set up Tailscale") {
            VStack(alignment: .leading, spacing: 9) {
                Text("Connect Tailscale on your Mac and phone to the same private network. On your Mac, run:")
                Text("tailscale serve --bg \(PhoneControl.port)").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Text("Paste its HTTPS address above. Use private Serve only, never public Funnel.")
                Text("Serve stays set up after Benji stops. To remove this route when you're done, run tailscale serve --https=443 off.")
            }
            .font(.caption).foregroundStyle(NotchPalette.secondary(a)).padding(.top, 8)
        }
        .font(.callout)
        Text("Keep your Mac awake and Benji open. Phone tasks use this Mac's conversation and model, as text only: no screen control and no background jobs.")
            .font(.caption).foregroundStyle(NotchPalette.secondary(a)).fixedSize(horizontal: false, vertical: true)
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}
