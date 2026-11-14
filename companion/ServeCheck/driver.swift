import Foundation

// Drives the app's real ServeBackend against a real `benji --serve` whose model is a localhost
// fake (run.py). No API key is read and nothing leaves the Mac. Compiled by run.py together
// with BenjiCore, ServeBackend.swift and OneShotBackend.swift.
let args = CommandLine.arguments
let assistantDir = args[1], outside = args[2]
var failures = 0
func check(_ name: String, _ ok: Bool) { print(ok ? "PASS" : "FAIL", name); if !ok { failures += 1 } }

// D-173: the real app says what it can carry out in `hello`, as AppController sets it.
ServeBackend.capabilities = { AppCapabilities.list(screenActions: true, drive: true) }
var b = ServeBackend(assistantDir: assistantDir)
var events: [BackendEvent] = []
var finished: Int32? = nil
var autoApprove: Bool? = nil
/// Answers each approval by its wording when set (and keeps every one it saw), instead of autoApprove.
var approveIf: ((String, String) -> Bool)? = nil
var approvalsSeen: [(action: String, target: String)] = []
var runCount = 0
/// Events and finishes tagged with a run other than the one just started (turn tokens).
var foreignRuns = 0
/// Plays the app's side of a screen step (D-123) when set.
var onScreenEvent: ((BackendEvent) -> Void)? = nil
func listen() {
    b.onEvent = { run, e in
        if run != runCount { foreignRuns += 1 }
        events.append(e)
        if case let .approval(action, target) = e {
            approvalsSeen.append((action, target))
            if let f = approveIf { b.resolveApproval(f(action, target)) } else if let a = autoApprove { b.resolveApproval(a) }
        }
        onScreenEvent?(e)
    }
    b.onFinished = { run, code in
        if run != runCount { foreignRuns += 1 }
        finished = code
    }
}
listen()

func run(_ task: String, memory: ConversationMemory = ConversationMemory(), pointing: Bool = false,
         spoken: Bool = false, screen: ScreenshotGeometry? = nil, after: Double? = nil, then: (() -> Void)? = nil) -> (events: [BackendEvent], code: Int32?) {
    events = []; finished = nil
    runCount += 1
    b.start(run: runCount, task: task, imagePath: nil, memory: memory, allowPointing: pointing, spoken: spoken, screen: screen)
    let t0 = Date()
    var fired = false
    while finished == nil && Date().timeIntervalSince(t0) < 30 {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        if let after, !fired, Date().timeIntervalSince(t0) > after { fired = true; then?() }
    }
    return (events, finished)
}
func answers(_ ev: [BackendEvent]) -> [String] {
    ev.compactMap { if case let .pointedAnswer(t, _) = $0 { return t } else { return nil } }
}

var r = run("hello")
check("first turn answers", answers(r.events) == ["1 user turns"] && r.code == 0)
check("approval timeout from ready stays 60 (the engine says 90)", b.approvalTimeout == 60)
r = run("again")
check("the engine keeps context between turns", answers(r.events) == ["2 user turns"])

autoApprove = true
r = run("write outside yes")
check("approval asked, approved, file written",
      r.events.contains { if case .approval = $0 { return true } else { return false } }
      && FileManager.default.fileExists(atPath: outside + "/yes.txt") && r.code == 0)
check("the engine takes the turn first, and the saved file is an activity by name only (D-98)",
      r.events.first == .accepted && r.events.contains(.activity(kind: "file_saved", name: "yes.txt")))
autoApprove = false
r = run("write outside no")
check("approval denied, no file", !FileManager.default.fileExists(atPath: outside + "/no.txt") && r.code == 0
      && r.events.contains { if case .approval = $0 { return true } else { return false } })
check("a denied action is no activity",
      !r.events.contains { if case .activity = $0 { return true } else { return false } })
autoApprove = nil

let t0 = Date()
r = run("sleep", after: 0.8) { b.cancel() }
check("cancel ends the turn at once, no answer", r.code == 0 && answers(r.events).isEmpty && Date().timeIntervalSince(t0) < 3)
r = run("after cancel")
check("cancelled turn leaves no trace (5 earlier turns ok + this)", answers(r.events) == ["5 user turns"])

r = run("point", pointing: true)
if case let .pointedAnswer(text, targets)? = r.events.last(where: { if case .pointedAnswer = $0 { return true }; return false }) {
    check("pointing targets parsed by the engine, text clean", text == "Here." && targets == [
        PointingTarget(shape: .box(x1: 10, y1: 20, x2: 110, y2: 60), label: "Field"),
        PointingTarget(shape: .point(x: 300, y: 400), label: "Save")])
} else { check("pointing answer", false) }

r = run("picture", pointing: true)
if case let .pointedAnswer(text, targets)? = r.events.last(where: { if case .pointedAnswer = $0 { return true }; return false }) {
    check("picture tags (D-97) come through the engine as targets", text == "A house." && targets == [
        PointingTarget(shape: .shape([10, 50, 90, 50, 50, 10]), label: "roof"),
        PointingTarget(shape: .line([20, 90, 20, 60, 40, 60]), label: "door"),
        PointingTarget(shape: .oval(x1: 60, y1: 60, x2: 70, y2: 70), label: "window"),
        PointingTarget(shape: .group(x1: 5, y1: 5, x2: 95, y2: 95), label: "house"),
        PointingTarget(shape: .callout(x: 100, y: 50), label: "Front door")])
} else { check("picture answer", false) }

// D-118: the app streams by default. The deltas arrive before the answer and join to its text;
// with pointing, the tags never stream.
func streamed(_ ev: [BackendEvent]) -> String {
    ev.reduce(into: "") { acc, e in
        if case let .delta(t) = e { acc += t } else if case .deltaReset = e { acc = "" }
    }
}
r = run("two sentences")
let firstDelta = r.events.firstIndex { if case .delta = $0 { return true }; return false }
let answerAt = r.events.firstIndex { if case .pointedAnswer = $0 { return true }; return false }
check("serve streams by default: several deltas, before the answer, joining to it",
      r.events.filter { if case .delta = $0 { return true }; return false }.count > 2
      && firstDelta != nil && answerAt != nil && firstDelta! < answerAt!
      && streamed(r.events) == "First sentence here. Second one follows."
      && answers(r.events) == ["First sentence here. Second one follows."])
r = run("point", pointing: true)
check("with pointing, the streamed text holds no tags", streamed(r.events) == "Here." && !streamed(r.events).contains("["))

let geo = ScreenshotGeometry(width: 1330, height: 864, notch: .init(x1: 577, y1: 0, x2: 753, y2: 28),
                             menuBarHeight: 33, builtIn: true, displayCount: 1)
r = run("context", pointing: true, spoken: true, screen: geo)
check("serve: the spoken flag and the screenshot's notch reach the model's prompt",
      answers(r.events) == ["spoken=True notch=True"])
r = run("context")
check("serve: a typed turn without the screen says neither", answers(r.events) == ["spoken=False notch=False"])

b.reset()
r = run("fresh")
check("reset forgets context", answers(r.events) == ["1 user turns"])

// Crash: kill the engine while idle; the next message restarts it and restores the app's memory.
let kids = Process(); kids.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
kids.arguments = ["-9", "-P", "\(getpid())"]; try! kids.run(); kids.waitUntilExit()
RunLoop.main.run(until: Date().addingTimeInterval(0.5))
var mem = ConversationMemory()
mem.record(user: "a", assistant: "b"); mem.record(user: "c", assistant: "d")
r = run("after crash", memory: mem)
check("restart + restore after a crash", answers(r.events) == ["3 user turns"] && r.code == 0)

// Crash mid-turn: the turn ends with an error.
r = run("sleep", after: 0.8) {
    let k = Process(); k.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
    k.arguments = ["-9", "-P", "\(getpid())"]; try! k.run(); k.waitUntilExit()
}
check("crash mid-turn reports an error and finishes",
      r.code != nil && r.code != 0 && r.events.contains { if case .error(let t) = $0 { return t.contains("stopped unexpectedly") }; return false })

r = run("after mid-turn crash")
check("works again after a mid-turn crash", answers(r.events) == ["1 user turns"])
check("every serve event and finish names the run it belongs to", foreignRuns == 0)
b.shutdown()
RunLoop.main.run(until: Date().addingTimeInterval(1.0))
let left = Process(); left.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
left.arguments = ["-P", "\(getpid())"]; let pipe = Pipe(); left.standardOutput = pipe
try! left.run(); left.waitUntilExit()
check("shutdown ends the engine", pipe.fileHandleForReading.readDataToEndOfFile().isEmpty)

// Explanation cards drawn on their sentences (chilly-beats): an engine started with the app's
// BENJI_CARDS=1 sends each card line as it closes, never in the deltas or the answer.
setenv("BENJI_CARDS", "1", 1)
b = ServeBackend(assistantDir: assistantDir)
listen()
r = run("card")
let cardEvents = r.events.filter { if case .cardLine = $0 { return true }; if case .cardEnd = $0 { return true }; return false }
check("cards: the card, its items and chips come as events, then the end, before the answer",
      cardEvents == [.cardLine(.open(ExplainCardHeader(title: "Letter", layout: .flow)), at: 0),
                     .cardLine(.item(.init(label: "Box", icon: "envelope")), at: 16),
                     .cardLine(.item(.init(label: "Van")), at: 32), .cardLine(.chips(["Why?"]), at: 32), .cardEnd]
      && r.events.lastIndex(of: .cardEnd)! < r.events.firstIndex { if case .pointedAnswer = $0 { return true }; return false }!)
check("cards: the words stream and answer without a card line",
      streamed(r.events) == "You drop it in.\nA van takes it.\n" && answers(r.events) == ["You drop it in.\nA van takes it.\n"])
var heard = CardScript()
for e in r.events {
    switch e {
    case .delta(let t): heard.delta(t, at: 0)
    case .cardLine(let line, _): _ = heard.card(line)
    default: break
    }
}
check("cards: each item lands after its own sentence, so the app gives it that sentence", heard.owners == [0, 1])
// The app's "streamReplies NO" (volatile: nothing is written to any defaults file): the lines come with the answer.
UserDefaults.standard.setVolatileDomain([FastPath.streamKey: false], forName: UserDefaults.argumentDomain)
b.shutdown()
b = ServeBackend(assistantDir: assistantDir)
listen()
r = run("card")
var replayed: [(line: ExplainCardLine, at: Int)] = []
for e in r.events { if case let .cardLine(line, at?) = e { replayed.append((line, at)) } }
check("cards, streaming off: no deltas; the lines carry their places, which give the same sentences",
      streamed(r.events).isEmpty && replayed.count == 4
      && CardScript.replay(spoken: answers(r.events).first ?? "", lines: replayed, at: 0).owners == [0, 1])
b.shutdown()
RunLoop.main.run(until: Date().addingTimeInterval(0.5))
unsetenv("BENJI_CARDS")
// The one-shot backend (the default) writes and removes its own --history file.
let one = OneShotBackend(assistantDir: assistantDir)
var oneEvents: [BackendEvent] = []
var oneDone: Int32? = nil
var oneRuns: Set<Int> = []
one.onEvent = { run, e in oneRuns.insert(run); oneEvents.append(e) }
one.onFinished = { run, code in oneRuns.insert(run); oneDone = code }
func historyFiles() -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory())) ?? []).filter { $0.hasPrefix("chilly-history-") }
}
let before = historyFiles()
one.start(run: 101, task: "one shot", imagePath: nil, memory: mem, allowPointing: false, spoken: false, screen: nil)
let t1 = Date()
while oneDone == nil && Date().timeIntervalSince(t1) < 30 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
check("one-shot run sees the history it was given", oneEvents.contains(.answer("3 user turns")) && oneDone == 0)
check("one-shot history file removed afterwards", historyFiles() == before)
check("one-shot events and finish name their run", oneRuns == [101])
oneEvents = []; oneDone = nil
one.start(run: 102, task: "context", imagePath: nil, memory: ConversationMemory(), allowPointing: true, spoken: true, screen: geo)
let t2 = Date()
while oneDone == nil && Date().timeIntervalSince(t2) < 30 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
check("one-shot: --spoken and --screen reach the model's prompt", oneEvents.contains(.answer("spoken=True notch=True")))

// The memory budget: the app drops older exchanges itself and the engine tells the model they are gone.
var long = ConversationMemory()
for _ in 0..<12 { long.record(user: String(repeating: "q", count: 3000), assistant: "a") }
oneEvents = []; oneDone = nil
one.start(run: 103, task: "memory", imagePath: nil, memory: long, allowPointing: false, spoken: false, screen: nil)
let t3 = Date()
while oneDone == nil && Date().timeIntervalSince(t3) < 30 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
check("one-shot: 10 exchanges sent, and the prompt says older ones are gone",
      oneEvents.contains(.answer("dropped 11 user turns")))
r = run("memory", memory: long)
check("serve: the restore says older ones are gone, and the prompt says so",
      answers(r.events) == ["dropped 11 user turns"])
// The 3D switch restarts a kept engine: the next message starts a fresh one and restores memory.
b.restartEngine()
r = run("after restart", memory: mem)
check("restartEngine: the next message starts a fresh engine with the app's memory", answers(r.events) == ["3 user turns"])
r = run("memory")
check("serve: the next prompt counts the exchanges the engine holds itself, none dropped",
      answers(r.events) == ["whole 4 user turns"])
// Cut-offs (D-122): the engine keeps what was heard as the answer, for a finished or a running turn.
r = run("two sentences")
let heardReply = "First sentence here. … " + CutOffReply.marker
b.cutOff(reply: heardReply, running: false)
r = run("heard?")
check("serve: a cut-off answer is what the next turn sees", answers(r.events) == ["last: \(heardReply)"])
let started = Date()
let stopped = "[cut off before any of it was said aloud: the user heard none of this reply]"
r = run("sleep", after: 0.5, then: { b.cutOff(reply: stopped, running: true) })
check("serve: cutting off a running turn ends it at once", r.code == 0 && Date().timeIntervalSince(started) < 4)
r = run("heard?")
check("serve: the running turn's message stays, with what was heard as its answer", answers(r.events) == ["last: \(stopped)"])

// Screen steps (D-123): the engine asks for the approval with the step, then for the step itself;
// the app's result and its fresh screenshot reach the model.
let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGD4DwABBAEAwS2OUAAAAABJRU5ErkJggg==")!
let shotPath = NSTemporaryDirectory() + "benji-servecheck-shot.png", afterPath = NSTemporaryDirectory() + "benji-servecheck-after.png"
FileManager.default.createFile(atPath: shotPath, contents: png)
// The screen after a step is a different picture: one that came back identical is not sent again (D-173).
let pngAfter = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC")!
FileManager.default.createFile(atPath: afterPath, contents: pngAfter)
func act(_ answer: @escaping (ScreenStep?) -> ScreenStepResult, image: String? = shotPath) -> [BackendEvent] {
    var steps: [ScreenStep?] = []
    onScreenEvent = { e in
        switch e {
        case .screenApproval: b.resolveApproval(true)
        case let .screenAction(request, step, _, _, _): steps.append(step); b.finishScreenStep(request: request, result: answer(step))
        default: break
        }
    }
    events = []; finished = nil
    runCount += 1
    b.start(run: runCount, task: "act", imagePath: image, memory: ConversationMemory(), allowPointing: true,
            spoken: false, screen: geo)
    let t0 = Date()
    while finished == nil && Date().timeIntervalSince(t0) < 30 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    onScreenEvent = nil
    return events
}
let save = ScreenStep.click(x: 412, y: 300, button: .left, count: 1, label: "Save button")
var acted = act { step in
    ScreenStepResult(status: step == save ? .done : .failed, text: "Clicked Save button in TextEdit.", imagePath: afterPath)
}
check("screen step: the approval carries the step, decoded for the app's own card",
      acted.contains(.screenApproval(action: "click on the screen", target: "Save button at 412,300", step: save)))
check("screen step: after the OK the engine asks the app to do exactly that step",
      acted.contains(.screenAction(request: "s1", step: save)))
check("screen step: the app's result and fresh screenshot reach the model; a 'screen' activity",
      answers(acted) == ["[done] Clicked Save button in TextEdit | screenshot=True"]
      && acted.contains(.activity(kind: "screen", name: nil)))
acted = act { _ in .refused(.secureField) }
check("screen step: a refusal reaches the model, with no screenshot and no activity",
      answers(acted) == ["[refused] That's a password field; Benji never clicks or types in one | screenshot=False"]
      && !acted.contains(.activity(kind: "screen", name: nil)))
acted = act({ _ in .refused(.unreadable) }, image: nil)
check("screen step: a turn without a screenshot isn't offered the screen tools",
      answers(acted) == ["no screen tools"] && !acted.contains { if case .screenAction = $0 { return true }; return false })
// Simple steps (D-126): the step's intent and confidence reach the app; a confident scroll goes
// unasked as free; a click goes as quiet and the app's "ask" brings the card; "Ask before every
// step" (the registration domain, so nothing is written to disk) makes the engine ask for a scroll.
func actSimply(_ task: String, answer: @escaping (ScreenStep?, ScreenStepClass?) -> ScreenStepResult) -> [BackendEvent] {
    onScreenEvent = { e in
        switch e {
        case .screenApproval: b.resolveApproval(true)
        case let .screenAction(request, step, mode, _, _): b.finishScreenStep(request: request, result: answer(step, mode))
        default: break
        }
    }
    events = []; finished = nil
    runCount += 1
    b.start(run: runCount, task: task, imagePath: shotPath, memory: ConversationMemory(), allowPointing: true,
            spoken: false, screen: geo)
    let t0 = Date()
    while finished == nil && Date().timeIntervalSince(t0) < 30 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    onScreenEvent = nil
    return events
}
func approvals(_ ev: [BackendEvent]) -> Int { ev.filter { if case .screenApproval = $0 { return true }; return false }.count }
let down = ScreenStep.scroll(x: 600, y: 400, direction: .down, amount: 3, label: "")
let readRest = ScreenStepIntent(intent: "to read the rest", confidence: .high)
acted = actSimply("act simply") { _, _ in ScreenStepResult(status: .done, text: "Scrolled down.", imagePath: afterPath) }
check("simple steps: a confident scroll reaches the app unasked, as free, with its intent",
      approvals(acted) == 0 && acted.contains(.screenAction(request: "s1", step: down, mode: .free, intent: readRest)))
check("simple steps: its result and screenshot reach the model; a 'screen' activity",
      answers(acted) == ["[done] Scrolled down | screenshot=True"] && acted.contains(.activity(kind: "screen", name: nil)))
let settingsTab = ScreenStep.click(x: 300, y: 40, button: .left, count: 1, label: "Settings tab")
let openSettings = ScreenStepIntent(intent: "to open settings", confidence: .high)
acted = actSimply("act quietly") { _, mode in
    mode == .quiet ? .ask("it's in a dialog") : ScreenStepResult(status: .done, text: "Clicked Settings tab.", imagePath: afterPath)
}
check("simple steps: a click goes as quiet; the app's \"ask\" brings the card with the intent",
      acted.contains(.screenAction(request: "s1", step: settingsTab, mode: .quiet, intent: openSettings))
      && acted.contains { if case let .screenApproval(_, target, step, intent) = $0 {
          return step == settingsTab && intent == openSettings && target.hasSuffix("(asked: it's in a dialog)") }; return false })
check("simple steps: after the OK the same step goes approved, and is done",
      acted.contains(.screenAction(request: "s2", step: settingsTab, mode: nil, intent: openSettings))
      && answers(acted) == ["[done] Clicked Settings tab | screenshot=True"])
UserDefaults.standard.register(defaults: [ScreenAutonomy.defaultsKey: true])
acted = actSimply("act simply") { _, mode in
    ScreenStepResult(status: mode == nil ? .done : .failed, text: "Scrolled down.", imagePath: afterPath)
}
UserDefaults.standard.register(defaults: [ScreenAutonomy.defaultsKey: false])
check("simple steps: with \"Ask before every step\" the engine asks for a confident scroll, then sends it approved",
      approvals(acted) == 1 && acted.contains(.screenAction(request: "s1", step: down, mode: nil, intent: readRest))
      && answers(acted) == ["[done] Scrolled down | screenshot=True"])
// Space with a Send button in front (chilly-gate fix 4): asked even with simple steps on.
acted = actSimply("press space") { _, _ in ScreenStepResult(status: .done, text: "Pressed Space.", imagePath: afterPath) }
check("gate: Space is asked on a card even with simple steps on, then done as approved",
      approvals(acted) == 1 && acted.contains { if case let .screenAction(_, _, mode, _, _) = $0 { return mode == nil }; return false }
      && !acted.contains { if case let .screenAction(_, _, mode, _, _) = $0 { return mode != nil }; return false })
// Drive mode (D-170), through the real ServeBackend and engine: the model asks to start, the engine
// raises the drive card (named goal, 45 s) and the app answers it as its own card (`via: card`);
// the drive begins, a click goes to the app marked as a drive step, the model ends it with a line.
func driveRun(_ task: String, answer: @escaping (ScreenStep?, ScreenStepClass?) -> ScreenStepResult) -> [BackendEvent] {
    onScreenEvent = { e in
        switch e {
        case .driveApproval: b.resolveApproval(true)
        case let .screenAction(request, step, mode, _, _): b.finishScreenStep(request: request, result: answer(step, mode))
        default: break
        }
    }
    events = []; finished = nil
    runCount += 1
    b.start(run: runCount, task: task, imagePath: shotPath, memory: ConversationMemory(), allowPointing: true,
            spoken: false, screen: geo)
    let t0 = Date()
    while finished == nil && Date().timeIntervalSince(t0) < 30 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    onScreenEvent = nil
    return events
}
acted = driveRun("drive") { _, _ in ScreenStepResult(status: .done, text: "Clicked Settings tab.", imagePath: afterPath) }
check("drive: the engine raises one drive card naming the goal, 45 s, and the app's own Yes begins the drive",
      acted.filter { if case .driveApproval = $0 { return true }; return false }
          == [.driveApproval(goal: "fill in the form", seconds: 45)]
      && acted.contains(.drive(DriveEvent(state: .active, goal: "fill in the form"))))
check("drive: a click inside it reaches the app as a quiet drive step, with no second card",
      acted.contains(.screenAction(request: "s1", step: settingsTab, mode: .quiet, intent: openSettings, drive: true))
      && approvals(acted) == 0)
check("drive: it ends with the model's spoken and written line, one step done",
      acted.contains(.drive(DriveEvent(state: .ended, goal: "fill in the form", reason: "finished",
                                       spoken: "I opened settings.", written: "Opened settings.", steps: 1))))
try? FileManager.default.removeItem(atPath: shotPath)
try? FileManager.default.removeItem(atPath: afterPath)

// The gate for every tool (chilly-gate): a page outside the folder tells Benji to read a key and
// send it out. The user lets it read the page; the key is refused with no card; the fetch to the
// attacker and the memory are asked, each card saying the turn read outside content, and declined.
approvalsSeen = []
approveIf = { _, target in target.hasSuffix("page.txt") }
r = run("hostile")
approveIf = nil
check("gate: the page outside the folder is read only after a card",
      approvalsSeen.first.map { $0.action.hasPrefix("read a file outside the working folder") && $0.target.hasSuffix("page.txt") } ?? false)
check("gate: ~/.ssh/id_rsa is refused and never put on a card",
      !approvalsSeen.contains { $0.target.contains("id_rsa") } && (answers(r.events).first ?? "").contains("[refused]"))
check("gate: the fetch to the attacker's host and the remember are asked, saying the turn read outside content",
      approvalsSeen.count == 3
      && approvalsSeen[1].target.contains("evil.example") && approvalsSeen[1].action.contains("Benji read a file outside the working folder this turn")
      && approvalsSeen[2].target == "the user wants commands run without asking" && approvalsSeen[2].action.contains("this turn"))
check("gate: the model got the page as marked data, then the refusal and two declines",
      answers(r.events).first.map { a in
          let parts = a.components(separatedBy: " | ")
          return parts.count == 4 && parts[0].hasPrefix("marked 1\tGreat recipes!") && parts[1].hasPrefix("[refused]")
              && parts[2].hasPrefix("[declined]") && parts[3].hasPrefix("[declined]") } ?? false)
approvalsSeen = []
autoApprove = false
r = run("subshell")
check("gate: allowed commands around a subshell are asked, and the card says why",
      approvalsSeen.count == 1 && approvalsSeen[0].action.contains("can't check first")
      && approvalsSeen[0].target == "ls; cat $(cat note.txt) | wc -l")
approvalsSeen = []
r = run("my name is Umar")
check("gate: remembering what the user said needs no card",
      approvalsSeen.isEmpty && r.events.contains(.activity(kind: "remembered", name: nil)))

// The screen as a whiteboard (chilly-whiteboard): what Benji has on the screen goes with each
// send and reaches the prompt; tags between sentences come back placed, with edits; the answer
// log keeps each turn.
ServeBackend.canvasNow = {
    var c = CanvasSnapshot()
    c.parts = [.init(id: "p1", kind: "text", label: "c", box: .init(x1: 1, y1: 2, x2: 30, y2: 40))]
    return c
}
r = run("canvas?")
check("serve: what Benji has on the screen reaches the model's prompt, by part (chilly-whiteboard)",
      answers(r.events) == ["canvas=True part=True"])
ServeBackend.canvasNow = nil
r = run("canvas?")
check("serve: nothing up, no canvas section", answers(r.events) == ["canvas=False part=False"])
r = run("whiteboard", pointing: true)
if case let .pointedAnswer(text, targets)? = r.events.last(where: { if case .pointedAnswer = $0 { return true }; return false }) {
    check("serve: tags between sentences come out of the words, each placed after its sentence, with the edit",
          text == "The legs meet at a corner.\nThe long side is c.\nThat is it."
          && targets.map(\.at) == [27, 27, 47, 58]
          && targets[2].shape == .text(x: 40, y: 40) && targets[2].label == "large:c"
          && targets[3].shape.edit == DrawingEdit(part: "p1", op: .recolor, text: "red")
          && !streamed(r.events).contains("["))
    let plan = PointingPlan(targets: targets, text: text, speaking: false, pixelSize: CGSize(width: 100, height: 100),
                            screenFrame: CGRect(x: 0, y: 0, width: 100, height: 100), displayID: nil)
    check("serve: the app gives each part its sentence and keeps the drawing for the edit",
          plan?.owners == [0, 0, 1] && plan?.extendsDrawing == true)
} else { check("whiteboard answer", false) }
let log = (ProcessInfo.processInfo.environment["BENJI_WORKDIR"] ?? "") + "/answers.jsonl"
let records = ((try? String(contentsOfFile: log, encoding: .utf8)) ?? "").split(separator: "\n")
    .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
let last = records.last ?? [:]
check("serve: the answer log keeps each turn with its raw answer, events and run id, no image",
      records.count >= 3 && (last["raw"] as? String)?.contains("[EDIT:p1:recolor red]") == true
      && (last["events"] as? [[String: Any]])?.contains { $0["type"] as? String == "answer" } == true
      && (last["run"] as? String)?.hasPrefix("t") == true)
// A saved conversation reopened (D-121): the app resets the running engine, then the next message
// restores that conversation's exchanges before it, without a new engine.
let saved = SavedConversation(id: ConversationStore.newID(), title: "Trip", started: Date(), updated: Date(), lines: [
    SavedLine(role: .user, text: "plan a trip"), SavedLine(role: .assistant, text: "Hunza in September."),
    SavedLine(role: .user, text: "cut off"), SavedLine(role: .error, text: "Cut off before it finished."),
    SavedLine(role: .user, text: "what to pack"), SavedLine(role: .assistant, text: "Layers."),
])
b.reset()
r = run("memory", memory: saved.memory)
check("serve: a reopened conversation's answered exchanges reach the engine after a reset",
      answers(r.events) == ["whole 3 user turns"])
r = run("next")
check("serve: and the engine keeps it from there", answers(r.events) == ["4 user turns"])
b.reset()
r = run("fresh again")
check("serve: a reset with no memory still starts empty", answers(r.events) == ["1 user turns"])
// Background jobs (D-130 step 1): the foreground turn starts a job, the job runs as a second turn in
// the same engine, parks on its approval until the app's own button answers, and ends with a turn_end.
var jobSeen: [JobSnapshot] = []
b.onJob = { jobSeen.append($0) }
func jobStates() -> [JobState] {
    var out: [JobState] = []
    for j in jobSeen where out.last != j.state { out.append(j.state) }
    return out
}
func waitJob(_ pred: (JobSnapshot) -> Bool, seconds: Double = 20) -> JobSnapshot? {
    let t = Date()
    while Date().timeIntervalSince(t) < seconds {
        if let j = jobSeen.last(where: pred) { return j }
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
    return nil
}
r = run("start a job")
check("jobs: the foreground turn answers at once; the job starts queued", answers(r.events) == ["tool done"]
      && jobSeen.first?.state == .queued && jobSeen.first?.title == "Fake job")
let parked = waitJob { $0.state == .needsYou }
check("jobs: a write outside the job's folder parks it as needs-you with the card's words",
      parked?.pending?.action == "write outside the working folder"
      && parked?.pending?.target.hasSuffix("/job.txt") == true)
RunLoop.main.run(until: Date().addingTimeInterval(1.0))
check("jobs: an unanswered approval parks the job: nothing written, still needs-you",
      !FileManager.default.fileExists(atPath: outside + "/job.txt") && jobSeen.last?.state == .needsYou)
r = run("while it waits")
check("jobs: a foreground turn runs beside the parked job", answers(r.events).count == 1 && r.code == 0
      && jobSeen.last?.state == .needsYou)
if let parked, let pending = parked.pending { b.answerJob(parked.id, request: pending.request, approved: true) }
let ended = waitJob { $0.state == .done }
check("jobs: the app's Yes lets it write and finish: states queued, working, needs-you, working, done",
      jobStates() == [.queued, .working, .needsYou, .working, .done]
      && FileManager.default.fileExists(atPath: outside + "/job.txt"))
check("jobs: the turn_end has the spoken line, a written line made from it for the row (D-146), only the file that exists, and the chips",
      ended?.spoken == "The job wrote job dot txt." && ended?.written == "The job wrote job.txt."
      && ended?.shownResult == "The job wrote job.txt." && ended?.files.map(\.name) == ["job.txt"]
      && ended?.chips == ["Open it", "Do more"])
if let ended { b.dismissJob(ended.id) }
jobSeen = []
r = run("start a job")
let queued = waitJob { $0.state == .queued }
if let queued { b.stopJob(queued.id) }
check("jobs: stopping in the beat ends it as stopped before it ran", waitJob { $0.state == .stopped } != nil
      && !jobSeen.contains { $0.state == .working })
// Second pass (D-172): the start row shows what the job was told; a stopped job can be continued.
check("jobs: the start row carries what the job was told (its goal first) and run 1",
      queued?.brief.hasPrefix("Goal (as Benji stated it): JOBMARK write the file.") == true && queued?.run == 1)
let stoppedJob = jobSeen.last(where: { $0.state == .stopped })
check("jobs: a stopped job offers Continue", stoppedJob?.offersContinue == true)
jobSeen = []
if let id = stoppedJob?.id { b.continueJob(id) }
let again = waitJob { $0.state == .queued && $0.run == 2 }
check("jobs: Continue starts run 2 of the same job, in the same folder (same id)", again?.id == stoppedJob?.id && again != nil)
if let again { b.stopJob(again.id) }
check("jobs: and that run can be stopped in its beat too", waitJob { $0.state == .stopped && $0.run == 2 } != nil)
// Browser reach (D-143): nothing listens until the app's switch says so; then the engine opens its
// link (private file, loopback), the real host connects to it the way Chrome would start it, and
// turning the switch off closes it. HOME is a temporary folder, so no real file is touched.
var browserSeen: [BrowserStatus] = []
ServeBackend.browserStatus = { browserSeen.append($0) }
func waitFor(_ cond: () -> Bool, seconds: Double = 10) -> Bool {
    let t = Date()
    while Date().timeIntervalSince(t) < seconds {
        if cond() { return true }
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
    return cond()
}
let tempHome = ProcessInfo.processInfo.environment["HOME"] ?? ""
let linkFile = tempHome + "/Library/Application Support/Benji/Browser/link.json"
check("browser: nothing listens until the app says so", !FileManager.default.fileExists(atPath: linkFile) && browserSeen.isEmpty)
b.setBrowser(true)
let linkOpened = waitFor { browserSeen.last == .waiting }
let linkMode = (try? FileManager.default.attributesOfItem(atPath: linkFile)[.posixPermissions] as? Int) ?? nil
check("browser: the switch opens the engine's link: state waiting, link.json private (0600)",
      linkOpened && linkMode == 0o600)
let host = Process()
host.executableURL = URL(fileURLWithPath: "/usr/bin/env")
host.arguments = ["python3", "-I", assistantDir + "/benji/browser_host.py", BrowserExtension.allowedOrigin]
host.environment = ["HOME": tempHome, "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"]
let hostOut = Pipe(), hostIn = Pipe()
host.standardOutput = hostOut
host.standardInput = hostIn
host.standardError = Pipe()
try? host.run()
let hostHead = hostOut.fileHandleForReading.readData(ofLength: 4)
let hostBody = hostOut.fileHandleForReading.readData(ofLength: hostHead.count == 4 ? Int(hostHead.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }) : 0)
check("browser: the real host, started as Chrome starts it, is accepted and tells the extension it is ready",
      String(decoding: hostBody, as: UTF8.self).contains("ready") && waitFor { browserSeen.last == .connected })
host.terminate()
check("browser: when the extension's side goes away the state is waiting again", waitFor { browserSeen.last == .waiting })
b.setBrowser(false)
check("browser: the switch off closes the link, removes link.json and says off",
      waitFor { browserSeen.last == .off } && !FileManager.default.fileExists(atPath: linkFile))
b.shutdown()
RunLoop.main.run(until: Date().addingTimeInterval(1.0))

// The logs (D-144): the real ServeBackend with the real engine. The app's lines and the engine's lines
// are in one private events.jsonl; engine.log holds the engine's stderr, redacted, private; and
// neither holds a word the fake page or the messages said.
let workFolder = ProcessInfo.processInfo.environment["BENJI_WORKDIR"] ?? ""
func fileText(_ name: String) -> String { (try? String(contentsOfFile: workFolder + "/" + name, encoding: .utf8)) ?? "" }
func fileMode(_ name: String) -> mode_t? { PrivateFile.mode(of: URL(fileURLWithPath: workFolder + "/" + name)).map { $0 & 0o777 } }
let eventLines = fileText("events.jsonl").split(separator: "\n")
    .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
let appKinds = Set(eventLines.filter { $0["src"] as? String == "app" }.compactMap { $0["kind"] as? String })
let engineKinds = Set(eventLines.filter { $0["src"] as? String == "engine" }.compactMap { $0["kind"] as? String })
check("logs: events.jsonl is private (0600) and holds the app's lines: the engine start and the job-row buttons (answer, stop)",
      fileMode("events.jsonl") == 0o600 && appKinds.isSuperset(of: ["engine_start", "job_action"])
      && eventLines.filter { $0["kind"] as? String == "job_action" }.compactMap { $0["action"] as? String }.contains("answer")
      && eventLines.filter { $0["kind"] as? String == "job_action" }.compactMap { $0["action"] as? String }.contains("stop"))
check("logs: and the engine's: its start, turns, tool decisions with their classes, approvals, job states, the browser link",
      engineKinds.isSuperset(of: ["engine_start", "turn_start", "turn_end", "tool", "approval_asked", "approval_answered",
                                  "job_state", "browser_link"]))
let toolGates = Set(eventLines.compactMap { $0["gate"] as? String })
check("logs: tool events carry only a gate class and a reason code (free, asked and denied all seen)",
      toolGates.isSuperset(of: ["free", "asked"]) && eventLines.filter { $0["kind"] as? String == "tool" }
        .allSatisfy { $0["code"] is String && $0["text"] == nil && $0["detail"] == nil })
let engineText = fileText("engine.log")
check("logs: engine.log is private (0600), has the engine's own stderr lines with a time before each, and no key",
      fileMode("engine.log") == 0o600 && engineText.contains("serving") && !engineText.contains("unused-fake-server")
      && engineText.split(separator: "\n").allSatisfy { $0.range(of: #"^\d{4}-\d\d-\d\dT"#, options: .regularExpression) != nil })
let everything = fileText("events.jsonl") + engineText
check("logs: neither file holds what the fake page said, a secret path it asked for, or a message the run sent",
      !everything.contains("Great recipes") && !everything.contains("id_rsa") && !everything.contains("evil.example/collect")
      && !everything.contains("SYSTEM:"))
check("logs: answers.jsonl and usage.jsonl are private too",
      fileMode("answers.jsonl") == 0o600 && fileMode("usage.jsonl") == 0o600)

// The talk key's prewarm (D-173): the real ServeBackend sends it only because the real engine said it can,
// and the engine writes one audit line for it: a flag and a time, never text.
b.prewarm()
check("prewarm: the real engine answers the app's prewarm with one audit line holding only a flag (and a time)",
      waitFor({ fileText("events.jsonl").contains("\"kind\":\"prewarm\"") }, seconds: 8)
      && fileText("events.jsonl").split(separator: "\n").filter { $0.contains("\"kind\":\"prewarm\"") }
        .allSatisfy { !$0.contains("text") && ($0.contains("\"skipped\":true") || $0.contains("\"skipped\":false")) })

// Fail closed (D-173): when the Keychain can't be read the engine is not started, the run ends with the
// plain words, and nothing falls back to a file.
func engineStarts() -> Int {
    fileText("events.jsonl").split(separator: "\n").filter { $0.contains("\"kind\":\"engine_start\"") && $0.contains("\"src\":\"app\"") }.count
}
let startsBefore = engineStarts()
let closed = ServeBackend(assistantDir: assistantDir)
var closedEvents: [BackendEvent] = []
var closedFinish: Int32? = nil
closed.onEvent = { _, e in closedEvents.append(e) }
closed.onFinished = { _, code in closedFinish = code }
ServeBackend.keyEnvironment = { .failure(.keychainUnreadable(.denied)) }
closed.start(run: 77, task: "hello", imagePath: nil, memory: ConversationMemory(), allowPointing: false, spoken: false, screen: nil)
check("keys: a Keychain that can't be read ends the run with the plain words and starts no engine (no fallback)",
      closedFinish == -1 && closedEvents.contains { if case let .error(text) = $0 { return text.contains("Keychain") && text.contains("won't fall back") }; return false })
Thread.sleep(forTimeInterval: 0.5)
check("keys: and no engine process was launched for it", engineStarts() == startsBefore)
ServeBackend.keyEnvironment = nil

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
