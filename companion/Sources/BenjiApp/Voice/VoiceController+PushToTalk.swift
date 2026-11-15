import AppKit
import AVFoundation
import Speech
import BenjiCore

extension VoiceController {
    // MARK: push-to-talk

    private static let debug = ProcessInfo.processInfo.environment["BENJI_DEBUG"] == "1"
    /// To stderr with BENJI_DEBUG=1, and always to ~/.benji/voice.log (states, formats, engines,
    /// error codes; never words that were heard).

    func trace(_ s: String) {
        if Self.debug { FileHandle.standardError.write(Data("[ptt] \(s)\n".utf8)) }
        VoiceLogFile.shared.append(s)
    }

    /// Talk key down. Starts listening; if listening was latched by a tap, this
    /// press stops and sends. While Benji is speaking, it just stops the speech.
    /// In a conversation it acts like a tap (`toggle`).
    func pressed() {
        trace("pressed phase=\(model.state.phase) recording=\(recording) latched=\(latched) handsFree=\(handsFree.isOn) awaitingPermission=\(awaitingPermission) mic=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue) speech=\(SFSpeechRecognizer.authorizationStatus().rawValue)")
        if handsFree.isOn { pressedAt = nil; toggle(); return }
        // One press: stop Benji and listen. The press goes on as a hold or a tap.
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
    /// - Benji speaking: stop the speech and listen, in the same press.
    /// - In a conversation: send now if something was heard, otherwise end the conversation.
    /// - Otherwise: start a conversation (or, with `handsFree` off, a tap-to-send turn).
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
    func openMic() {
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
    func finish() {
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
}
