import AppKit
import AVFoundation
import Speech
import BenjiCore

extension VoiceController {
    // MARK: live on-device transcription

    /// Starts streaming recognition for a new utterance. Partial results are shown as you
    /// speak; the audio never leaves the Mac (`requiresOnDeviceRecognition`).
    func startLiveRecognition() throws {
        committedText = ""
        latestLiveText = ""
        restarts = RecognizerRestarts()
        try startRecognitionRequest()
    }

    /// One recognition request. A request can end on its own while the mic is still open (a
    /// final result after a pause, or "no speech" after a quiet while); a new one then carries on
    /// and the text so far is kept, so the rest of what is said isn't lost.
    func startRecognitionRequest() throws {
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
    var liveText: String { TranscriptJoin.join(committedText, latestLiveText) }

    func heard(_ raw: String) {
        let now = ProcessInfo.processInfo.systemUptime
        if listeningOverSpeech {
            // Nothing heard over the answer is shown or counted until it is the user's own words.
            // On speakers without echo cancelling the words must also come with a voice louder than
            // Benji's own in the mic.
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
    func finishLiveRecognition(_ completion: @escaping (String) -> Void) {
        liveCompletion = completion
        guard liveRequest != nil else { return deliverLive("") }   // between requests: use what we have
        liveRequest?.endAudio()
        liveFallbackTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.trace("no final result in time; using partial text")
            self.deliverLive(self.latestLiveText)
        }
    }

    func deliverLive(_ text: String) {
        guard let completion = liveCompletion else { return }
        let finalText = TranscriptJoin.join(committedText, text.isEmpty ? latestLiveText : text)
        endLiveRecognition()
        trace("transcript chars=\(finalText.count)")
        completion(finalText)
    }

    func endLiveRecognition() {
        liveFallbackTimer?.invalidate()
        liveFallbackTimer = nil
        liveCompletion = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        liveRequest = nil
        requestBox.set(nil)
    }

    func transcribeWithEngine(_ url: URL, completion: @escaping (Result<String, Error>) -> Void) {
        let p = Process()
        var env = ProcessInfo.processInfo.environment
        env["BENJI_DIR"] = assistantDir
        env["BENJI_WAV"] = url.path
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
        do { try EngineLaunch.configure(p, entry: .engine, arguments: ["--transcribe", url.path], sourceDirectory: assistantDir, environment: env)
            try p.run() } catch { completion(.failure(error)) }
    }
}
