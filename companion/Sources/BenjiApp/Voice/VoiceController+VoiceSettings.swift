import AppKit
import AVFoundation
import Speech
import BenjiCore

extension VoiceController {
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
    var isSpeechActive: Bool {
        (kokoro?.isBusy ?? false) || systemSpeechQueued || echoSpeechQueued || appleStreamActive || streamVoice == .buffered
    }
}
