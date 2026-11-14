import XCTest
@testable import BenjiCore

final class AppOffersTests: XCTestCase {
    let calendar = "com.apple.iCal"
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let day: TimeInterval = 24 * 3600

    private var offer: AppOffer { AppOfferCatalog.offer(for: calendar)! }

    // MARK: the catalog

    func testEveryOfferHasThreeDifferentExamplesAndAShippedSkill() {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        XCTAssertEqual(Set(AppOfferCatalog.offers.map(\.bundleID)).count, AppOfferCatalog.offers.count)
        for o in AppOfferCatalog.offers {
            XCTAssertEqual(Set(o.examples).count, 3, o.appName)
            let skill = repo.appendingPathComponent("skills/\(o.skill)/SKILL.md")
            XCTAssertTrue(FileManager.default.fileExists(atPath: skill.path), o.skill)
        }
    }

    func testAnExampleFitsItsRow() {
        for o in AppOfferCatalog.offers { for e in o.examples { XCTAssertLessThanOrEqual(e.count, 46, e) } }
    }

    func testTheWordingNeverSaysItWasWatching() {
        let words = AppOfferCatalog.offers.map(\.title) + [AppOfferCopy.caption, AppOfferCopy.detail, AppOfferCopy.footer]
        for w in words {
            XCTAssertFalse(w.lowercased().contains("noticed"), w)
            XCTAssertFalse(w.lowercased().contains("i see you"), w)
        }
    }

    // MARK: when an offer may appear

    func testAnAppThatIsNotListedIsNeverOffered() {
        XCTAssertNil(AppOfferRules.offer(for: "com.example.secret", record: AppOfferRecord(), now: t0))
    }

    func testAListedAppIsOfferedTheFirstTime() {
        XCTAssertEqual(AppOfferRules.offer(for: calendar, record: AppOfferRecord(), now: t0)?.skill, "calendar")
    }

    func testNoIsForever() {
        let r = AppOfferRules.applying(.no, to: offer, in: AppOfferRecord(), now: t0)
        XCTAssertNil(AppOfferRules.offer(for: calendar, record: r, now: t0.addingTimeInterval(3650 * day)))
    }

    func testTryItEndsTheOffer() {
        let r = AppOfferRules.applying(.tryIt, to: offer, in: AppOfferRecord(), now: t0)
        XCTAssertNil(AppOfferRules.offer(for: calendar, record: r, now: t0.addingTimeInterval(3650 * day)))
    }

    func testNotNowWaitsAWeek() {
        let r = AppOfferRules.applying(.notNow, to: offer, in: AppOfferRecord(), now: t0)
        XCTAssertNil(AppOfferRules.offer(for: calendar, record: r, now: t0.addingTimeInterval(7 * day - 1)))
        XCTAssertNotNil(AppOfferRules.offer(for: calendar, record: r, now: t0.addingTimeInterval(7 * day)))
    }

    func testOneOfferADayAcrossAllApps() {
        let r = AppOfferRules.recordingShown(offer, in: AppOfferRecord(), now: t0)
        XCTAssertNil(AppOfferRules.offer(for: "com.apple.Notes", record: r, now: t0.addingTimeInterval(day - 1)))
        XCTAssertNotNil(AppOfferRules.offer(for: "com.apple.Notes", record: r, now: t0.addingTimeInterval(day)))
    }

    func testResetBringsBackAnAppButNotASecondOfferToday() {
        var r = AppOfferRules.applying(.no, to: offer, in: AppOfferRecord(), now: t0)
        r = AppOfferRules.recordingShown(offer, in: r, now: t0)
        r = AppOfferRules.reset(r)
        XCTAssertNil(AppOfferRules.offer(for: calendar, record: r, now: t0.addingTimeInterval(60)))
        XCTAssertNotNil(AppOfferRules.offer(for: calendar, record: r, now: t0.addingTimeInterval(day)))
        XCTAssertTrue(r.declined.isEmpty)
    }

    func testTheRecordHoldsOnlyWhatItWasGiven() {
        var r = AppOfferRules.applying(.no, to: offer, in: AppOfferRecord(), now: t0)
        r = AppOfferRules.recordingShown(offer, in: r, now: t0)
        XCTAssertEqual(AppOfferRecord.decode(r.encoded()), r)
        XCTAssertEqual(r.declinedNames, ["Calendar"])
        XCTAssertEqual(AppOfferRecord.decode("junk"), AppOfferRecord())
    }

    func testTheSwitchStartsOff() {
        XCTAssertFalse(AppOfferSettings.isOn(nil))
        XCTAssertTrue(AppOfferSettings.isOn(true))
        XCTAssertEqual(QuietGate().verdict(switchOn: AppOfferSettings.isOn(nil), signals: { XCTFail("read"); return QuietSignals() }),
                       .switchedOff)
    }

    func testACallHoldsTheOffer() {
        let call = QuietSignals(windows: [.init(owner: "us.zoom.xos", title: "Zoom Meeting")])
        XCTAssertEqual(QuietGate().verdict(switchOn: true, signals: { call }), .quiet(.meetingWindow))
    }

    func testAnOfferOnlyAppearsWhenNothingElseHasTheNotch() {
        func free(_ phase: CompanionPhase = .idle, open: Bool = false, talk: Bool = false, live: Bool = false, peek: Bool = false) -> Bool {
            AppOfferRules.momentIsFree(phase: phase, panelOpen: open, conversationOn: talk, jobLive: live, jobPeek: peek)
        }
        XCTAssertTrue(free())
        for phase in [CompanionPhase.listening, .transcribing, .thinking, .speaking, .awaitingApproval, .error] {
            XCTAssertFalse(free(phase), "\(phase)")
        }
        XCTAssertFalse(free(open: true))
        XCTAssertFalse(free(talk: true))
        XCTAssertFalse(free(live: true))
        XCTAssertFalse(free(peek: true))
    }

    // MARK: the card size

    func testTheCardSitsBetweenPeekAndOpen() {
        XCTAssertLessThan(NotchSize.peek, .card)
        XCTAssertLessThan(NotchSize.card, .open)
        XCTAssertGreaterThan(PanelGeometry.cardSize.width, PanelGeometry.peekSize.width)
        XCTAssertGreaterThan(PanelGeometry.cardSize.height, PanelGeometry.peekSize.height)
        XCTAssertLessThan(PanelGeometry.cardSize.width, PanelGeometry.openSize.width)
        XCTAssertLessThan(PanelGeometry.cardSize.height, PanelGeometry.openSize.height)
    }

    func testTheCardGrowsFromTheNotch() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let notch = CGRect(x: 661, y: 950, width: 190, height: 32)
        let card = PanelGeometry.notchShape(.card, notch: notch, screenFrame: screen)
        XCTAssertEqual(card.frame.maxY, screen.maxY)
        XCTAssertEqual(card.frame.midX, notch.midX)
        XCTAssertEqual(card.frame.size, PanelGeometry.cardSize)
    }

    func testTheCardShowsOnlyWhenNothingElseHasTheNotch() {
        XCTAssertEqual(NotchPresence.targetSize(.init(phase: .idle, appOffer: true)), .card)
        XCTAssertEqual(NotchPresence.targetSize(.init(phase: .idle, hovered: true, appOffer: true)), .card)
        XCTAssertEqual(NotchPresence.targetSize(.init(phase: .idle, userOpened: true, appOffer: true)), .open)
        XCTAssertEqual(NotchPresence.targetSize(.init(phase: .idle, jobPeek: true, appOffer: true)), .peek)
        XCTAssertEqual(NotchPresence.targetSize(.init(phase: .idle, doneHolding: true, appOffer: true)), .peek)
        XCTAssertEqual(NotchPresence.targetSize(.init(phase: .listening, appOffer: true)), .peek)
        XCTAssertEqual(NotchPresence.targetSize(.init(phase: .awaitingApproval, appOffer: true)), .open)
        XCTAssertEqual(NotchPresence.targetSize(.init(phase: .error, appOffer: true)), .peek)
    }

    func testTheCardDrawsItsOwnLayerAndUsesTheLargerSpring() {
        XCTAssertEqual(NotchLayer.layers(for: .card), [.wings, .offer])
        XCTAssertEqual(MotionTokens.morph(from: .closed, to: .card), MotionTokens.open)
        XCTAssertEqual(MotionTokens.morph(from: .closed, to: .peek), MotionTokens.peek)
    }
}
