import XCTest
@testable import BenjiCore

/// D-133: date lines between turns from different days, and the scroll-to-latest button.
final class TranscriptDaysTests: XCTestCase {
    var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Karachi")!
        return c
    }()
    let locale = Locale(identifier: "en_GB")
    /// Monday 2 November 2026, 14:00 PKT.
    lazy var now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 14))!

    func row(_ text: String, daysAgo: Int?, hour: Int = 10, role: TranscriptRole = .user) -> PanelRow {
        let at = daysAgo.map { calendar.date(byAdding: .day, value: -$0, to: calendar.date(bySettingHour: hour, minute: 0, second: 0, of: now)!)! }
        return PanelRow(line: TranscriptLine(role: role, text: text, at: at))
    }

    func titles(_ items: [TranscriptItem]) -> [String] {
        items.map {
            switch $0 {
            case .dateLine(_, let title): return "— \(title) —"
            case .row(let r): return r.line.text
            }
        }
    }

    func items(_ rows: [PanelRow]) -> [TranscriptItem] {
        TranscriptDays.items(rows, now: now, calendar: calendar, locale: locale)
    }

    func testOneDayHasNoLines() {
        XCTAssertEqual(titles(items([row("a", daysAgo: 0, hour: 9), row("b", daysAgo: 0, hour: 9, role: .assistant),
                                     row("c", daysAgo: 0, hour: 13)])), ["a", "b", "c"])
        XCTAssertEqual(items([]), [])
    }

    func testEachDayIsNamedOnceItSpansDays() {
        let rows = [row("a", daysAgo: 3), row("b", daysAgo: 3, role: .assistant),
                    row("c", daysAgo: 1), row("d", daysAgo: 0), row("e", daysAgo: 0, role: .assistant)]
        XCTAssertEqual(titles(items(rows)),
                       ["— Fri 30 Oct —", "a", "b", "— Yesterday —", "c", "— Today —", "d", "e"])
    }

    func testAcrossMidnightIsANewDay() {
        let late = row("late", daysAgo: 1, hour: 23)
        let early = row("early", daysAgo: 0, hour: 0)
        XCTAssertEqual(titles(items([late, early])), ["— Yesterday —", "late", "— Today —", "early"])
    }

    func testOldFilesWithoutTimesGetNoLinesUntilATimedTurn() {
        let old = [row("old q", daysAgo: nil), row("old a", daysAgo: nil, role: .assistant)]
        XCTAssertEqual(titles(items(old)), ["old q", "old a"], "an old file alone draws no date lines")
        XCTAssertEqual(titles(items(old + [row("new", daysAgo: 0)])), ["old q", "old a", "— Today —", "new"],
                       "continued today: today's turns sit under Today")
    }

    func testDateLineIDsAreStableAndDistinctFromRows() {
        let rows = [row("a", daysAgo: 1), row("b", daysAgo: 0)]
        let first = items(rows), second = items(rows)
        XCTAssertEqual(first.map(\.id), second.map(\.id))
        XCTAssertEqual(Set(first.map(\.id)).count, first.count)
    }

    func testTitles() {
        func t(_ days: Int, _ years: Int = 0) -> String {
            let d = calendar.date(byAdding: DateComponents(year: -years, day: -days), to: now)!
            return TranscriptDays.title(d, now: now, calendar: calendar, locale: locale)
        }
        XCTAssertEqual(t(0), "Today")
        XCTAssertEqual(t(1), "Yesterday")
        XCTAssertEqual(t(3), "Fri 30 Oct")
        XCTAssertEqual(t(9), "Sat 24 Oct")
        XCTAssertEqual(t(0, 1), "Sun, 2 Nov 2025", "another year says which")
    }

    func testScrollToLatestOnlyPastAboutARow() {
        XCTAssertFalse(ScrollToLatest.shows(distanceFromBottom: -40), "content shorter than the view")
        XCTAssertFalse(ScrollToLatest.shows(distanceFromBottom: 0))
        XCTAssertFalse(ScrollToLatest.shows(distanceFromBottom: ScrollToLatest.threshold))
        XCTAssertTrue(ScrollToLatest.shows(distanceFromBottom: ScrollToLatest.threshold + 1))
        XCTAssertTrue(ScrollToLatest.shows(distanceFromBottom: 400))
    }

    // MARK: saved times (backward compatible)

    func testLinesCarryTheirTimeIntoTheSavedFormatAndBack() throws {
        let at = Date(timeIntervalSince1970: 1_793_000_000)
        let saved = SavedLine(TranscriptLine(role: .user, text: "hi", at: at))!
        XCTAssertEqual(saved.at, at)
        XCTAssertEqual(saved.transcriptLine.at, at)
        let data = try ConversationStore.encoder.encode(saved)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"at\""))
        XCTAssertEqual(try ConversationStore.decoder.decode(SavedLine.self, from: data), saved)
    }

    func testAnOldFileWithoutTimesStillOpens() throws {
        let json = #"{"role": "assistant", "text": "Hey."}"#
        let line = try ConversationStore.decoder.decode(SavedLine.self, from: Data(json.utf8))
        XCTAssertNil(line.at)
        XCTAssertNil(line.transcriptLine.at)
        XCTAssertFalse(String(decoding: try ConversationStore.encoder.encode(line), as: UTF8.self).contains("\"at\""),
                       "and it is written back without one")
    }

    func testTheSharedSampleStillDecodes() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("conversation-sample.json")
        let c = try ConversationStore.decoder.decode(SavedConversation.self, from: Data(contentsOf: url))
        XCTAssertFalse(c.lines.isEmpty)
        XCTAssertTrue(c.lines.allSatisfy { $0.at == nil })
    }

    func testACutOffAnswerKeepsItsTime() {
        var s = CompanionState()
        reduce(&s, .submitText("hello"))
        reduce(&s, .assistantAnswer("Hello there, how"))
        let at = s.lines.last?.at
        XCTAssertNotNil(at)
        reduce(&s, .answerCutOff(shown: "Hello there"))
        XCTAssertEqual(s.lines.first { $0.role == .assistant }?.at, at)
    }
}
