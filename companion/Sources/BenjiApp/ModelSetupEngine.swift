import Foundation
import BenjiCore

/// A separate engine process: no conversation, tools or screen are available to a setup test.
@MainActor
final class ModelSetupEngine: ModelSetupBackend {
    private let assistantDir: String
    private let environment: () -> Result<[String: String], KeyHandoff.Failure>
    private let executable: URL
    private let arguments: [String]
    private let timeoutSeconds: TimeInterval
    private let inheritedEnvironment: () -> [String: String]

    init(assistantDir: String, environment: @escaping () -> Result<[String: String], KeyHandoff.Failure>,
         executable: URL = URL(fileURLWithPath: "/bin/zsh"), arguments: [String]? = nil,
         timeoutSeconds: TimeInterval = 90,
         inheritedEnvironment: @escaping () -> [String: String] = { ProcessInfo.processInfo.environment }) {
        self.assistantDir = assistantDir; self.environment = environment
        self.executable = executable
        self.arguments = arguments ?? ["-lc", "cd \"$BENJI_DIR\" && exec python3 -c 'from benji.serve import model_setup_main; model_setup_main()'"]
        self.timeoutSeconds = timeoutSeconds; self.inheritedEnvironment = inheritedEnvironment
    }

    func run(test source: ModelSetupSource?, completion: @escaping (Result<ModelSetupSource, ModelSetupFailure>) -> Void) {
        let additions: [String: String]
        switch environment() {
        case let .success(env): additions = env
        case let .failure(error): completion(.failure(ModelSetupFailure(words: error.words))); return
        }
        var env = inheritedEnvironment()
        env.merge(additions) { _, new in new }
        // Probes need key presence, never key values. The reply names the key the chosen provider
        // actually uses, so Test can pass just that key (including custom-server BENJI_API_KEY).
        let secrets = env.filter { KeyNames.isSecret($0.key) && !$0.value.isEmpty }
        env["BENJI_SETUP_KEYCHAIN_KEYS"] = additions.keys.filter { KeyNames.isSecret($0) && !(additions[$0] ?? "").isEmpty }.sorted().joined(separator: ",")
        for name in env.keys where KeyNames.isSecret(name) {
            if source == nil {
                if !(env[name] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { env[name] = "setup-key-present" }
            } else if KeyNames.canonicalAccount(name) != source?.keyVariable {
                env.removeValue(forKey: name)
            }
        }
        env["BENJI_DIR"] = assistantDir
        if env["BENJI_WORKDIR"] == nil { env["BENJI_WORKDIR"] = WorkingFolder.url().path }
        let input = (try? JSONEncoder().encode(source)) ?? Data("null".utf8)
        let executable = self.executable, arguments = self.arguments, timeoutSeconds = self.timeoutSeconds
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process(), stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
            process.executableURL = executable; process.arguments = arguments
            process.environment = env
            process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
            let result: Result<ModelSetupSource, ModelSetupFailure>
            let state = SetupProcessState()
            func safe(_ words: String) -> String {
                var text = words
                for value in secrets.values.sorted(by: { $0.count > $1.count }) { text = text.replacingOccurrences(of: value, with: "[key]") }
                return LogRedaction.redact(text)
            }
            func couldNotStart(_ details: String) -> ModelSetupFailure {
                let tail = String(safe(details).trimmingCharacters(in: .whitespacesAndNewlines).suffix(300))
                return ModelSetupFailure(words: "Benji couldn't start the model check. Check that Python and the engine are installed, then try again." + (tail.isEmpty ? "" : "\n" + tail))
            }
            do {
                try process.run()
                let reads = DispatchGroup(), output = SetupProcessOutput(), errors = SetupProcessOutput()
                DispatchQueue.global().async(group: reads) { output.data = stdout.fileHandleForReading.readDataToEndOfFile() }
                DispatchQueue.global().async(group: reads) { errors.data = stderr.fileHandleForReading.readDataToEndOfFile() }
                let timeout = DispatchWorkItem { state.terminateIfRunning(process) }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: timeout)
                // A child may exit before reading stdin. Still collect its result and diagnostic.
                try? stdin.fileHandleForWriting.write(contentsOf: input)
                try? stdin.fileHandleForWriting.close()
                process.waitUntilExit(); timeout.cancel(); reads.wait()
                struct Reply: Decodable { let ok: Bool; let source: ModelSetupSource?; let error: String? }
                let reply = String(decoding: output.data, as: UTF8.self).components(separatedBy: .newlines).reversed().compactMap {
                    try? JSONDecoder().decode(Reply.self, from: Data($0.utf8))
                }.first
                if state.timedOut {
                    result = .failure(ModelSetupFailure(words: "The test timed out. The request may have reached the model."))
                } else if let reply {
                    if reply.ok, process.terminationStatus == 0, let source = reply.source {
                        result = .success(source)
                    } else {
                        result = .failure(ModelSetupFailure(words: String(safe(reply.error ?? "The model test didn't finish. Try again.").prefix(300))))
                    }
                } else if process.terminationStatus != 0 {
                    result = .failure(couldNotStart(String(decoding: errors.data, as: UTF8.self)))
                } else {
                    result = .failure(ModelSetupFailure(words: "Benji couldn't read the engine's model settings or test result. Check that Python and the engine are installed, then try again."))
                }
            } catch {
                if process.isRunning { process.terminate() }
                result = .failure(couldNotStart(error.localizedDescription))
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
}

/// Each pipe has one writer; the process worker reads only after the DispatchGroup joins it.
private final class SetupProcessOutput { var data = Data() }

private final class SetupProcessState {
    private let lock = NSLock()
    private var expired = false
    var timedOut: Bool { lock.lock(); defer { lock.unlock() }; return expired }
    func terminateIfRunning(_ process: Process) {
        lock.lock(); defer { lock.unlock() }
        if process.isRunning { expired = true; process.terminate() }
    }
}
