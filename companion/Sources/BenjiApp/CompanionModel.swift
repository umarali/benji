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
    @Published private(set) var partialTranscript = ""
    /// Live mic level, 0…1, while recording; 0 otherwise.
    @Published private(set) var micLevel: Float = 0
    /// The user wants the full panel (the notch object's open size).
    @Published var expanded = false
    /// Bumped each time a turn ends with an answer (NotchPresence.isDone): the notch shows Done.
    @Published private(set) var doneCount = 0
    /// The home hint for talking, e.g. "To talk: hold Right ⌥ and let go to send"; when Right ⌥ is not
    /// ready it says why and points to Finish Setup.
    @Published var pttHint = ""
    /// The hold-to-talk key the composer's talk capsule names ("Right ⌥"), nil when none is ready.
    @Published var talkKeyName: String?
    /// The talk key is on but not ready (no Accessibility, D-139): the capsule says so instead of naming it.
    @Published var talkKeyNeedsSetup: String?
    /// A tap of the talk key starts hands-free listening (as `pttHint` says); else a tap starts and a second tap sends.
    @Published var talkStartsOnTap = false
    /// The open panel is at its expanded size with the conversation sidebar (D-133), as the user
    /// last chose with Expand / Shrink. Not `expanded`, which is whether the panel is open at all.
    @Published private(set) var panelExpanded = UserDefaults.standard.bool(forKey: PanelGeometry.expandedKey)
    /// A hands-free conversation is on (D-43): Benji listens again after each answer.
    @Published private(set) var conversationOn = false
    /// A short note for the status line ("Stopped listening."), never a transcript row.
    @Published private(set) var statusNote: String?
    /// The note says why words weren't sent: it stays while the mic reopens, until the user speaks.
    private var noteOutlastsListening = false
    /// The menu setting "Listen While Benji Is Open" (the controller owns the real value).
    @Published private(set) var listenWhileOpen = true
    /// "Read answers aloud" (D-98): on, typed answers are spoken too. Stored in user defaults.
    @Published private(set) var readAloud = ReadAloud.isOn(UserDefaults.standard.object(forKey: ReadAloud.defaultsKey))
    private var levelSmoother = LevelSmoother()

    private var backend: CompanionBackend
    /// Asked before each run for the backend to use; it may hand back a different one (the 3D
    /// switch wraps or unwraps it). Not called while a run is live.
    var backendForNextRun: ((CompanionBackend) -> CompanionBackend)?
    /// The settings page inside the open panel; the app sets how it reads and applies settings.
    let settings = SettingsModel()
    /// The open panel shows the settings page instead of the conversation.
    @Published private(set) var settingsOpen = false

    // Diagnostics for a run: raw (unstructured) output, and whether anything
    // structured was produced. Used to surface silent failures (e.g. no API key).
    private var rawLines: [String] = []
    private var producedOutput = false

    /// Set by the controller to bring the panel forward with the keyboard for an approval.
    var onApprovalNeeded: ((ApprovalRequest) -> Void)?
    /// Denies the waiting approval when nobody answers in time.
    private var approvalTimer: Timer?
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
    /// The "…" menu's Listen While Benji Is Open.
    var onListenWhileOpenChange: ((Bool) -> Void)?
    /// Stop an answer being read aloud, without touching the mic.
    var onStopSpeaking: (() -> Void)?
    /// The answer being read aloud was typed: turning read-aloud off stops it.
    private var speakingTypedAnswer = false

    // MARK: the streamed reply (D-118 step 1)

    /// The reply so far while it streams: shown as Benji's line in progress, replaced by the
    /// answer when it arrives. Never holds a figure block (cut at the first code fence).
    @Published private(set) var streamingText = ""
    private var rawStream = ""
    private var sentences = SentenceStream()
    /// This turn's answer is spoken sentence by sentence as it streams: it will be read aloud,
    /// and it has no screenshot (marks on screen follow the whole answer's words).
    private var speaksWhileStreaming = false
    /// Streamed speech began and hasn't been ended yet.
    private var speechStreamOpen = false
    /// A sentence of the streaming answer, for the voice to say now (the first starts the answer).
    var onSpeakSentence: ((String) -> Void)?
    /// The rest of a streamed answer (nil: nothing left); the voice finishes after it.
    var onSpeakStreamEnd: ((String?) -> Void)?
    /// A turn is about to go to the engine (`speaks`: its answer will be read aloud); the card
    /// stage times its parts by the voice or by an estimate from this (chilly-beats).
    var onTurnStarts: ((_ speaks: Bool) -> Void)?

    /// When each stage of the current turn happened; written to the local log when it ends.
    private(set) var latency = TurnLatency()
    /// The turn's record is complete except for audio that is still to start.
    private var latencyWaitsForAudio = false
    /// This turn handed words to the voice and its audio hasn't started yet.
    private var awaitsAudio = false
    /// The voice is playing (its own start and end events).
    private var voiceSpeakingNow = false
    /// A turn's latency record is ready (the controller writes it to ~/.benji/latency.jsonl).
    var onLatency: ((TurnLatency) -> Void)?
    /// The steps from the final words to the send, timed into ~/.benji/voice.log (durations only),
    /// to find where a slow send spends its time.
    private var stepStart: Double?
    var onStep: ((String) -> Void)?
    private func step(_ name: String) {
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
    /// Off / Ask / On (the panel's Screen control and the menu).
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
    @Published private(set) var includeOnce: CaptureTarget?
    /// The display this message's screenshot is for, latched when it was sent and kept through the
    /// Ask card, a slow capture and a refused one; cleared when the message is cancelled. A latched
    /// display that is disconnected is refused at capture, never swapped for another.
    private(set) var captureTarget: CaptureTarget?

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
    /// The model's name when it can't read images (D-147): the screen is never captured or sent
    /// while this is set, whatever the saved Screen mode is. The saved mode is left as the user set it.
    @Published var visionUnavailable: String?

    /// The Screen mode in force: the saved one, or Off for a model that can't read images.
    var screenModeInForce: ScreenMode { visionUnavailable == nil ? screenMode.mode : .off }
    /// A message waiting for the user to say whether the screen may be sent with it.
    @Published private(set) var pendingScreenSend: PendingScreenSend?
    private var screenConfirmTimer: Timer?

    /// Show the answer's targets on the captured display, revealed as their words come up.
    var onPoint: ((PointingPlan) -> Void)?
    /// Screen steps (D-123, ScreenActuator): what a step would act on (for its card), doing an
    /// approved one, and stopping one when the turn is cancelled.
    var describeScreenStep: ((ScreenStep, CapturedScreen?) -> ScreenTarget?)?
    /// The app where a drag would let go.
    var describeScreenStepEnd: ((ScreenStep, CapturedScreen?) -> ScreenTarget?)?
    /// The step, its screenshot, and the apps the card named (where it acts; where a drag lets go).
    var performScreenStep: ((ScreenStep, CapturedScreen, Int32?, Int32?, @escaping (ScreenStepOutcome) -> Void) -> Void)?
    var cancelScreenStep: (() -> Void)?
    /// Simple steps without a card (D-126): doing one after its ring (a quiet one after its
    /// longer beat), and watching for Esc between steps while a turn acts unasked.
    var performSimpleScreenStep: ((ScreenStep, CapturedScreen, ScreenStepClass, @escaping (ScreenStepOutcome) -> Void) -> Void)?
    var watchScreenTurn: ((Bool) -> Void)?

    // MARK: drive mode (D-170)

    /// Doing a step inside a drive: the class it was sent with (nil: the step the user approved on
    /// a card), checked again by the drive's rules at the point (ScreenActuator, DriveClassifier).
    var performDriveStep: ((ScreenStep, CapturedScreen, Int32?, Int32?, DriveClass?, @escaping (ScreenStepOutcome) -> Void) -> Void)?
    /// Watches the user's own input while a drive is on (a global monitor, set by the app) and
    /// stops the step in flight when the user hands the screen back.
    var watchDrive: ((Bool) -> Void)?
    var handBackDriveStep: (() -> Void)?
    /// The goal of the drive on now, or nil. A drive is on only after the user pressed Yes on its card.
    private(set) var driveGoal: String?
    /// The user's mouse is moving: Benji waits, and the notch says so.
    private(set) var drivePaused = false
    private var driveGranted = false
    private var driveCardID: String?
    private var handBack = DriveHandBack(pointer: .zero)
    private var driveResumeTimer: Timer?
    private static func uptime() -> Double { ProcessInfo.processInfo.systemUptime }

    // MARK: background jobs (D-130 step 1)

    /// The one job the panel shows: queued, working, parked on an approval, or over until cleared.
    /// Its state is the engine's, derived there in code; nothing here reads it from text.
    @Published private(set) var job: JobSnapshot?
    /// The job's news (it needs you, or it ended) has been seen: the panel was open. The peek
    /// only speaks up for news not yet seen.
    @Published private(set) var jobSeen = true
    /// The job row's details are open (steer, stop, files, next steps).
    @Published var jobExpanded = false
    /// The cue a job's change of state maps to (done, needs approval, error). Fires when the "jobCues"
    /// setting is on; the app plays it (Benji's own cues, D-173) unless the quiet check says to hold it.
    var onJobCue: ((JobCue) -> Void)?
    /// Why an unasked notch event should wait (the user is on a call), or nil (D-173). Set by the app.
    var quietNow: (() -> QuietReason?)?
    /// The offer on the notch card, while it waits for an answer (D-187).
    @Published private(set) var appOffer: AppOffer?
    var onAppOfferAnswered: ((AppOffer, AppOfferAnswer) -> Void)?
    /// Open the panel and give it the keyboard, for words just put in the message box.
    var onOpenForTyping: (() -> Void)?
    /// Whether the default output is muted or at zero, read just before Benji would speak (D-173).
    var outputState: (() -> OutputState?)?
    /// An answer that would have been read aloud but the Mac is muted or at zero: shown as text with a
    /// hint and a Copy button. Cleared by the next message. Benji never changes the volume.
    @Published private(set) var silentAnswer: SilentAnswer?
    /// A one-line ask for a permission Benji needs just now, with a button to its Settings pane (D-173).
    @Published private(set) var permissionAsk: PermissionNeed?
    private var permissionAsks = PermissionAsks()
    /// The talk key went down: warm the engine (D-173).
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
    private var jobStarted: [String: Date] = [:]
    private var answeredJobRequests: Set<String> = []
    private var jobBackend: JobBackend? { backend as? JobBackend }
    /// "Act on simple steps" (Settings › Screen); read at each step, so a change applies at once.
    var actsOnSimpleSteps: () -> Bool = {
        ScreenAutonomy.actsOnSimpleSteps(UserDefaults.standard.object(forKey: ScreenAutonomy.defaultsKey))
    }
    /// The user took the screen back this turn (a step stopped, Esc between steps, the talk key):
    /// no more steps without a card until the next message.
    private(set) var screenStopped = false
    /// Free and quiet steps done this turn: the sixth is asked (ScreenStepClassifier.maxUnaskedSteps).
    private(set) var unaskedSteps = 0
    private var watchingScreenTurn = false
    /// Why Benji's own look asked about a step, for the card that follows for it.
    private var screenAskWhy: (step: ScreenStep, why: String)?
    /// The step the card on show is for, and the app it named.
    private var screenCard: (requestID: String, step: ScreenStep, appPID: Int32?, endAppPID: Int32?)?
    /// One approval, one step: what the engine then asks to do must be what the user approved.
    private var screenGate = ScreenStepGate()
    /// Screenshots taken after steps, deleted with the message's own.
    private var stepImageURLs: [URL] = []
    var onHidePointer: (() -> Void)?

    /// Recent exchanges passed to each run, so follow-ups have context. In memory only.
    private var memory = ConversationMemory()
    var conversationMemory: ConversationMemory { memory }
    private var currentTask = ""
    /// The current (or last) run handed words to the voice, so a cut-off can shorten its answer.
    private var speechForRun = false
    /// The answer that run gave, once it has arrived.
    private var spokenAnswer: String?
    private var currentShot: CapturedScreen?
    /// The screenshot going with the message being answered (chilly-whiteboard: the board's busy
    /// map, and the canvas mapped into its pixels).
    var currentScreenshotURL: URL? { currentShot?.url }
    var currentScreenshotGeometry: (screenFrame: CGRect, pixelSize: CGSize)? {
        currentShot.map { ($0.screenFrame, $0.pixelSize) }
    }
    var hasConversation: Bool { !memory.isEmpty || !state.lines.isEmpty }

    /// New conversation is available (D-134): at rest, listening or taking the final words, with
    /// something to clear; not while a reply runs or a card waits.
    var canStartNewConversation: Bool {
        NewConversationRule.enabled(phase: state.phase, hasConversation: hasConversation)
    }

    private var voiceTurn = false
    /// The engine run whose events count; nil once it finished or was cancelled.
    private var runs = RunToken()
    /// Bumped on every send and cancel, so a capture that finishes after a cancel is dropped.
    private var turnSerial = 0
    /// The image file sent this turn; deleted when the run ends.
    private var sentImageURL: URL?
    /// Thumbnails of what was actually sent, in memory only (never written to disk).
    private var thumbnails: [String: NSImage] = [:]

    func thumbnail(for id: String) -> NSImage? { thumbnails[id] }

    /// How long the approval card waits before denying; always below the engine's own timeout.
    var approvalTimeout: TimeInterval { backend.approvalTimeout }
    /// How long the card on show waits: a drive's card declines itself after 45 s (D-170).
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
    private func listen(to backend: CompanionBackend) {
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
            // If the run produced no structured output, it failed quietly — surface
            // the raw text (e.g. "No API key found…") instead of showing nothing.
            if !self.producedOutput {
                let msg = self.rawLines.isEmpty
                    ? "Benji's backend (the engine) exited with no output (code \(code)). Is your API key set in ~/.benji.env?"
                    : self.rawLines.joined(separator: "\n")
                self.apply(.backendError(msg))
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
            self.rawLines = []
            self.producedOutput = false
            self.voiceTurn = false
        }
    }

    private func clearStream() {
        rawStream = ""
        if !streamingText.isEmpty { streamingText = "" }
        sentences = SentenceStream()
    }

    /// Ends streamed speech that began, saying `rest` last.
    private func endSpeechStream(_ rest: String?) {
        guard speechStreamOpen else { return }
        speechStreamOpen = false
        onSpeakStreamEnd?(rest)
    }

    private static func now() -> Double { ProcessInfo.processInfo.systemUptime }

    /// Starts a new latency record unless the current one is still collecting this turn's marks.
    private func freshLatencyIfStale() {
        guard latency.time(.sent) != nil else { return }
        flushLatency()
        latency = TurnLatency()
    }

    private func flushLatency() {
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

    // MARK: user actions

    func submit() {
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, canSendTyped else { return }
        if state.phase == .listening { onTypedWhileListening?() }
        guard !state.isBusy else { return }
        composerText = ""
        statusNote = nil; noteOutlastsListening = false
        rawLines = []
        producedOutput = false
        voiceTurn = false
        turnSerial += 1
        setExpanded(true)
        onHidePointer?()
        apply(.submitText(text))
        send(task: text, restoreText: text, spoken: false)
    }

    /// A follow-up chip under an explanation card (D-125): its words are sent as a typed message.
    /// While a turn runs they wait in the composer instead.
    func ask(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        composerText = t
        submit()
    }

    /// Resends the cut-off message as a new attempt, through the screen rules like any message:
    /// Ask asks again and On takes a fresh picture; an earlier screenshot is never reused.
    func retry() {
        guard canRetry, let turn = state.retryableTurn,
              let text = state.lines.first(where: { $0.id == turn.userLineID })?.text else { return }
        if state.phase == .listening { onTypedWhileListening?() }
        guard !state.isBusy else { return }
        statusNote = nil; noteOutlastsListening = false
        rawLines = []
        producedOutput = false
        voiceTurn = turn.spoken
        turnSerial += 1
        setExpanded(true)
        onHidePointer?()
        apply(.retry)
        send(task: text, restoreText: turn.spoken ? nil : text, spoken: turn.spoken)
    }

    func setReadAloud(_ on: Bool) {
        guard readAloud != on else { return }
        readAloud = on
        UserDefaults.standard.set(on, forKey: ReadAloud.defaultsKey)
        if !on, speakingTypedAnswer, state.phase == .speaking { onStopSpeaking?() }
    }

    /// Updates the panel at once, whether or not the engine can stop yet: the run's token is
    /// dropped first, so nothing it still says (answer, error, approval, finish) comes back.
    func cancel() {
        endScreenConfirm()
        if driveGoal != nil { backend.stopDrive(reason: "user_stop") }   // the Stop button ends a drive at once (D-170)
        turnSerial += 1   // drops a capture that is still in flight
        captureTarget = nil
        includeOnce = nil
        let wasRunning = runs.isLive
        runs.end()
        if wasRunning { backend.cancel() }
        cancelScreenStep?()
        screenGate.clear()
        screenCard = nil
        endScreenTurn()
        discardSentImage()
        currentShot = nil
        rawLines = []
        producedOutput = false
        onHidePointer?()
        speechStreamOpen = false   // onCancel stops the voice, streamed or not
        speechForRun = false
        clearStream()
        onCancel?()
        voiceTurn = false
        apply(.cancel)
    }

    /// Forget the recent exchanges and clear the panel (not while a turn is running).
    func newConversation() {
        guard NewConversationRule.allows(phase: state.phase) else { return }
        if NewConversationRule.dropsHeardWords(phase: state.phase) {
            // Half-heard words belong to the old conversation; a hands-free mic reopens by itself.
            onDropHeardWords?()
            apply(.micStopped)
            partialTranscript = ""
        }
        memory.clear()
        silentAnswer = nil
        speechForRun = false
        spokenAnswer = nil
        backend.reset()
        onHidePointer?()
        statusNote = nil; noteOutlastsListening = false
        history.startNew()
        history.requestedPage = nil
        apply(.newConversation)
    }

    /// Starts one engine run with the recent exchanges, and the screenshot if there is one.
    private func run(task: String, shot: CapturedScreen? = nil) {
        currentTask = task
        currentShot = shot
        endScreenTurn()
        screenStopped = false
        unaskedSteps = 0
        step("run starts (screen \(screenMode.mode))")
        if !runs.isLive, let next = backendForNextRun?(backend), next !== backend {
            backend = next
            listen(to: next)
        }
        step("backend chosen")
        apply(.turnSent)
        if shot == nil, permissionAsk == .screenToLook { dismissPermissionAsk() }
        if !voiceTurn {
            freshLatencyIfStale()
            latency = TurnLatency()
        }
        latency.mark(.sent, at: Self.now())
        latency.spoken = voiceTurn
        latency.screen = shot != nil
        latency.backend = BackendMode.name
        latencyWaitsForAudio = false
        awaitsAudio = false
        speechForRun = false
        spokenAnswer = nil
        clearStream()
        endSpeechStream(nil)
        silentAnswer = nil
        let wouldSpeak = ReadAloud.speaks(setting: readAloud, spoken: voiceTurn)
        let mayStream = SilentSpeech.shouldSpeak(wouldSpeak: wouldSpeak, state: outputState?())   // a muted Mac: nothing starts speaking
        // An answer about the screen speaks early too (D-164); its marks catch up when they arrive.
        // On a muted Mac neither kind starts (D-173).
        let earlyOnScreen = FastPath.speaksScreenAnswersEarly(UserDefaults.standard.object(forKey: FastPath.earlyScreenSpeechKey))
        speaksWhileStreaming = (shot == nil || earlyOnScreen) && mayStream
        onTurnStarts?(mayStream)
        backend.start(run: runs.begin(), task: task, imagePath: shot?.url.path, memory: memory, allowPointing: shot != nil,
                      spoken: voiceTurn, screen: shot?.geometry)
        step("sent to the engine")
    }

    /// Ends the backend process, if it keeps one (on quit).
    func shutdown() { backend.shutdown() }

    func setScreenMode(_ mode: ScreenMode) {
        includeOnce = nil
        screenMode.choose(mode)
    }

    // MARK: screen context (Off: never; Ask: one capture after a Yes; On: one capture per message)

    /// One message, typed or spoken, with the screen as the mode says. The display it is about is
    /// latched here, once: the one chosen with Include once, else where a spoken message's talk key
    /// went down, else the panel's display for a typed one. Moving the pointer to answer the Ask card,
    /// or a capture that lands later, never changes it.
    private func send(task: String, restoreText: String?, spoken: Bool) {
        let once = includeOnce
        includeOnce = nil
        captureTarget = screenModeInForce == .off ? nil : once ?? (spoken ? voiceDisplay : panelDisplay)
        switch screenModeInForce {
        case .off: run(task: task)
        case .ask where once != nil: startWithScreen(task: task, restoreText: restoreText)   // the user already said yes
        case .ask: askToSendScreen(task: task, restoreText: restoreText ?? task)
        case .on: startWithScreen(task: task, restoreText: restoreText)
        }
    }

    /// Nothing is captured until the user says Send on the card; no answer cancels the message.
    private func askToSendScreen(task: String, restoreText: String?) {
        pendingScreenSend = PendingScreenSend(task: task, restoreText: restoreText)
        settingsOpen = false   // the question needs the panel
        setExpanded(true)
        screenConfirmTimer?.invalidate()
        let serial = turnSerial
        let timer = Timer(timeInterval: ScreenCapturePolicy.confirmTimeout, repeats: false) { [weak self] _ in
            guard let self, serial == self.turnSerial, self.pendingScreenSend != nil else { return }
            self.cancel()
        }
        RunLoop.main.add(timer, forMode: .common)
        screenConfirmTimer = timer
    }

    /// The confirm card's answer: send with the screen, send without it, or cancel the message.
    func decideScreenSend(_ choice: ScreenSendChoice) {
        guard let pending = pendingScreenSend else { return }
        switch choice {
        case .send:
            endScreenConfirm()
            startWithScreen(task: pending.task, restoreText: pending.restoreText)
        case .withoutScreen:
            endScreenConfirm()
            captureTarget = nil
            run(task: pending.task)
        case .cancel:
            if composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let text = pending.restoreText {
                composerText = text
            }
            cancel()
        }
    }

    private func endScreenConfirm() {
        screenConfirmTimer?.invalidate()
        screenConfirmTimer = nil
        pendingScreenSend = nil
    }

    private func startWithScreen(task: String, restoreText: String?) {
        guard let captureScreen else {
            apply(.backendError("Screen capture isn't available in this build. Your message wasn't sent."))
            return
        }
        let serial = turnSerial
        captureScreen { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let shot):
                guard serial == self.turnSerial else {   // cancelled while capturing
                    try? FileManager.default.removeItem(at: shot.url)
                    return
                }
                if self.permissionAsk == .screenToLook { self.dismissPermissionAsk() }
                let id = UUID().uuidString
                self.thumbnails[id] = shot.thumbnail
                self.sentImageURL = shot.url
                self.apply(.screenAttached(
                    id: id,
                    summary: ScreenCapturePolicy.attachmentSummary(pixelSize: shot.pixelSize, provider: self.providerID,
                                                                   leftOut: shot.leftOut, display: shot.displayName)))
                self.run(task: task, shot: shot)
            case .failure(let error):
                guard serial == self.turnSerial else { return }
                if let denied = error as? ScreenCaptureError, case .permissionNeeded = denied {
                    self.needPermission(.screenToLook, granted: false)
                    // Keep typed or spoken words on the existing Ask card. Nothing has been
                    // sent, and its Without screen action can send this same turn once.
                    self.askToSendScreen(task: task, restoreText: restoreText ?? task)
                    return
                }
                self.apply(.backendError("Screen capture failed: \(error.localizedDescription) Your message wasn't sent."))
                if let restoreText { self.composerText = restoreText }
            }
        }
    }

    private func discardSentImage() {
        if let url = sentImageURL { try? FileManager.default.removeItem(at: url) }
        sentImageURL = nil
        stepImageURLs.forEach { try? FileManager.default.removeItem(at: $0) }
        stepImageURLs = []
    }

    // MARK: voice (driven by VoiceController's real events)

    /// Listening shows in the peek (live words in its line); it opens the panel only if it already was.
    func voiceListeningStarted() {
        if state.isBusy { screenStopped = true }   // the talk key during a turn takes the screen back
        freshLatencyIfStale()
        partialTranscript = ""
        if !noteOutlastsListening { statusNote = nil }
        apply(.micStarted)
    }

    /// The conversation's mic opened over Benji's answer (barge-in): the panel shows the mic is
    /// on, and Benji talks on until the user's own words are heard.
    func voiceListeningOverSpeech() {
        partialTranscript = ""
        apply(.micOpenedOverSpeech)
    }

    /// The conversation heard words but didn't send them (another app was playing out loud): say
    /// so, and announce it, since nothing else on screen changes.
    /// Words the conversation heard but didn't send. `words` go into the box, so a Return sends
    /// them instead of the user having to say them again.
    func voiceHeldBack(_ notice: String, words: String = "") {
        let kept = words.trimmingCharacters(in: .whitespacesAndNewlines)
        if !kept.isEmpty { composerText = composerText.isEmpty ? kept : composerText + " " + kept }
        partialTranscript = ""
        statusNote = notice
        noteOutlastsListening = true
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: notice,
            .priority: NSAccessibilityPriorityLevel.medium.rawValue,
        ])
    }

    /// A one-line note on the status line, e.g. after a menu switch.
    func showNote(_ note: String) {
        statusNote = note
        noteOutlastsListening = false
    }

    func voiceCancelled() {
        partialTranscript = ""
        apply(.micStopped)
    }

    func voiceTranscribing() { apply(.transcribingStarted) }

    /// A conversation heard only noise, or a stop phrase: nothing is sent and nothing is said.
    func voiceIgnored() {
        partialTranscript = ""
        apply(.micStopped)
    }

    func conversationChanged(on: Bool, reason: HandsFreeEndReason? = nil) {
        guard conversationOn != on else { return }
        conversationOn = on
        statusNote = on ? nil : reason?.notice
        noteOutlastsListening = false
    }

    /// The setting's current value, from the controller (menu bar or the "…" menu).
    func listenWhileOpenChanged(_ on: Bool) { listenWhileOpen = on }

    func setListenWhileOpen(_ on: Bool) { onListenWhileOpenChange?(on) }

    func voiceError(_ message: String) {
        partialTranscript = ""
        apply(.backendError(message))
    }

    /// Live words count only while listening (a late partial after Cancel shows nothing).
    func voicePartial(_ text: String) {
        guard state.phase == .listening || state.phase == .transcribing else { return }
        partialTranscript = text
        if !text.isEmpty, history.requestedPage != nil { history.requestedPage = nil }   // words: the conversation shows
        if noteOutlastsListening, !text.isEmpty {   // new words: the held-back note has been read
            noteOutlastsListening = false
            statusNote = nil
        }
    }

    func voiceLevel(_ level: Float) {
        // Smoothed with the level tokens; tiny changes are skipped so SwiftUI isn't redrawn for
        // every audio buffer.
        let smoothed = levelSmoother.update(level, at: ProcessInfo.processInfo.systemUptime)
        if smoothed == 0 || abs(smoothed - micLevel) > Float(MotionTiming.meterMinChange) { micLevel = smoothed }
    }

    func voiceSpeaking(_ speaking: Bool) {
        voiceSpeakingNow = speaking
        if speaking {
            latency.mark(.firstAudio, at: Self.now())
            awaitsAudio = false
            flushLatency()
        }
        apply(speaking ? .speakingStarted : .speakingFinished)
    }

    /// Benji's last reply, when nothing has been said since (for how long to wait for the answer
    /// to a question it asked, `TurnPatience`).
    var lastReply: String? {
        guard let line = state.lines.last(where: { $0.role == .assistant || $0.role == .user }),
              line.role == .assistant else { return nil }
        return line.text
    }

    /// The user cut Benji's spoken answer off (talked over it, or pressed the talk key or the mic
    /// while it spoke). Called before the voice stops. The conversation keeps only `heard`, what was
    /// said aloud, marked as cut off (`CutOffReply`), here and in the engine (D-122). An answer
    /// still being written is stopped there: its message stays, with what was heard as the reply.
    func speechCutOff(heard: String) {
        guard speechForRun else { return }
        speechForRun = false
        if runs.isLive, spokenAnswer == nil {   // still being written
            let reply = CutOffReply.reply(heard: heard, full: nil)
            backend.cutOff(reply: reply, running: true)
            runs.end()
            discardSentImage()
            currentShot = nil
            rawLines = []
            producedOutput = false
            speechStreamOpen = false
            speaksWhileStreaming = false
            clearStream()
            voiceTurn = false
            memory.record(user: currentTask, assistant: reply)
            if let shown = CutOffReply.shown(heard: heard) { apply(.assistantAnswer(shown)) }
            apply(.answerCutOff(shown: nil))
            apply(.backendFinished(0))
            latency.mark(.finished, at: Self.now())
            latencyWaitsForAudio = true
            flushLatency()
            return
        }
        guard let answer = spokenAnswer, memory.exchanges.last?.assistant == answer.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return }
        let reply = CutOffReply.reply(heard: heard, full: answer)
        guard CutOffReply.isCutOff(reply) else { return }   // it had all been said
        memory.cutOffLast(reply: reply)
        backend.cutOff(reply: reply, running: false)
        apply(.answerCutOff(shown: CutOffReply.shown(heard: heard)))
    }

    /// `quiet`: a conversation turn, where an empty transcript is dropped without a word.
    /// Taken only while Transcribing: a transcript that arrives after Cancel, an error or a typed
    /// message (the cloud transcriber can't be stopped mid-way) never starts a turn.
    func voiceSubmit(_ text: String, quiet: Bool = false) {
        partialTranscript = ""
        guard state.phase == .transcribing else { return }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else {
            if quiet { apply(.micStopped); return }
            apply(.backendError("Didn't catch that. Tap the talk key, speak, then tap it again."))
            return
        }
        statusNote = nil; noteOutlastsListening = false
        rawLines = []
        producedOutput = false
        voiceTurn = true
        turnSerial += 1
        latency.mark(.transcript, at: Self.now())   // a conversation's turn has no key: no release stages
        stepStart = Self.now()
        onHidePointer?()
        step("pointer hidden")
        apply(.transcribed(t))
        step("panel state applied")
        send(task: t, restoreText: nil, spoken: true)
        stepStart = nil
    }

    /// The card's answer. Adjust says No, ends the turn and puts the action in the composer so it
    /// can be edited and sent again (a running turn can't take a new message).
    /// `request`: the card's own request; an answer from a card for an earlier request (answered,
    /// timed out or cancelled) is ignored, never applied to the one waiting now.
    func decideApproval(_ choice: ApprovalChoice, request id: String? = nil) {
        guard let req = state.pendingApproval, id == nil || id == req.id else { return }
        switch choice {
        case .yes: resolveApproval(true)
        case .no: resolveApproval(false)
        case .adjust:
            composerText = ApprovalPolicy.adjustText(for: req)
            setExpanded(true)   // before the state changes, so the panel stays open with the keyboard
            resolveApproval(false)
            cancel()
        }
    }

    /// A timeout is always a No; it is only recorded differently. Answers once per request.
    func resolveApproval(_ approved: Bool, timedOut: Bool = false) {
        guard state.pendingApproval != nil else { return }
        approvalTimer?.invalidate()
        approvalTimer = nil
        if let card = screenCard, card.requestID == state.pendingApproval?.id, approved, !timedOut {
            screenGate.approve(card.step, appPID: card.appPID, endAppPID: card.endAppPID)
        } else {
            screenGate.clear()
        }
        screenCard = nil
        // A drive begins only on a Yes pressed on its own card (D-170): remember that it was.
        if let id = driveCardID, id == state.pendingApproval?.id {
            driveGranted = approved && !timedOut
            driveCardID = nil
        }
        backend.resolveApproval(approved && !timedOut)
        apply(timedOut ? .approvalTimedOut : .approvalResolved(approved))
    }

    /// Timeout → No. Common modes, so it fires during tracking loops too.
    private func startApprovalTimer(for req: ApprovalRequest, timeout: TimeInterval? = nil) {
        approvalTimer?.invalidate()
        let timer = Timer(timeInterval: timeout ?? approvalTimeout, repeats: false) { [weak self] _ in
            guard let self, self.state.pendingApproval?.id == req.id else { return }
            self.resolveApproval(false, timedOut: true)
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
                .announcement: ApprovalPolicy.timedOutLine,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ])
        }
        RunLoop.main.add(timer, forMode: .common)
        approvalTimer = timer
    }

    /// `byBenji`: Benji collapses the panel itself (to uncover a drawing); listening carries on.
    func setExpanded(_ value: Bool, byBenji: Bool = false, preservingVoiceDisplay: Bool = false) {
        guard expanded != value else { return }
        if value && !byBenji && !preservingVoiceDisplay { voiceStartedInPanel() }
        expanded = value
        if value, job != nil { jobSeen = true }
        if !value {
            settingsOpen = false   // the next open shows the conversation
            includeOnce = nil      // a one-message choice is never left armed out of sight
        }
        onExpandedChange?(value, byBenji)
    }

    // MARK: app offers (D-187)

    /// Nothing else has the notch, so an offer may appear (or, if showing, may stay).
    var appOfferMomentIsFree: Bool {
        AppOfferRules.momentIsFree(phase: state.phase, panelOpen: expanded, conversationOn: conversationOn,
                                   jobLive: job?.state.isLive ?? false, jobPeek: jobPeek)
    }

    func showAppOffer(_ offer: AppOffer) {
        guard appOffer == nil, appOfferMomentIsFree else { return }
        appOffer = offer
    }

    /// `example`: the row the user picked; Try it alone uses the first. Nothing is sent from here:
    /// the words wait in the message box for the user's Return.
    func answerAppOffer(_ answer: AppOfferAnswer, example: String? = nil) {
        guard let offer = appOffer else { return }
        appOffer = nil
        onAppOfferAnswered?(offer, answer)
        guard answer == .tryIt else { return }
        composerText = example ?? offer.examples.first ?? ""
        onOpenForTyping?()
    }

    /// Something else wants the notch: an offer that's showing steps aside, as if waited out.
    func withdrawAppOfferIfBusy() {
        if appOffer != nil && !appOfferMomentIsFree { answerAppOffer(.notNow) }
    }

    // MARK: jobs

    /// The notch peeks for the job: during its beat (so Esc can be seen to work), and for news
    /// the user hasn't seen (it needs them, or it ended).
    var jobPeek: Bool {
        guard let job else { return false }
        // News waits while the user is on a call (the row and the resting mark still show it).
        return job.state == .queued || (job.wantsAttention && !jobSeen && quietNow?() == nil)
    }

    private func handleJob(_ snapshot: JobSnapshot, now: Date = Date()) {
        // A quiet repeat run of some other job (nothing new, D-172) never takes over the row the user
        // is looking at, and makes no sound, no peek and no thread entry.
        if snapshot.quiet, let current = job, current.id != snapshot.id { return }
        let before = job?.id == snapshot.id ? job?.state : nil
        if before == nil { jobStarted[snapshot.id] = jobStarted[snapshot.id] ?? now }
        job = snapshot
        // A job already over when first heard of (the engine's last one, after a restart) is old news.
        jobSeen = (before == nil && !snapshot.state.isLive && snapshot.state != .needsYou) || expanded
        if snapshot.state != .needsYou { answeredJobRequests = [] }
        if !snapshot.quiet, let cue = JobCues.cue(from: before, to: snapshot.state),
           JobCues.isOn(UserDefaults.standard.object(forKey: JobCues.defaultsKey)) {
            onJobCue?(cue)
        }
        watchJobBeat?(snapshot.state == .queued)
        if snapshot.savesThread,
           let thread = JobThread.conversation(snapshot, started: jobStarted[snapshot.id] ?? now, now: now) {
            history.saveJob(thread)
        }
    }

    /// The engine ended with a job in flight: it is lost with it (the record says so at the next start).
    private func engineExited() {
        guard let job, job.state.isLive else { return }
        handleJob(JobSnapshot(id: job.id, title: job.title, state: .failed,
                              error: "Benji restarted before this finished.", tainted: job.tainted, taint: job.taint,
                              sites: job.sites, brief: job.brief, run: job.run, canContinue: true,
                              schedule: job.schedule, actSites: job.actSites))
    }

    /// The user's switch for repeating jobs (D-172), passed to the engine.
    func setSchedules(_ on: Bool) { backend.setSchedules(on) }

    /// Start the engine at launch when a schedule exists, so it can run while Benji is open and idle.
    func startEngineForSchedules() { backend.startEngineForSchedules() }

    /// The row's Continue: another run of a job that failed or stopped. Only the user's button.
    func continueJob() {
        guard let job, job.offersContinue else { return }
        jobBackend?.continueJob(job.id)
    }

    /// The row's schedule buttons: pause, resume, delete. Only what the schedule offers.
    func scheduleJob(_ action: JobScheduleAction) {
        guard let job, let schedule = job.schedule else { return }
        switch action {
        case .pause where !schedule.canPause, .resume where !schedule.canResume: return
        default: jobBackend?.scheduleJob(job.id, action)
        }
    }

    /// The user's switch for browser reach (D-143), passed to the engine.
    func setBrowser(_ on: Bool) { backend.setBrowser(on) }
    func setBrowserAlways(_ sites: [String]) { backend.setBrowserAlways(sites) }

    /// The row's Yes or No. Only the app's own button answers a job's approval. Once per request.
    func answerJob(_ approved: Bool) {
        guard let job, let pending = job.pending, !answeredJobRequests.contains(pending.request) else { return }
        answeredJobRequests.insert(pending.request)
        jobBackend?.answerJob(job.id, request: pending.request, approved: approved)
    }

    func stopJob() {
        guard let job, job.state.isLive else { return }
        jobBackend?.stopJob(job.id)
    }

    /// Esc during the job's beat cancels it before it starts. True when it did.
    @discardableResult
    func jobEscape() -> Bool {
        guard job?.state == .queued else { return false }
        stopJob()
        return true
    }

    /// What the user says to steer the running job; the engine takes it between tool steps.
    @discardableResult
    func steerJob(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let job, job.state == .working || job.state == .needsYou, !t.isEmpty else { return false }
        jobBackend?.steerJob(job.id, text: t)
        return true
    }

    /// Clears a job that is over from the row.
    func dismissJob() {
        guard let job, !job.state.isLive else { return }
        jobBackend?.dismissJob(job.id)
        self.job = nil
        jobExpanded = false
        watchJobBeat?(false)
    }

    /// The job's thread, in the history view like any saved conversation.
    func openJobThread() {
        guard let job else { return }
        openConversation(job.id)
    }

    /// A next-step chip: its words are sent as a typed message, through the gate like any message.
    func askJobChip(_ chip: String) { ask(chip) }

    /// Opens the panel on its settings page (the gear, or the menu bar's Settings…).
    func openSettings(_ section: SettingsSection? = nil) {
        if let section { settings.section = section }
        settings.refresh()
        settingsOpen = true
        setExpanded(true)
    }

    func closeSettings() { settingsOpen = false }

    /// Expand / Shrink in the band; remembered for the next open and the next launch.
    func setPanelExpanded(_ on: Bool, defaults: UserDefaults = .standard) {
        guard on != panelExpanded else { return }
        panelExpanded = on
        defaults.set(on, forKey: PanelGeometry.expandedKey)
    }

    // MARK: backend → state

    private func handle(_ event: BackendEvent) {
        switch event {
        case .tool(let name, let detail):
            producedOutput = true
            apply(.toolProgress(name: name, detail: detail))
        case .answer(let raw):
            // Only screen-context answers may point; the tag is never shown or spoken.
            let (text, targets) = currentShot != nil ? PointingTags.parse(raw) : (raw, [])
            showAnswer(text, targets: targets)
        case .pointedAnswer(let text, let targets):
            showAnswer(text, targets: currentShot != nil ? targets : [])
        case .error(let text):
            producedOutput = true
            apply(.backendError(text))
        case .approval(let action, let target):
            producedOutput = true
            // One at a time: a pending request is never replaced (the serve backend refuses a
            // second one itself; the engine asks one at a time anyway).
            guard state.pendingApproval == nil else { return }
            let req = ApprovalRequest(id: UUID().uuidString, action: action, target: target)
            apply(.approvalRequested(req))
            startApprovalTimer(for: req)
            onApprovalNeeded?(req)
        case let .screenApproval(_, _, step, intent):
            producedOutput = true
            guard state.pendingApproval == nil else { return }
            // The card names the app the step would act in, worded from the step itself, with what
            // it is for and, when Benji's own look asked, why (D-126).
            let found = describeScreenStep?(step, currentShot)
            let end = describeScreenStepEnd?(step, currentShot)
            let why = screenAskWhy?.step == step ? screenAskWhy?.why : nil
            screenAskWhy = nil
            let req = ApprovalRequest(id: UUID().uuidString,
                                      action: ScreenStepCard.action(step, app: found?.appName, endApp: end?.appName),
                                      target: ScreenStepCard.target(step, intent: intent, why: why))
            screenCard = (req.id, step, found?.pid, end?.pid)
            apply(.approvalRequested(req))
            startApprovalTimer(for: req)
            onApprovalNeeded?(req)
        case let .driveApproval(goal, seconds):
            producedOutput = true
            guard state.pendingApproval == nil else { return }
            // One card per drive, naming the goal; it declines itself after 45 s and is answered only
            // by its own buttons or ⌘Return (a spoken yes never reaches it).
            let req = ApprovalRequest(id: UUID().uuidString, action: DriveCopy.cardAction,
                                      target: DriveCopy.cardTarget(goal: goal))
            driveCardID = req.id
            apply(.approvalRequested(req))
            startApprovalTimer(for: req, timeout: min(seconds, DriveCopy.cardSeconds))
            onApprovalNeeded?(req)
        case .drive(let event):
            producedOutput = true
            driveEvent(event)
        case let .screenAction(request, step, mode, intent, drive):
            producedOutput = true
            if drive, driveGoal != nil, let step {
                doDriveScreenStep(request: request, step: step, mode: mode, intent: intent)
            } else if let mode, let step {
                doSimpleScreenStep(request: request, step: step, mode: mode, intent: intent)
            } else {
                doScreenStep(request: request, step: step)
            }
        case .delta(let piece):
            producedOutput = true
            latency.mark(.firstText, at: Self.now())
            latency.streamed = true
            rawStream += piece
            let visible = StreamingReply.visible(rawStream)
            let shown = visible.trimmingCharacters(in: .whitespacesAndNewlines)
            if shown != streamingText { streamingText = shown }
            guard speaksWhileStreaming else { break }
            for sentence in sentences.feed(visible) {
                let plain = SpeechText.plain(sentence)
                guard !plain.isEmpty else { continue }
                latency.mark(.firstSentence, at: Self.now())
                speechStreamOpen = true
                speechForRun = true
                speakingTypedAnswer = !voiceTurn
                awaitsAudio = true
                onSpeakSentence?(plain)
            }
        case .cardLine, .cardEnd:
            break   // the card stage's (ExplainCardBackend); never shown or said
        case .deltaReset:
            rawStream = ""
            if !streamingText.isEmpty { streamingText = "" }
            sentences.reset()   // what was said stays said; the answer starts a new segment
        case .accepted:
            latency.mark(.accepted, at: Self.now())
            apply(.engineAccepted)   // not output: a run that then says nothing is still a failure
        case .activity(let kind, let name):
            producedOutput = true
            if let activity = TurnActivity(kind: kind, name: name) { apply(.activity(activity)) }
        case .raw(let line):
            // Keep unstructured lines so a silent failure can be surfaced on finish.
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { rawLines.append(trimmed) }
        }
    }

    /// Acts on the step the user just approved (only that one, once) on the latest screenshot,
    /// then tells the engine how it went. The screen after it is the turn's screenshot from now on:
    /// the next step's coordinates and the answer's marks are in its pixels.
    private func doScreenStep(request: String, step: ScreenStep?) {
        guard let step else { return backend.finishScreenStep(request: request, result: .refused(.unreadable)) }
        guard let approval = screenGate.take(step) else {
            return backend.finishScreenStep(request: request, result: .refused(.notApproved))
        }
        guard let shot = currentShot, let performScreenStep else {
            return backend.finishScreenStep(request: request, result: .refused(.noScreenshot))
        }
        let run = runs.live
        performScreenStep(step, shot, approval.appPID, approval.endAppPID) { [weak self] outcome in
            guard let self, let run, self.runs.admits(run) else {   // cancelled meanwhile
                if let url = outcome.shot?.url { try? FileManager.default.removeItem(at: url) }
                return
            }
            if let next = outcome.shot {
                self.stepImageURLs.append(next.url)
                self.currentShot = next
            }
            if outcome.status == .stopped {
                self.screenStopped = true
                self.showNote(ScreenActionPolicy.tookOverLine)
            }
            self.backend.finishScreenStep(request: request, result: ScreenStepResult(
                status: outcome.status, text: outcome.text, imagePath: outcome.shot?.url.path))
        }
    }

    /// A step the engine didn't ask about (D-126), free or quiet. The app checks it again before
    /// anything shows: the setting, a take-over earlier this turn, and the class from the step and
    /// the model's confidence (the engine is trusted only on whether the message asked for text).
    /// Then the actuator rings it, looks at what is really there and may still answer "ask".
    private func doSimpleScreenStep(request: String, step: ScreenStep, mode: ScreenStepClass, intent: ScreenStepIntent?) {
        guard actsOnSimpleSteps() else {
            return backend.finishScreenStep(request: request, result: .ask("you chose to be asked before every step"))
        }
        if screenStopped {
            return backend.finishScreenStep(request: request, result: ScreenStepResult(
                status: .stopped, text: ScreenActionPolicy.tookOverLine + ", so nothing was done."))
        }
        let (planned, why) = ScreenStepClassifier.plan(step, intent: intent, askEveryStep: false, askedForText: true,
                                                       unaskedSoFar: unaskedSteps)
        let mode = max(planned, mode)
        if mode == .asked {
            screenAskWhy = (step, why)
            return backend.finishScreenStep(request: request, result: .ask(why))
        }
        guard let shot = currentShot, let performSimpleScreenStep else {
            return backend.finishScreenStep(request: request, result: .refused(.noScreenshot))
        }
        apply(.screenActing(ScreenAutonomy.actingLine(step, app: describeScreenStep?(step, shot)?.appName)))
        if !watchingScreenTurn {
            watchingScreenTurn = true
            watchScreenTurn?(true)
        }
        let run = runs.live
        performSimpleScreenStep(step, shot, mode) { [weak self] outcome in
            guard let self, let run, self.runs.admits(run) else {   // cancelled meanwhile
                if let url = outcome.shot?.url { try? FileManager.default.removeItem(at: url) }
                return
            }
            self.apply(.screenActingEnded)
            if let next = outcome.shot {
                self.stepImageURLs.append(next.url)
                self.currentShot = next
            }
            switch outcome.status {
            case .stopped:
                self.screenStopped = true
                self.showNote(ScreenActionPolicy.tookOverLine)
            case .ask:
                self.screenAskWhy = (step, outcome.text)
            case .done:
                self.unaskedSteps += 1
            default:
                break
            }
            self.backend.finishScreenStep(request: request, result: ScreenStepResult(
                status: outcome.status, text: outcome.text, imagePath: outcome.shot?.url.path))
        }
    }

    /// Esc between steps while a turn acts unasked: the next step is stopped, and the engine is
    /// told so when it asks for it.
    func screenTurnEscape() {
        guard runs.isLive, watchingScreenTurn, !screenStopped else { return }
        screenStopped = true
        apply(.screenActingEnded)
        showNote(ScreenActionPolicy.tookOverLine)
    }

    // MARK: drive (D-170)

    /// The engine says the drive began or ended. It begins only if the user pressed Yes on its card;
    /// anything else is refused and told to the engine as a stop.
    private func driveEvent(_ event: DriveEvent) {
        switch event.state {
        case .active:
            guard driveGranted else {
                backend.stopDrive(reason: "user_stop")
                return
            }
            driveGranted = false
            driveGoal = event.goal
            drivePaused = false
            handBack = DriveHandBack(pointer: NSEvent.mouseLocation)
            watchDrive?(true)
            apply(.screenActing(DriveCopy.activeLine(goal: event.goal)))
        case .ended:
            finishDrive()
            let line = event.written.isEmpty ? event.spoken : event.written
            if !line.isEmpty { showNote(line) }
        }
    }

    private func finishDrive() {
        driveGranted = false
        driveResumeTimer?.invalidate()
        driveResumeTimer = nil
        drivePaused = false
        guard driveGoal != nil else { return }
        driveGoal = nil
        watchDrive?(false)
        apply(.screenActingEnded)
    }

    /// One input of the user's while a drive is on (the app's monitor calls this; Benji's own
    /// events never get here). Esc, typing, a click or a scroll hand the screen back at once; a
    /// move of the mouse pauses and nudges, and a long run of it hands the screen back.
    func driveInput(_ input: DriveHandBack.Input, at now: Double = CompanionModel.uptime()) {
        guard let goal = driveGoal else { return }
        switch handBack.observe(input, at: now) {
        case .none:
            break
        case .paused:
            if !drivePaused {
                drivePaused = true
                apply(.screenActing(DriveCopy.pausedLine(goal: goal)))
            }
            scheduleResume()
        case .handBack(let reason):
            endDriveByUser(reason)
        }
    }

    private func scheduleResume() {
        driveResumeTimer?.invalidate()
        let timer = Timer(timeInterval: DriveHandBack.resumeAfter, repeats: false) { [weak self] _ in
            guard let self, let goal = self.driveGoal, self.drivePaused else { return }
            if self.handBack.isPaused(at: Self.uptime()) { return self.scheduleResume() }
            self.drivePaused = false
            self.apply(.screenActing(DriveCopy.activeLine(goal: goal)))
        }
        RunLoop.main.add(timer, forMode: .common)
        driveResumeTimer = timer
    }

    /// The user ended the drive (Esc, typing, a click, a scroll, a long move of the mouse, or the
    /// Stop button): the step in flight stops, the engine is told why, and no more steps this turn.
    func endDriveByUser(_ reason: DriveHandBack.Reason) {
        guard driveGoal != nil else { return }
        screenStopped = true
        let why: String
        switch reason {
        case .escape: why = "user_stop"
        case .typing: why = "typing"
        case .click: why = "click"
        case .scroll: why = "scroll"
        case .movement: why = "mouse"
        }
        backend.stopDrive(reason: why)
        handBackDriveStep?()
        finishDrive()
        showNote(reason == .movement ? "Handed back: you moved the mouse." : ScreenActionPolicy.tookOverLine)
    }

    /// A step inside a drive. The step the user approved on a card (`mode` nil) is the one-use gate's;
    /// a step sent unasked is classed again here: the drive's plan can only raise what the engine
    /// said, and the actuator looks at the point and may raise it again (never lower).
    private func doDriveScreenStep(request: String, step: ScreenStep, mode: ScreenStepClass?, intent: ScreenStepIntent?) {
        if screenStopped {
            return backend.finishScreenStep(request: request, result: ScreenStepResult(
                status: .stopped, text: ScreenActionPolicy.tookOverLine + ", so nothing was done."))
        }
        var approvedPID: Int32?
        var approvedEndPID: Int32?
        var cls: DriveClass?
        if let mode {
            guard actsOnSimpleSteps() else {
                return backend.finishScreenStep(request: request, result: .ask("you chose to be asked before every step"))
            }
            let (planned, why) = DriveClassifier.plan(step, intent: intent)
            let combined = max(planned, DriveClass(mode))
            if combined == .denied {
                return backend.finishScreenStep(request: request, result: ScreenStepResult(status: .refused, text: why))
            }
            if combined == .asked {
                screenAskWhy = (step, why)
                return backend.finishScreenStep(request: request, result: .ask(why))
            }
            cls = combined
        } else {
            guard let approval = screenGate.take(step) else {
                return backend.finishScreenStep(request: request, result: .refused(.notApproved))
            }
            approvedPID = approval.appPID
            approvedEndPID = approval.endAppPID
        }
        guard let shot = currentShot, let performDriveStep else {
            return backend.finishScreenStep(request: request, result: .refused(.noScreenshot))
        }
        let run = runs.live
        performDriveStep(step, shot, approvedPID, approvedEndPID, cls) { [weak self] outcome in
            guard let self, let run, self.runs.admits(run) else {   // cancelled meanwhile
                if let url = outcome.shot?.url { try? FileManager.default.removeItem(at: url) }
                return
            }
            if let next = outcome.shot {
                self.stepImageURLs.append(next.url)
                self.currentShot = next
            }
            switch outcome.status {
            case .stopped:
                self.screenStopped = true
                self.showNote(ScreenActionPolicy.tookOverLine)
            case .ask:
                self.screenAskWhy = (step, outcome.text)
            default:
                break
            }
            self.backend.finishScreenStep(request: request, result: ScreenStepResult(
                status: outcome.status, text: outcome.text, imagePath: outcome.shot?.url.path))
        }
    }

    private func endScreenTurn() {
        finishDrive()
        screenAskWhy = nil
        guard watchingScreenTurn else { return }
        watchingScreenTurn = false
        watchScreenTurn?(false)
    }

    /// Up to three targets, in order, each revealed when its words come up.
    private func showAnswer(_ text: String, targets: [PointingTarget]) {
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

    private func apply(_ event: CompanionEvent) {
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

// MARK: - Saved conversations and the home view

extension CompanionModel {
    private var hearing: Bool { !partialTranscript.isEmpty }
    private var cardPending: Bool { pendingScreenSend != nil || state.pendingApproval != nil }

    /// What the open panel shows below the band: the conversation, home or every saved one.
    var panelPage: PanelPage {
        HomeView.page(requested: history.requestedPage, hasLines: !state.lines.isEmpty, phase: state.phase,
                      hearing: hearing, cardPending: cardPending)
    }

    /// A saved conversation can be opened, or the current one deleted, now.
    var canSwitchConversation: Bool {
        HomeView.canSwitchConversation(phase: state.phase, hearing: hearing, cardPending: cardPending)
    }

    func showPage(_ page: PanelPage) {
        history.requestedPage = page
    }

    /// Makes a saved conversation current: its lines in the panel, its exchanges in memory (sent
    /// to the engine with the next message, within the usual budget), the home view closed.
    func openConversation(_ id: String) {
        guard canSwitchConversation else { return }
        if id == history.currentID, !state.lines.isEmpty {
            history.requestedPage = nil
            return
        }
        guard let saved = history.open(id) else { return }
        replaceConversation(lines: saved.lines.map(\.transcriptLine), memory: saved.memory)
    }

    /// Deletes one saved conversation; if it is the open one, the panel starts afresh.
    func deleteConversation(_ id: String) {
        if id == history.currentID {
            guard canSwitchConversation else { return }
            replaceConversation(lines: [], memory: ConversationMemory())
        }
        history.delete(id)
    }

    /// Deletes every saved conversation; the open one leaves the panel too, when nothing runs.
    func deleteAllConversations() {
        if history.currentID != nil, canSwitchConversation {
            replaceConversation(lines: [], memory: ConversationMemory())
        }
        history.deleteAll()
    }

    private func replaceConversation(lines: [TranscriptLine], memory: ConversationMemory) {
        self.memory = memory
        backend.reset()   // the engine forgets the old one; the next message restores this memory
        onHidePointer?()
        statusNote = nil
        if lines.isEmpty { history.startNew() }
        history.requestedPage = nil
        apply(.openConversation(lines))
    }
}

struct PendingScreenSend: Equatable {
    let task: String
    /// Typed or spoken words restored on explicit dismissal, only into an empty composer.
    let restoreText: String?
}

enum ScreenSendChoice {
    case send, withoutScreen, cancel
}
