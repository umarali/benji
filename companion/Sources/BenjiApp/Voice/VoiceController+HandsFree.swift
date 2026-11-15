import AppKit
import AVFoundation
import Speech
import BenjiCore

extension VoiceController {
    // MARK: hands-free conversation

    /// Starts a conversation, or ends the one running.
    func toggleHandsFree() {
        if handsFree.isOn { endHandsFree(.user) } else { startHandsFree() }
    }

    var listenWhileOpen: Bool { openListening.enabled }
    var keepListeningWhenClosed: Bool { openListening.keepsListeningWhenClosed }
    var endsConversationOnMenuClose: Bool {
        openListening.endsConversationOnMenuClose(conversationOn: handsFree.isOn)
    }

    /// Settings › Voice › "Keep listening when the panel closes".
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

    /// Settings › Voice › "Listen while Benji is open".
    func setListenWhileOpen(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: OpenListening.defaultsKey)
        follow(openListening.setEnabled(on, conversationOn: handsFree.isOn, canListen: canListenWithoutAsking))
    }

    /// Settings › Voice › "Stop listening after quiet"; applies to a running conversation too.
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
    /// current answer. `byUser`: the talk key or the mic glyph, not the panel opening.
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
    func adoptMicForConversation() {
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

    var snapshot: HandsFreeSnapshot {
        HandsFreeSnapshot(phase: model.state.phase,
                          approvalPending: model.state.pendingApproval != nil,
                          screenCardPending: model.pendingScreenSend != nil,
                          speechPending: isSpeechActive,
                          bargeIn: handsFree.isOn && handsFreeAvailable && talkOverPath.listensOverSpeech)
    }
}
