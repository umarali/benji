import BenjiCore
import Foundation

/// The app's settings live under its bundle id, so each rename left them behind. Copies the user's own
/// settings into `com.emerssive.heybenji.app` once, without overwriting anything already set here; the older domains
/// are left as they were, which is the way back. Permission bookkeeping is never copied: macOS grants
/// permissions per bundle id and signature, so the new app starts without them, and a copied flag would
/// only make it believe otherwise.
enum DefaultsMigration {
    static let legacyDomains = ["com.chilly.app", "com.pal.companion"]      // newest first
    static let doneKey = "migratedFromChillyApp"
    static let palDoneKey = "migratedFromPalCompanion"
    /// What the older build's own earlier migrations and the user's choices left: every key that
    /// `selftest_benji_upgrade.py` finds in the app's sources, but for `neverCopied`.
    static let settings = [
        palDoneKey, FigureSetting.migrationKey,
        "talkKey", "pttTranscriber", "backendMode", "ttsVoice", "ttsEngine", "kokoroVoice", "kokoroSpeed",
        "streamReplies", "speakScreenAnswersEarly", "modelChoice", "readAnswersAloud", "listenWhileOpen",
        "keepListeningWhenClosed", "handsFree", "handsFreeEndSilence", "handsFreeIdleTimeout", "bargeIn",
        "explainCards", "figureStage", "showDrawingsInScreenshots", "outlineWidth", "cutPlane", "pointerCompanion",
        "screenMode", "screenActions", "screenActionsAsk", "driveMode", "holdBackOverOtherAppAudio",
        "backgroundJobs", "jobSchedules", "jobCues", "cueVolume", "saveConversations", "panelExpanded",
        "browserForJobs", "browserAlwaysRead", "keySource", "echoCancellationFailures",
        "appOffers", "appOffersRecord",
        "setupModelProvider", "setupLocalModel", "setupLocalEndpoint", "setupModelNeedsTest",
    ]
    /// A grant macOS holds for one bundle id, or the app's note about one. Never carried over.
    static let neverCopied = ["screenRecordingConfirmed", "talkKeyAskedAccessibility", "lastLaunchGrants",
                              "permissionSetupShown", "permissionSetupResumeAfterRelaunch",
                              "permissionSetupScreenRecordingAsked"]

    /// `domain` reads another app's stored settings; tests pass their own, so they never see a real domain.
    /// `finish: false` copies but doesn't mark it done: while an older app is still running it can change
    /// them, but this run still needs them (the key source above all). The next start copies what is still missing.
    static func run(_ defaults: UserDefaults = .standard, finish: Bool = true,
                    domain: (String) -> [String: Any]? = { UserDefaults.standard.persistentDomain(forName: $0) }) {
        guard !defaults.bool(forKey: doneKey) else { return }
        let current = Bundle.main.bundleIdentifier.flatMap(domain) ?? [:]
        let chilly = domain(legacyDomains[0]) ?? [:]
        // The older copy already had its one chance at Pal's settings: a value since cleared stays cleared.
        let pal = (chilly[palDoneKey] as? Bool) == true ? [:] : (domain(legacyDomains[1]) ?? [:])
        for key in settings where current[key] == nil {
            if let value = chilly[key] ?? pal[key] { defaults.set(value, forKey: key) }
        }
        if finish { defaults.set(true, forKey: doneKey) }
    }

    /// "Draw Things in 3D" became an off switch, on by default (chilly-whiteboard): an "off" stored
    /// under the old opt-in meaning is cleared once; anything set after that is kept.
    static func figureSensing(_ defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: FigureSetting.migrationKey) else { return }
        if FigureSetting.clearsOnMigration(stored: defaults.object(forKey: FigureSetting.defaultsKey)) {
            defaults.removeObject(forKey: FigureSetting.defaultsKey)
        }
        defaults.set(true, forKey: FigureSetting.migrationKey)
    }
}
