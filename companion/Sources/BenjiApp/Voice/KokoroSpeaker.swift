import AVFoundation
import BenjiCore

/// Speaks with Kokoro, on-device. The model runs in `benji --tts` (the voice venv's
/// Python, benji/tts.py), which streams 24 kHz PCM back a sentence at a time; this class
/// plays it in the app's own process. Text goes to the child process over a pipe and
/// never leaves the Mac. Any failure before the first sentence plays hands the text back
/// through `fallback`, so the Apple voice can say it instead.
/// Each sentence's audio names its text, so `onProgress` can say when each word will be heard
/// (`SpeechFollow`) and marks on screen appear on their words, as with the Apple voice.
/// The voice and speed are read when an answer starts and kept for all of it, so a new choice in
/// Settings › Voice speaks from the next answer and never switches voices mid-answer.
final class KokoroSpeaker {
    /// When the words of the sentence now playing will be heard.
    var onProgress: (([SpeechMilestone]) -> Void)?

    private let install: KokoroInstall
    private let assistantDir: String
    private let onSpeaking: (Bool) -> Void

    private var process: Process?
    private var input: FileHandle?
    private var ready = false
    private var serial = 0
    private var currentID: String?
    /// The requests that make up the answer now speaking (one, or one per sentence of a streamed
    /// answer) and which of them the service hasn't finished yet.
    private var answerIDs: Set<String> = []
    private var unfinished: Set<String> = []
    /// A streamed answer may still get more sentences: it isn't over when the queue runs dry.
    private var streamOpen = false
    private var currentText = ""
    private var fallback: ((String) -> Void)?
    /// The voice and speed of the answer now speaking, for every sentence of it.
    private var answerVoice = KokoroSettings.defaultVoice
    private var answerSpeed = 1.0
    /// What's playing is a Settings › Voice preview, not an answer: it reports no speaking or
    /// progress, doesn't count as busy, and any answer stops it.
    private var previewing = false
    /// The voices the installed voices file holds, from the service's `ready`; empty until then.
    private(set) var installedVoices: [String] = []
    private var playback = KokoroPlayback()
    private var speaking = false
    private var firstAudioTimer: Timer?
    private var idleTimer: Timer?
    /// Launches that died before becoming ready. After two, Kokoro is off until relaunch.
    private var failedLaunches = 0

    /// Each scheduled sentence's text and playing time, in order; which one is playing; and
    /// where in `currentText` to look for the next one.
    private var sentences: [(text: String, duration: Double)] = []
    private var waitingForSentence = false
    private var followFrom = 0
    /// How loud the answer plays, moment by moment, and when each of its words is heard: for
    /// talking over Benji on speakers and for keeping only what was said when it is cut off.
    private var envelope = PlaybackEnvelope()
    private var progress = SpokenProgress()

    private let audio = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var format: AVAudioFormat?
    /// Set for an answer that plays through the shared echo-cancelling engine (barge-in on
    /// speakers); nil plays through this speaker's own engine.
    var output: SpeechOutput?
    /// The output used by the answer playing now.
    private var playingOn: SpeechOutput?
    /// The echo-cancelling output refused a sentence: this speaker moved to its own output.
    var onEchoOutputFailed: (() -> Void)?

    /// No first sentence this long after asking (model load included): use the Apple voice.
    static let firstAudioTimeout: TimeInterval = 20
    /// The model holds a few hundred MB; let it go when Benji hasn't spoken for a while.
    static let idleShutdown: TimeInterval = 15 * 60

    init(install: KokoroInstall, assistantDir: String, onSpeaking: @escaping (Bool) -> Void) {
        self.install = install
        self.assistantDir = assistantDir
        self.onSpeaking = onSpeaking
        audio.attach(player)
        // The output device changed (headphones, AirPods): the engine has stopped, so the
        // buffers still queued would never report back. End this answer cleanly.
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: audio,
                                               queue: .main) { [weak self] _ in self?.stop() }
    }

    /// The chosen voice (`kokoroVoice`), or the default when the voices file lacks it.
    var voice: String {
        KokoroVoices.resolve(setting: UserDefaults.standard.string(forKey: "kokoroVoice"), installed: installedVoices)
    }
    private var speed: Double { KokoroSettings.speed(UserDefaults.standard.object(forKey: "kokoroSpeed") as? Double) }
    var isUsable: Bool { failedLaunches < 2 }
    /// An answer is queued or playing (a preview isn't one).
    var isBusy: Bool { currentID != nil && !previewing }

    private static let debug = ProcessInfo.processInfo.environment["BENJI_DEBUG"] == "1"
    private func trace(_ s: String) {
        guard Self.debug else { return }
        FileHandle.standardError.write(Data("[kokoro] \(s)\n".utf8))
    }

    /// Start the service early (e.g. when the talk key goes down) so the model is loaded
    /// by the time the answer arrives.
    func prepare() {
        guard isUsable, process == nil else { return }
        launch()
    }

    func speak(_ plain: String, fallback: @escaping (String) -> Void) {
        begin(plain, streaming: false, fallback: fallback)
    }

    /// The first sentence of a streamed answer: it plays as soon as it is ready, and later
    /// sentences (`append`) play after it. The answer ends after `closeStream`.
    func beginStream(_ first: String, fallback: @escaping (String) -> Void) {
        begin(first, streaming: true, fallback: fallback)
    }

    /// The next sentence of the streamed answer now speaking. False if there is none (stopped or
    /// failed), so the caller can say it another way.
    @discardableResult
    func append(_ sentence: String) -> Bool {
        guard streamOpen, currentID != nil, process != nil else { return false }
        serial += 1
        let id = String(serial)
        currentID = id
        answerIDs.insert(id)
        unfinished.insert(id)
        currentText += (currentText.isEmpty ? "" : " ") + sentence
        send(.speak(id: id, text: sentence, voice: answerVoice, speed: answerSpeed))
        trace("append id=\(id) chars=\(sentence.count)")
        return true
    }

    /// No more sentences: the answer ends once what is queued has played.
    func closeStream() {
        guard streamOpen else { return }
        streamOpen = false
        guard currentID != nil else { return }
        if unfinished.isEmpty { synthesisDone() }
    }

    var isStreaming: Bool { streamOpen && currentID != nil }

    /// Settings › Voice's Preview: `text` in `voice` at the chosen speed, on this speaker's own
    /// output. False when an answer is queued or playing (it is never interrupted) or Kokoro can't
    /// run. An answer that starts meanwhile stops the preview.
    @discardableResult
    func preview(_ text: String, voice: String) -> Bool {
        guard isUsable, !isBusy else { return false }
        stop()   // an earlier preview
        if process == nil { launch() }
        guard process != nil else { return false }
        start(text, voice: voice, streaming: false, previewing: true, fallback: nil)
        return true
    }

    /// Ends a preview that is playing (the mic is about to open); an answer is left alone.
    func stopPreview() {
        if previewing { stop() }
    }

    /// The answer's playback level around `time` (meter scale, 0 when nothing plays).
    func playbackLevel(at time: Double) -> Float {
        currentID == nil ? 0 : envelope.level(at: time)
    }

    /// What of the answer had been said aloud by `time` (its words that had started playing).
    func heardText(at time: Double) -> String {
        progress.heard(currentText, at: time)
    }

    private func begin(_ plain: String, streaming: Bool, fallback: @escaping (String) -> Void) {
        guard isUsable else { return fallback(plain) }
        stop()
        if process == nil { launch() }
        guard process != nil else { return fallback(plain) }
        start(plain, voice: voice, streaming: streaming, previewing: false, fallback: fallback)
    }

    private func start(_ plain: String, voice: String, streaming: Bool, previewing: Bool,
                       fallback: ((String) -> Void)?) {
        serial += 1
        let id = String(serial)
        currentID = id
        answerIDs = [id]
        unfinished = [id]
        streamOpen = streaming
        currentText = plain
        self.fallback = fallback
        self.previewing = previewing
        answerVoice = voice
        answerSpeed = speed
        playback = KokoroPlayback()
        sentences = []
        waitingForSentence = false
        followFrom = 0
        envelope.reset()
        progress.reset()
        idleTimer?.invalidate()
        firstAudioTimer?.invalidate()
        firstAudioTimer = Timer.scheduledTimer(withTimeInterval: Self.firstAudioTimeout, repeats: false) { [weak self] _ in
            self?.failCurrent("no audio after \(Int(Self.firstAudioTimeout))s")
        }
        send(.speak(id: id, text: plain, voice: voice, speed: answerSpeed))
        trace("\(previewing ? "preview" : "speak") id=\(id) chars=\(plain.count) voice=\(voice)")
    }

    /// Barge-in and Cancel: silence now and drop whatever the service still has queued.
    func stop() {
        guard currentID != nil else { return }
        trace("stop id=\(currentID ?? "")")
        currentID = nil
        answerIDs = []
        unfinished = []
        streamOpen = false
        fallback = nil
        previewing = false
        firstAudioTimer?.invalidate()
        send(.stop)
        player.stop()   // drops scheduled buffers; their callbacks see a stale id
        audio.stop()
        playingOn?.stopPlayback()
        playingOn = nil
        setSpeaking(false)
        scheduleIdleShutdown()
    }

    func shutdown() {
        stop()
        idleTimer?.invalidate()
        try? input?.close()   // EOF: the service finishes and exits
        process = nil
        input = nil
        ready = false
    }

    // MARK: process

    private func launch() {
        let process = Process()
        let inPipe = Pipe(), outPipe = Pipe()
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        env["BENJI_WORKDIR"] = WorkingFolder.url().path     // the voice lives in Benji's one folder
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice
        let lines = LineReader { [weak self] line in
            let event = KokoroEvent.decode(line)
            DispatchQueue.main.async { self?.handle(event, from: process) }
        }
        outPipe.fileHandleForReading.readabilityHandler = { lines.consume($0.availableData) }
        process.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                outPipe.fileHandleForReading.readabilityHandler = nil
                self?.exited(proc)
            }
        }
        do {
            try EngineLaunch.configure(process, entry: .tts, arguments: [], sourceDirectory: assistantDir, environment: env, optionalPython: install.python)
            try process.run()
            self.process = process
            input = inPipe.fileHandleForWriting
            ready = false
            trace("launched pid \(process.processIdentifier)")
        } catch {
            failedLaunches += 1
            trace("launch failed: \(error.localizedDescription)")
        }
    }

    private func send(_ request: KokoroRequest) {
        try? input?.write(contentsOf: request.line())   // the service reads requests even while loading
    }

    private func exited(_ proc: Process) {
        guard proc === process else { return }
        trace("exited \(proc.terminationStatus) ready=\(ready)")
        if !ready { failedLaunches += 1 }
        process = nil
        input = nil
        ready = false
        failCurrent("the speech service stopped")
    }

    private func scheduleIdleShutdown() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: Self.idleShutdown, repeats: false) { [weak self] _ in
            guard let self, self.currentID == nil else { return }
            self.trace("idle; shutting down")
            self.shutdown()
        }
    }

    // MARK: events

    private func handle(_ event: KokoroEvent, from proc: Process) {
        guard proc === process else { return }
        switch event {
        case .ready(let rate, let voices, let model):
            ready = true
            failedLaunches = 0
            installedVoices = voices
            format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)
            trace("ready model=\(model) voices=\(voices.count)")
        case .audio(let id, _, let text, let pcm):
            guard currentID != nil, answerIDs.contains(id) else { return }
            schedule(pcm, id: id, text: text)
        case .done(let id, _):
            guard currentID != nil, answerIDs.contains(id) else { return }
            unfinished.remove(id)
            if unfinished.isEmpty, !streamOpen { synthesisDone() }
        case .error(let id, let text):
            trace("error id=\(id ?? "-") \(text)")
            if id == nil || id == currentID { failCurrent(text) }
        case .unknown:
            break
        }
    }

    private func schedule(_ pcm: Data, id: String, text: String) {
        let format = format ?? AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
        let samples = KokoroEvent.floats(fromPCM16: pcm)
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { return }
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        if !playback.hasStarted { playingOn = previewing ? nil : output }   // one output for the whole answer
        envelope.add(samples: samples, sampleRate: format.sampleRate, at: ProcessInfo.processInfo.systemUptime)
        let index = sentences.count
        sentences.append((text, Double(samples.count) / format.sampleRate))
        let answer = answerIDs
        let played: () -> Void = { [weak self] in
            guard let self, self.currentID != nil, self.answerIDs.isSuperset(of: answer) else { return }
            // The next sentence starts now, or as soon as it arrives.
            if index + 1 < self.sentences.count { self.sentenceStarted(index + 1) } else { self.waitingForSentence = true }
            if self.playback.didPlay() { self.finish() }
        }
        if let shared = playingOn, !shared.play(buffer, played: played) {
            // The echo-cancelling output didn't start: play on this speaker's own output.
            trace("echo-cancelling output didn't start; playing on Kokoro's own output")
            playingOn = nil
            output = nil
            onEchoOutputFailed?()
        }
        if playingOn == nil {
            if !audio.isRunning {
                audio.disconnectNodeOutput(player)
                audio.connect(player, to: audio.mainMixerNode, format: format)
                do {
                    try audio.start()
                } catch {
                    sentences.removeLast()
                    failCurrent("couldn't start audio output: \(error.localizedDescription)")
                    return
                }
            }
            player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
                DispatchQueue.main.async(execute: played)
            }
            if !player.isPlaying { player.play() }
        }
        if playback.didSchedule() {
            firstAudioTimer?.invalidate()
            setSpeaking(true)
            sentenceStarted(index)
        } else if waitingForSentence {
            sentenceStarted(index)
        }
    }

    /// Every request of the answer is synthesized and no more are coming.
    private func synthesisDone() {
        if !playback.hasStarted {   // nothing speakable in the text
            finish()
        } else if playback.didFinishSynthesis() {
            finish()
        }
    }

    private func sentenceStarted(_ index: Int) {
        waitingForSentence = false
        guard !previewing else { return }
        let s = sentences[index]
        guard let found = SpeechFollow.milestones(sentence: s.text, in: currentText, from: followFrom,
                                                  duration: s.duration) else { return }
        followFrom = found.end
        progress.sentenceStarted(at: ProcessInfo.processInfo.systemUptime, milestones: found.milestones)
        onProgress?(found.milestones)
    }

    private func finish() {
        trace("finished id=\(currentID ?? "")")
        currentID = nil
        answerIDs = []
        unfinished = []
        streamOpen = false
        fallback = nil
        previewing = false
        firstAudioTimer?.invalidate()
        player.stop()
        audio.stop()
        playingOn?.stopPlayback()
        playingOn = nil
        setSpeaking(false)
        scheduleIdleShutdown()
    }

    /// Before any audio: the Apple voice says it instead. Mid-answer: stop where we are.
    private func failCurrent(_ reason: String) {
        guard currentID != nil else { return }
        trace("failed: \(reason)")
        let handBack = playback.hasStarted ? nil : fallback
        let text = currentText
        stop()
        handBack?(text)
    }

    private func setSpeaking(_ value: Bool) {
        guard value != speaking, !(value && previewing) else { return }
        speaking = value
        onSpeaking(value)
    }
}
