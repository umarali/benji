import Foundation
import BenjiCore

/// What `CompanionModel` needs from a backend. Callbacks arrive on the main queue.
/// Every event and finish names the run it belongs to (the `run` given to `start`), so the model
/// can drop what a cancelled or replaced run still says (turn tokens).
protocol CompanionBackend: AnyObject {
    var onEvent: ((_ run: Int, BackendEvent) -> Void)? { get set }
    /// The run is over (answered, failed or cancelled); 0 when it ended normally.
    var onFinished: ((_ run: Int, Int32) -> Void)? { get set }
    /// How long the approval card waits before denying.
    var approvalTimeout: TimeInterval { get }
    /// `spoken`: the user said it and the answer will be read aloud. `screen`: what the screenshot
    /// at `imagePath` holds (size, notch, menu bar), for drawing on it.
    func start(run: Int, task: String, imagePath: String?, memory: ConversationMemory, allowPointing: Bool,
               spoken: Bool, screen: ScreenshotGeometry?)
    func resolveApproval(_ approved: Bool)
    func cancel()
    /// The user cut the spoken answer off (D-122): the backend's conversation keeps `reply` (what
    /// was heard, marked) as that turn's answer. `running`: the turn is still running, and stops.
    func cutOff(reply: String, running: Bool)
    /// New conversation: forget the backend's context.
    func reset()
    func shutdown()
    /// The next message starts a fresh engine process, which reads the app's environment anew
    /// (the 3D switch). Nothing to do for a backend that starts a process per message.
    func restartEngine()
    /// How the `screenAction` step `request` ended (D-123). Only `benji --serve` asks.
    func finishScreenStep(request: String, result: ScreenStepResult)
    /// The user's switch for browser reach (D-143). Only `benji --serve` has a browser link.
    func setBrowser(_ on: Bool)
    /// The sites the user set to always allow reading (D-171); the engine checks them again.
    func setBrowserAlways(_ sites: [String])
    /// The user ended the drive (D-170): Esc, typing, a click, the Stop button or a long move of the
    /// mouse. Only `benji --serve` drives.
    func stopDrive(reason: String)
    /// The user's switch for repeating jobs (D-172). Only `benji --serve` runs schedules.
    func setSchedules(_ on: Bool)
    /// Start the engine now if it isn't running, so a schedule can run while Benji is open and
    /// idle. The one-shot backend has nothing to start.
    func startEngineForSchedules()
    /// The talk key went down (D-173): a chance to warm the engine and its provider connection. Only
    /// `benji --serve` does anything with it; every wrapper passes it on.
    func prewarm()
}

extension CompanionBackend {
    func restartEngine() {}
    func setBrowser(_ on: Bool) {}
    func setBrowserAlways(_ sites: [String]) {}
    func setSchedules(_ on: Bool) {}
    func startEngineForSchedules() {}
    func prewarm() {}
    /// A backend that is handed the app's conversation every run (one-shot) only needs to stop.
    func cutOff(reply: String, running: Bool) {
        if running { cancel() }
    }
    func finishScreenStep(request: String, result: ScreenStepResult) {}
    func stopDrive(reason: String) {}
}

/// What `CompanionModel` needs for background jobs (D-130 step 1); only `benji --serve` runs them.
/// Callbacks arrive on the main queue. A job's approval is answered by `answerJob`, with the app's
/// own button: the job's id names the engine's turn for it.
protocol JobBackend: AnyObject {
    /// The job as it is now (any change).
    var onJob: ((JobSnapshot) -> Void)? { get set }
    /// The engine process ended: a job it was running is lost.
    var onEngineExit: (() -> Void)? { get set }
    func answerJob(_ job: String, request: String, approved: Bool)
    func stopJob(_ job: String)
    func steerJob(_ job: String, text: String)
    func dismissJob(_ job: String)
    /// Another run of a job that stopped or didn't finish (D-172).
    func continueJob(_ job: String)
    /// The row's schedule buttons (D-172).
    func scheduleJob(_ job: String, _ action: JobScheduleAction)
}

extension JobBackend {
    func continueJob(_ job: String) {}
    func scheduleJob(_ job: String, _ action: JobScheduleAction) {}
}

/// A backend that wraps another (the card and figure stages). The wrapper doesn't run jobs; it
/// hands every job call to the backend it wraps when that is one, and does nothing when it isn't
/// (one-shot). Without this, `backend as? JobBackend` fails for the app's wrapped backend, and
/// the job row and its buttons are never connected.
protocol JobForwarding: JobBackend {
    var inner: CompanionBackend { get }
}

extension JobForwarding {
    private var jobs: JobBackend? { inner as? JobBackend }
    var onJob: ((JobSnapshot) -> Void)? {
        get { jobs?.onJob }
        set { jobs?.onJob = newValue }
    }
    var onEngineExit: (() -> Void)? {
        get { jobs?.onEngineExit }
        set { jobs?.onEngineExit = newValue }
    }
    func answerJob(_ job: String, request: String, approved: Bool) {
        jobs?.answerJob(job, request: request, approved: approved)
    }
    func stopJob(_ job: String) { jobs?.stopJob(job) }
    func steerJob(_ job: String, text: String) { jobs?.steerJob(job, text: text) }
    func dismissJob(_ job: String) { jobs?.dismissJob(job) }
    func continueJob(_ job: String) { jobs?.continueJob(job) }
    func scheduleJob(_ job: String, _ action: JobScheduleAction) { jobs?.scheduleJob(job, action) }
}

enum BackendMode {
    /// `benji --serve` by default (D-118); `defaults write com.emerssive.heybenji.app backendMode oneshot`
    /// starts a fresh engine per message instead.
    static func make(assistantDir: String) -> CompanionBackend {
        if FastPath.usesServe(UserDefaults.standard.string(forKey: FastPath.backendModeKey)) {
            return ServeBackend(assistantDir: assistantDir)
        }
        return OneShotBackend(assistantDir: assistantDir)
    }

    /// "serve" or "oneshot", for the latency log.
    static var name: String {
        FastPath.usesServe(UserDefaults.standard.string(forKey: FastPath.backendModeKey)) ? "serve" : "oneshot"
    }
}

/// The persistent backend: one `benji --serve` kept for the app's lifetime, spoken to in JSON
/// lines (D-72, docs/proposal-serve.md). The engine keeps the conversation, tool results
/// included. Started on the first message; if it exits, the next message starts it again
/// and restores the recent exchanges. A protocol mismatch falls back to one-shot runs.
final class ServeBackend: CompanionBackend, JobBackend {
    var onEvent: ((_ run: Int, BackendEvent) -> Void)?
    var onFinished: ((_ run: Int, Int32) -> Void)?
    var onJob: ((JobSnapshot) -> Void)?
    var onEngineExit: (() -> Void)?
    private(set) var approvalTimeout = ServeProtocol.appApprovalTimeout

    private let assistantDir: String
    private var process: Process?
    private var input: FileHandle?
    private var ready = false
    /// The engine said (in `ready`) that it carries out schedules (D-172); an older one doesn't, and is
    /// never offered `repeat` or sent the schedule requests.
    private var engineSchedules = false
    /// What the engine said it can do in `ready` (D-173); empty for an older engine.
    private var engineCapabilities: Set<String> = []
    /// A prewarm was asked for before the engine answered `hello`; sent once it says it can.
    private var prewarmWaiting = false
    private var lastPrewarm = Date.distantPast
    /// Requests written once the engine has answered `hello`.
    private var queued: [ServeRequest] = []
    private var turnCount = 0
    private var turnID: String?
    /// The last turn sent, finished or not: a cut-off after its answer names it.
    private var lastTurnID: String?
    /// The model's run for `turnID`; a cancelled turn keeps both until its `done`, and the model
    /// drops whatever still arrives for that run.
    private var turnRun = 0
    private var pendingApproval: (turn: String, request: String)?
    /// The last few stderr lines, to explain an unexpected exit. The engine never logs message text
    /// (its stderr lines carry tool names, reason codes and ids; checked in selftest.py, D-144), and
    /// every line also goes, redacted, to engine.log.
    private var stderrTail: [String] = []
    private var lastStart: (run: Int, task: String, imagePath: String?, memory: ConversationMemory, allowPointing: Bool,
                            spoken: Bool, screen: ScreenshotGeometry?)?

    private let oneShot: OneShotBackend
    private var useOneShot = false
    /// The running engine was reset: the next message restores the app's memory first (a
    /// reopened conversation, D-121); a new conversation's memory is empty and restores nothing.
    private var restoreAfterReset = false

    private static let debug = ProcessInfo.processInfo.environment["BENJI_DEBUG"] == "1"

    init(assistantDir: String) {
        self.assistantDir = assistantDir
        oneShot = OneShotBackend(assistantDir: assistantDir)
        oneShot.onEvent = { [weak self] in self?.onEvent?($0, $1) }
        oneShot.onFinished = { [weak self] in self?.onFinished?($0, $1) }
        // Writing to an engine that has just exited must fail, not kill the app.
        signal(SIGPIPE, SIG_IGN)
    }

    func start(run: Int, task: String, imagePath: String?, memory: ConversationMemory, allowPointing: Bool,
               spoken: Bool, screen: ScreenshotGeometry?) {
        if useOneShot {
            oneShot.start(run: run, task: task, imagePath: imagePath, memory: memory, allowPointing: allowPointing,
                          spoken: spoken, screen: screen)
            return
        }
        lastStart = (run, task, imagePath, memory, allowPointing, spoken, screen)
        turnRun = run       // before launch(): a failure to start is reported against this run
        if process?.isRunning != true || restoreAfterReset {
            if process?.isRunning != true {
                launch()
                guard process != nil else { return }    // it could not start; the run was already ended
            }
            if !memory.isEmpty { write(.restore(memory.exchanges, droppedEarlier: memory.droppedEarlier)) }
        }
        restoreAfterReset = false
        turnCount += 1
        let id = "t\(turnCount)"
        turnID = id
        lastTurnID = id
        turnRun = run
        // With a screenshot, Benji may act on it (D-123) unless the switch is off, and do simple
        // steps without a card (D-126) unless the user chose to be asked before every step.
        let defaults = UserDefaults.standard
        let acts = ScreenActions.isOn(defaults.object(forKey: ScreenActions.defaultsKey))
        let simple = ScreenAutonomy.actsOnSimpleSteps(defaults.object(forKey: ScreenAutonomy.defaultsKey))
        let jobs = JobsSetting.isOn(defaults.object(forKey: JobsSetting.defaultsKey))
        // A drive (D-170) is offered only where simple steps are on; the switch is `driveMode`.
        let drive = acts && simple && DriveCopy.isOn(defaults.object(forKey: DriveCopy.defaultsKey))
        write(.send(id: id, text: task, imagePath: imagePath, allowPointing: allowPointing,
                    spoken: spoken, screen: screen, screenActions: acts, screenSimpleSteps: simple,
                    canvas: Self.canvasNow?(), jobs: jobs, schedules: engineSchedules, drive: drive))
    }

    // MARK: jobs

    // The job-row buttons are written to the audit log here (D-144): which button, on which job, and
    // for an answer yes or no. Never the steer's words or what the approval was for.
    func answerJob(_ job: String, request: String, approved: Bool) {
        guard !useOneShot else { return }
        AuditFile.shared.record(.jobAction(.answer, job: job, approved: approved))
        write(.approve(id: job, request: request, approved: approved))
    }

    func stopJob(_ job: String) {
        guard !useOneShot else { return }
        AuditFile.shared.record(.jobAction(.stop, job: job, approved: nil))
        write(.jobStop(job: job))
    }

    func steerJob(_ job: String, text: String) {
        guard !useOneShot else { return }
        AuditFile.shared.record(.jobAction(.steer, job: job, approved: nil))
        write(.jobSteer(job: job, text: text))
    }

    func dismissJob(_ job: String) {
        guard !useOneShot else { return }
        AuditFile.shared.record(.jobAction(.dismiss, job: job, approved: nil))
        write(.jobDismiss(job: job))
    }

    func continueJob(_ job: String) {
        guard !useOneShot else { return }
        AuditFile.shared.record(.jobAction(.continue, job: job, approved: nil))
        write(.jobContinue(job: job))
    }

    func scheduleJob(_ job: String, _ action: JobScheduleAction) {
        guard !useOneShot, engineSchedules else { return }
        let audited: AuditEvent.JobAction = action == .pause ? .schedulePause : action == .resume ? .scheduleResume : .scheduleDelete
        AuditFile.shared.record(.jobAction(audited, job: job, approved: nil))
        write(.jobSchedule(job: job, action: action))
    }

    /// The one switch for repeating jobs. A running engine is told at once; one that starts later is
    /// told in `ready`. Off also stops a repeat run in flight (the engine does that).
    func setSchedules(_ on: Bool) {
        guard !useOneShot, process?.isRunning == true, engineSchedules else { return }
        AuditFile.shared.record(.jobAction(on ? .schedulesOn : .schedulesOff, job: nil, approved: nil))
        write(.schedulesSet(enabled: on))
    }

    func startEngineForSchedules() {
        guard !useOneShot, process?.isRunning != true else { return }
        launch()
    }

    /// What Benji has on the screen now, for each `send` (chilly-whiteboard); set by the app.
    static var canvasNow: (() -> CanvasSnapshot?)?

    /// The environment the engine gets for its keys (D-173): nothing in file mode, the Keychain's keys in
    /// Keychain mode, or a failure, in which case the engine is not started (no fallback to the file).
    /// Static like `canvasNow`; set by the app. Nil: nothing added.
    static var keyEnvironment: (() -> Result<[String: String], KeyHandoff.Failure>)?

    /// What this app can carry out, said in `hello` (D-173). Nil: the old `hello` with no list.
    static var capabilities: (() -> [String])?

    /// The state of the link to the browser extension, on the main queue, on every change (D-143).
    /// Static like `canvasNow`: the backend is wrapped, and the app is the one listener.
    static var browserStatus: ((BrowserStatus) -> Void)?

    /// The "always allow reading" sites the engine kept, on the main queue (D-171).
    static var browserAlwaysKept: (([String]) -> Void)?

    func setBrowserAlways(_ sites: [String]) {
        guard !useOneShot, process?.isRunning == true else { return }
        write(.browserAlways(sites: sites))
    }

    /// Turns the engine's browser link on or off. Turning it on starts the engine if it isn't
    /// running, so the extension can connect without waiting for a message.
    func setBrowser(_ on: Bool) {
        guard !useOneShot else { return }
        if on, process?.isRunning != true { launch() }
        guard process?.isRunning == true else { return }
        write(.browserSet(enabled: on))
    }

    /// The talk key went down. Starts the engine if it isn't running (its start-up is the slow part of a
    /// first message) and asks a running one to warm its provider connection, at most every 30 s, and
    /// only if it said it knows how (an older engine would answer an unknown request with an error).
    func prewarm() {
        guard !useOneShot, Date().timeIntervalSince(lastPrewarm) > 30 else { return }
        lastPrewarm = Date()
        if process?.isRunning != true {
            prewarmWaiting = true
            launch()
        } else if ready, engineCapabilities.contains("prewarm") {
            send(.prewarm)
        }
    }

    func finishScreenStep(request: String, result: ScreenStepResult) {
        guard !useOneShot, let id = turnID else { return }   // the turn ended: the engine stopped waiting
        write(.screenResult(id: id, request: request, result: result))
    }

    func resolveApproval(_ approved: Bool) {
        if useOneShot { return oneShot.resolveApproval(approved) }
        guard let pending = pendingApproval else { return }
        pendingApproval = nil
        // Only the app's own card calls this (its button, ⌘Return, Esc or its timer), so the answer
        // says so: the engine grants a drive (D-170) to no other yes.
        write(.approve(id: pending.turn, request: pending.request, approved: approved, viaCard: true))
    }

    func stopDrive(reason: String) {
        guard !useOneShot, let id = turnID else { return }
        write(.driveStop(id: id, reason: reason))
    }

    func cancel() {
        if useOneShot { return oneShot.cancel() }
        guard let id = turnID else { return }
        pendingApproval = nil   // the engine denies a waiting approval itself
        write(.cancel(id: id))
    }

    func cutOff(reply: String, running: Bool) {
        if useOneShot { return oneShot.cutOff(reply: reply, running: running) }
        guard let id = running ? turnID : lastTurnID, process?.isRunning == true else { return }
        if running { pendingApproval = nil }   // the engine stops the turn as for a cancel
        write(.cutOff(id: id, reply: reply))
    }

    func reset() {
        lastTurnID = nil
        guard !useOneShot, process?.isRunning == true else { return }
        write(.reset)
        restoreAfterReset = true
    }

    func shutdown() {
        guard process?.isRunning == true else { return }
        write(.shutdown)
        try? input?.close()
    }

    /// Asks the running engine to stop and forgets it: its late events and exit are ignored
    /// (`proc === process` fails), and the next message launches a new one and restores the
    /// recent exchanges, as after an unexpected exit.
    func restartEngine() {
        guard !useOneShot, process != nil else { return }
        shutdown()
        onEngineExit?()
        process = nil
        input = nil
        ready = false
        engineSchedules = false
        queued = []
        pendingApproval = nil
        turnID = nil
    }

    // MARK: process

    private func launch() {
        let process = Process()
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        self.process = process
        input = inPipe.fileHandleForWriting
        ready = false
        queued = []
        stderrTail = []

        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // Login shell for PATH/pyenv; the engine loads ~/.benji.env for the key. stdout carries only
        // events; stderr is read separately (no 2>&1).
        process.arguments = ["-lc", "cd \"$BENJI_DIR\" && exec python3 -m benji --serve"]
        var env = ProcessInfo.processInfo.environment
        env["BENJI_DIR"] = assistantDir
        env["BENJI_WORKDIR"] = WorkingFolder.url().path     // the one folder, the same for the app and the engine (D-175)
        env["PYTHONUNBUFFERED"] = "1"
        env["BENJI_SURFACE"] = "panel"   // the model writes for Benji's panel, not a terminal
        // Stream the reply (D-118): words reach the panel and the voice as the model writes them.
        // Set here, so it wins over ~/.benji.env; `streamReplies` NO turns it off.
        env["BENJI_STREAM"] = FastPath.engineStreamValue(UserDefaults.standard.object(forKey: FastPath.streamKey))
        // The user's keys, when they have moved them to the Keychain (D-173). If the Keychain can't be
        // read the engine is not started, and the engine is told to read no key from the file either way.
        switch Self.keyEnvironment?() ?? .success([:]) {
        case let .success(keys): env.merge(keys) { _, new in new }
        case let .failure(failure):
            self.process = nil
            input = nil
            AuditFile.shared.record(.error(.engineLaunch))
            onEvent?(turnRun, .error(failure.words))
            onFinished?(turnRun, -1)
            return
        }
        process.environment = env
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe

        let events = LineReader { [weak self] line in
            let event = ServeEvent.decode(line)
            DispatchQueue.main.async { self?.handle(event, from: process) }
        }
        outPipe.fileHandleForReading.readabilityHandler = { events.consume($0.availableData) }
        let logs = LineReader { [weak self] line in
            if Self.debug { FileHandle.standardError.write(Data("[engine] \(line)\n".utf8)) }
            EngineLogFile.shared.append(line)       // every line, redacted, in engine.log (D-144)
            DispatchQueue.main.async { self?.keepStderr(line, from: process) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { logs.consume($0.availableData) }

        process.terminationHandler = { [weak self] proc in
            let code = proc.terminationStatus
            DispatchQueue.main.async {
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                self?.exited(proc, code: code)
            }
        }
        do {
            try process.run()
            trace("launched pid \(process.processIdentifier)")
            AuditFile.shared.record(.engineStart)
            send(Self.capabilities.map { .helloWith(capabilities: $0()) } ?? .hello)
        } catch {
            self.process = nil
            input = nil
            AuditFile.shared.record(.error(.engineLaunch))
            onEvent?(turnRun, .error("Couldn't start Benji's backend (the engine): \(error.localizedDescription)"))
            onFinished?(turnRun, -1)
        }
    }

    private func write(_ request: ServeRequest) {
        if ready { send(request) } else { queued.append(request) }
    }

    private func send(_ request: ServeRequest) {
        trace("→ \(Mirror(reflecting: request).children.first?.label ?? "\(request)")")
        try? input?.write(contentsOf: request.line())   // fails quietly if the engine is gone
    }

    private func keepStderr(_ line: String, from proc: Process) {
        guard proc === process else { return }
        stderrTail.append(line)
        if stderrTail.count > 20 { stderrTail.removeFirst() }
    }

    private func exited(_ proc: Process, code: Int32) {
        guard proc === process else { return }
        trace("exited \(code)")
        AuditFile.shared.record(.engineExit(code: code, clean: code == 0))
        process = nil
        input = nil
        ready = false
        engineCapabilities = []
        prewarmWaiting = false
        queued = []
        pendingApproval = nil
        if !useOneShot { onEngineExit?(); Self.browserStatus?(.off) }
        guard turnID != nil, !useOneShot else { return }
        turnID = nil
        let why = stderrTail.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
        onEvent?(turnRun, .error("Benji's backend (the engine) stopped unexpectedly (exit code \(code))." + (why.isEmpty ? "" : " \(why)")))
        onFinished?(turnRun, code == 0 ? 1 : code)
    }

    // MARK: events

    private func handle(_ event: ServeEvent?, from proc: Process) {
        guard proc === process, let event else { return }
        trace("← \(Mirror(reflecting: event).children.first?.label ?? "\(event)")")
        switch event {
        case .ready(let info):
            ready = true
            engineCapabilities = Set(info.capabilities)
            approvalTimeout = ServeProtocol.approvalTimeout(engineTimeout: info.approvalTimeout)
            if prewarmWaiting, engineCapabilities.contains("prewarm") { send(.prewarm) }
            prewarmWaiting = false
            // The switch lives in the app: a restarted engine is told again (D-143).
            if info.browser, BrowserSetting.isOn(UserDefaults.standard.object(forKey: BrowserSetting.defaultsKey)) {
                send(.browserSet(enabled: true))
                send(.browserAlways(sites: BrowserAlways.decode(UserDefaults.standard.object(forKey: BrowserAlways.defaultsKey))))
            }
            // Likewise the schedules switch (D-172): the engine runs no schedule until it hears true.
            engineSchedules = info.schedules && info.jobs
            if engineSchedules, JobSchedulesSetting.isOn(UserDefaults.standard.object(forKey: JobSchedulesSetting.defaultsKey)) {
                send(.schedulesSet(enabled: true))
            }
            let waiting = queued
            queued = []
            waiting.forEach(send)
        case let .accepted(id):
            guard id == turnID else { return }
            onEvent?(turnRun, .accepted)
        case let .tool(id, name, detail):
            guard id == turnID else { return }
            onEvent?(turnRun, .tool(name: name, detail: detail))
        case let .activity(id, kind, name):
            guard id == turnID else { return }
            onEvent?(turnRun, .activity(kind: kind, name: name))
        case let .approval(id, request, action, target):
            guard id == turnID else { return }
            // One approval at a time: an answer always goes to the request the card shows, so a
            // second request while one waits is refused, never swapped in under the first.
            if pendingApproval != nil {
                send(.approve(id: id, request: request, approved: false))
                trace("refused a second approval while one was waiting")
                return
            }
            pendingApproval = (id, request)
            onEvent?(turnRun, .approval(action: action, target: target))
        case let .screenApproval(id, request, action, target, step, intent):
            guard id == turnID else { return }
            if pendingApproval != nil {
                send(.approve(id: id, request: request, approved: false))
                trace("refused a second approval while one was waiting")
                return
            }
            pendingApproval = (id, request)
            onEvent?(turnRun, .screenApproval(action: action, target: target, step: step, intent: intent))
        case let .driveApproval(id, request, goal, seconds):
            guard id == turnID else { return }
            if pendingApproval != nil {
                send(.approve(id: id, request: request, approved: false))
                trace("refused a second approval while one was waiting")
                return
            }
            pendingApproval = (id, request)
            onEvent?(turnRun, .driveApproval(goal: goal, seconds: seconds))
        case let .drive(id, event):
            guard id == turnID else { return }
            onEvent?(turnRun, .drive(event))
        case let .screenAction(id, request, step, mode, intent, drive):
            guard id == turnID else { return }
            onEvent?(turnRun, .screenAction(request: request, step: step, mode: mode, intent: intent, drive: drive))
        case let .approvalResult(id, request, _, why):
            // The app's own timeout is shorter, so the engine timing out first means a bug.
            if why == "timeout", pendingApproval?.turn == id, pendingApproval?.request == request {
                pendingApproval = nil
                trace("the engine timed out an approval before the app did")
            }
        case let .answer(id, text, targets):
            guard id == turnID else { return }
            onEvent?(turnRun, .pointedAnswer(text: text, targets: targets))
        case let .delta(id, text):
            guard id == turnID else { return }
            onEvent?(turnRun, .delta(text))
        case let .deltaReset(id):
            guard id == turnID else { return }
            onEvent?(turnRun, .deltaReset)
        case let .cardLine(id, line, at):
            guard id == turnID else { return }
            onEvent?(turnRun, .cardLine(line, at: at))
        case let .cardEnd(id):
            guard id == turnID else { return }
            onEvent?(turnRun, .cardEnd)
        case let .job(snapshot):
            onJob?(snapshot)
        case let .browser(status):
            Self.browserStatus?(status)
        case let .browserAlways(sites):
            Self.browserAlwaysKept?(sites)
        case .usage:
            break   // the engine logs it to usage.jsonl itself
        case let .error(id, code, text):
            if !ready, code == "protocol" {
                fallBackToOneShot()
            } else if id == nil || id == turnID {
                onEvent?(turnRun, .error(text))
            }
        case let .done(id, status):
            guard id == turnID else { return }
            turnID = nil
            pendingApproval = nil
            onFinished?(turnRun, status == "error" ? 1 : 0)
        case .unknown:
            break
        }
    }

    /// The engine doesn't speak this protocol version: stop it and run this turn, and every later
    /// one, the one-shot way.
    private func fallBackToOneShot() {
        useOneShot = true
        turnID = nil
        shutdown()
        process?.terminate()
        process = nil
        trace("protocol mismatch; one-shot from now on")
        if let s = lastStart {
            oneShot.start(run: s.run, task: s.task, imagePath: s.imagePath, memory: s.memory, allowPointing: s.allowPointing,
                          spoken: s.spoken, screen: s.screen)
        }
    }

    private func trace(_ text: String) {
        guard Self.debug else { return }
        FileHandle.standardError.write(Data("[serve] \(text)\n".utf8))
    }
}

/// Splits a byte stream into UTF-8 lines. Called from one pipe's handler at a time.
final class LineReader {
    private var buf = [UInt8]()
    private let onLine: (String) -> Void

    init(onLine: @escaping (String) -> Void) { self.onLine = onLine }

    func consume(_ data: Data) {
        guard !data.isEmpty else { return }
        buf.append(contentsOf: data)
        while let nl = buf.firstIndex(of: 0x0A) {
            let line = String(decoding: buf[..<nl], as: UTF8.self)
            buf.removeSubrange(...nl)
            onLine(line)
        }
    }
}
