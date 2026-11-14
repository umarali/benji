import AppKit
import AVFoundation
import Speech
import BenjiCore

struct VoiceError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// The tap from the audio thread reads the current recognition request through this, so a new
/// request can take over mid-utterance without reinstalling the tap.
private final class RequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    func set(_ r: SFSpeechAudioBufferRecognitionRequest?) { lock.lock(); request = r; lock.unlock() }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); let r = request; lock.unlock()
        r?.append(buffer)
    }
}

/// Voice transport: push-to-talk and hands-free conversation (D-43). Records the mic,
/// transcribes on-device by default, hands the text to the normal engine pipeline, and speaks
/// answers to voice turns. In a conversation (`HandsFreeSession`) it sends when the user
/// pauses and opens the mic again after each answer. Every state it reports comes from a real
/// event: engine started, recognition running, synthesizer callbacks.
final class VoiceController: NSObject, AVSpeechSynthesizerDelegate {
    private let model: CompanionModel
    private let assistantDir: String
    let transcriber: TranscriberKind

    /// The plain mic engine (push-to-talk, and conversations that need no echo cancelling).
    /// Replaced by a fresh one when it fails to start, so the next start reads the device anew.
    private var engine = AVAudioEngine()
    private var file: AVAudioFile?
    private var recordingURL: URL?
    // Debug-only input level stats, written on the audio thread.
    private let levelLock = NSLock()
    private var levelFrames = 0
    private var levelPeak: Float = 0
    private var pressedAt: Date?
    private var recording = false
    private var awaitingPermission = false
    /// Listening was started by a tap and stays on until the next tap (or the time limit).
    private var latched = false
    private var maxRecordingTimer: Timer?
    private var recognitionTask: SFSpeechRecognitionTask?
    // Live on-device recognition: audio is streamed to the recognizer while the user speaks.
    private var liveRequest: SFSpeechAudioBufferRecognitionRequest?
    private let requestBox = RequestBox()
    /// Text from earlier requests in this utterance (a request can end on its own mid-way).
    private var committedText = ""
    private var latestLiveText = ""
    private var requestStartedAt: TimeInterval = 0
    private var restarts = RecognizerRestarts()
    private var liveCompletion: ((String) -> Void)?
    private var liveFallbackTimer: Timer?
    private let synth = AVSpeechSynthesizer()
    /// On-device Kokoro voice when it's installed and chosen (`ttsEngine`); nil = Apple voice.
    private var kokoro: KokoroSpeaker?
    private let kokoroInstalled: Bool
    /// Where the spoken answer has got to, for the pointer overlay's speech-paced reveal.
    var onSpeechProgress: ((SpeechProgress) -> Void)?
    /// When the answer's words are heard, as offsets in all the voice was given for it
    /// (`spokenText`, UTF-16) with that text: the explanation card's clock (chilly-beats).
    var onSpokenWords: ((_ spoken: String, _ marks: [SpokenProgress.Mark]) -> Void)?
    /// An Apple-voice utterance is queued or playing (Kokoro keeps its own `isBusy`).
    private var systemSpeechQueued = false

    // Barge-in: talking over Benji to interrupt it (Settings › Voice).
    /// One engine for the voice and the mic with echo cancellation, for barge-in on speakers.
    /// Made on first use, which happens only in that mode.
    private lazy var echoAudio: EchoCancellingAudio = {
        let audio = EchoCancellingAudio()
        audio.onConfigurationChange = { [weak self] in self?.echoConfigurationChanged() }
        return audio
    }()
    /// The mic is open over Benji's answer and the user hasn't been heard yet.
    private var listeningOverSpeech = false
    /// This recording is on the echo-cancelling engine.
    private var recordingOnEcho = false
    /// What Benji is saying, so its own words coming back through the mic aren't the user's.
    private var spokenText = ""
    private var routeChecked: (route: OutputRoute, at: TimeInterval)?
    /// The Apple voice rendered into buffers and played through the echo-cancelling engine.
    private let echoSynth = AVSpeechSynthesizer()
    private var echoSpeechQueued = false
    private var echoSpeechID = 0
    private var echoScheduled = 0
    private var echoPlayed = 0
    private var echoRendered = false
    /// Word marks of the echo-path answer: which buffer they fall in, and where in the text.
    private var echoMarks: [(buffer: Int, offset: Int)] = []
    /// Where the echo-path answer starts in `spokenText`.
    private var echoBase = 0

    // Talking over Benji on speakers without echo cancelling (D-122), and cut-offs.
    /// Whether the mic hears someone other than Benji while it speaks (fed while listening over speech).
    private var speechGate = SpeechGate()
    /// Benji stopped while the guarded mic was open over it: its last words may still be heard.
    private var settle: (endedAt: Double, spoken: String)?
    private var settleFirstWordAt: Double?
    /// When the Apple voice reached each word, and where each of its utterances starts in
    /// `spokenText` (a streamed answer is one utterance per sentence).
    private var appleProgress = SpokenProgress()
    private var appleBases: [ObjectIdentifier: Int] = [:]

    // Hands-free conversation.
    private(set) var handsFreeSettings: HandsFreeSettings
    private var handsFree: HandsFreeSession
    /// Opening the panel starts a conversation; closing it ends one ("Listen While Benji Is Open").
    private var openListening: OpenListening
    /// Decides the end of the current utterance; non-nil while a conversation is recording.
    private var endpointer: UtteranceEndpointer?
    private var handsFreeTimer: Timer?
    /// When another app's sound was last checked (a few times a second while the mic is open).
    private var otherAudioCheckedAt: TimeInterval = 0
    /// The conversation started or ended (for the lock/sleep/Escape watcher).
    var onHandsFreeChange: ((Bool) -> Void)?
    var isHandsFreeOn: Bool { handsFree.isOn }
    /// A conversation needs live on-device recognition to hear the pauses, and never sends
    /// audio anywhere; with the cloud transcriber the talk key keeps its one-message behaviour.
    var handsFreeAvailable: Bool { transcriber == .onDevice }
    private var tapStartsConversation: Bool { handsFreeSettings.startsOnTap && handsFreeAvailable }

    static let micDenied = "Microphone access is off for Benji. Turn it on in System Settings › Privacy & Security › Microphone, then try again."
    static let speechDenied = "Speech Recognition is off for Benji. Turn it on in System Settings › Privacy & Security › Speech Recognition (or set pttTranscriber to \"engine\" to use a cloud key)."

    init(model: CompanionModel, assistantDir: String, transcriber: TranscriberKind) {
        self.model = model
        self.assistantDir = assistantDir
        self.transcriber = transcriber
        let defaults = UserDefaults.standard
        handsFreeSettings = HandsFreeSettings.from(handsFree: defaults.object(forKey: "handsFree"),
                                                   endSilence: defaults.object(forKey: "handsFreeEndSilence"),
                                                   idleTimeout: defaults.object(forKey: "handsFreeIdleTimeout"))
        handsFree = HandsFreeSession(settings: handsFreeSettings)
        openListening = OpenListening(
            enabled: OpenListening.enabled(from: defaults.object(forKey: OpenListening.defaultsKey)),
            keepsListeningWhenClosed: OpenListening.enabled(from: defaults.object(forKey: OpenListening.keepWhenClosedKey)))
        let install = KokoroInstall(dataDir: KokoroInstall.dataDir(environment: ProcessInfo.processInfo.environment))
        kokoroInstalled = install.isInstalled { FileManager.default.fileExists(atPath: $0) }
        super.init()
        synth.delegate = self
        let engine = SpeechEngine.resolve(setting: UserDefaults.standard.string(forKey: "ttsEngine"),
                                          kokoroInstalled: kokoroInstalled)
        if engine == .kokoro {
            kokoro = KokoroSpeaker(install: install, assistantDir: assistantDir) { [weak self, weak model] speaking in
                model?.voiceSpeaking(speaking)
                self?.onSpeechProgress?(speaking ? .started : .ended)
                if !speaking { self?.speechEnded() }
            }
            kokoro?.onProgress = { [weak self] words in
                guard let self else { return }
                self.onSpeechProgress?(.willReach(words))
                let now = ProcessInfo.processInfo.systemUptime
                self.onSpokenWords?(self.spokenText, words.map { SpokenProgress.Mark(at: now + $0.delay, offset: $0.offset) })
            }
            // Kokoro couldn't play through the echo-cancelling engine: it carries on on its own
            // output (never the Apple voice), and Always stops trying echo cancelling here.
            kokoro?.onEchoOutputFailed = { [weak self] in self?.echoCancellationFailed("voice") }
        }
    }

    var transcriberDescription: String {
        transcriber == .onDevice ? "on-device (audio stays on this Mac)" : "`benji --transcribe` (cloud key)"
    }

    // MARK: push-to-talk

    private static let debug = ProcessInfo.processInfo.environment["BENJI_DEBUG"] == "1"
    /// To stderr with BENJI_DEBUG=1, and always to ~/.benji/voice.log (states, formats, engines,
    /// error codes; never words that were heard).
    /// The words of the utterance being decided, so a held-back one can be kept in the box.
    private var heardWords = ""

    private func trace(_ s: String) {
        if Self.debug { FileHandle.standardError.write(Data("[ptt] \(s)\n".utf8)) }
        VoiceLogFile.shared.append(s)
    }

    /// Talk key down. Starts listening; if listening was latched by a tap, this
    /// press stops and sends. While Benji is speaking, it just stops the speech.
    /// In a conversation it acts like a tap (`toggle`).
    func pressed() {
        trace("pressed phase=\(model.state.phase) recording=\(recording) latched=\(latched) handsFree=\(handsFree.isOn) awaitingPermission=\(awaitingPermission) mic=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue) speech=\(SFSpeechRecognizer.authorizationStatus().rawValue)")
        if handsFree.isOn { pressedAt = nil; toggle(); return }
        // One press: stop Benji and listen (D-122). The press goes on as a hold or a tap.
        if model.state.phase == .speaking || isSpeechActive { cutOffSpeech(at: ProcessInfo.processInfo.systemUptime) }
        if latched && (recording || awaitingPermission) { finish(); return }
        guard !model.state.isBusy, !recording, !awaitingPermission else { return }
        stopSpeaking()        // an answer still being synthesized must not play over the new turn
        kokoro?.prepare()     // load the voice model while the user talks and Benji thinks
        pressedAt = Date()
        latched = false
        openMic()
    }

    /// Talk key up. A hold sends now. A quick tap starts a conversation with the mic already
    /// open (or, with `handsFree` off, keeps listening until the next tap).
    func released() {
        guard let start = pressedAt else { return }   // the release of a send-tap
        let held = Date().timeIntervalSince(start)
        pressedAt = nil
        trace("released held=\(String(format: "%.2f", held))s recording=\(recording)")
        // Letting go to answer a permission prompt shouldn't lose the turn either.
        if TalkGesturePolicy.isTap(holdSeconds: held) || awaitingPermission {
            if tapStartsConversation { adoptMicForConversation() } else { latched = true }
            return
        }
        finish()
    }

    /// A tap of Right ⌥, the mic button, or a talk-key press during a conversation.
    /// - Benji speaking: stop the speech and listen, in the same press (D-122).
    /// - In a conversation: send now if something was heard, otherwise end the conversation.
    /// - Otherwise: start a conversation (or, with `handsFree` off, the old tap-to-send turn).
    func toggle() {
        let now = ProcessInfo.processInfo.systemUptime
        if handsFree.isOn {
            if handsFree.utterancePending {
                // The words are being finalised: a tap means "send now", never "end the conversation".
                trace("tap while transcribing: sending now")
                deliverLive(latestLiveText)
                return
            }
            if model.state.phase == .speaking || isSpeechActive {
                cutOffSpeech(at: now)
                if !recording { apply(handsFree.listenNow(snapshot, at: now)) }
                return
            }
            if recording, endpointer?.hasSpeech == true { finishUtterance(); return }
            endHandsFree(.user)
            return
        }
        if recording || awaitingPermission { finish(); return }
        if model.state.phase == .speaking || isSpeechActive { cutOffSpeech(at: now) }
        if tapStartsConversation {
            guard !model.state.isBusy else { return }
            startHandsFree()
            return
        }
        pressed()
        if recording || awaitingPermission {
            pressedAt = nil
            latched = true
        }
    }

    /// Opens the mic once permissions allow: for a push-to-talk turn or a conversation.
    private func openMic() {
        awaitingPermission = true
        ensurePermissions { [weak self] granted, message in
            guard let self else { return }
            self.awaitingPermission = false
            self.trace("permissions granted=\(granted) held=\(self.pressedAt != nil) latched=\(self.latched) handsFree=\(self.handsFree.isOn)")
            guard granted else {
                self.latched = false
                self.model.voiceError(message)
                self.apply(self.handsFree.stop(.micUnavailable))
                return
            }
            // Released, cancelled, or the conversation closed the mic meanwhile: don't open it.
            guard self.pressedAt != nil || self.latched || self.handsFree.micOpen else { return }
            if !self.startRecording() { self.apply(self.handsFree.stop(.micUnavailable)) }
        }
    }

    /// Stop listening and send what was heard.
    private func finish() {
        latched = false
        pressedAt = nil
        guard recording else { return }
        let url = recordingURL
        stopRecording()
        levelLock.lock(); let frames = levelFrames, peak = levelPeak; levelLock.unlock()
        trace("captured frames=\(frames) peak=\(String(format: "%.4f", peak))")
        model.voiceTranscribing()
        let deliver: (Result<String, Error>) -> Void = { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let text): self.model.voiceSubmit(text)
            case .failure(let error): self.model.voiceError(error.localizedDescription)
            }
        }
        if transcriber == .onDevice {
            finishLiveRecognition { text in deliver(.success(text)) }
        } else if let url {
            transcribeWithEngine(url) { result in
                try? FileManager.default.removeItem(at: url)
                deliver(result)
            }
        }
    }

    /// Stop everything voice-related (used by Cancel); ends a conversation too, except one the
    /// open panel is keeping: there Cancel stops the task and the speech, and listening resumes.
    func cancelAll() {
        if handsFree.isOn && openListening.keepsListeningOnCancel {
            pressedAt = nil
            latched = false
            if recording || awaitingPermission { discardRecording() }
            endpointer = nil
            endLiveRecognition()   // words still being finalised are dropped, not sent
            handsFree.micClosed(at: ProcessInfo.processInfo.systemUptime)
            stopSpeaking()
            return
        }
        apply(handsFree.stop(.cancelled))
        pressedAt = nil
        latched = false
        if recording { stopRecording() }
        if let url = recordingURL { try? FileManager.default.removeItem(at: url) }
        recordingURL = nil
        endLiveRecognition()
        stopSpeaking()
    }

    // MARK: hands-free conversation

    /// The "…" menu's Start / Stop Listening.
    func toggleHandsFree() {
        if handsFree.isOn { endHandsFree(.user) } else { startHandsFree() }
    }

    var listenWhileOpen: Bool { openListening.enabled }
    var keepListeningWhenClosed: Bool { openListening.keepsListeningWhenClosed }
    var endsConversationOnMenuClose: Bool {
        openListening.endsConversationOnMenuClose(conversationOn: handsFree.isOn)
    }

    /// Settings › Voice › "Keep listening when the panel closes" (D-122).
    func setKeepListeningWhenClosed(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: OpenListening.keepWhenClosedKey)
        follow(openListening.setKeepsListeningWhenClosed(on, conversationOn: handsFree.isOn))
    }

    /// Mic and Speech Recognition already allowed, on-device: opening the panel may listen
    /// without asking for anything. Without them only the talk key asks.
    private var canListenWithoutAsking: Bool {
        handsFreeAvailable
            && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            && SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    /// The panel opened or closed (`keepListening`: Benji collapsed it to show a drawing).
    func panelOpenChanged(_ open: Bool, keepListening: Bool = false) {
        follow(openListening.update(panelOpen: open, conversationOn: handsFree.isOn,
                                    canListen: canListenWithoutAsking, keepListening: keepListening))
    }

    /// The menu setting "Listen While Benji Is Open".
    func setListenWhileOpen(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: OpenListening.defaultsKey)
        follow(openListening.setEnabled(on, conversationOn: handsFree.isOn, canListen: canListenWithoutAsking))
    }

    /// The menu's quiet-spell choice; applies to a running conversation too.
    func setIdleTimeout(_ seconds: TimeInterval) {
        UserDefaults.standard.set(seconds, forKey: "handsFreeIdleTimeout")
        handsFreeSettings = HandsFreeSettings(startsOnTap: handsFreeSettings.startsOnTap,
                                              endSilence: handsFreeSettings.endSilence, idleTimeout: seconds)
        handsFree.settings = handsFreeSettings
    }

    private func follow(_ action: OpenListeningAction?) {
        switch action {
        case .start: trace("open panel: listening"); startHandsFree(byUser: false)
        case .stop(let reason): endHandsFree(reason)
        case nil: break
        }
    }

    /// Turns the conversation on. The mic opens now if Benji is free, otherwise after the
    /// current answer. `byUser`: the talk key, the mic glyph or the menu, not the panel opening.
    func startHandsFree(byUser: Bool = true) {
        if byUser { openListening.userStarted() }
        guard !handsFree.isOn, !recording, !awaitingPermission else { return }
        guard handsFreeAvailable else {
            model.voiceError("Conversation needs on-device transcription. Remove the pttTranscriber setting to use it.")
            return
        }
        if model.state.phase == .speaking { stopSpeaking() }
        kokoro?.prepare()
        latched = false
        pressedAt = nil
        beginHandsFree()
        let now = ProcessInfo.processInfo.systemUptime
        apply(handsFree.update(snapshot, at: now))
        apply(handsFree.start(at: now))
    }

    /// A tap that already opened the mic becomes the first turn of a conversation.
    private func adoptMicForConversation() {
        guard !handsFree.isOn else { return }
        openListening.userStarted()
        latched = false
        let now = ProcessInfo.processInfo.systemUptime
        _ = handsFree.update(snapshot, at: now)
        handsFree.adoptOpenMic(at: now)
        maxRecordingTimer?.invalidate()
        maxRecordingTimer = nil
        if recording {
            var e = UtteranceEndpointer(endSilence: handsFreeSettings.endSilence)
            e.transcript(liveText, at: now)
            endpointer = e
        }
        beginHandsFree()
    }

    private func beginHandsFree() {
        trace("conversation on (silence \(handsFreeSettings.endSilence)s, quiet timeout \(handsFreeSettings.idleTimeout)s)")
        model.conversationChanged(on: true)
        handsFreeTimer?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.handsFreeTick() }
        RunLoop.main.add(timer, forMode: .common)
        handsFreeTimer = timer
        onHandsFreeChange?(true)
    }

    /// Escape, lock, sleep, closing the panel, the control: end the conversation now.
    func endHandsFree(_ reason: HandsFreeEndReason) {
        apply(handsFree.stop(reason))
    }

    /// The user typed a message while the conversation was listening: drop what was heard so
    /// the typed message goes instead. The mic reopens after its answer.
    func typedMessageWhileListening() {
        guard handsFree.isOn, recording else { return }
        discardRecording()
        handsFree.micClosed(at: ProcessInfo.processInfo.systemUptime)
    }

    private var snapshot: HandsFreeSnapshot {
        HandsFreeSnapshot(phase: model.state.phase,
                          approvalPending: model.state.pendingApproval != nil,
                          screenCardPending: model.pendingScreenSend != nil,
                          speechPending: isSpeechActive,
                          bargeIn: handsFree.isOn && handsFreeAvailable && talkOverPath.listensOverSpeech)
    }

    // MARK: barge-in

    private var bargeInMode: BargeInMode {
        BargeInMode.from(UserDefaults.standard.object(forKey: BargeInMode.defaultsKey))
    }

    /// Where echo cancellation failed to start (D-119), from user defaults (the settings page
    /// clears them when Always is chosen again).
    private var echoVerdicts: EchoVerdicts {
        EchoVerdicts(stored: UserDefaults.standard.object(forKey: EchoVerdicts.defaultsKey))
    }

    /// This audio setup: where the sound goes and which mic listens.
    private var echoKey: String { EchoVerdicts.key(route: outputRoute, input: SystemAudio.defaultInputName()) }

    /// The setting as it acts here: Always is Headphones on speakers whose echo cancelling failed.
    private var activeBargeIn: BargeInMode {
        let mode = bargeInMode
        guard mode == .always else { return mode }
        return mode.effective(route: outputRoute,
                              echoUnavailable: echoVerdicts.isKnownBad(echoKey, now: Date().timeIntervalSince1970))
    }

    /// How the mic may listen while Benji speaks here (D-122): on speakers whose echo cancelling
    /// failed, Always still listens, on the plain mic, guarded.
    private var talkOverPath: TalkOverPath {
        TalkOverPath.choose(mode: bargeInMode, route: outputRoute,
                            echoUnavailable: echoVerdicts.isKnownBad(echoKey, now: Date().timeIntervalSince1970))
    }

    /// The status-line notice was shown this run.
    private var echoNoticeShown = false

    /// Echo cancellation didn't start (`what`: "mic" or "voice"). Remember it for this setup, so the
    /// next turns use the plain mic and Benji's own voice output without trying again; free the
    /// echo engine (unless Benji's voice is still playing on it); say so once.
    private func echoCancellationFailed(_ what: String) {
        let key = echoKey
        var verdicts = echoVerdicts
        let news = verdicts.recordFailure(key, now: Date().timeIntervalSince1970)
        UserDefaults.standard.set(verdicts.stored, forKey: EchoVerdicts.defaultsKey)
        trace("echo cancelling failed (\(what)) on \(key): Always listens guarded here from now on (plain mic, D-122)")
        if echoAudio.isPlaying { echoAudio.stopMic() } else { echoAudio.reset() }
        if news, !echoNoticeShown {
            echoNoticeShown = true
            model.showNote(BargeInMode.echoUnavailableNotice)
        }
    }

    /// Where the sound goes, checked at most twice a second (the tick asks ten times).
    private var outputRoute: OutputRoute {
        let now = ProcessInfo.processInfo.systemUptime
        if let checked = routeChecked, now - checked.at < 0.5 { return checked.route }
        let route = SystemAudio.bargeInRoute()
        routeChecked = (route, now)
        return route
    }

    /// Benji's voice has to go through the echo-cancelling engine so the mic can listen over it.
    private var echoNeeded: Bool {
        handsFree.isOn && handsFreeAvailable && activeBargeIn.needsEchoCancellation(outputRoute)
    }

    /// Words over the answer that aren't Benji's own: stop speaking, keep listening, and keep
    /// what the user said as the start of their next message. The conversation keeps what Benji
    /// had said by `startedAt`, when the user began talking.
    private func interrupt(keeping words: String, startedAt: Double) {
        trace("barge-in: the user talked over the answer (\(talkOverPath.rawValue))")
        model.speechCutOff(heard: heardSoFar(at: startedAt))
        listeningOverSpeech = false
        settle = nil
        stopSpeaking()
        restartRecognition(keeping: words)
        model.voiceListeningStarted()
        heard(liveText)
    }

    /// The talk key or the mic while Benji speaks: the conversation keeps what was said aloud
    /// (`CompanionModel.speechCutOff`, before the voice stops), then the voice stops. A mic already
    /// open over the answer goes on as the user's (`speechEnded`).
    private func cutOffSpeech(at time: Double) {
        trace("cut off by a press")
        model.speechCutOff(heard: heardSoFar(at: time))
        settle = nil
        stopSpeaking()
        // The Apple voice says it was cancelled a moment later: the press listens now, not then.
        if model.state.phase == .speaking {
            model.voiceSpeaking(false)
            onSpeechProgress?(.ended)
        }
        if listeningOverSpeech, recording {   // stopSpeaking found speech still queued: listen anyway
            listeningOverSpeech = false
            restartRecognition(keeping: "")
            model.voiceListeningStarted()
        }
    }

    /// What of the answer now speaking had been said aloud by `time`.
    private func heardSoFar(at time: Double) -> String {
        if let kokoro, kokoro.isBusy { return kokoro.heardText(at: time) }
        if streamVoice == .buffered { return "" }
        return appleProgress.heard(spokenText, at: time)
    }

    /// A voice stopped (finished, failed, stopped by a tap or an interrupt). If the mic was open
    /// over it, everything heard so far was Benji: drop it and listen to the user from here. On the
    /// guarded path its last words may still come in for a moment (`SettleWindow`).
    private func speechEnded() {
        guard listeningOverSpeech, recording, !isSpeechActive else { return }
        listeningOverSpeech = false
        let now = ProcessInfo.processInfo.systemUptime
        if talkOverPath == .guarded {
            settle = (now, spokenText)
            settleFirstWordAt = nil
        }
        if handsFree.isOn {   // the answer is over: wait for the reply to it as for any utterance
            endpointer = UtteranceEndpointer(endSilence: handsFreeSettings.endSilence,
                                             patience: TurnPatience.after(reply: model.lastReply))
        }
        restartRecognition(keeping: "")
        model.voiceListeningStarted()
    }

    /// Heard words with Benji's own last words dropped, right after it stopped (guarded path).
    private func settled(_ text: String) -> String {
        guard let settle else { return text }
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return text }
        let first = settleFirstWordAt ?? ProcessInfo.processInfo.systemUptime
        settleFirstWordAt = first
        return SettleWindow.strip(words, spoken: settle.spoken, firstWordAt: first, speechEndedAt: settle.endedAt)
    }

    /// One mic buffer while the mic is open over Benji's answer.
    private func overSpeechLevel(_ level: Float, duration: Double, at time: Double) {
        guard listeningOverSpeech else { return }
        speechGate.mic(level, playback: playbackLevel(at: time), duration: duration, at: time)
    }

    /// Benji's own level around `time`: Kokoro's real playback, an assumed level for the Apple
    /// voice (its audio isn't seen), 0 when nothing plays.
    private func playbackLevel(at time: Double) -> Float {
        if let kokoro, kokoro.isBusy { return kokoro.playbackLevel(at: time) }
        if model.state.phase == .speaking && (systemSpeechQueued || echoSpeechQueued || appleStreamActive) {
            return PlaybackEnvelope.unknownLevel
        }
        return 0
    }

    /// A fresh recognition request in the same listening spell, starting from `text`.
    private func restartRecognition(keeping text: String) {
        recognitionTask?.cancel()
        recognitionTask = nil
        liveRequest = nil
        requestBox.set(nil)
        committedText = text
        latestLiveText = ""
        do { try startRecognitionRequest() } catch {
            trace("recognition restart failed: \(error.localizedDescription)")
        }
    }

    /// New conversation while the mic is open or finalising (D-134): the words heard so far are
    /// dropped, not sent. A running conversation keeps listening (the mic reopens at once).
    func dropHeardWords() {
        pressedAt = nil
        latched = false
        if recording || awaitingPermission { discardRecording() }
        endpointer = nil
        endLiveRecognition()
        if handsFree.isOn { handsFree.micClosed(at: ProcessInfo.processInfo.systemUptime) }
    }

    /// The output device changed under the echo-cancelling engine: its voice and mic have stopped.
    /// The mic reopens by itself, for the new route.
    private func echoConfigurationChanged() {
        trace("echo-cancelling engine: output changed")
        routeChecked = nil
        if echoSpeechQueued || kokoro?.isBusy == true { stopSpeaking() }
        if recordingOnEcho {
            discardRecording()
            handsFree.micClosed(at: ProcessInfo.processInfo.systemUptime)
        }
    }

    private func handsFreeTick() {
        let now = ProcessInfo.processInfo.systemUptime
        if recording, now - otherAudioCheckedAt >= 0.25 { checkOtherAudio(at: now) }
        if recording, let e = endpointer, e.shouldEnd(at: now) {
            finishUtterance()
            return
        }
        apply(handsFree.update(snapshot, at: now))
        apply(handsFree.tick(at: now))
    }

    /// Another app playing out loud while the conversation listens: its words may be heard as the
    /// user's, so the session holds that utterance back. Push-to-talk isn't checked.
    private func checkOtherAudio(at now: TimeInterval) {
        otherAudioCheckedAt = now
        // Off by default (the menu's "Hold Back Words Heard Over Other Apps' Sound"): Core Audio
        // isn't even asked, and the conversation sends what it heard as it always did.
        guard OtherAppAudioGuard.isOn(from: UserDefaults.standard.object(forKey: OtherAppAudioGuard.defaultsKey)) else {
            handsFree.otherAppAudio(false)
            return
        }
        let audible = OtherAppAudio.audible(playing: SystemAudio.otherAppPlaying(), route: SystemAudio.outputRoute())
        if audible, !handsFree.otherAudioDuringUtterance { trace("another app is playing out loud") }
        handsFree.otherAppAudio(audible)
    }

    /// The user paused: close the mic, take the final words, and let the session decide.
    private func finishUtterance() {
        guard recording else { return }
        checkOtherAudio(at: ProcessInfo.processInfo.systemUptime)
        let heardSoFar = settled(liveText)
        endpointer = nil
        handsFree.utteranceEnding()
        stopRecording()
        model.voiceTranscribing()
        let decide: (String) -> Void = { [weak self] text in
            guard let self else { return }
            let final = text.isEmpty ? heardSoFar : self.settled(text)
            self.settle = nil
            self.heardWords = final
            let actions = self.handsFree.utteranceFinished(final, at: ProcessInfo.processInfo.systemUptime)
            // Noise and stop phrases send nothing: leave Transcribing quietly.
            if !actions.contains(where: { if case .submit = $0 { return true } else { return false } }) {
                self.model.voiceIgnored()
            }
            self.apply(actions)
            self.heardWords = ""
        }
        finishLiveRecognition(decide)   // conversations are on-device only (`handsFreeAvailable`)
    }

    /// Close the mic and drop whatever was heard.
    private func discardRecording() {
        endpointer = nil
        settle = nil
        if recording { stopRecording() }
        if let url = recordingURL { try? FileManager.default.removeItem(at: url) }
        recordingURL = nil
        endLiveRecognition()
        model.voiceCancelled()
    }

    private func apply(_ actions: [HandsFreeAction]) {
        for action in actions {
            switch action {
            case .openMic:
                guard !recording, !awaitingPermission else { continue }
                trace("conversation: listening")
                openMic()
            case .closeMic:
                trace("conversation: mic closed")
                if recording || awaitingPermission || model.state.phase == .listening { discardRecording() }
            case .submit(let text):
                model.voiceSubmit(text, quiet: true)
            case .heldBack(let reason):
                trace("conversation: utterance held back (\(reason))")
                model.voiceHeldBack(reason.notice, words: heardWords)
            case .ended(let reason):
                trace("conversation off (\(reason.rawValue))")
                handsFreeTimer?.invalidate()
                handsFreeTimer = nil
                endpointer = nil
                openListening.conversationEnded(reason)
                model.conversationChanged(on: false, reason: reason)
                onHandsFreeChange?(false)
            }
        }
    }

    // MARK: permissions

    private func ensurePermissions(_ done: @escaping (Bool, String) -> Void) {
        // The one-line ask at the moment of need (D-173): says once per launch what is off, with a button.
        func refused(_ need: PermissionNeed, _ words: String) {
            model.needPermission(need, granted: false)
            done(false, words)
        }
        func speechStep() {
            guard transcriber == .onDevice else { return done(true, "") }
            switch SFSpeechRecognizer.authorizationStatus() {
            case .authorized:
                done(true, "")
            case .notDetermined:
                SFSpeechRecognizer.requestAuthorization { status in
                    DispatchQueue.main.async { status == .authorized ? done(true, "") : refused(.speechToTranscribe, Self.speechDenied) }
                }
            default:
                refused(.speechToTranscribe, Self.speechDenied)
            }
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            speechStep()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { granted ? speechStep() : refused(.microphoneToHear, Self.micDenied) }
            }
        default:
            refused(.microphoneToHear, Self.micDenied)
        }
    }

    // MARK: recording

    /// Returns false (after reporting why) when the mic couldn't be opened.
    @discardableResult
    private func startRecording() -> Bool {
        guard !recording else { return true }
        kokoro?.stopPreview()   // a Settings › Voice preview must not be heard as the user
        // Over Benji's answer (barge-in) the mic hears it too. On speakers in "Always" mode the
        // voice plays through the echo-cancelling engine, and every utterance of the conversation
        // opens on that same engine (`MicEngine`): two engines taking turns on one mic failed.
        let overSpeech = handsFree.isOn && snapshot.overSpeech
        let route = outputRoute
        let chosen = MicEngine.choose(mode: activeBargeIn, route: route, handsFreeOn: handsFree.isOn,
                                      handsFreeAvailable: handsFreeAvailable)
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard chosen == .echoCancelling || (format.sampleRate > 0 && format.channelCount > 0) else {
            model.voiceError("No microphone input is available.")
            return false
        }
        do {
            // On-device: stream buffers to the recognizer. Cloud (`benji --transcribe`): write a WAV.
            var file: AVAudioFile?
            if transcriber == .onDevice {
                try startLiveRecognition()
            } else {
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("benji-ptt-\(UUID().uuidString).wav")
                let settings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: format.sampleRate,
                    AVNumberOfChannelsKey: format.channelCount,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                ]
                file = try AVAudioFile(forWriting: url, settings: settings,
                                       commonFormat: format.commonFormat, interleaved: format.isInterleaved)
                recordingURL = url
            }
            self.file = file
            let box = requestBox
            levelLock.lock(); levelFrames = 0; levelPeak = 0; levelLock.unlock()
            trace("recording format=\(format) live=\(liveRequest != nil) handsFree=\(handsFree.isOn) "
                  + "overSpeech=\(overSpeech) engine=\(chosen.rawValue) bargeIn=\(bargeInMode.rawValue) acting=\(activeBargeIn.rawValue) "
                  + "talkOver=\(talkOverPath.rawValue) route=\(route)")
            // Audio goes only to the recogniser in memory (or, for the cloud transcriber, to a
            // temporary WAV that is deleted after use). A conversation never writes audio.
            let consume: (AVAudioPCMBuffer) -> Void = { [weak self] buffer in
                box.append(buffer)
                try? file?.write(from: buffer)
                guard let self, let data = buffer.floatChannelData else { return }
                let n = Int(buffer.frameLength)
                let seconds = buffer.format.sampleRate > 0 ? Double(n) / buffer.format.sampleRate : 0
                var sum: Float = 0, peak: Float = 0
                for i in 0..<n { let v = data[0][i]; sum += v * v; peak = max(peak, abs(v)) }
                let level = MicLevel.normalized(rms: n > 0 ? (sum / Float(n)).squareRoot() : 0)
                self.levelLock.lock()
                self.levelFrames += n
                self.levelPeak = max(self.levelPeak, peak)
                self.levelLock.unlock()
                DispatchQueue.main.async {
                    let now = ProcessInfo.processInfo.systemUptime
                    self.model.voiceLevel(level)
                    self.endpointer?.level(level, at: now)
                    self.overSpeechLevel(level, duration: seconds, at: now)
                }
            }
            // The cloud transcriber's WAV has the plain engine's format: no fallback to the other one.
            let used = try openMic(chosen, consume, mayUseEcho: transcriber == .onDevice)
            recordingOnEcho = used == .echoCancelling
            recording = true
            if handsFree.isOn {
                endpointer = UtteranceEndpointer(endSilence: handsFreeSettings.endSilence,
                                                 patience: overSpeech ? 0 : TurnPatience.after(reply: model.lastReply))
            } else {
                maxRecordingTimer = Timer.scheduledTimer(withTimeInterval: TalkGesturePolicy.maximumRecording,
                                                         repeats: false) { [weak self] _ in self?.finish() }
            }
            listeningOverSpeech = overSpeech
            speechGate = SpeechGate()
            settle = nil
            if overSpeech { model.voiceListeningOverSpeech() } else { model.voiceListeningStarted() }
            return true
        } catch {
            file = nil
            if let url = recordingURL { try? FileManager.default.removeItem(at: url) }
            recordingURL = nil
            endLiveRecognition()
            if let failed = error as? MicStartError {
                model.voiceError(MicEngine.failureMessage(code: failed.code, description: failed.description,
                                                          triedBoth: failed.triedBoth))
            } else {
                model.voiceError("Couldn't start recording: \(error.localizedDescription)")
            }
            return false
        }
    }

    /// Both mic engines failed to start (or the one there was).
    private struct MicStartError: Error {
        let code: Int
        let description: String
        let triedBoth: Bool
    }

    /// Opens the mic on `choice`. If that fails, the failed engine is stopped (its tap removed)
    /// and the other engine is tried once; only then is the failure reported. Returns the engine
    /// in use.
    private func openMic(_ choice: MicEngine, _ consume: @escaping (AVAudioPCMBuffer) -> Void,
                         mayUseEcho: Bool) throws -> MicEngine {
        do {
            try startMic(on: choice, consume)
            return choice
        } catch let first as NSError {
            trace("mic didn't start engine=\(choice.rawValue) domain=\(first.domain) code=\(first.code)")
            closeFailedMic(choice)
            if choice == .echoCancelling {
                echoCancellationFailed("mic")
                // A fresh plain engine: the failed voice-processing start must leave nothing behind
                // that keeps the plain mic silent.
                engine.inputNode.removeTap(onBus: 0)
                if engine.isRunning { engine.stop() }
                engine = AVAudioEngine()
            }
            let other = choice.other
            guard other == .plain || mayUseEcho else {
                throw MicStartError(code: first.code, description: first.localizedDescription, triedBoth: false)
            }
            do {
                try startMic(on: other, consume)
                trace("mic started on the other engine=\(other.rawValue)")
                return other
            } catch let second as NSError {
                trace("mic didn't start engine=\(other.rawValue) domain=\(second.domain) code=\(second.code)")
                closeFailedMic(other)
                throw MicStartError(code: second.code, description: second.localizedDescription, triedBoth: true)
            }
        }
    }

    private func startMic(on choice: MicEngine, _ consume: @escaping (AVAudioPCMBuffer) -> Void) throws {
        switch choice {
        case .echoCancelling:
            _ = try echoAudio.startMic(consume)
        case .plain:
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw VoiceError("No microphone input is available.") }
            input.removeTap(onBus: 0)   // never install two taps on one bus
            input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in consume(buffer) }
            engine.prepare()
            try engine.start()
        }
    }

    /// After a failed start: no tap left behind, the engine stopped. A failed plain engine is
    /// replaced, so the next start reads the device's format anew.
    private func closeFailedMic(_ choice: MicEngine) {
        switch choice {
        case .echoCancelling:
            echoAudio.stopMic()
        case .plain:
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            engine = AVAudioEngine()
        }
    }

    private func stopRecording() {
        maxRecordingTimer?.invalidate()
        maxRecordingTimer = nil
        if recordingOnEcho {
            echoAudio.stopMic()
            recordingOnEcho = false
        } else {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        listeningOverSpeech = false
        recording = false
        if #available(macOS 15.0, *) { file?.close() }
        file = nil
        model.voiceLevel(0)
    }

    // MARK: live on-device transcription

    /// Starts streaming recognition for a new utterance. Partial results are shown as you
    /// speak; the audio never leaves the Mac (`requiresOnDeviceRecognition`).
    private func startLiveRecognition() throws {
        committedText = ""
        latestLiveText = ""
        restarts = RecognizerRestarts()
        try startRecognitionRequest()
    }

    /// One recognition request. A request can end on its own while the mic is still open (a
    /// final result after a pause, or "no speech" after a quiet while); a new one then carries on
    /// and the text so far is kept, so the rest of what is said isn't lost.
    private func startRecognitionRequest() throws {
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
            throw VoiceError("Speech recognition isn't available right now.")
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw VoiceError("This Mac can't transcribe \(recognizer.locale.identifier) on-device. "
                             + "Set pttTranscriber to \"engine\" to use a cloud key instead.")
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true
        liveRequest = request
        requestBox.set(request)
        requestStartedAt = ProcessInfo.processInfo.systemUptime
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            DispatchQueue.main.async {
                guard let self, self.liveRequest === request else { return }
                if let text, !text.isEmpty {
                    self.latestLiveText = text
                    if self.recording { self.heard(self.liveText) }
                }
                guard isFinal || error != nil else { return }
                if let error {
                    // 1110 = no speech detected. Either way, keep what was heard so far.
                    self.trace("recognition error \((error as NSError).code): \(error.localizedDescription)")
                }
                if self.liveCompletion != nil {
                    self.deliverLive(self.latestLiveText)
                } else if self.recording {
                    self.requestEndedWhileRecording()
                }
            }
        }
    }

    /// Everything heard in this utterance so far.
    private var liveText: String { TranscriptJoin.join(committedText, latestLiveText) }

    private func heard(_ raw: String) {
        let now = ProcessInfo.processInfo.systemUptime
        if listeningOverSpeech {
            // Nothing heard over the answer is shown or counted until it is the user's own words.
            // On speakers without echo cancelling the words must also come with a voice louder than
            // Benji's own in the mic (D-122).
            let guarded = talkOverPath == .guarded
            let interrupts = guarded
                ? GuardedTalkOver.interrupts(heard: raw, spoken: spokenText, voiceOpen: speechGate.isOpen(at: now))
                : EchoGuard.interrupts(heard: raw, spoken: spokenText)
            guard interrupts else { return }
            // The recogniser lags the voice: the user began about when the level first said so.
            let started = speechGate.voiceStarted(at: now) ?? now - 0.6
            interrupt(keeping: EchoGuard.userWords(heard: raw, spoken: spokenText).joined(separator: " "),
                      startedAt: min(started, now))
            return
        }
        let text = settled(raw)
        model.voicePartial(text)
        endpointer?.transcript(text, at: now)
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { handsFree.heardSpeech(at: now) }
    }

    private func requestEndedWhileRecording() {
        let now = ProcessInfo.processInfo.systemUptime
        let heardWords = !latestLiveText.isEmpty
        committedText = liveText
        latestLiveText = ""
        recognitionTask?.cancel()
        recognitionTask = nil
        liveRequest = nil
        requestBox.set(nil)
        guard restarts.requestEnded(started: requestStartedAt, ended: now, heardWords: heardWords) else {
            trace("recognition keeps ending at once; not restarting")
            if handsFree.isOn {
                discardRecording()
                model.voiceError("On-device speech recognition stopped working. Try again in a moment.")
                apply(handsFree.stop(.micUnavailable))
            }
            return
        }
        trace("recognition request ended mid-utterance; continuing with a new one")
        do { try startRecognitionRequest() } catch {
            trace("restart failed: \(error.localizedDescription)")
        }
    }

    /// Ends the audio and waits briefly for the final result. If the recognizer returns
    /// nothing final (or an empty final), the latest partial text is used.
    private func finishLiveRecognition(_ completion: @escaping (String) -> Void) {
        liveCompletion = completion
        guard liveRequest != nil else { return deliverLive("") }   // between requests: use what we have
        liveRequest?.endAudio()
        liveFallbackTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.trace("no final result in time; using partial text")
            self.deliverLive(self.latestLiveText)
        }
    }

    private func deliverLive(_ text: String) {
        guard let completion = liveCompletion else { return }
        let finalText = TranscriptJoin.join(committedText, text.isEmpty ? latestLiveText : text)
        endLiveRecognition()
        trace("transcript chars=\(finalText.count)")
        completion(finalText)
    }

    private func endLiveRecognition() {
        liveFallbackTimer?.invalidate()
        liveFallbackTimer = nil
        liveCompletion = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        liveRequest = nil
        requestBox.set(nil)
    }

    private func transcribeWithEngine(_ url: URL, completion: @escaping (Result<String, Error>) -> Void) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "cd \"$BENJI_DIR\" && exec python3 -m benji --transcribe \"$BENJI_WAV\""]
        var env = ProcessInfo.processInfo.environment
        env["BENJI_DIR"] = assistantDir
        env["BENJI_WAV"] = url.path
        p.environment = env
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.terminationHandler = { proc in
            let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let errText = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                if proc.terminationStatus == 0 {
                    completion(.success(text))
                } else {
                    completion(.failure(VoiceError(errText.isEmpty
                        ? "Transcription failed (exit \(proc.terminationStatus))." : errText)))
                }
            }
        }
        do { try p.run() } catch { completion(.failure(error)) }
    }

    // MARK: speech output

    /// How the streamed answer now speaking is being said (D-118): nil when none is.
    private enum StreamVoice { case kokoro, apple, buffered }
    private var streamVoice: StreamVoice?
    /// Sentences of a streamed answer kept to be said in one go (the echo-cancelling Apple voice,
    /// whose word marks follow one utterance).
    private var streamBuffer: [String] = []
    /// The Apple voice is saying a streamed answer whose last sentence may still be to come.
    private var appleStreamOpen = false
    /// The Apple voice is on a streamed answer (from its first sentence until its last one ends),
    /// and has started playing it.
    private var appleStreamActive = false
    private var appleStreamStarted = false

    /// A sentence of an answer that is still streaming: the first starts the answer, the rest
    /// queue behind it. `plain` is already speech text (no Markdown).
    func speakSentence(_ plain: String) {
        guard !plain.isEmpty else { return }
        if streamVoice == nil {
            spokenText = plain
            appleProgress.reset()
            appleBases = [:]
            if echoNeeded, kokoro?.isUsable != true {
                streamVoice = .buffered
                streamBuffer = [plain]
                return
            }
            if let kokoro, kokoro.isUsable {
                streamVoice = .kokoro
                kokoro.output = echoNeeded ? echoAudio : nil
                kokoro.beginStream(plain) { [weak self] text in self?.kokoroFailedMidStream(text) }
            } else {
                streamVoice = .apple
                appleStreamOpen = true
                appleStreamActive = true
                appleStreamStarted = false
                speakWithSystemVoice(plain)
            }
            return
        }
        spokenText += " " + plain
        switch streamVoice {
        case .kokoro:
            if kokoro?.append(plain) != true { speakWithSystemVoice(plain) }
        case .apple:
            speakWithSystemVoice(plain)
        case .buffered:
            streamBuffer.append(plain)
        case nil:
            break
        }
    }

    /// The streamed answer's last words (nil: none). It ends once everything queued has played.
    func endSpeechStream(_ rest: String?) {
        if let rest, !rest.isEmpty { speakSentence(rest) }
        let voice = streamVoice
        streamVoice = nil
        switch voice {
        case .kokoro:
            kokoro?.closeStream()
        case .apple:
            appleStreamOpen = false
            if appleStreamStarted, !synth.isSpeaking { appleStreamFinished() }
        case .buffered:
            let text = streamBuffer.joined(separator: " ")
            streamBuffer = []
            spokenText = text
            speakWithSystemVoice(text)
        case nil:
            break
        }
    }

    /// Kokoro failed before its first sound: the Apple voice says what it was given, and the
    /// rest of the streamed answer goes to the Apple voice too.
    private func kokoroFailedMidStream(_ text: String) {
        guard streamVoice == .kokoro else { return speakWithSystemVoice(text) }   // already closed: say it whole
        if echoNeeded {
            streamVoice = .buffered
            streamBuffer = [text]
            return
        }
        streamVoice = .apple
        appleStreamOpen = true
        appleStreamActive = true
        appleStreamStarted = false
        speakWithSystemVoice(text)
    }

    private func appleStreamFinished() {
        appleStreamActive = false
        appleStreamStarted = false
        systemSpeechQueued = false
        model.voiceSpeaking(false)
        onSpeechProgress?(.ended)
        speechEnded()
    }

    func speak(_ text: String) {
        let plain = SpeechText.plain(text)
        guard !plain.isEmpty else { return }
        spokenText = plain
        appleProgress.reset()
        appleBases = [:]
        if let kokoro, kokoro.isUsable {
            kokoro.output = echoNeeded ? echoAudio : nil
            kokoro.speak(plain) { [weak self] text in self?.speakWithSystemVoice(text) }
        } else {
            speakWithSystemVoice(plain)
        }
    }

    private func speakWithSystemVoice(_ plain: String) {
        if echoNeeded { return speakThroughEcho(plain) }
        let utterance = AVSpeechUtterance(string: plain)
        utterance.voice = Self.chosenVoice()
        appleBases[ObjectIdentifier(utterance)] = offsetInSpokenText(plain)
        systemSpeechQueued = true
        synth.speak(utterance)
    }

    /// Where `plain` (the latest one, if it is there twice) starts in `spokenText`, in UTF-16.
    private func offsetInSpokenText(_ plain: String) -> Int {
        guard let range = spokenText.range(of: plain, options: .backwards) else { return 0 }
        return spokenText.utf16.distance(from: spokenText.startIndex, to: range.lowerBound)
    }

    /// The best installed voice for the user's language (Premium > Enhanced), or the
    /// `ttsVoice` setting if that voice is installed; nil means the system default.
    static func chosenVoice() -> AVSpeechSynthesisVoice? {
        let candidates = AVSpeechSynthesisVoice.speechVoices().map {
            VoiceCandidate(id: $0.identifier, language: $0.language, quality: $0.quality.rawValue,
                           isNovelty: $0.voiceTraits.contains(.isNoveltyVoice))
        }
        let id = VoiceChoice.best(from: candidates,
                                  language: AVSpeechSynthesisVoice.currentLanguageCode(),
                                  preferredID: UserDefaults.standard.string(forKey: "ttsVoice"))
        return id.flatMap { AVSpeechSynthesisVoice(identifier: $0) }
    }

    var voiceDescription: String {
        if let kokoro, kokoro.isUsable { return "\(KokoroVoices.named(kokoro.voice).name), Kokoro on this Mac" }
        let voice = Self.chosenVoice()
            ?? AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
        guard let voice else { return "system default" }
        let quality = [2: " (Enhanced)", 3: " (Premium)"][voice.quality.rawValue] ?? " (basic)"
        return voice.name + quality
    }

    // MARK: Settings › Voice

    var voicePickerStatus: VoicePickerStatus {
        VoicePickerStatus.from(engine: kokoro == nil ? .system : .kokoro, installed: kokoroInstalled,
                               usable: kokoro?.isUsable ?? false)
    }

    /// The Kokoro voice the next answer speaks in.
    var kokoroVoiceChosen: String {
        kokoro?.voice ?? KokoroSettings.voice(UserDefaults.standard.string(forKey: "kokoroVoice"))
    }

    /// The Kokoro voices on offer, as far as the voices file is known.
    var kokoroVoiceChoices: [KokoroVoice] {
        KokoroVoices.choices(installed: kokoro?.installedVoices ?? [], chosen: kokoroVoiceChosen)
    }

    /// Says one sentence in `id` for Settings › Voice, unless that could get in the way of a turn
    /// (`VoicePreview.refusal`): then nothing plays and the reason comes back.
    func previewVoice(_ id: String) -> VoicePreview.Refusal? {
        guard let kokoro, kokoro.isUsable else { return .unavailable }
        if let refusal = VoicePreview.refusal(phase: model.state.phase, micOpen: recording,
                                              speechActive: isSpeechActive, headphones: outputRoute == .headphones) {
            return refusal
        }
        let voice = KokoroVoices.named(KokoroSettings.voice(id))
        return kokoro.preview(VoicePreview.sentence(for: voice), voice: voice.id) ? nil : .unavailable
    }

    func stopSpeaking() {
        streamVoice = nil
        streamBuffer = []
        appleStreamOpen = false
        appleStreamActive = false
        appleStreamStarted = false
        kokoro?.stop()
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        systemSpeechQueued = false
        if echoSpeechQueued {
            echoSpeechID += 1   // late buffers and marks of this answer are dropped
            echoSpeechQueued = false
            echoSynth.stopSpeaking(at: .immediate)
            echoAudio.stopPlayback()
            model.voiceSpeaking(false)
            onSpeechProgress?(.ended)
        }
        speechEnded()
    }

    /// An answer is queued, loading or playing in any voice: the conversation's mic stays shut
    /// (unless barge-in lets it listen over the answer).
    private var isSpeechActive: Bool {
        (kokoro?.isBusy ?? false) || systemSpeechQueued || echoSpeechQueued || appleStreamActive || streamVoice == .buffered
    }

    // MARK: the Apple voice through the echo-cancelling engine

    /// Renders the answer into buffers and plays them on the shared engine, so the mic can listen
    /// over it with Benji's voice cancelled. Word marks keep the pointer's speech-paced reveal.
    private func speakThroughEcho(_ plain: String) {
        let utterance = AVSpeechUtterance(string: plain)
        utterance.voice = Self.chosenVoice()
        echoSpeechID += 1
        let id = echoSpeechID
        echoSpeechQueued = true
        echoScheduled = 0
        echoPlayed = 0
        echoRendered = false
        echoMarks = []
        echoBase = offsetInSpokenText(plain)
        echoSynth.write(utterance, toBufferCallback: { [weak self] buffer in
            DispatchQueue.main.async { self?.echoBuffer(buffer, id: id) }
        }, toMarkerCallback: { [weak self] markers in
            let offsets = markers.map { $0.textRange.location }
            DispatchQueue.main.async { self?.echoMarks(offsets, id: id) }
        })
    }

    private func echoBuffer(_ buffer: AVAudioBuffer, id: Int) {
        guard id == echoSpeechID, echoSpeechQueued else { return }
        guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {   // the last, empty buffer
            echoRendered = true
            if echoPlayed == echoScheduled { echoSpeechFinished() }
            return
        }
        let index = echoScheduled
        echoScheduled += 1
        let started = echoAudio.play(pcm) { [weak self] in self?.echoPlayedBuffer(index, id: id) }
        guard started else {
            trace("echo-cancelling output didn't start; using the Apple voice as before")
            echoCancellationFailed("voice")
            echoSpeechID += 1
            echoSpeechQueued = false
            echoSynth.stopSpeaking(at: .immediate)
            let utterance = AVSpeechUtterance(string: spokenText)
            utterance.voice = Self.chosenVoice()
            systemSpeechQueued = true
            synth.speak(utterance)
            return
        }
        if index == 0 {
            model.voiceSpeaking(true)
            onSpeechProgress?(.started)
            reachMarks(inBuffer: 0)
        }
    }

    private func echoMarks(_ offsets: [Int], id: Int) {
        guard id == echoSpeechID else { return }
        // A mark falls in the next buffer to come; if that one is already playing, say so now.
        let buffer = echoScheduled
        echoMarks += offsets.map { (buffer, $0) }
        if buffer <= echoPlayed && echoScheduled > 0 { reachMarks(inBuffer: buffer) }
    }

    private func echoPlayedBuffer(_ index: Int, id: Int) {
        guard id == echoSpeechID, echoSpeechQueued else { return }
        echoPlayed += 1
        reachMarks(inBuffer: index + 1)
        if echoRendered && echoPlayed == echoScheduled { echoSpeechFinished() }
    }

    private func reachMarks(inBuffer buffer: Int) {
        let due = echoMarks.filter { $0.buffer <= buffer }
        echoMarks.removeAll { $0.buffer <= buffer }
        let now = ProcessInfo.processInfo.systemUptime
        for mark in due {
            appleProgress.reached(offset: echoBase + mark.offset, at: now)
            onSpeechProgress?(.reached(offset: mark.offset))
            onSpokenWords?(spokenText, [SpokenProgress.Mark(at: now, offset: echoBase + mark.offset)])
        }
    }

    private func echoSpeechFinished() {
        let spoke = echoScheduled > 0
        echoSpeechQueued = false
        echoAudio.stopPlayback()
        if spoke {
            model.voiceSpeaking(false)
            onSpeechProgress?(.ended)
        }
        speechEnded()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            if self.appleStreamActive {
                guard !self.appleStreamStarted else { return }   // the next sentence of the same answer
                self.appleStreamStarted = true
            }
            self.model.voiceSpeaking(true)
            self.onSpeechProgress?(.started)
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange,
                           utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        DispatchQueue.main.async {
            if let base = self.appleBases[id] {
                let now = ProcessInfo.processInfo.systemUptime
                self.appleProgress.reached(offset: base + characterRange.location, at: now)
                self.onSpokenWords?(self.spokenText, [SpokenProgress.Mark(at: now, offset: base + characterRange.location)])
            }
            self.onSpeechProgress?(.reached(offset: characterRange.location))
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            if self.appleStreamActive {
                // A streamed answer ends after its last sentence, not after each one.
                if self.appleStreamOpen || self.synth.isSpeaking { return }
                self.appleStreamFinished()
                return
            }
            self.systemSpeechQueued = self.synth.isSpeaking
            self.model.voiceSpeaking(false)
            self.onSpeechProgress?(.ended)
            self.speechEnded()
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.systemSpeechQueued = self.synth.isSpeaking
            self.model.voiceSpeaking(false)
            self.onSpeechProgress?(.ended)
            self.speechEnded()
        }
    }
}
