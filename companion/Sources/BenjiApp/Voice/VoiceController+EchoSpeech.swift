import AppKit
import AVFoundation
import Speech
import BenjiCore

extension VoiceController {
    // MARK: the Apple voice through the echo-cancelling engine

    /// Renders the answer into buffers and plays them on the shared engine, so the mic can listen
    /// over it with Benji's voice cancelled. Word marks keep the pointer's speech-paced reveal.
    func speakThroughEcho(_ plain: String) {
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
}
