import AppKit
import Combine
import BenjiCore

/// Bridges the pure state machine and backend transport to SwiftUI. Holds the
/// single source of truth (`state`) and drives it only from real events.
/// All mutation happens on the main thread (the backend dispatches events there).
final class CompanionModel: ObservableObject {
    @Published private(set) var state = CompanionState()
    @Published var composerText = ""
    /// What the recognizer has heard so far while listening (live, on-device). Cleared when sent.
    @Published var partialTranscript = ""
    /// Live mic level, 0…1, while recording; 0 otherwise.
    @Published var micLevel: Float = 0
    /// The user wants the full panel (the notch object's open size).
    @Published var expanded = false
    /// Bumped each time a turn ends with an answer (NotchPresence.isDone): the notch shows Done.
    @Published private(set) var doneCount = 0
    /// The home hint for talking, e.g. "To talk: hold Right ⌥ and let go to send"; when Right ⌥ is not
    /// ready it says why and points to Finish Setup.
    @Published var pttHint = ""
    /// The hold-to-talk key the composer's talk capsule names ("Right ⌥"), nil when none is ready.
    @Published var talkKeyName: String?
    /// The talk key is on but not ready (no Accessibility): the capsule says so instead of naming it.
    @Published var talkKeyNeedsSetup: String?
    /// A tap of the talk key starts hands-free listening (as `pttHint` says); else a tap starts and a second tap sends.
    @Published var talkStartsOnTap = false
    /// The open panel is at its expanded size with the conversation sidebar, as the user
    /// last chose with Expand / Shrink. Not `expanded`, which is whether the panel is open at all.
    @Published var panelExpanded = UserDefaults.standard.bool(forKey: PanelGeometry.expandedKey)
    /// A hands-free conversation is on: Benji listens again after each answer.
    @Published var conversationOn = false
    /// A short note for the status line ("Stopped listening."), never a transcript row.
    @Published var statusNote: String?
    /// The note says why words weren't sent: it stays while the mic reopens, until the user speaks.
    var noteOutlastsListening = false
    /// Settings › Voice › "Listen while Benji is open" (the controller owns the real value).
    @Published var listenWhileOpen = true
    /// "Read answers aloud": on, typed answers are spoken too. Stored in user defaults.
    @Published var readAloud = ReadAloud.isOn(UserDefaults.standard.object(forKey: ReadAloud.defaultsKey))
    var levelSmoother = LevelSmoother()

    var backend: CompanionBackend
    /// Asked before each run for the backend to use; it may hand back a different one (the 3D
    /// switch wraps or unwraps it). Not called while a run is live.
    var backendForNextRun: ((CompanionBackend) -> CompanionBackend)?
    /// The settings page inside the open panel; the app sets how it reads and applies settings.
    let settings = SettingsModel()
    /// The open panel shows the settings page instead of the conversation.
    @Published var settingsOpen = false

    /// Whether the run produced anything (a tool, an answer, an error, an approval). Used to surface
    /// silent failures (e.g. no API key).
    var producedOutput = false

    /// Set by the controller to bring the panel forward with the keyboard for an approval.
    var onApprovalNeeded: ((ApprovalRequest) -> Void)?
    /// Denies the waiting approval when nobody answers in time.
    var approvalTimer: Timer?
    /// Speak an answer aloud (only for turns that started from voice).
    var onSpeak: ((String) -> Void)?
    /// Stop recording/recognition/speech when the user cancels.
    var onCancel: (() -> Void)?
    /// Click-to-talk: start recording, or stop and send (set by the controller).
    var onMicToggle: (() -> Void)?
    /// New conversation while the mic is open: drop what was half heard, keep a conversation listening.
    var onDropHeardWords: (() -> Void)?
    /// The Conversation control: start or end a hands-free conversation.
    var onConversationToggle: (() -> Void)?
    /// A typed message is about to go while the conversation listens: drop what was heard.
    var onTypedWhileListening: (() -> Void)?
    /// The panel opened or closed. `byBenji`: Benji collapsed it itself (to show a drawing).
    var onExpandedChange: ((_ open: Bool, _ byBenji: Bool) -> Void)?
    /// Sets "Listen while Benji is open"; the controller applies it.
    var onListenWhileOpenChange: ((Bool) -> Void)?
    /// Stop an answer being read aloud, without touching the mic.
    var onStopSpeaking: (() -> Void)?
    /// The answer being read aloud was typed: turning read-aloud off stops it.
    var speakingTypedAnswer = false

    // MARK: the streamed reply

    /// The reply so far while it streams: shown as Benji's line in progress, replaced by the
    /// answer when it arrives. Never holds a figure block (cut at the first code fence).
    @Published var streamingText = ""
    var rawStream = ""
    var sentences = SentenceStream()
    /// This turn's answer is spoken sentence by sentence as it streams: it will be read aloud,
    /// and it has no screenshot (marks on screen follow the whole answer's words).
    var speaksWhileStreaming = false
    /// Streamed speech began and hasn't been ended yet.
    var speechStreamOpen = false
    /// A sentence of the streaming answer, for the voice to say now (the first starts the answer).
    var onSpeakSentence: ((String) -> Void)?
    /// The rest of a streamed answer (nil: nothing left); the voice finishes after it.
    var onSpeakStreamEnd: ((String?) -> Void)?
    /// A turn is about to go to the engine (`speaks`: its answer will be read aloud); the card
    /// stage times its parts by the voice or by an estimate from this.
    var onTurnStarts: ((_ speaks: Bool) -> Void)?

    /// When each stage of the current turn happened; written to the local log when it ends.
    var latency = TurnLatency()
    /// The turn's record is complete except for audio that is still to start.
    var latencyWaitsForAudio = false
    /// This turn handed words to the voice and its audio hasn't started yet.
    var awaitsAudio = false
    /// The voice is playing (its own start and end events).
    var voiceSpeakingNow = false
    /// A turn's latency record is ready (the controller writes it to ~/.benji/latency.jsonl).
    var onLatency: ((TurnLatency) -> Void)?
    /// The steps from the final words to the send, timed into ~/.benji/voice.log (durations only),
    /// to find where a slow send spends its time.
    var stepStart: Double?
    var onStep: ((String) -> Void)?
    func step(_ name: String) {
        guard let start = stepStart else { return }
        onStep?("[turn] \(name) +\(Int(((Self.now() - start) * 1000).rounded())) ms")
    }

    /// Typing is allowed when idle, and while a conversation listens (the typed message wins).
    var canSendTyped: Bool {
        !state.isBusy || (conversationOn && state.phase == .listening)
    }

    /// The last message was cut off and a new one could go now: its Retry button works.
    var canRetry: Bool { state.retryableTurn != nil && canSendTyped }

    /// The mic button can start a turn when idle, stop a recording, or stop speech.
    var micButtonEnabled: Bool {
        !state.isBusy || state.micActive || state.phase == .speaking
    }
    /// Off / Ask / On (Settings › Screen).
    let screenMode: ScreenModeStore
    /// Take one screenshot for this message (set by the controller: of `captureTarget`, see `CaptureRouting`).
    var captureScreen: ((@escaping (Result<CapturedScreen, Error>) -> Void) -> Void)?
    /// The display the panel is on now (set by the app as the panel moves or displays change): a
    /// typed message is about the display it was typed on.
    @Published var panelDisplay: CaptureTarget?
    /// Where the talk key last went down: the spoken messages of that interaction are about it.
    private(set) var voiceDisplay: CaptureTarget?
    /// "Include this display once" (Ask only): the next message, typed or spoken, takes a picture of
    /// this display without the card. Used up by that message; cleared by Don't include, Cancel or a
    /// change of mode. The saved mode is never changed.
    @Published var includeOnce: CaptureTarget?
    /// The display this message's screenshot is for, latched when it was sent and kept through the
    /// Ask card, a slow capture and a refused one; cleared when the message is cancelled. A latched
    /// display that is disconnected is refused at capture, never swapped for another.
    var captureTarget: CaptureTarget?

    /// The talk key went down over `display` (the app reads the pointer's display at that moment).
    func voiceEngaged(on display: CaptureTarget?) {
        // A later tap can finish an existing recording. It must not retarget words already heard.
        guard !state.micActive, state.phase != .transcribing else { return }
        voiceDisplay = display
    }

    /// A deliberate use of the panel mic, whose callback owns recording.
    func toggleMicFromPanel() {
        voiceStartedInPanel()
        onMicToggle?()
    }

    /// A new panel voice interaction uses that panel's display. Stopping an existing recording or
    /// continuing a conversation keeps the display that interaction started on.
    func voiceStartedInPanel() {
        guard !conversationOn, state.phase != .listening, state.phase != .transcribing else { return }
        voiceDisplay = panelDisplay
    }

    /// The panel's one-message action: only in Ask, only with a display to name.
    var canIncludeOnce: Bool { screenModeInForce == .ask && panelDisplay != nil }

    func includeDisplayOnce() {
        guard canIncludeOnce else { return }
        includeOnce = panelDisplay
    }

    func clearIncludeOnce() { includeOnce = nil }

    /// Provider id from `benji --print-provider` ("claude"/"openai"); nil until known.
    @Published var providerID: String?
    /// The model's name when it can't read images: the screen is never captured or sent
    /// while this is set, whatever the saved Screen mode is. The saved mode is left as the user set it.
    @Published var visionUnavailable: String?

    /// The Screen mode in force: the saved one, or Off for a model that can't read images.
    var screenModeInForce: ScreenMode { visionUnavailable == nil ? screenMode.mode : .off }
    /// A message waiting for the user to say whether the screen may be sent with it.
    @Published var pendingScreenSend: PendingScreenSend?
    var screenConfirmTimer: Timer?

    /// Show the answer's targets on the captured display, revealed as their words come up.
    var onPoint: ((PointingPlan) -> Void)?
    /// Screen steps (ScreenActuator): what a step would act on (for its card), doing an
    /// approved one, and stopping one when the turn is cancelled.
    var describeScreenStep: ((ScreenStep, CapturedScreen?) -> ScreenTarget?)?
    /// The app where a drag would let go.
    var describeScreenStepEnd: ((ScreenStep, CapturedScreen?) -> ScreenTarget?)?
    /// The step, its screenshot, and the apps the card named (where it acts; where a drag lets go).
    var performScreenStep: ((ScreenStep, CapturedScreen, Int32?, Int32?, @escaping (ScreenStepOutcome) -> Void) -> Void)?
    var cancelScreenStep: (() -> Void)?
    /// Simple steps without a card: doing one after its ring (a quiet one after its
    /// longer beat), and watching for Esc between steps while a turn acts unasked.
    var performSimpleScreenStep: ((ScreenStep, CapturedScreen, ScreenStepClass, @escaping (ScreenStepOutcome) -> Void) -> Void)?
    var watchScreenTurn: ((Bool) -> Void)?

    // MARK: drive mode

    /// Doing a step inside a drive: the class it was sent with (nil: the step the user approved on
    /// a card), checked again by the drive's rules at the point (ScreenActuator, DriveClassifier).
    var performDriveStep: ((ScreenStep, CapturedScreen, Int32?, Int32?, DriveClass?, @escaping (ScreenStepOutcome) -> Void) -> Void)?
    /// Watches the user's own input while a drive is on (a global monitor, set by the app) and
    /// stops the step in flight when the user hands the screen back.
    var watchDrive: ((Bool) -> Void)?
    var handBackDriveStep: (() -> Void)?
    /// The goal of the drive on now, or nil. A drive is on only after the user pressed Yes on its card.
    var driveGoal: String?
    /// The user's mouse is moving: Benji waits, and the notch says so.
    var drivePaused = false
    var driveGranted = false
    var driveCardID: String?
    var handBack = DriveHandBack(pointer: .zero)
    var driveResumeTimer: Timer?
    static func uptime() -> Double { ProcessInfo.processInfo.systemUptime }

    // MARK: background jobs

    /// The one job the panel shows: queued, working, parked on an approval, or over until cleared.
    /// Its state is the engine's, derived there in code; nothing here reads it from text.
    @Published var job: JobSnapshot?
    /// The job's news (it needs you, or it ended) has been seen: the panel was open. The peek
    /// only speaks up for news not yet seen.
    @Published var jobSeen = true
    /// The job row's details are open (steer, stop, files, next steps).
    @Published var jobExpanded = false
    /// The cue a job's change of state maps to (done, needs approval, error). Fires when the "jobCues"
    /// setting is on; the app plays it (Benji's own cues) unless the quiet check says to hold it.
    var onJobCue: ((JobCue) -> Void)?
    /// Why an unasked notch event should wait (the user is on a call), or nil. Set by the app.
    var quietNow: (() -> QuietReason?)?
    /// The offer on the notch card, while it waits for an answer.
    @Published var appOffer: AppOffer?
    var onAppOfferAnswered: ((AppOffer, AppOfferAnswer) -> Void)?
    /// Open the panel and give it the keyboard, for words just put in the message box.
    var onOpenForTyping: (() -> Void)?
    /// Whether the default output is muted or at zero, read just before Benji would speak.
    var outputState: (() -> OutputState?)?
    /// An answer that would have been read aloud but the Mac is muted or at zero: shown as text with a
    /// hint and a Copy button. Cleared by the next message. Benji never changes the volume.
    @Published var silentAnswer: SilentAnswer?
    /// A one-line ask for a permission Benji needs just now, with a button to its Settings pane.
    @Published private(set) var permissionAsk: PermissionNeed?
    private var permissionAsks = PermissionAsks()
    /// The talk key went down: warm the engine.
    func prewarm() { backend.prewarm() }

    /// Where Copy puts the text (tests replace it; the clipboard is written only when the user presses Copy).
    var writeClipboard: (String) -> Void = { text in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Copies the unspoken answer, only when the user presses Copy.
    func copySilentAnswer() {
        guard let text = silentAnswer?.text else { return }
        writeClipboard(text)
    }

    /// Says, once per launch per permission, what Benji can't do for lack of one (the ask at the moment of need).
    func needPermission(_ need: PermissionNeed, granted: Bool) {
        if let asked = permissionAsks.ask(need, granted: granted) { permissionAsk = asked }
    }

    func dismissPermissionAsk() { permissionAsk = nil }
    /// Esc is listened for during a job's beat (a global monitor, set by the app), because the
    /// panel is usually closed when a job starts.
    var watchJobBeat: ((Bool) -> Void)?
    var jobStarted: [String: Date] = [:]
    var answeredJobRequests: Set<String> = []
    var jobBackend: JobBackend? { backend as? JobBackend }
    /// "Act on simple steps" (Settings › Screen); read at each step, so a change applies at once.
    var actsOnSimpleSteps: () -> Bool = {
        ScreenAutonomy.actsOnSimpleSteps(UserDefaults.standard.object(forKey: ScreenAutonomy.defaultsKey))
    }
    /// The user took the screen back this turn (a step stopped, Esc between steps, the talk key):
    /// no more steps without a card until the next message.
    var screenStopped = false
    /// Free and quiet steps done this turn: the sixth is asked (ScreenStepClassifier.maxUnaskedSteps).
    var unaskedSteps = 0
    var watchingScreenTurn = false
    /// Why Benji's own look asked about a step, for the card that follows for it.
    var screenAskWhy: (step: ScreenStep, why: String)?
    /// The step the card on show is for, and the app it named.
    var screenCard: (requestID: String, step: ScreenStep, appPID: Int32?, endAppPID: Int32?)?
    /// One approval, one step: what the engine then asks to do must be what the user approved.
    var screenGate = ScreenStepGate()
    /// Screenshots taken after steps, deleted with the message's own.
    var stepImageURLs: [URL] = []
    var onHidePointer: (() -> Void)?

    /// Recent exchanges passed to each run, so follow-ups have context. In memory only.
    var memory = ConversationMemory()
    var conversationMemory: ConversationMemory { memory }
    var currentTask = ""
    /// The current (or last) run handed words to the voice, so a cut-off can shorten its answer.
    var speechForRun = false
    /// The answer that run gave, once it has arrived.
    var spokenAnswer: String?
    var currentShot: CapturedScreen?
    /// The screenshot going with the message being answered (for the board's busy
    /// map, and the canvas mapped into its pixels).
    var currentScreenshotURL: URL? { currentShot?.url }
    var currentScreenshotGeometry: (screenFrame: CGRect, pixelSize: CGSize)? {
        currentShot.map { ($0.screenFrame, $0.pixelSize) }
    }
    var hasConversation: Bool { !memory.isEmpty || !state.lines.isEmpty }

    /// New conversation is available: at rest, listening or taking the final words, with
    /// something to clear; not while a reply runs or a card waits.
    var canStartNewConversation: Bool {
        NewConversationRule.enabled(phase: state.phase, hasConversation: hasConversation)
    }

    var voiceTurn = false
    /// The engine run whose events count; nil once it finished or was cancelled.
    var runs = RunToken()
    /// Bumped on every send and cancel, so a capture that finishes after a cancel is dropped.
    var turnSerial = 0
    /// The image file sent this turn; deleted when the run ends.
    var sentImageURL: URL?
    /// Thumbnails of what was actually sent, in memory only (never written to disk).
    var thumbnails: [String: NSImage] = [:]

    func thumbnail(for id: String) -> NSImage? { thumbnails[id] }

    /// How long the approval card waits before denying; always below the engine's own timeout.
    var approvalTimeout: TimeInterval { backend.approvalTimeout }
    /// How long the card on show waits: a drive's card declines itself after 45 s.
    var cardTimeout: TimeInterval {
        driveCardID != nil && driveCardID == state.pendingApproval?.id ? DriveCopy.cardSeconds : approvalTimeout
    }

    private var screenModeWatch: AnyCancellable?
    /// Saved conversations and the home view's page (none written without a store).
    let history: ConversationHistory
    private var historyWatch: AnyCancellable?

    init(backend: CompanionBackend, screenMode: ScreenModeStore = ScreenModeStore(),
         history: ConversationHistory = ConversationHistory(store: nil)) {
        self.backend = backend
        self.screenMode = screenMode
        self.history = history
        screenModeWatch = screenMode.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        historyWatch = history.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        listen(to: backend)
    }

    /// Takes `backend`'s events from now on.
    func listen(to backend: CompanionBackend) {
        // Only the live run's events reach the state: a cancelled or replaced run's late answer,
        // error, approval or finish is dropped here, so it can't revive or end a newer turn.
        backend.onEvent = { [weak self] run, event in
            guard let self, self.runs.admits(run) else { return }
            self.handle(event)
        }
        if let jobs = backend as? JobBackend {
            jobs.onJob = { [weak self] in self?.handleJob($0) }
            jobs.onEngineExit = { [weak self] in self?.engineExited() }
        }
        backend.onFinished = { [weak self] run, code in
            guard let self, self.runs.admits(run) else { return }
            self.runs.end()
            self.discardSentImage()
            self.currentShot = nil
            self.screenGate.clear()
            self.screenCard = nil
            self.endScreenTurn()
            // If the run produced nothing, it failed quietly: say so instead of showing nothing.
            if !self.producedOutput {
                self.apply(.backendError("Benji's backend (the engine) exited with no output (code \(code)). Is your API key set in ~/.benji.env?"))
            }
            self.apply(.backendFinished(code))
            // Speech that began while the reply streamed can outlast a tool step that set the
            // phase back to thinking: while the voice still plays, the panel says so.
            if self.voiceSpeakingNow, self.state.phase == .idle { self.apply(.speakingStarted) }
            self.clearStream()
            self.endSpeechStream(nil)   // an error or an empty answer: a voice still waiting ends
            self.latency.mark(.finished, at: Self.now())
            self.latencyWaitsForAudio = true
            // An answer being read aloud whose voice hasn't started: the record waits for it.
            if self.latency.time(.firstAudio) != nil || self.state.phase != .speaking && !self.awaitsAudio {
                self.flushLatency()
            }
            self.producedOutput = false
            self.voiceTurn = false
        }
    }

    func clearStream() {
        rawStream = ""
        if !streamingText.isEmpty { streamingText = "" }
        sentences = SentenceStream()
    }

    /// Ends streamed speech that began, saying `rest` last.
    func endSpeechStream(_ rest: String?) {
        guard speechStreamOpen else { return }
        speechStreamOpen = false
        onSpeakStreamEnd?(rest)
    }

    static func now() -> Double { ProcessInfo.processInfo.systemUptime }

    /// Starts a new latency record unless the current one is still collecting this turn's marks.
    func freshLatencyIfStale() {
        guard latency.time(.sent) != nil else { return }
        flushLatency()
        latency = TurnLatency()
    }

    func flushLatency() {
        guard latencyWaitsForAudio else { return }
        latencyWaitsForAudio = false
        onLatency?(latency)
    }

    /// The talk key went down: a voice turn's clock starts.
    func latencyKeyDown() {
        freshLatencyIfStale()
        latency.mark(.keyDown, at: Self.now())
    }

    /// The talk key went up (a hold ends here; a conversation's turn ends when words go).
    func latencyKeyUp() { latency.mark(.keyUp, at: Self.now()) }

    func endScreenTurn() {
        finishDrive()
        screenAskWhy = nil
        guard watchingScreenTurn else { return }
        watchingScreenTurn = false
        watchScreenTurn?(false)
    }

    /// Up to three targets, in order, each revealed when its words come up.
    func showAnswer(_ text: String, targets: [PointingTarget]) {
        producedOutput = true
        apply(.assistantAnswer(text))
        memory.record(user: currentTask, assistant: text)
        let wouldSpeak = ReadAloud.speaks(setting: readAloud, spoken: voiceTurn)
        let output = wouldSpeak ? outputState?() : nil
        let speak = SilentSpeech.shouldSpeak(wouldSpeak: wouldSpeak, state: output)
        silentAnswer = SilentSpeech.note(wouldSpeak: wouldSpeak, state: output, answer: SpeechText.plain(text))
        let streamedSpeech = speechStreamOpen
        if let shot = currentShot,
           var plan = PointingPlan(targets: targets, text: text, speaking: speak, pixelSize: shot.pixelSize,
                                   screenFrame: shot.screenFrame, displayID: shot.displayID, windows: shot.windows) {
            plan.spokenFirst = streamedSpeech
            onPoint?(plan)
            apply(.activity(.drewOnScreen))
        }
        latency.mark(.answer, at: Self.now())
        let rest = streamedSpeech ? sentences.finish(text).map(SpeechText.plain) : nil
        clearStream()
        speakingTypedAnswer = speak && !voiceTurn
        spokenAnswer = text
        if speak { speechForRun = true }
        if streamedSpeech {
            endSpeechStream(rest.flatMap { $0.isEmpty ? nil : $0 })
        } else if speak {
            awaitsAudio = !SpeechText.plain(text).isEmpty
            onSpeak?(text)
        }
    }

    private static let traceEvents = ProcessInfo.processInfo.environment["BENJI_DEBUG"] == "1"

    func apply(_ event: CompanionEvent) {
        let before = state.phase
        reduce(&state, event)
        if state.pendingApproval != nil { settingsOpen = false }   // an approval needs the panel
        if state.pendingApproval == nil, let timer = approvalTimer {   // cancelled, errored or finished
            timer.invalidate()
            approvalTimer = nil
        }
        if NotchPresence.isDone(event: event, before: before, after: state.phase) { doneCount += 1 }
        history.record(state.lines)
        if history.requestedPage != nil, !HomeView.keepsRequest(phase: state.phase) { history.requestedPage = nil }
        if Self.traceEvents {
            // Case name only (no message text), except errors and approval outcomes.
            var name = Mirror(reflecting: event).children.first?.label ?? "\(event)"
            if case .backendError(let msg) = event { name += "(\(msg))" }
            if case .approvalResolved(let approved) = event { name += "(approved=\(approved))" }
            let time = Date().formatted(.dateTime.hour().minute().second())
            FileHandle.standardError.write(Data("[event \(time)] \(name) → \(state.phase)\n".utf8))
        }
    }
}
