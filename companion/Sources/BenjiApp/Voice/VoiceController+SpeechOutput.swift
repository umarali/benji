import AppKit
import AVFoundation
import Speech
import BenjiCore

extension VoiceController {
    // MARK: speech output

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

    func appleStreamFinished() {
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
    func offsetInSpokenText(_ plain: String) -> Int {
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
}
