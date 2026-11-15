import AppKit
import Combine
import BenjiCore

extension CompanionModel {
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

    /// A one-line note on the status line, e.g. after a setting changes.
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

    /// The "Listen while Benji is open" value, from the controller.
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
    /// said aloud, marked as cut off (`CutOffReply`), here and in the engine. An answer
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
        // A drive begins only on a Yes pressed on its own card: remember that it was.
        if let id = driveCardID, id == state.pendingApproval?.id {
            driveGranted = approved && !timedOut
            driveCardID = nil
        }
        backend.resolveApproval(approved && !timedOut)
        apply(timedOut ? .approvalTimedOut : .approvalResolved(approved))
    }

    /// Timeout → No. Common modes, so it fires during tracking loops too.
    func startApprovalTimer(for req: ApprovalRequest, timeout: TimeInterval? = nil) {
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
}
