import SwiftUI
import BenjiCore

struct ModelSetupRow: View {
    @ObservedObject var model: ModelSetupModel
    let isCurrent: Bool
    @State private var showLocal = false
    @State private var provider = "ollama"
    @State private var localModel = ""
    @State private var endpoint = "http://localhost:11434/v1"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "key.fill")
                    .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
                    .frame(width: 20).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Model").font(isCurrent ? .body.weight(.semibold) : .body)
                    Text("So I can answer your first message.").font(.callout)
                }
                Spacer()
                Label(model.isDone ? "Ready" : "Not yet", systemImage: model.isDone ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(model.isDone ? .green : .secondary)
                    .font(.callout)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(model.note).font(.callout).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if !model.isDone && model.canLookInKeychain {
                    Button("Look for a key in the Keychain") { model.lookInKeychain() }
                }
                if model.canUseKeychainKey {
                    Text(model.useDisclosure).font(.caption).fixedSize(horizontal: false, vertical: true)
                    Button("Use the Keychain key") { model.useKeychainKey() }
                        .disabled(model.isBusy)
                }
                if let source = model.source {
                    Text("\(source.model) · \(source.origin)").font(.caption).foregroundStyle(.secondary)
                    Text(source.disclosure).font(.caption).fixedSize(horizontal: false, vertical: true)
                    Button(model.phase == .testing ? "Testing…" : "Test") { model.test() }
                        .disabled(!model.canTest)
                }
                if !model.isDone {
                    SecureField("Anthropic API key", text: $model.pastedKey)
                        .textFieldStyle(.roundedBorder)
                        .disabled(model.isBusy)
                        .accessibilityHint("Paste your API key. Save key keeps it in the macOS Keychain.")
                    Text(model.saveDisclosure).fixedSize(horizontal: false, vertical: true)
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Save key") { model.saveKey() }
                        .disabled(model.pastedKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isBusy)
                    DisclosureGroup("Use a local model", isExpanded: $showLocal) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Experimental. Start Ollama or LM Studio and load a model first.").font(.caption)
                            Picker("Provider", selection: $provider) {
                                Text("Ollama").tag("ollama")
                                Text("LM Studio").tag("lmstudio")
                            }
                            .onChange(of: provider) { _, value in
                                endpoint = value == "ollama" ? "http://localhost:11434/v1" : "http://localhost:1234/v1"
                            }
                            TextField("Model name", text: $localModel).textFieldStyle(.roundedBorder)
                            TextField("Local endpoint", text: $endpoint).textFieldStyle(.roundedBorder)
                            Button("Use this model") { model.useLocal(provider: provider, model: localModel, endpoint: endpoint) }
                        }
                        .disabled(model.isBusy)
                        .padding(.top, 6)
                    }
                    Button("Check existing source again") { model.checkExisting() }.buttonStyle(.link).disabled(model.isBusy)
                }
            }
            .padding(.leading, 30)
        }
        .padding(.vertical, 4)
    }
}
