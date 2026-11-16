import AppKit
import Combine
import BenjiCore

extension CompanionModel {
    // MARK: user actions

    func submit() {
        guard !phoneTaskRunning else { return }
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, canSendTyped else { return }
        if state.phase == .listening { onTypedWhileListening?() }
        guard !state.isBusy else { return }
        composerText = ""
        statusNote = nil; noteOutlastsListening = false
        producedOutput = false
        voiceTurn = false
        turnSerial += 1
        setExpanded(true)
        onHidePointer?()
        apply(.submitText(text))
        send(task: text, restoreText: text, spoken: false)
    }

    /// A follow-up chip under an explanation card: its words are sent as a typed message.
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
        guard !phoneTaskRunning, canRetry, let turn = state.retryableTurn,
              let text = state.lines.first(where: { $0.id == turn.userLineID })?.text else { return }
        if state.phase == .listening { onTypedWhileListening?() }
        guard !state.isBusy else { return }
        statusNote = nil; noteOutlastsListening = false
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
        if driveGoal != nil { backend.stopDrive(reason: "user_stop") }   // the Stop button ends a drive at once
        turnSerial += 1   // drops a capture that is still in flight
        captureTarget = nil
        if !phoneTaskRunning { includeOnce = nil }   // the Mac's one-message choice was not the phone's to use
        let wasRunning = runs.isLive
        runs.end()
        if wasRunning { backend.cancel() }
        cancelScreenStep?()
        screenGate.clear()
        screenCard = nil
        endScreenTurn()
        discardSentImage()
        currentShot = nil
        producedOutput = false
        onHidePointer?()
        speechStreamOpen = false   // onCancel stops the voice, streamed or not
        speechForRun = false
        clearStream()
        onCancel?()
        voiceTurn = false
        apply(.cancel)
        phoneTaskStopped()
    }

    /// Forget the recent exchanges and clear the panel (not while a turn is running).
    func newConversation() {
        guard !phoneTaskRunning, NewConversationRule.allows(phase: state.phase) else { return }
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
    func run(task: String, shot: CapturedScreen? = nil) {
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
        latencyWaitsForAudio = false
        awaitsAudio = false
        speechForRun = false
        spokenAnswer = nil
        clearStream()
        endSpeechStream(nil)
        silentAnswer = nil
        let wouldSpeak = !phoneTaskRunning && ReadAloud.speaks(setting: readAloud, spoken: voiceTurn)
        let mayStream = SilentSpeech.shouldSpeak(wouldSpeak: wouldSpeak, state: outputState?())   // a muted Mac: nothing starts speaking
        // An answer about the screen speaks early too; its marks catch up when they arrive.
        // On a muted Mac neither kind starts.
        speaksWhileStreaming = mayStream
        onTurnStarts?(mayStream)
        if phoneTaskRunning {
            backend.startRemote(run: runs.begin(), task: task, memory: memory)
        } else {
            backend.start(run: runs.begin(), task: task, imagePath: shot?.url.path, memory: memory, allowPointing: shot != nil,
                          spoken: voiceTurn, screen: shot?.geometry)
        }
        step("sent to the engine")
    }

    /// Ends the backend process, if it keeps one (on quit).
    func shutdown() { backend.shutdown() }

    func setScreenMode(_ mode: ScreenMode) {
        includeOnce = nil
        screenMode.choose(mode)
    }
}
