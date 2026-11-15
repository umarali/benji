import XCTest
@testable import BenjiCore

/// The open panel's home: greeting, recent rows, which page shows, and the switch; plus
/// the profile file Settings › Memory edits.
final class HomeViewTests: XCTestCase {
    var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    let locale = Locale(identifier: "en_US_POSIX")
    /// Saturday 2026-10-31 22:00 UTC.
    let now = Date(timeIntervalSince1970: 1_793_484_000)

    func summary(_ title: String, hoursAgo: Double, id: String = UUID().uuidString) -> ConversationSummary {
        let d = now.addingTimeInterval(-hoursAgo * 3600)
        return ConversationSummary(id: id, title: title, started: d, updated: d, messages: 1)
    }

    func testGreetingByTimeOfDay() {
        XCTAssertEqual([5, 11, 12, 16, 17, 23, 0, 4].map(HomeView.greeting(hour:)),
                       ["Good morning.", "Good morning.", "Good afternoon.", "Good afternoon.",
                        "Good evening.", "Good evening.", "Good evening.", "Good evening."])
    }

    /// Times as the system writes them (a narrow no-break space before PM).
    func testWhenReadsLikeAClock() {
        func when(_ hours: Double) -> String {
            HomeView.when(now.addingTimeInterval(-hours * 3600), now: now, calendar: calendar, locale: locale)
        }
        XCTAssertEqual(when(2), "8:00\u{202F}PM")
        XCTAssertEqual(when(24), "Yesterday")
        XCTAssertEqual(when(24 * 3), "Wednesday")
        XCTAssertEqual(when(24 * 20), "Oct 11")
        XCTAssertEqual(when(24 * 400), "Sep 26, 2025")
        XCTAssertEqual(when(-1), "11:00\u{202F}PM", "a clock that ran ahead still reads as today")
    }

    func testRecentsAreTheNewestFourWithoutTheOpenOne() {
        let open = summary("Open now", hoursAgo: 0.1, id: "open")
        let all = [summary("c", hoursAgo: 30), open, summary("a", hoursAgo: 1), summary("e", hoursAgo: 90),
                   summary("b", hoursAgo: 5), summary("d", hoursAgo: 50), summary("f", hoursAgo: 900)]
        let recents = HomeView.recents(all, current: "open", now: now, calendar: calendar, locale: locale)
        XCTAssertEqual(recents.rows.map(\.title), ["a", "b", "c", "d"])
        XCTAssertEqual(recents.more, 2)
        XCTAssertEqual(recents.rows[2].when, "Yesterday")
        XCTAssertEqual(recents.rows[0].accessibilityLabel, "a, 9:00\u{202F}PM")
        XCTAssertEqual(HomeView.rows(all, now: now, calendar: calendar, locale: locale).first?.title, "Open now",
                       "the full list keeps it")
        XCTAssertEqual(HomeView.recents([], current: nil, now: now), HomeRecents(rows: [], more: 0))
    }

    // MARK: jobs in Recent

    func jobThread(_ title: String, hoursAgo: Double) -> ConversationSummary {
        summary(JobThread.titlePrefix + title, hoursAgo: hoursAgo)
    }

    func testRecentsShowAtMostOneJobThreadTheNewest() {
        let all = [jobThread("job 1", hoursAgo: 0.5), jobThread("job 2", hoursAgo: 0.6), jobThread("job 3", hoursAgo: 0.7),
                   summary("a", hoursAgo: 2), summary("b", hoursAgo: 3), summary("c", hoursAgo: 4), summary("d", hoursAgo: 5),
                   summary("e", hoursAgo: 6)]
        let recents = HomeView.recents(all, current: nil, now: now, calendar: calendar, locale: locale)
        XCTAssertEqual(recents.rows.map(\.title), ["Job · job 1", "a", "b", "c"], "one job, then the others fill the rows")
        XCTAssertEqual(recents.more, 4, "the rest are under All conversations")
        XCTAssertEqual(recents.rows.count + recents.more, all.count, "the count on that button stays the total")
        XCTAssertEqual(HomeView.rows(all, now: now, calendar: calendar, locale: locale).count, 8, "the list keeps every job")
    }

    func testAJobThatIsOpenIsLeftOutAndTheNextOneTakesItsPlace() {
        let open = jobThread("open job", hoursAgo: 0.1)
        let all = [open, jobThread("older job", hoursAgo: 1), summary("a", hoursAgo: 2)]
        let recents = HomeView.recents(all, current: open.id, now: now, calendar: calendar, locale: locale)
        XCTAssertEqual(recents.rows.map(\.title), ["Job · older job", "a"])
        XCTAssertEqual(recents.rows.count + recents.more, 2)
    }

    func testOnlyJobsAndTheRecentsStillWork() {
        let jobs = (1...6).map { jobThread("j\($0)", hoursAgo: Double($0)) }
        let recents = HomeView.recents(jobs, current: nil, now: now, calendar: calendar, locale: locale)
        XCTAssertEqual(recents.rows.map(\.title), ["Job · j1"])
        XCTAssertEqual(recents.more, 5)
        XCTAssertEqual(HomeView.recents([], current: nil, now: now), HomeRecents(rows: [], more: 0))
        XCTAssertEqual(summary("Jobs are fun", hoursAgo: 1).title.hasPrefix(JobThread.titlePrefix), false)
    }

    func testTheSidebarThinsJobsTheSameWayAndCountsEverything() {
        var all = (1...5).map { jobThread("j\($0)", hoursAgo: Double($0)) }
        all += (1...9).map { summary("c\($0)", hoursAgo: 10 + Double($0)) }
        let side = HomeView.sidebar(all, now: now, calendar: calendar, locale: locale)
        XCTAssertEqual(side.rows.filter { $0.title.hasPrefix(JobThread.titlePrefix) }.count, 1)
        XCTAssertEqual(side.rows.count, HomeView.sidebarLimit)
        XCTAssertEqual(side.rows.first?.title, "Job · j1")
        XCTAssertEqual(side.rows.count + side.more, all.count)
    }

    func testTiesKeepAStableOrder() {
        let a = ConversationSummary(id: "a", title: "A", started: now, updated: now, messages: 1)
        let b = ConversationSummary(id: "b", title: "B", started: now.addingTimeInterval(-60), updated: now, messages: 1)
        let c = ConversationSummary(id: "c", title: "C", started: now, updated: now, messages: 1)
        XCTAssertEqual([b, a, c].sorted(by: ConversationSummary.newestFirst).map(\.id), ["c", "a", "b"])
    }

    // MARK: which page

    func testHomeShowsWhenNothingRunsAndTheConversationIsEmpty() {
        func page(_ requested: PanelPage? = nil, lines: Bool = false, _ phase: CompanionPhase = .idle,
                  hearing: Bool = false, card: Bool = false) -> PanelPage {
            HomeView.page(requested: requested, hasLines: lines, phase: phase, hearing: hearing, cardPending: card)
        }
        XCTAssertEqual(page(), .home)
        XCTAssertEqual(page(lines: true), .conversation, "reopening the panel keeps the conversation")
        XCTAssertEqual(page(.home, lines: true), .home)
        XCTAssertEqual(page(.list, lines: true), .list)
        XCTAssertEqual(page(.conversation), .conversation)
        XCTAssertEqual(page(.home, lines: true, .listening), .home, "listening with no words keeps home")
        XCTAssertEqual(page(.home, lines: true, .error), .home)
        XCTAssertEqual(page(.home, .listening, hearing: true), .conversation, "words: they show where they go")
        for busy in [CompanionPhase.transcribing, .thinking, .speaking, .awaitingApproval] {
            XCTAssertEqual(page(.home, busy), .conversation, "\(busy)")
            XCTAssertFalse(HomeView.keepsRequest(phase: busy))
            XCTAssertFalse(HomeView.canSwitchConversation(phase: busy, hearing: false, cardPending: false))
        }
        XCTAssertEqual(page(.home, card: true), .conversation, "the screen question needs the panel")
        XCTAssertTrue(HomeView.canSwitchConversation(phase: .listening, hearing: false, cardPending: false))
        XCTAssertFalse(HomeView.canSwitchConversation(phase: .listening, hearing: true, cardPending: false))
        XCTAssertFalse(HomeView.canSwitchConversation(phase: .idle, hearing: false, cardPending: true))
    }

    func testTheSwitchGoesHomeAndBack() {
        XCTAssertEqual(HomeView.toggleTarget(from: .conversation, hasLines: true), .home)
        XCTAssertEqual(HomeView.toggleTarget(from: .list, hasLines: false), .home)
        XCTAssertEqual(HomeView.toggleTarget(from: .home, hasLines: true), .conversation)
        XCTAssertNil(HomeView.toggleTarget(from: .home, hasLines: false), "nothing to go back to")
    }

    func testEmptyLinesSayWhy() {
        XCTAssertTrue(HomeView.emptyLine(saving: false).contains("Settings › Memory"))
        XCTAssertNotEqual(HomeView.emptyLine(saving: true), HomeView.emptyLine(saving: false))
    }

    // MARK: Settings › Memory

    func testTheMemoryPaneSitsBetweenScreenAndShortcuts() {
        XCTAssertEqual(SettingsPane.all.map(\.title), ["General", "Voice", "Screen", "Browser", "Memory", "Shortcuts", "Permissions"])
        XCTAssertEqual(Set(SettingsPane.all.map(\.symbol)).count, SettingsPane.all.count)
        XCTAssertEqual(Set(SettingsPane.all.map(\.id)).count, SettingsPane.all.count)
        XCTAssertTrue(SettingsPane.memory.subtitle.hasSuffix("."))
        XCTAssertTrue(MemorySettings.savesConversations(nil), "saving is on until turned off")
        XCTAssertFalse(MemorySettings.savesConversations(false))
        XCTAssertEqual([0, 1, 12].map(MemorySettings.count), ["No conversations saved", "1 conversation", "12 conversations"])
        XCTAssertTrue(MemorySettings.deleteAllQuestion(3).contains("can't be undone"))
    }

    // MARK: the profile file

    let file = """
    {"ts": 1, "text": "the user's name is Umar", "tags": ["profile"]}

    not json
    {"ts": 2, "text": "prefers concise answers", "tags": []}
    {"ts": 3, "text": "  ", "tags": []}
    {"ts": 4, "text": "works on Benji", "tags": ["work"]}

    """

    func testFactsAreTheLinesWithText() {
        let facts = ProfileMemory.facts(in: file)
        XCTAssertEqual(facts.map(\.text), ["the user's name is Umar", "prefers concise answers", "works on Benji"])
        XCTAssertEqual(facts.map(\.line), [0, 3, 5])
        XCTAssertEqual(ProfileMemory.facts(in: ""), [])
    }

    func testForgettingRemovesOnlyThatLine() throws {
        let fact = ProfileMemory.facts(in: file)[1]
        let after = try XCTUnwrap(ProfileMemory.removing(fact, from: file))
        XCTAssertEqual(ProfileMemory.facts(in: after).map(\.text), ["the user's name is Umar", "works on Benji"])
        XCTAssertTrue(after.contains("not json"), "lines it doesn't understand stay")
        XCTAssertFalse(after.contains("concise"))
        XCTAssertNil(ProfileMemory.removing(fact, from: after), "already gone: nothing else is removed")
    }

    func testChangingKeepsTheOtherFields() throws {
        let fact = ProfileMemory.facts(in: file)[2]
        let after = try XCTUnwrap(ProfileMemory.replacing(fact, with: " works on Benji,\nthe notch app ", in: file))
        let facts = ProfileMemory.facts(in: after)
        XCTAssertEqual(facts.last?.text, "works on Benji, the notch app")
        let line = after.components(separatedBy: "\n")[5]
        XCTAssertTrue(line.contains("\"tags\":[\"work\"]") && line.contains("\"ts\":4"), line)
        XCTAssertEqual(after.components(separatedBy: "\n")[0], file.components(separatedBy: "\n")[0], "others byte for byte")
        XCTAssertNil(ProfileMemory.replacing(ProfileFact(line: 5, text: "something else"), with: "x", in: file),
                     "a line that changed underneath is left alone")
        let emptied = try XCTUnwrap(ProfileMemory.replacing(fact, with: "  ", in: file))
        XCTAssertEqual(ProfileMemory.facts(in: emptied).count, 2, "empty text forgets it")
    }

    func testTheFileIsRewrittenForTheUserOnly() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("benji-profile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("memory.jsonl")
        try ProfileMemory.write(file, to: url)
        XCTAssertEqual(ProfileMemory.read(url), file)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, 0o600)
        try ProfileMemory.write("", to: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "forgetting everything removes the file")
    }

    func testRowsFittingYieldBeforeTheComposer() {
        XCTAssertEqual(HomeView.rowsFitting(height: 400, available: 4), 4)
        XCTAssertLessThan(HomeView.rowsFitting(height: 190, available: 4, hintLines: 2), 4)
        XCTAssertEqual(HomeView.rowsFitting(height: 20, available: 4), 0)
        XCTAssertEqual(HomeView.rowsFitting(height: 400, available: 2), 2)
        XCTAssertGreaterThanOrEqual(HomeView.rowsFitting(height: 250, available: 4),
                                    HomeView.rowsFitting(height: 250, available: 4, hintLines: 2))
    }

    func testDrawingsShowInCapturesUnlessTurnedOff() {
        XCTAssertTrue(DrawingCapture.shownWhileDrawing(from: nil))
        XCTAssertTrue(DrawingCapture.shownWhileDrawing(from: true))
        XCTAssertFalse(DrawingCapture.shownWhileDrawing(from: false))
    }
}
