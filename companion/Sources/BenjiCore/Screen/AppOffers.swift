import Foundation

// App offers: after a while in an app Benji has a skill for, the notch offers that skill once,
// on a card. This is an unasked surface, so it has a switch that starts off and goes through `QuietGate`.
// Only the app's bundle id is looked at, only supported ids are ever stored, and nothing
// leaves the Mac: Try it puts words in the message box and the user sends them.

/// One supported app: which skill helps there and three things to try.
public struct AppOffer: Equatable, Sendable, Identifiable {
    public let bundleID: String
    public let appName: String
    /// The folder under `skills/` that does the work.
    public let skill: String
    public let examples: [String]

    public var id: String { bundleID }
    public var title: String { "I can help in \(appName)." }

    public init(bundleID: String, appName: String, skill: String, examples: [String]) {
        self.bundleID = bundleID
        self.appName = appName
        self.skill = skill
        self.examples = examples
    }
}

public enum AppOfferCatalog {
    /// A list, not a guess: an app that isn't here is never offered and never stored.
    public static let offers: [AppOffer] = [
        AppOffer(bundleID: "com.apple.Notes", appName: "Notes", skill: "apple-notes",
                 examples: ["List my notes", "Start a note called Ideas", "Summarise my latest note"]),
        AppOffer(bundleID: "com.apple.iCal", appName: "Calendar", skill: "calendar",
                 examples: ["What's on my calendar today?", "What does my week look like?",
                            "Add a meeting tomorrow at 10"]),
        AppOffer(bundleID: "com.apple.mail", appName: "Mail", skill: "draft-email",
                 examples: ["Draft a short thank-you email", "Draft an email asking to move our meeting",
                            "Draft an email asking for Friday off"]),
        AppOffer(bundleID: "com.apple.reminders", appName: "Reminders", skill: "reminders",
                 examples: ["What are my reminders today?", "Show my overdue reminders",
                            "Remind me to call the bank tomorrow"]),
        AppOffer(bundleID: "com.apple.Music", appName: "Music", skill: "music",
                 examples: ["What's playing?", "Skip this song", "List my playlists"]),
        AppOffer(bundleID: "com.culturedcode.ThingsMac", appName: "Things", skill: "things",
                 examples: ["What's in Today in Things?", "What's in my Things inbox?",
                            "Add a to-do in Things to renew my passport"]),
        AppOffer(bundleID: "md.obsidian", appName: "Obsidian", skill: "obsidian",
                 examples: ["Search Obsidian for meeting notes", "Create a note called Ideas in Obsidian",
                            "Search Obsidian for project plans"]),
        AppOffer(bundleID: "com.github.GitHubClient", appName: "GitHub Desktop", skill: "github",
                 examples: ["List my open pull requests", "What needs my review on GitHub?",
                            "Show the GitHub issues assigned to me"]),
    ]

    public static func offer(for bundleID: String) -> AppOffer? {
        offers.first { $0.bundleID == bundleID }
    }
}

/// How the user answered. Waiting it out, or starting something else, counts as Not now.
public enum AppOfferAnswer: Equatable, Sendable {
    case no, notNow, tryIt
}

/// What is remembered, on this Mac, in UserDefaults. Supported bundle ids only.
public struct AppOfferRecord: Codable, Equatable, Sendable {
    /// No: never for this app, until the user resets it in Settings.
    public var declined: Set<String> = []
    /// Try it: the offer did its job.
    public var tried: Set<String> = []
    public var snoozedUntil: [String: Date] = [:]
    public var lastShown: Date?

    public init() {}

    public static let defaultsKey = "appOffersRecord"

    public static func decode(_ stored: Any?) -> AppOfferRecord {
        guard let data = stored as? Data,
              let record = try? JSONDecoder().decode(AppOfferRecord.self, from: data) else { return AppOfferRecord() }
        return record
    }

    public func encoded() -> Data? { try? JSONEncoder().encode(self) }

    /// The apps turned down with No, by name, for Settings.
    public var declinedNames: [String] {
        AppOfferCatalog.offers.filter { declined.contains($0.bundleID) }.map(\.appName)
    }
}

public enum AppOfferRules {
    /// How long an app has to stay in front first.
    public static let dwell: TimeInterval = 30
    /// The user has to have touched the Mac this recently when the dwell ends.
    public static let activeWithin: TimeInterval = 30
    /// Not now, or no answer.
    public static let snooze: TimeInterval = 7 * 24 * 3600
    /// At most one offer in this long, across all apps.
    public static let minimumGap: TimeInterval = 24 * 3600
    /// The card goes away by itself after this, unless the pointer is on it.
    public static let timeout: TimeInterval = 20
    /// The pointer was on the card when it timed out: look again after this.
    public static let timeoutRecheck: TimeInterval = 5

    /// The offer for this app if the record allows one now, or nil.
    public static func offer(for bundleID: String, record: AppOfferRecord, now: Date) -> AppOffer? {
        guard let offer = AppOfferCatalog.offer(for: bundleID),
              !record.declined.contains(bundleID), !record.tried.contains(bundleID) else { return nil }
        if let until = record.snoozedUntil[bundleID], now < until { return nil }
        if let last = record.lastShown, now.timeIntervalSince(last) < minimumGap { return nil }
        return offer
    }

    public static func recordingShown(_ offer: AppOffer, in record: AppOfferRecord, now: Date) -> AppOfferRecord {
        var r = record
        r.lastShown = now
        return r
    }

    public static func applying(_ answer: AppOfferAnswer, to offer: AppOffer, in record: AppOfferRecord,
                                now: Date) -> AppOfferRecord {
        var r = record
        r.snoozedUntil[offer.bundleID] = nil
        switch answer {
        case .no: r.declined.insert(offer.bundleID)
        case .tryIt: r.tried.insert(offer.bundleID)
        case .notNow: r.snoozedUntil[offer.bundleID] = now.addingTimeInterval(snooze)
        }
        return r
    }

    /// Settings' reset: apps turned down or snoozed may be offered again. `lastShown` stays, so a
    /// reset can't produce a second offer the same day.
    public static func reset(_ record: AppOfferRecord) -> AppOfferRecord {
        var r = record
        r.declined = []
        r.snoozedUntil = [:]
        return r
    }

    /// Nothing else is going on: Benji is idle, the panel is shut, no conversation or job has the notch.
    public static func momentIsFree(phase: CompanionPhase, panelOpen: Bool, conversationOn: Bool,
                                    jobLive: Bool, jobPeek: Bool) -> Bool {
        phase == .idle && !panelOpen && !conversationOn && !jobLive && !jobPeek
    }
}

public enum AppOfferSettings {
    public static let defaultsKey = "appOffers"

    /// Off unless switched on, as every unasked surface starts.
    public static func isOn(_ stored: Any?) -> Bool { (stored as? Bool) ?? false }
}

public enum AppOfferCopy {
    public static let caption = "Nothing is read until you ask."
    public static let noHelp = "Don't offer this again"
    public static let notNowHelp = "Ask again in a week"
    public static let tryHelp = "Puts this in the message box. Nothing is sent until you press Return."
    public static let detail = "After 30 seconds in an app Benji has a skill for, offer the skill once on a card. "
        + "Off until you turn it on."
    public static let appList = AppOfferCatalog.offers.map(\.appName).joined(separator: ", ")
    public static let footer = "Only for \(appList). Benji checks which app is in front and nothing else, and that stays "
        + "on your Mac. At most one offer a day, never while you're on a call."
}
