import Foundation

/// Benji's settings page, inside the open notch panel: the status-bar menu keeps only a few
/// commands, and every switch and choice lives here, one section at a time.
public enum SettingsSection: String, CaseIterable, Identifiable, Sendable {
    case general, voice, screen, browser, shortcuts, permissions

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .general: return "General"
        case .voice: return "Voice"
        case .screen: return "Screen"
        case .browser: return "Browser"
        case .shortcuts: return "Shortcuts"
        case .permissions: return "Permissions"
        }
    }

    /// The line under the section's title.
    public var subtitle: String {
        switch self {
        case .general: return "How Benji answers and draws."
        case .voice: return "How Benji listens and speaks."
        case .screen: return "When Benji may look at your screen."
        case .browser: return "Let background jobs read pages in your Chrome."
        case .shortcuts: return "Ways to call Benji."
        case .permissions: return "What macOS lets Benji use."
        }
    }

    /// The SF Symbol beside the title in the sidebar.
    public var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .voice: return "waveform"
        case .screen: return "rectangle.dashed"
        case .browser: return "globe"
        case .shortcuts: return "keyboard"
        case .permissions: return "lock.shield"
        }
    }
}

/// What the settings page shows, read from the app each time it opens or something changes.
public struct SettingsSnapshot: Equatable, Sendable {
    public struct PermissionRow: Equatable, Sendable, Identifiable {
        public let permission: CompanionPermission
        public let granted: Bool
        public var id: String { permission.rawValue }

        public init(permission: CompanionPermission, granted: Bool) {
            self.permission = permission
            self.granted = granted
        }
    }

    // General
    public var figures = false
    public var model: ModelChoice = .haiku
    /// The engine talks to Anthropic, so the choice can apply.
    public var modelApplies = true
    /// What the engine says it uses ("claude-haiku-5-5"); empty until it has said.
    public var modelInUse = ""
    /// Who receives what Benji sends, with the host: "DeepSeek (api.deepseek.com)"; empty until the
    /// engine has said.
    public var modelDestination = ""
    /// The model's name when it can't read images: Benji keeps Screen off for this session and
    /// says so. Nil when it can, or when the engine hasn't said.
    public var screenUnavailable: String?
    public var drawingsInScreenshots = false
    /// "Show Benji beside the pointer".
    public var pointerCompanion = true
    public var readAloud = false
    // Voice
    public var handsFreeAvailable = true
    public var listenWhileOpen = false
    /// A conversation goes on in the notch when the panel closes.
    public var keepListeningWhenClosed = false
    public var holdBack = false
    public var bargeIn: BargeInMode = .headphones
    /// Always was chosen but the Mac's echo cancelling failed on these speakers.
    public var echoUnavailable = false

    /// The line under "Talk over Benji to interrupt".
    public var bargeInCaption: String {
        bargeIn == .always && echoUnavailable ? BargeInMode.echoUnavailableCaption : bargeIn.caption
    }
    public var idleTimeout: TimeInterval = 120
    public var idleTimeoutChoices: [TimeInterval] = []
    public var transcription = ""
    public var voice = ""
    /// Whether the Kokoro voice picker shows, and why not when it doesn't.
    public var voiceStatus: VoicePickerStatus = .notInstalled
    /// The Kokoro voices to choose from (`KokoroVoices.choices`), the chosen one's id, and the speed.
    public var voiceChoices: [KokoroVoice] = []
    public var voiceChosen = KokoroSettings.defaultVoice
    public var voiceSpeed = 1.0
    /// Why the last Preview didn't play; nil when it did.
    public var voiceNote: String?
    // Screen
    public var screenMode: ScreenMode = .off
    /// What each choice means, as the panel's Screen control says it (it names the provider).
    public var screenCaptions: [ScreenMode: String] = [:]
    /// "Act on simple steps" (true, the default) or "Ask before every step".
    public var screenSimpleSteps = true
    // Diagnostics: how the last "Copy diagnostics" went
    public var diagnostics: DiagnosticsCopy.Status = .idle
    // Repeating jobs: the one switch for every schedule. On, because nothing repeats until a
    // schedule has been approved on a card; off stops them all.
    public var schedulesOn = true
    // Browser: off until the user turns it on
    public var browserOn = false
    public var browserStatus: BrowserStatus = .off
    /// Why the last attempt to turn it on failed; nil when it didn't.
    public var browserError: String?
    /// The browsers installed on this Mac, each with whether the user has turned Benji's connection on
    /// for it.
    public var browsers: [BrowserRow] = []
    /// Sites the user set to always allow reading (reading only).
    public var browserAlways: [String] = []
    // Starting up, the key and quiet cues. Off or unknown until the app says.
    public var openAtLogin = false
    public var openAtLoginCaption = OpenAtLogin.caption(.disabled)
    public var keyStorage: KeyStorageStatus = .none
    /// How the last "Move to the Keychain" went; nil before it is pressed.
    public var keyMoveNote: String?
    public var cuesOn = false
    // App offers. Off until switched on.
    public var appOffersOn = false
    /// Apps turned down with No, by name.
    public var appOffersDeclined: [String] = []
    // Shortcuts
    public var talkKey: String?
    // Permissions
    public var permissions: [PermissionRow] = []
    /// "Benji 0.4 (12)" under the sidebar; empty when unknown.
    public var version = ""
    // Memory
    public var saveConversations = true
    public var savedConversations = 0
    public var facts: [ProfileFact] = []

    public init() {}

    public var setupComplete: Bool { permissions.allSatisfy(\.granted) }

    /// "2 Minutes", "1 Minute": how a quiet-spell choice is named.
    public static func minutes(_ seconds: TimeInterval) -> String {
        let m = Int(seconds / 60)
        return m == 1 ? "1 Minute" : "\(m) Minutes"
    }
}

/// One installed browser in Settings › Browser.
public struct BrowserRow: Equatable, Sendable, Identifiable {
    public let browser: ChromiumBrowser
    public var registered: Bool
    public var id: String { browser.id }
    public init(browser: ChromiumBrowser, registered: Bool) {
        self.browser = browser
        self.registered = registered
    }
}

/// One thing the user changed or asked for on the settings page, for the app to apply.
public enum SettingsChange: Equatable, Sendable {
    case figures(Bool)
    case model(ModelChoice)
    case drawingsInScreenshots(Bool)
    case pointerCompanion(Bool)
    case readAloud(Bool)
    case listenWhileOpen(Bool)
    case holdBack(Bool)
    case bargeIn(BargeInMode)
    case idleTimeout(TimeInterval)
    case screenMode(ScreenMode)
    /// Act on simple steps without a card (true) or ask before every step.
    case screenSimpleSteps(Bool)
    /// Let background jobs read pages in Chrome: writes or removes the native-messaging files.
    case browser(Bool)
    /// Turn Benji's connection on or off for one browser (its id, `ChromiumBrowser.id`): writes or
    /// removes that browser's manifest, and only that.
    case browserUse(String, Bool)
    /// Add a site (as typed) to, or remove an origin from, the "always allow reading" list.
    case browserAlwaysAdd(String)
    case browserAlwaysRemove(String)
    /// The one switch for every repeating job: off stops a repeat run in flight and runs none.
    case schedules(Bool)
    /// Show the unpacked extension in Finder, to load it in Chrome.
    case showBrowserExtension
    /// Put `benji --diagnose` on the clipboard.
    case copyDiagnostics
    /// Open Benji's folder, ~/.benji, in Finder.
    case showBenjiFolder
    /// Open Benji when the user logs in. Off until switched on; registers only from this switch.
    case openAtLogin(Bool)
    /// Move the API key out of ~/.benji.env into the Keychain. Only this button does it.
    case moveKeysToKeychain
    /// Benji's own quiet cues for a job's outcome. Off by default.
    case cues(Bool)
    /// Offer a skill on the notch for the app in front. Off by default.
    case appOffers(Bool)
    /// Forget No and Not now answers, so those apps may be offered again.
    case resetAppOffers
    case downloadVoices
    /// A Kokoro voice id; it speaks from Benji's next answer.
    case kokoroVoice(String)
    case kokoroSpeed(Double)
    /// Say one sentence in this voice (`VoicePreview`).
    case previewVoice(String)
    case requestPermission(CompanionPermission)
    case openPermissionSetup
    case keepListeningWhenClosed(Bool)
    case saveConversations(Bool)
    /// Confirmed on the page first; the files are removed, not moved to the Trash.
    case deleteAllConversations
    case forgetFact(ProfileFact)
    /// Empty text forgets it.
    case editFact(ProfileFact, String)
    /// Confirmed on the page first.
    case forgetAllFacts
}

/// The status-bar item's menu: a short list of commands, everything else is in Settings.
public enum StatusMenuItem: Equatable, Sendable {
    case showHide
    case settings
    /// Only while a permission Benji needs is missing.
    case finishSetup
    case separator
    case quit

    public var title: String {
        switch self {
        case .showHide: return "Show / Hide Benji"
        case .settings: return "Settings…"
        case .finishSetup: return "Finish Setup…"
        case .separator: return ""
        case .quit: return "Quit Benji"
        }
    }

    public var keyEquivalent: String {
        switch self {
        case .showHide: return "p"
        case .settings: return ","
        case .quit: return "q"
        case .finishSetup, .separator: return ""
        }
    }

    public static func menu(setupComplete: Bool) -> [StatusMenuItem] {
        [.showHide, .separator, .settings] + (setupComplete ? [] : [.finishSetup]) + [.separator, .quit]
    }
}
