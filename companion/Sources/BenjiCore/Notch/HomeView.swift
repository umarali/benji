import Foundation

// The open panel's home: a time-of-day greeting, one line on how to talk, and the recent saved
// conversations, with every one a click away. Pure decisions only; the app draws them.

/// What the open panel shows below the band (the settings page is separate).
public enum PanelPage: Equatable, Sendable {
    case conversation
    /// The greeting and the recent conversations.
    case home
    /// Every saved conversation.
    case list
}

/// One saved conversation as a row of the home view or the list.
public struct HomeRow: Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    /// "10:24 PM", "Yesterday", "Monday", "Oct 12", "Oct 12, 2025".
    public let when: String

    public var accessibilityLabel: String { "\(title), \(when)" }
}

/// The home view's recent rows, and how many more the list holds.
public struct HomeRecents: Equatable, Sendable {
    public let rows: [HomeRow]
    public let more: Int

    public init(rows: [HomeRow], more: Int) {
        self.rows = rows
        self.more = more
    }
}

public enum HomeView {
    /// Rows on the home view; the rest are under "All conversations…".
    public static let recentLimit = 4

    /// Estimated heights (points) of the home page's parts, for `rowsFitting`: the greeting block
    /// without its hint, one hint line, the Recent header with the "All conversations…" button and
    /// the gaps between the blocks, and one recent row.
    public static let greetingHeight: Double = 36, hintLineHeight: Double = 18
    public static let recentChromeHeight: Double = 74, rowHeight: Double = 31

    /// How many of `available` recent rows fit in `height` points of page, so the page gives way
    /// above the composer instead of pushing it off the panel. Rows yield first, down to none (the
    /// "All conversations…" button stays); `hintLines` is 2 when the hint can wrap (listening).
    public static func rowsFitting(height: Double, available: Int, hintLines: Int = 1) -> Int {
        let fixed = greetingHeight + hintLineHeight * Double(max(0, hintLines)) + recentChromeHeight
        let room = Int(((height - fixed) / rowHeight).rounded(.down))
        return max(0, min(available, room))
    }

    /// Good morning (5–11), afternoon (12–16), evening (17–4).
    public static func greeting(hour: Int) -> String {
        switch hour {
        case 5..<12: return "Good morning."
        case 12..<17: return "Good afternoon."
        default: return "Good evening."
        }
    }

    /// The home view's quiet line when nothing has been saved, or saving is off.
    public static func emptyLine(saving: Bool) -> String {
        saving ? "Conversations you have with Benji will be listed here."
               : "Saving conversations is off. Turn it on in Settings › Memory."
    }

    /// Job threads ("Job · …") shown among the recent rows: one, the newest. A busy day of jobs
    /// would otherwise fill the four rows; "All conversations…" keeps every one.
    public static let recentJobLimit = 1

    /// `summaries` newest first, with only the newest `recentJobLimit` job threads kept.
    static func withFewJobs(_ sorted: [ConversationSummary]) -> [ConversationSummary] {
        var jobs = 0
        return sorted.filter { summary in
            guard summary.title.hasPrefix(JobThread.titlePrefix) else { return true }
            jobs += 1
            return jobs <= recentJobLimit
        }
    }

    /// The newest `recentLimit` conversations, the open one left out (it is a click away already),
    /// with at most one job thread among them. `more` counts everything else the list holds.
    public static func recents(_ summaries: [ConversationSummary], current: String?, now: Date,
                               calendar: Calendar = .current, locale: Locale = .current) -> HomeRecents {
        let all = rows(summaries, current: current, now: now, calendar: calendar, locale: locale)
        let few = withFewJobs(summaries.filter { $0.id != current }.sorted(by: ConversationSummary.newestFirst))
        let shown = Set(few.prefix(recentLimit).map(\.id))
        return HomeRecents(rows: all.filter { shown.contains($0.id) }, more: max(0, all.count - shown.count))
    }

    /// Rows in the expanded panel's sidebar; the rest are under "All conversations…".
    public static let sidebarLimit = 8

    /// The expanded panel's "Recent": the newest `sidebarLimit` conversations, the open one kept
    /// (the sidebar highlights it), and how many more the list holds.
    public static func sidebar(_ summaries: [ConversationSummary], now: Date, calendar: Calendar = .current,
                               locale: Locale = .current) -> HomeRecents {
        let sorted = summaries.sorted(by: ConversationSummary.newestFirst)
        let all = withFewJobs(sorted).map {
            HomeRow(id: $0.id, title: $0.title, when: shortWhen($0.updated, now: now, calendar: calendar, locale: locale))
        }
        return HomeRecents(rows: Array(all.prefix(sidebarLimit)), more: max(0, sorted.count - min(all.count, sidebarLimit)))
    }

    /// The sidebar's narrow "when": "Today", the short weekday within a week ("Sat"), then the
    /// short date ("Oct 12"), with the year once it isn't this year's.
    public static func shortWhen(_ date: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                           to: calendar.startOfDay(for: now)).day ?? 0
        let template: String
        switch days {
        case ...0: return "Today"
        case 1...6: template = "EEE"
        default:
            template = calendar.component(.year, from: date) == calendar.component(.year, from: now) ? "MMMd" : "yMMMd"
        }
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = locale
        f.setLocalizedDateFormatFromTemplate(template)
        return f.string(from: date)
    }

    /// Every conversation, newest first. `current`: left out (nil keeps them all).
    public static func rows(_ summaries: [ConversationSummary], current: String? = nil, now: Date,
                            calendar: Calendar = .current, locale: Locale = .current) -> [HomeRow] {
        summaries.filter { $0.id != current }
            .sorted(by: ConversationSummary.newestFirst)
            .map { HomeRow(id: $0.id, title: $0.title, when: when($0.updated, now: now, calendar: calendar, locale: locale)) }
    }

    /// When a conversation last changed: the time today, "Yesterday", the weekday within a
    /// week, then the date (with the year once it isn't this year's).
    public static func when(_ date: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let today = calendar.startOfDay(for: now)
        let day = calendar.startOfDay(for: date)
        let days = calendar.dateComponents([.day], from: day, to: today).day ?? 0
        let template: String
        switch days {
        case ...0: template = "jmm"
        case 1: return "Yesterday"
        case 2...6: template = "EEEE"
        default:
            template = calendar.component(.year, from: date) == calendar.component(.year, from: now) ? "MMMd" : "yMMMd"
        }
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = locale
        f.setLocalizedDateFormatFromTemplate(template)
        return f.string(from: date)
    }

    // MARK: which page

    /// The page the open panel shows. Nothing running (idle, an error, or listening with no words
    /// heard yet), no card waiting: the page asked for, else home when the conversation is
    /// empty. Anything else is the conversation, where it happens.
    public static func page(requested: PanelPage?, hasLines: Bool, phase: CompanionPhase, hearing: Bool,
                            cardPending: Bool) -> PanelPage {
        if cardPending || hearing || !quiet(phase) { return .conversation }
        return requested ?? (hasLines ? .conversation : .home)
    }

    /// A page asked for holds only while nothing runs; a turn starting forgets it, so the panel
    /// comes back to the conversation afterwards.
    public static func keepsRequest(phase: CompanionPhase) -> Bool { quiet(phase) }

    /// A saved conversation can be opened (or the current one dropped) only while nothing runs.
    public static func canSwitchConversation(phase: CompanionPhase, hearing: Bool, cardPending: Bool) -> Bool {
        quiet(phase) && !hearing && !cardPending
    }

    private static func quiet(_ phase: CompanionPhase) -> Bool {
        switch phase {
        case .idle, .error, .listening: return true
        case .transcribing, .thinking, .speaking, .awaitingApproval: return false
        }
    }

    /// The bottom row's switch: where it goes from `page`, or nil when there is nowhere to go
    /// (home with an empty conversation).
    public static func toggleTarget(from page: PanelPage, hasLines: Bool) -> PanelPage? {
        switch page {
        case .conversation, .list: return .home
        case .home: return hasLines ? .conversation : nil
        }
    }
}
