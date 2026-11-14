import Foundation
import BenjiCore

/// The one-shot backend: runs `python3 -m benji` once per message and turns its output stream
/// into typed events. This is the only component that talks to the process — geometry and
/// state never touch it, so each can be reasoned about independently.
final class OneShotBackend: CompanionBackend {
    private let assistantDir: String
    private var process: Process?
    private var inPipe: Pipe?

    /// Called on the main queue for each parsed event, with the run it came from.
    var onEvent: ((_ run: Int, BackendEvent) -> Void)?
    var onFinished: ((_ run: Int, Int32) -> Void)?

    init(assistantDir: String) {
        self.assistantDir = assistantDir
    }

    var isRunning: Bool { process?.isRunning ?? false }
    let approvalTimeout = ServeProtocol.appApprovalTimeout

    /// `imagePath`: an attachment for this turn (screen context), passed as `--image`.
    /// `memory`: recent exchanges for context, passed as a `--history` file. `allowPointing`:
    /// the image is the user's screen and the answer may end with pointing tags; `screen` says what
    /// that image holds (--screen). `spoken`: the user said it (--spoken).
    func start(run: Int, task: String, imagePath: String?, memory: ConversationMemory, allowPointing: Bool,
               spoken: Bool, screen: ScreenshotGeometry?) {
        // Each run keeps its own history file and line buffer: a cancelled run that is still
        // exiting must not delete the next run's file or mix its lines into the next run's.
        let historyURL = writeHistory(memory)
        let historyPath = historyURL?.path
        let removeHistory = { if let historyURL { try? FileManager.default.removeItem(at: historyURL) } }
        let process = Process()
        let inPipe = Pipe()
        let outPipe = Pipe()
        self.process = process
        self.inPipe = inPipe

        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // Login shell for PATH/pyenv; the engine loads ~/.benji.env for the key.
        // BENJI_APPROVAL_IO: approvals over stdio. BENJI_EVENTS: structured UI events.
        // exec so terminate() reaches python directly for a clean cancel.
        // Values travel in environment variables, never spliced into the command text.
        var flags = ""
        if imagePath != nil { flags += "--image \"$BENJI_IMAGE\" " }
        if historyPath != nil { flags += "--history \"$BENJI_HISTORY\" " }
        if historyPath != nil, memory.droppedEarlier { flags += "--history-dropped " }
        if allowPointing { flags += "--allow-pointing " }
        if allowPointing, screen != nil { flags += "--screen \"$BENJI_SCREEN\" " }
        if spoken { flags += "--spoken " }
        process.arguments = ["-lc", "cd \"$BENJI_DIR\" && exec python3 -m benji \(flags)\"$BENJI_TASK\" 2>&1"]
        var env = ProcessInfo.processInfo.environment
        env["BENJI_DIR"] = assistantDir
        env["BENJI_WORKDIR"] = WorkingFolder.url().path     // the same folder as the app's (D-175)
        env["BENJI_TASK"] = task
        if let imagePath { env["BENJI_IMAGE"] = imagePath }
        if let historyPath { env["BENJI_HISTORY"] = historyPath }
        if allowPointing, let screen { env["BENJI_SCREEN"] = screen.json() }
        env["BENJI_APPROVAL_IO"] = "1"
        env["BENJI_EVENTS"] = "1"
        env["BENJI_SURFACE"] = "panel"   // the model writes for Benji's panel, not a terminal
        env["PYTHONUNBUFFERED"] = "1"
        switch ServeBackend.keyEnvironment?() ?? .success([:]) {
        case let .success(keys): env.merge(keys) { _, new in new }
        case let .failure(error):
            removeHistory()
            self.process = nil; self.inPipe = nil
            onEvent?(run, .error(error.words)); onFinished?(run, -1)
            return
        }
        process.environment = env
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = outPipe

        let lines = LineReader { [weak self] line in
            let event = EngineEventParser.parse(line)
            DispatchQueue.main.async { self?.onEvent?(run, event) }
        }
        outPipe.fileHandleForReading.readabilityHandler = { lines.consume($0.availableData) }
        process.terminationHandler = { [weak self] proc in
            let code = proc.terminationStatus
            DispatchQueue.main.async {
                outPipe.fileHandleForReading.readabilityHandler = nil
                removeHistory()
                if self?.process === proc { self?.process = nil; self?.inPipe = nil }
                self?.onFinished?(run, code)
            }
        }
        do {
            try process.run()
            onEvent?(run, .accepted)
        } catch {
            removeHistory()
            onEvent?(run, .error("Couldn't start Benji's backend (the engine): \(error.localizedDescription)"))
            onFinished?(run, -1)
        }
    }

    /// Writes the recent exchanges to a private temp file (owner-only), deleted after the run.
    private func writeHistory(_ memory: ConversationMemory) -> URL? {
        guard !memory.isEmpty, let data = try? memory.jsonData() else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("benji-history-\(UUID().uuidString).json")
        guard FileManager.default.createFile(atPath: url.path, contents: data,
                                             attributes: [.posixPermissions: 0o600]) else { return nil }
        return url
    }

    /// Each run starts fresh from `memory`, so there is nothing to forget or stop.
    func reset() {}
    func shutdown() {}

    /// Answer an approval request the engine is blocking on.
    func resolveApproval(_ approved: Bool) {
        let reply = (approved ? "y" : "n") + "\n"
        try? inPipe?.fileHandleForWriting.write(contentsOf: Data(reply.utf8))
    }

    /// Cancel the running task (SIGTERM; the engine exits its loop cleanly).
    /// An approval answer can't reach it any more either: the pipe goes with the process.
    func cancel() {
        if process?.isRunning == true { process?.terminate() }
        process = nil
        inPipe = nil
    }
}
