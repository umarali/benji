import AppKit
import AVFoundation
import Speech
import BenjiCore

struct VoiceError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// The tap from the audio thread reads the current recognition request through this, so a new
/// request can take over mid-utterance without reinstalling the tap.
final class RequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    func set(_ r: SFSpeechAudioBufferRecognitionRequest?) { lock.lock(); request = r; lock.unlock() }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); let r = request; lock.unlock()
        r?.append(buffer)
    }
}

/// Voice transport: push-to-talk and hands-free conversation. Records the mic,
/// transcribes on-device by default, hands the text to the normal engine pipeline, and speaks
/// answers to voice turns. In a conversation (`HandsFreeSession`) it sends when the user
/// pauses and opens the mic again after each answer. Every state it reports comes from a real
/// event: engine started, recognition running, synthesizer callbacks.
final class VoiceController: NSObject, AVSpeechSynthesizerDelegate {
    let model: CompanionModel
    let assistantDir: String
    let transcriber: TranscriberKind

    /// The plain mic engine (push-to-talk, and conversations that need no echo cancelling).
    /// Replaced by a fresh one when it fails to start, so the next start reads the device anew.
    var engine = AVAudioEngine()
    var file: AVAudioFile?
    var recordingURL: URL?
    // Debug-only input level stats, written on the audio thread.
    let levelLock = NSLock()
    var levelFrames = 0
    var levelPeak: Float = 0
    var pressedAt: Date?
    var recording = false
    var awaitingPermission = false
    /// Listening was started by a tap and stays on until the next tap (or the time limit).
    var latched = false
    var maxRecordingTimer: Timer?
    var recognitionTask: SFSpeechRecognitionTask?
    // Live on-device recognition: audio is streamed to the recognizer while the user speaks.
    var liveRequest: SFSpeechAudioBufferRecognitionRequest?
    let requestBox = RequestBox()
    /// Text from earlier requests in this utterance (a request can end on its own mid-way).
    var committedText = ""
    var latestLiveText = ""
    var requestStartedAt: TimeInterval = 0
    var restarts = RecognizerRestarts()
    var liveCompletion: ((String) -> Void)?
    var liveFallbackTimer: Timer?
    let synth = AVSpeechSynthesizer()
    /// On-device Kokoro voice when it's installed and chosen (`ttsEngine`); nil = Apple voice.
    var kokoro: KokoroSpeaker?
    let kokoroInstalled: Bool
    /// Where the spoken answer has got to, for the pointer overlay's speech-paced reveal.
    var onSpeechProgress: ((SpeechProgress) -> Void)?
    /// When the answer's words are heard, as offsets in all the voice was given for it
    /// (`spokenText`, UTF-16) with that text: the explanation card's clock.
    var onSpokenWords: ((_ spoken: String, _ marks: [SpokenProgress.Mark]) -> Void)?
    /// An Apple-voice utterance is queued or playing (Kokoro keeps its own `isBusy`).
    var systemSpeechQueued = false

    // Barge-in: talking over Benji to interrupt it (Settings › Voice).
    /// One engine for the voice and the mic with echo cancellation, for barge-in on speakers.
    /// Made on first use, which happens only in that mode.
    lazy var echoAudio: EchoCancellingAudio = {
        let audio = EchoCancellingAudio()
        audio.onConfigurationChange = { [weak self] in self?.echoConfigurationChanged() }
        return audio
    }()
    /// The mic is open over Benji's answer and the user hasn't been heard yet.
    var listeningOverSpeech = false
    /// This recording is on the echo-cancelling engine.
    var recordingOnEcho = false
    /// What Benji is saying, so its own words coming back through the mic aren't the user's.
    var spokenText = ""
    var routeChecked: (route: OutputRoute, at: TimeInterval)?
    /// The Apple voice rendered into buffers and played through the echo-cancelling engine.
    let echoSynth = AVSpeechSynthesizer()
    var echoSpeechQueued = false
    var echoSpeechID = 0
    var echoScheduled = 0
    var echoPlayed = 0
    var echoRendered = false
    /// Word marks of the echo-path answer: which buffer they fall in, and where in the text.
    var echoMarks: [(buffer: Int, offset: Int)] = []
    /// Where the echo-path answer starts in `spokenText`.
    var echoBase = 0

    // Talking over Benji on speakers without echo cancelling, and cut-offs.
    /// Whether the mic hears someone other than Benji while it speaks (fed while listening over speech).
    var speechGate = SpeechGate()
    /// Benji stopped while the guarded mic was open over it: its last words may still be heard.
    var settle: (endedAt: Double, spoken: String)?
    var settleFirstWordAt: Double?
    /// When the Apple voice reached each word, and where each of its utterances starts in
    /// `spokenText` (a streamed answer is one utterance per sentence).
    var appleProgress = SpokenProgress()
    var appleBases: [ObjectIdentifier: Int] = [:]

    // Hands-free conversation.
    var handsFreeSettings: HandsFreeSettings
    var handsFree: HandsFreeSession
    /// Opening the panel starts a conversation; closing it ends one ("Listen while Benji is open").
    var openListening: OpenListening
    /// Decides the end of the current utterance; non-nil while a conversation is recording.
    var endpointer: UtteranceEndpointer?
    var handsFreeTimer: Timer?
    /// When another app's sound was last checked (a few times a second while the mic is open).
    var otherAudioCheckedAt: TimeInterval = 0
    /// The conversation started or ended (for the lock/sleep/Escape watcher).
    var onHandsFreeChange: ((Bool) -> Void)?
    var isHandsFreeOn: Bool { handsFree.isOn }
    /// A conversation needs live on-device recognition to hear the pauses, and never sends
    /// audio anywhere; with the cloud transcriber the talk key keeps its one-message behaviour.
    var handsFreeAvailable: Bool { transcriber == .onDevice }
    var tapStartsConversation: Bool { handsFreeSettings.startsOnTap && handsFreeAvailable }

    static let micDenied = "Microphone access is off for Benji. Turn it on in System Settings › Privacy & Security › Microphone, then try again."
    static let speechDenied = "Speech Recognition is off for Benji. Turn it on in System Settings › Privacy & Security › Speech Recognition (or set pttTranscriber to \"engine\" to use a cloud key)."

    init(model: CompanionModel, assistantDir: String, transcriber: TranscriberKind) {
        self.model = model
        self.assistantDir = assistantDir
        self.transcriber = transcriber
        let defaults = UserDefaults.standard
        handsFreeSettings = HandsFreeSettings.from(handsFree: defaults.object(forKey: "handsFree"),
                                                   endSilence: defaults.object(forKey: "handsFreeEndSilence"),
                                                   idleTimeout: defaults.object(forKey: "handsFreeIdleTimeout"))
        handsFree = HandsFreeSession(settings: handsFreeSettings)
        openListening = OpenListening(
            enabled: OpenListening.enabled(from: defaults.object(forKey: OpenListening.defaultsKey)),
            keepsListeningWhenClosed: OpenListening.enabled(from: defaults.object(forKey: OpenListening.keepWhenClosedKey)))
        let install = KokoroInstall(dataDir: KokoroInstall.dataDir(environment: ProcessInfo.processInfo.environment))
        kokoroInstalled = install.isInstalled { FileManager.default.fileExists(atPath: $0) }
        super.init()
        synth.delegate = self
        let engine = SpeechEngine.resolve(setting: UserDefaults.standard.string(forKey: "ttsEngine"),
                                          kokoroInstalled: kokoroInstalled)
        if engine == .kokoro {
            kokoro = KokoroSpeaker(install: install, assistantDir: assistantDir) { [weak self, weak model] speaking in
                model?.voiceSpeaking(speaking)
                self?.onSpeechProgress?(speaking ? .started : .ended)
                if !speaking { self?.speechEnded() }
            }
            kokoro?.onProgress = { [weak self] words in
                guard let self else { return }
                self.onSpeechProgress?(.willReach(words))
                let now = ProcessInfo.processInfo.systemUptime
                self.onSpokenWords?(self.spokenText, words.map { SpokenProgress.Mark(at: now + $0.delay, offset: $0.offset) })
            }
            // Kokoro couldn't play through the echo-cancelling engine: it carries on on its own
            // output (never the Apple voice), and Always stops trying echo cancelling here.
            kokoro?.onEchoOutputFailed = { [weak self] in self?.echoCancellationFailed("voice") }
        }
    }

    var transcriberDescription: String {
        transcriber == .onDevice ? "on-device (audio stays on this Mac)" : "`benji --transcribe` (cloud key)"
    }

    /// The words of the utterance being decided, so a held-back one can be kept in the box.
    var heardWords = ""

    /// The status-line notice was shown this run.
    var echoNoticeShown = false

    /// How the streamed answer now speaking is being said: nil when none is.
    enum StreamVoice { case kokoro, apple, buffered }
    var streamVoice: StreamVoice?
    /// Sentences of a streamed answer kept to be said in one go (the echo-cancelling Apple voice,
    /// whose word marks follow one utterance).
    var streamBuffer: [String] = []
    /// The Apple voice is saying a streamed answer whose last sentence may still be to come.
    var appleStreamOpen = false
    /// The Apple voice is on a streamed answer (from its first sentence until its last one ends),
    /// and has started playing it.
    var appleStreamActive = false
    var appleStreamStarted = false
}
