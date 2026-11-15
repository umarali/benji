import AppKit
import AVFoundation
import Speech
import BenjiCore

extension VoiceController {
    // MARK: permissions

    func ensurePermissions(_ done: @escaping (Bool, String) -> Void) {
        // The one-line ask at the moment of need: says once per launch what is off, with a button.
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
    func startRecording() -> Bool {
        guard !recording else { return true }
        kokoro?.stopPreview()   // a Settings › Voice preview must not be heard as the user
        // Over Benji's answer (barge-in) the mic hears it too. On speakers in "Always" mode the
        // voice plays through the echo-cancelling engine, and every utterance of the conversation
        // opens on that same engine (`MicEngine`): two engines taking turns on one mic don't work.
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

    func stopRecording() {
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
}
