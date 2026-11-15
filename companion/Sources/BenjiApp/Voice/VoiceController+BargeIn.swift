import AppKit
import AVFoundation
import Speech
import BenjiCore

extension VoiceController {
    // MARK: barge-in

    var bargeInMode: BargeInMode {
        BargeInMode.from(UserDefaults.standard.object(forKey: BargeInMode.defaultsKey))
    }

    /// Where echo cancellation failed to start, from user defaults (the settings page
    /// clears them when Always is chosen again).
    private var echoVerdicts: EchoVerdicts {
        EchoVerdicts(stored: UserDefaults.standard.object(forKey: EchoVerdicts.defaultsKey))
    }

    /// This audio setup: where the sound goes and which mic listens.
    private var echoKey: String { EchoVerdicts.key(route: outputRoute, input: SystemAudio.defaultInputName()) }

    /// The setting as it acts here: Always is Headphones on speakers whose echo cancelling failed.
    var activeBargeIn: BargeInMode {
        let mode = bargeInMode
        guard mode == .always else { return mode }
        return mode.effective(route: outputRoute,
                              echoUnavailable: echoVerdicts.isKnownBad(echoKey, now: Date().timeIntervalSince1970))
    }

    /// How the mic may listen while Benji speaks here: on speakers whose echo cancelling
    /// failed, Always still listens, on the plain mic, guarded.
    var talkOverPath: TalkOverPath {
        TalkOverPath.choose(mode: bargeInMode, route: outputRoute,
                            echoUnavailable: echoVerdicts.isKnownBad(echoKey, now: Date().timeIntervalSince1970))
    }

    /// Echo cancellation didn't start (`what`: "mic" or "voice"). Remember it for this setup, so the
    /// next turns use the plain mic and Benji's own voice output without trying again; free the
    /// echo engine (unless Benji's voice is still playing on it); say so once.
    func echoCancellationFailed(_ what: String) {
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
    var outputRoute: OutputRoute {
        let now = ProcessInfo.processInfo.systemUptime
        if let checked = routeChecked, now - checked.at < 0.5 { return checked.route }
        let route = SystemAudio.bargeInRoute()
        routeChecked = (route, now)
        return route
    }

    /// Benji's voice has to go through the echo-cancelling engine so the mic can listen over it.
    var echoNeeded: Bool {
        handsFree.isOn && handsFreeAvailable && activeBargeIn.needsEchoCancellation(outputRoute)
    }

    /// Words over the answer that aren't Benji's own: stop speaking, keep listening, and keep
    /// what the user said as the start of their next message. The conversation keeps what Benji
    /// had said by `startedAt`, when the user began talking.
    func interrupt(keeping words: String, startedAt: Double) {
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
    func cutOffSpeech(at time: Double) {
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
    func speechEnded() {
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
    func settled(_ text: String) -> String {
        guard let settle else { return text }
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return text }
        let first = settleFirstWordAt ?? ProcessInfo.processInfo.systemUptime
        settleFirstWordAt = first
        return SettleWindow.strip(words, spoken: settle.spoken, firstWordAt: first, speechEndedAt: settle.endedAt)
    }

    /// One mic buffer while the mic is open over Benji's answer.
    func overSpeechLevel(_ level: Float, duration: Double, at time: Double) {
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

    /// New conversation while the mic is open or finalising: the words heard so far are
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
    func echoConfigurationChanged() {
        trace("echo-cancelling engine: output changed")
        routeChecked = nil
        if echoSpeechQueued || kokoro?.isBusy == true { stopSpeaking() }
        if recordingOnEcho {
            discardRecording()
            handsFree.micClosed(at: ProcessInfo.processInfo.systemUptime)
        }
    }

    func handsFreeTick() {
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
        // Off by default (Settings' "Hold back words heard over other apps' sound"): Core Audio
        // isn't even asked, and the conversation sends what it heard.
        guard OtherAppAudioGuard.isOn(from: UserDefaults.standard.object(forKey: OtherAppAudioGuard.defaultsKey)) else {
            handsFree.otherAppAudio(false)
            return
        }
        let audible = OtherAppAudio.audible(playing: SystemAudio.otherAppPlaying(), route: SystemAudio.outputRoute())
        if audible, !handsFree.otherAudioDuringUtterance { trace("another app is playing out loud") }
        handsFree.otherAppAudio(audible)
    }

    /// The user paused: close the mic, take the final words, and let the session decide.
    func finishUtterance() {
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
    func discardRecording() {
        endpointer = nil
        settle = nil
        if recording { stopRecording() }
        if let url = recordingURL { try? FileManager.default.removeItem(at: url) }
        recordingURL = nil
        endLiveRecognition()
        model.voiceCancelled()
    }

    func apply(_ actions: [HandsFreeAction]) {
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
}
