import XCTest
@testable import BenjiCore

/// The composer's talk control, the New conversation rule and the sidebar.
final class ComposerTests: XCTestCase {
    func testTheCapsuleWhileEmptyTheMicOnceTyping() {
        XCTAssertEqual(ComposerTalk.shape(text: ""), .capsule)
        XCTAssertEqual(ComposerTalk.shape(text: "  \n"), .capsule)
        XCTAssertEqual(ComposerTalk.shape(text: "What does"), .round)
    }

    func testTheCapsuleNamesTheRealKey() {
        XCTAssertEqual(ComposerTalk.title(key: "Right ⌥", listening: false), "Hold Right ⌥ to talk")
        XCTAssertEqual(ComposerTalk.title(key: nil, listening: false), "Click to talk")
        XCTAssertEqual(ComposerTalk.title(key: "", listening: false), "Click to talk")
        XCTAssertEqual(ComposerTalk.title(key: "Right ⌥", listening: true), "Stop listening")
        XCTAssertEqual(ComposerTalk.help(key: "Right ⌥", startsOnTap: true, listening: false),
                       "Click to talk. Or hold Right ⌥ and let go to send; tap it and Benji keeps listening until you say “that's all”")
        XCTAssertEqual(ComposerTalk.help(key: "Right ⌥", startsOnTap: false, listening: false),
                       "Click to talk. Or hold Right ⌥ and let go to send, or tap it and tap again to send")
        XCTAssertEqual(ComposerTalk.help(key: nil, startsOnTap: true, listening: false), "Click to talk")
        XCTAssertTrue(ComposerTalk.help(key: nil, startsOnTap: false, listening: true).contains("Click to stop"))
        XCTAssertEqual(ComposerTalk.accessibilityLabel(listening: true), "Stop listening")
        XCTAssertEqual(ComposerTalk.accessibilityLabel(listening: false), "Talk")
    }

    /// Right ⌥ is the only talk key. When it is on but not ready the capsule and the tooltip
    /// say why and point to Finish Setup, and never name another key.
    func testAKeyThatIsNotReadySaysWhyAndNamesNoOtherKey() {
        XCTAssertEqual(ComposerTalk.title(key: nil, needsSetup: "Right ⌥", listening: false), "Right ⌥ needs Accessibility")
        let help = ComposerTalk.help(key: nil, needsSetup: "Right ⌥", startsOnTap: true, listening: false)
        XCTAssertTrue(help.contains("Right ⌥ needs Accessibility"))
        XCTAssertTrue(help.contains("Finish Setup"))
        for text in ["Right ⌥ needs Accessibility", help] {
            XCTAssertFalse(text.contains("⇧"), text)
            XCTAssertFalse(text.contains("⌘"), text)
            XCTAssertFalse(text.contains("Space"), text)
        }
        XCTAssertEqual(ComposerTalk.title(key: nil, needsSetup: "Right ⌥", listening: true), "Stop listening")
        XCTAssertEqual(ComposerTalk.title(key: "Right ⌥", needsSetup: "Right ⌥", listening: false), "Hold Right ⌥ to talk")
        XCTAssertEqual(ComposerTalk.title(key: nil, needsSetup: nil, listening: false), "Click to talk", "talk key off")
    }

    func testTheHintNamesOnlyRightOptionAndPointsToFinishSetup() {
        let ready = ComposerTalk.hint(key: "Right ⌥", ready: true, enabled: true, startsOnTap: false)
        XCTAssertEqual(ready, "To talk: hold Right ⌥ and let go to send, or tap it and tap again to send.")
        XCTAssertTrue(ComposerTalk.hint(key: "Right ⌥", ready: true, enabled: true, startsOnTap: true)
            .contains("keeps listening until you say “that's all”"))
        let notReady = ComposerTalk.hint(key: "Right ⌥", ready: false, enabled: true, startsOnTap: true)
        XCTAssertTrue(notReady.hasPrefix("Right ⌥ needs Accessibility"))
        XCTAssertTrue(notReady.contains("Finish Setup"))
        XCTAssertEqual(ComposerTalk.hint(key: "Right ⌥", ready: false, enabled: false, startsOnTap: false),
                       "Click to talk below, or type.")
        for text in [ready, notReady] {
            XCTAssertFalse(text.contains("⇧"), text)
            XCTAssertFalse(text.contains("⌘"), text)
            XCTAssertFalse(text.contains("Space"), text)
        }
    }

    func testTalkingStartsOrStopsOnlyWhileNothingElseRuns() {
        for phase in [CompanionPhase.idle, .error, .listening] { XCTAssertTrue(ComposerTalk.enabled(phase: phase), "\(phase)") }
        for phase in [CompanionPhase.transcribing, .thinking, .speaking, .awaitingApproval] {
            XCTAssertFalse(ComposerTalk.enabled(phase: phase), "\(phase)")
        }
    }

    func testNewConversationIsAllowedAtRestAndWhileTheMicIsOpen() {
        for phase in [CompanionPhase.idle, .error, .listening, .transcribing] {
            XCTAssertTrue(NewConversationRule.allows(phase: phase), "\(phase)")
            XCTAssertTrue(NewConversationRule.enabled(phase: phase, hasConversation: true), "\(phase)")
            XCTAssertFalse(NewConversationRule.enabled(phase: phase, hasConversation: false), "\(phase), nothing to clear")
        }
    }

    func testNewConversationWaitsForARunningReplyOrACard() {
        for phase in [CompanionPhase.thinking, .speaking, .awaitingApproval] {
            XCTAssertFalse(NewConversationRule.allows(phase: phase), "\(phase)")
            XCTAssertFalse(NewConversationRule.enabled(phase: phase, hasConversation: true), "\(phase)")
        }
    }

    func testOnlyAnOpenMicHasHeardWordsToDrop() {
        XCTAssertTrue(NewConversationRule.dropsHeardWords(phase: .listening))
        XCTAssertTrue(NewConversationRule.dropsHeardWords(phase: .transcribing))
        for phase in [CompanionPhase.idle, .error, .thinking, .speaking, .awaitingApproval] {
            XCTAssertFalse(NewConversationRule.dropsHeardWords(phase: phase), "\(phase)")
        }
    }

    func testTheSidebarKeepsTheOpenConversation() {
        let now = Date(timeIntervalSince1970: 1_793_600_000)
        let summaries = (0..<12).map { i in
            ConversationSummary(id: "c\(i)", title: "T\(i)", started: now.addingTimeInterval(Double(-i) * 3600),
                                updated: now.addingTimeInterval(Double(-i) * 3600), messages: 1)
        }
        let s = HomeView.sidebar(summaries, now: now)
        XCTAssertEqual(s.rows.map(\.id), (0..<HomeView.sidebarLimit).map { "c\($0)" }, "newest first, the open one kept")
        XCTAssertEqual(s.more, 12 - HomeView.sidebarLimit)
        XCTAssertEqual(HomeView.sidebar([], now: now), HomeRecents(rows: [], more: 0))
    }

    func testTheSidebarSaysWhenInFewWords() {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Karachi")!
        let en = Locale(identifier: "en_US")
        let now = c.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 14))!   // a Monday
        func w(_ days: Int) -> String {
            HomeView.shortWhen(c.date(byAdding: .day, value: -days, to: now)!, now: now, calendar: c, locale: en)
        }
        XCTAssertEqual(w(0), "Today")
        XCTAssertEqual(w(2), "Sat")
        XCTAssertEqual(w(6), "Tue")
        XCTAssertEqual(w(10), "Oct 23")
        XCTAssertEqual(w(400), "Sep 28, 2025")
    }
}
