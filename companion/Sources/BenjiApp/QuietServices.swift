import AppKit
import AVFoundation
import ServiceManagement
import BenjiCore

/// `SMAppService.mainApp` behind `LoginItemService` (D-173). Reading `status` is a plain read; only the
/// Settings switch calls `register` and `unregister`. Nothing registers at launch.
final class SMLoginItem: LoginItemService {
    var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .needsApproval
        case .notRegistered: return .disabled
        case .notFound: return .unavailable
        @unknown default: return .unavailable
        }
    }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
}

/// Plays Benji's own cues (Resources/Cues, made by tools/make_cues.py). One quiet `AVAudioPlayer` at
/// a time: a newer cue replaces the one still sounding. Built lazily, so with cues off nothing is loaded.
final class CuePlayer {
    private var bags: [CueID: ShuffleBag] = [:]
    private var player: AVAudioPlayer?

    func play(_ id: CueID, volume: Double) {
        var bag = bags[id] ?? ShuffleBag(count: CueCatalog.variants[id] ?? 1)
        let variant = bag.next()
        bags[id] = bag
        let name = CueCatalog.fileName(id, variant: variant)
        guard let url = Bundle.main.url(forResource: (name as NSString).deletingPathExtension, withExtension: "wav",
                                        subdirectory: CueCatalog.folderName),
              let next = try? AVAudioPlayer(contentsOf: url) else { return }
        player?.stop()
        next.volume = CueSettings.gain(volume: volume)
        next.prepareToPlay()
        next.play()
        player = next
    }
}

/// The app's side of D-173 that is not a view: the Keychain, the login item, the cues and the quiet check,
/// built once. Everything here waits for the user or for an event; nothing runs at launch except
/// `grantChangeLine`, which only reads.
final class QuietServices {
    static let shared = QuietServices()

    let keyStore: KeyStore = LegacyAwareKeyStore(primary: KeychainKeyStore(),
                                                 legacy: KeyNames.legacyServices.map { KeychainKeyStore(service: $0) })
    let loginItem: LoginItemService = SMLoginItem()
    private let cues = CuePlayer()
    /// Benji is speaking just now (set by the app); a cue never plays over it.
    var benjiSpeaking: () -> Bool = { false }

    private var defaults: UserDefaults { .standard }
    static let keyFiles: [URL] = [".benji.env", ".chilly.env", ".pal.env"].map {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent($0)
    }

    // MARK: cues and the quiet check

    /// A job changed state: play its cue if the switch is on, Benji isn't speaking and the user isn't on a call.
    func jobCue(_ cue: JobCue) {
        let on = CueSettings.isOn(defaults.object(forKey: CueSettings.defaultsKey))
        if case let .play(id) = CuePlan.plan(cue, switchOn: on, benjiSpeaking: benjiSpeaking(), signals: QuietSignalsReader.read) {
            cues.play(id, volume: CueSettings.volume(defaults.object(forKey: CueSettings.volumeKey)))
        }
    }

    /// Why Benji should hold an unasked notch event now, or nil. Reads the signals only when asked.
    func quietReason() -> QuietReason? { QuietCheck.reason(QuietSignalsReader.read()) }

    // MARK: keys

    /// Preserve the single selected key source. File mode never reads the Keychain.
    func keyEnvironment() -> Result<[String: String], KeyHandoff.Failure> {
        ModelSetupPreferences.keyEnvironment(defaults, store: keyStore)
    }

    func keyStatus() -> KeyStorageStatus {
        KeyStorageStatus.current(defaults: defaults, store: keyStore, files: Self.keyFiles)
    }

    /// The Settings button, using the same migration as setup Save.
    func moveKeysToKeychain() -> KeyMigration.Outcome {
        KeyMigration.migrate(files: Self.keyFiles, store: keyStore, defaults: defaults)
    }

    // MARK: permissions

    /// At launch: the grants macOS took away since last time, as one line, and remember today's. Reads only.
    func grantChangeLine() -> String? {
        let now = Dictionary(uniqueKeysWithValues: CompanionPermission.allCases.map { ($0, Permissions.isGranted($0)) })
        let previous = defaults.dictionary(forKey: GrantChanges.defaultsKey) as? [String: Bool]
        defaults.set(GrantChanges.encode(now), forKey: GrantChanges.defaultsKey)
        return GrantChanges.launchLine(lost: GrantChanges.lost(previous: previous, now: now))
    }
}
