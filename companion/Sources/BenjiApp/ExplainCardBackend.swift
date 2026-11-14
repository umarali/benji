import AppKit
import BenjiCore

/// What the backend hook asks of the card stage (`ExplainCardStage`; a test double in the tests).
protocol ExplainCardShowing: AnyObject {
    /// A reply opened a card: show it (empty or not) and replace any card up. `busy`: the turn's
    /// screenshot measured; `targets`: what the reply points at, when known. Every call names the
    /// run whose card it is; the stage ignores calls for a card it isn't showing.
    func open(_ script: CardScript, run: Int, busy: ExplainBusyScreen?, targets: [PointingTarget])
    /// The open card's script moved on: more sentences, parts, chips, or its end.
    func update(_ script: CardScript, run: Int)
    /// The text that opened it was taken back (a tool call followed it): the card goes.
    func withdraw(run: Int)
    /// The user cut Benji off, or the turn stopped: what isn't drawn yet is drawn now; nothing
    /// more is added.
    func hurry(run: Int)
}

/// Wraps the app's backend when explanation cards are on (D-125): tells the engine it can show
/// cards, measures each turn's screenshot for busy space while the model works, and builds each
/// reply's card as its lines come (chilly-beats): the engine sends card lines as events, apart
/// from the spoken deltas; a finished answer that still holds card lines (one-shot mode), or an
/// older reply's fenced `card` block, is read whole. The card goes to the stage as soon as it
/// opens and grows as the reply streams; the stage draws each part on its sentence. Off, the
/// app's backend is used as it is and nothing here runs.
final class ExplainCardBackend: CompanionBackend, JobForwarding {
    /// The engine adds its card section to the prompt when this is set in its environment.
    static let engineFlag = "BENJI_CARDS"

    static func wrap(_ inner: CompanionBackend) -> CompanionBackend {
        guard ExplainCardStage.isOn else { return inner }
        setenv(engineFlag, "1", 1)   // inherited by the engine process, started on the first message
        return ExplainCardBackend(inner, stage: ExplainCardStage.shared)
    }

    let inner: CompanionBackend
    private weak var stage: ExplainCardShowing?
    /// The display a screenshot is taken of: the one under the pointer, as the app captures.
    var screenUnderPointer: () -> NSScreen? = {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }
    var onEvent: ((_ run: Int, BackendEvent) -> Void)?
    var onFinished: ((_ run: Int, Int32) -> Void)? {
        get { inner.onFinished }
        set { inner.onFinished = newValue }
    }
    var approvalTimeout: TimeInterval { inner.approvalTimeout }
    /// The clock the scripts are timed on (seconds); a test sets its own.
    var now: () -> Double = { ProcessInfo.processInfo.systemUptime }

    /// Busy maps are made and read in order on this queue, so a card waits for its own turn's.
    private let measureQueue = DispatchQueue(label: "benji.card-busy", qos: .userInitiated)
    private var busy: [Int: ExplainBusyScreen] = [:]   // by run; touched on measureQueue only

    /// This run's reply so far (main thread).
    private var run: Int?
    private var script = CardScript()
    /// The script's card has been handed to the stage (or is on its way there).
    private var opened = false
    /// Card lines that came before any spoken text streamed, with where each stood in the spoken
    /// text: taken in at the first delta, or placed by position when they come with the answer.
    private var held: [(line: ExplainCardLine, at: Int)] = []
    private var streamed = false
    /// The run was cut off or stopped: its later card lines are dropped.
    private var stopped = false

    init(_ inner: CompanionBackend, stage: ExplainCardShowing) {
        self.inner = inner
        self.stage = stage
        inner.onEvent = { [weak self] run, event in
            guard let self, let out = self.taking(event, run: run) else { return }
            self.onEvent?(run, out)
        }
    }

    /// The event as the model gets it (nil: the card's alone), after the card has had its part.
    func taking(_ event: BackendEvent, run: Int) -> BackendEvent? {
        if run != self.run { beginReply(run) }
        let t = now()
        switch event {
        case .delta(let piece):
            guard !stopped else { return event }
            if !streamed {
                // The reply streams after all: the lines held so far come before this text.
                streamed = true
                held.forEach { take($0.line, run: run) }
                held = []
            }
            script.delta(piece, at: t)
            if opened { stage?.update(script, run: run) }
            return event
        case .deltaReset:
            if opened { stage?.withdraw(run: run) }
            script.reset()
            opened = false
            held = []
            return event
        case let .cardLine(line, at):
            guard !stopped else { return nil }
            if !streamed {
                // Nothing spoken has streamed yet: either the card line comes first (it opens with
                // the first words, a moment later) or streaming is off and every line comes with
                // the answer, placed by `at`.
                held.append((line, at ?? 0))
                return nil
            }
            take(line, run: run)
            return nil
        case .cardEnd:
            return nil
        case .answer(let raw):
            return .answer(finishing(raw, targets: [], run: run, at: t))
        case .pointedAnswer(let raw, let targets):
            return .pointedAnswer(text: finishing(raw, targets: targets, run: run, at: t), targets: targets)
        default:
            return event
        }
    }

    private func take(_ line: ExplainCardLine, run: Int) {
        guard script.card(line) else { return }
        if opened { stage?.update(script, run: run) } else { openSoon(run: run, targets: []) }
    }

    private func beginReply(_ run: Int) {
        if opened, !stopped, let last = self.run { stage?.hurry(run: last) }   // never waits on this reply's voice
        self.run = run
        script = CardScript()
        opened = false
        held = []
        streamed = false
        stopped = false
    }

    /// The answer's text without card lines; the card's end, or the whole card when it came only now.
    private func finishing(_ raw: String, targets: [PointingTarget], run: Int, at t: Double) -> String {
        guard !stopped else { return raw }
        if opened {
            script.finish(spoken: raw, at: t)
            stage?.update(script, run: run)
            return raw
        }
        var text = raw
        if !held.isEmpty {
            script = CardScript.replay(spoken: raw, lines: held, at: t)
            held = []
        } else {
            let whole = CardScript.whole(raw, at: t)
            if whole.script.draft != nil {
                text = whole.text.trimmingCharacters(in: .whitespacesAndNewlines)
                script = whole.script
            } else {
                // An older reply: one fenced block at the end, drawn at once as it was (D-125).
                let (rest, card) = ExplainCardGrammar.parse(raw)
                guard let card else { return raw }
                text = rest
                script = CardScript.fenced(card, spoken: rest, at: t)
            }
        }
        guard script.draft != nil else { return text }
        openSoon(run: run, targets: targets)
        return text
    }

    /// Opens the card once the turn's screenshot is measured (main thread then), with the script
    /// as it is by then.
    private func openSoon(run: Int, targets: [PointingTarget]) {
        opened = true
        measureQueue.async { [weak self] in
            guard let self else { return }
            let map = self.busy.removeValue(forKey: run)
            DispatchQueue.main.async {
                guard self.run == run, self.opened else { return }
                self.stage?.open(self.script, run: run, busy: map, targets: targets)
                if self.stopped { self.stage?.hurry(run: run) }   // cut off while it was being placed
            }
        }
    }

    func start(run: Int, task: String, imagePath: String?, memory: ConversationMemory, allowPointing: Bool,
               spoken: Bool, screen: ScreenshotGeometry?) {
        if let imagePath, let display = screenUnderPointer() {
            measureQueue.async { [weak self] in
                guard let self else { return }
                self.busy = self.busy.filter { $0.key > run - 4 }   // runs that never answered
                self.busy[run] = ExplainBusyScreen.measure(path: imagePath, screen: display)
            }
        }
        inner.start(run: run, task: task, imagePath: imagePath, memory: memory, allowPointing: allowPointing,
                    spoken: spoken, screen: screen)
    }

    /// The reply stops growing here: its card is finished at once, and nothing of it comes later.
    private func stopCard() {
        guard !stopped else { return }
        stopped = true
        held = []
        if opened, let run { stage?.hurry(run: run) }
    }

    func resolveApproval(_ approved: Bool) { inner.resolveApproval(approved) }
    func cancel() {
        stopCard()
        inner.cancel()
    }
    func cutOff(reply: String, running: Bool) {
        stopCard()
        inner.cutOff(reply: reply, running: running)
    }
    func reset() { inner.reset() }
    func shutdown() { inner.shutdown() }
    func restartEngine() { inner.restartEngine() }
    func setBrowser(_ on: Bool) { inner.setBrowser(on) }
    func stopDrive(reason: String) { inner.stopDrive(reason: reason) }
    func setSchedules(_ on: Bool) { inner.setSchedules(on) }
    func startEngineForSchedules() { inner.startEngineForSchedules() }
    func prewarm() { inner.prewarm() }
    func finishScreenStep(request: String, result: ScreenStepResult) {
        inner.finishScreenStep(request: request, result: result)
    }
}
