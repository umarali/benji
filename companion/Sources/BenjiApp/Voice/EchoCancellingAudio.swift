import AVFoundation

/// Where a voice plays its audio when it doesn't use its own output.
protocol SpeechOutput: AnyObject {
    /// Plays `buffer` after whatever is queued; `played` runs on the main queue once it has been
    /// heard. False: the output couldn't start.
    func play(_ buffer: AVAudioPCMBuffer, played: @escaping () -> Void) -> Bool
    /// Silence now and drop what is queued.
    func stopPlayback()
}

/// One audio engine for Benji's voice and the mic, with the Mac's voice processing on, so what
/// Benji says is cancelled from what the mic hears: barge-in on speakers (Settings › Voice ›
/// Talk over Benji to interrupt › Always). Used only in that mode; otherwise each voice keeps its
/// own output and the mic its own engine.
/// While this engine runs the mic is in use (voice processing is one unit for both directions),
/// which in this mode is the point: Benji listens while it speaks.
final class EchoCancellingAudio: SpeechOutput {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    /// Keeps the mic in the graph without sending it anywhere audible.
    private let sink = AVAudioMixerNode()
    private var playerFormat: AVAudioFormat?
    private var processing = false
    private var micOn = false
    /// The output device changed: the engine stopped. The voice and the mic must start again.
    var onConfigurationChange: (() -> Void)?

    init() {
        engine.attach(player)
        engine.attach(sink)
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                               queue: .main) { [weak self] _ in
            self?.micOn = false
            self?.onConfigurationChange?()
        }
    }

    private func start() throws {
        if !processing {
            if engine.isRunning { engine.stop() }
            try engine.inputNode.setVoiceProcessingEnabled(true)
            if #available(macOS 14.0, *) {
                // Don't turn other apps down while Benji listens.
                engine.inputNode.voiceProcessingOtherAudioDuckingConfiguration =
                    .init(enableAdvancedDucking: false, duckingLevel: .min)
            }
            sink.outputVolume = 0
            // Read the input only after voice processing is on (it changes the input's format, e.g.
            // a 3-channel built-in mic), and let the engine pick the connection format.
            engine.connect(engine.inputNode, to: sink, format: nil)
            engine.connect(sink, to: engine.mainMixerNode, format: nil)
            processing = true
        }
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
    }

    func play(_ buffer: AVAudioPCMBuffer, played: @escaping () -> Void) -> Bool {
        do {
            if playerFormat != buffer.format {
                player.stop()
                engine.disconnectNodeOutput(player)
                engine.connect(player, to: engine.mainMixerNode, format: buffer.format)
                playerFormat = buffer.format
            }
            try start()
        } catch {
            return false
        }
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
            DispatchQueue.main.async(execute: played)
        }
        if !player.isPlaying { player.play() }
        return true
    }

    /// Benji's voice is playing on this engine.
    var isPlaying: Bool { player.isPlaying }

    func stopPlayback() {
        player.stop()
        stopIfIdle()
    }

    /// Opens the mic on this engine; `tap` gets every buffer, on the audio thread.
    func startMic(_ tap: @escaping (AVAudioPCMBuffer) -> Void) throws -> AVAudioFormat {
        try start()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw VoiceError("No microphone input is available.") }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in tap(buffer) }
        micOn = true
        return format
    }

    func stopMic() {
        engine.inputNode.removeTap(onBus: 0)
        micOn = false
        stopIfIdle()
    }

    /// After a failed start: stop everything, turn voice processing back off and forget the
    /// graph, so this engine holds nothing of the mic or the output while the plain paths run.
    func reset() {
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        if engine.isRunning { engine.stop() }
        if processing {
            engine.disconnectNodeOutput(engine.inputNode)
            engine.disconnectNodeOutput(sink)
            try? engine.inputNode.setVoiceProcessingEnabled(false)
            processing = false
        }
        engine.disconnectNodeOutput(player)
        playerFormat = nil
        micOn = false
        engine.reset()
    }

    private func stopIfIdle() {
        if !micOn && !player.isPlaying && engine.isRunning { engine.stop() }
    }
}
