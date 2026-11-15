import AppKit
import AVFoundation
import Speech
import BenjiCore

extension VoiceController {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            if self.appleStreamActive {
                guard !self.appleStreamStarted else { return }   // the next sentence of the same answer
                self.appleStreamStarted = true
            }
            self.model.voiceSpeaking(true)
            self.onSpeechProgress?(.started)
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange,
                           utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        DispatchQueue.main.async {
            if let base = self.appleBases[id] {
                let now = ProcessInfo.processInfo.systemUptime
                self.appleProgress.reached(offset: base + characterRange.location, at: now)
                self.onSpokenWords?(self.spokenText, [SpokenProgress.Mark(at: now, offset: base + characterRange.location)])
            }
            self.onSpeechProgress?(.reached(offset: characterRange.location))
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            if self.appleStreamActive {
                // A streamed answer ends after its last sentence, not after each one.
                if self.appleStreamOpen || self.synth.isSpeaking { return }
                self.appleStreamFinished()
                return
            }
            self.systemSpeechQueued = self.synth.isSpeaking
            self.model.voiceSpeaking(false)
            self.onSpeechProgress?(.ended)
            self.speechEnded()
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.systemSpeechQueued = self.synth.isSpeaking
            self.model.voiceSpeaking(false)
            self.onSpeechProgress?(.ended)
            self.speechEnded()
        }
    }
}
