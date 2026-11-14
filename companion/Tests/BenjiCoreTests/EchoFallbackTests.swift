import XCTest
@testable import BenjiCore

/// D-119: where the Mac's echo cancelling fails to start, Always acts like Headphones instead of
/// failing (or hearing nothing) on every turn.
final class EchoFallbackTests: XCTestCase {
    let speakers = EchoVerdicts.key(route: .speakers, input: "MacBook Pro Microphone")

    func testAFailureIsRememberedPerSetupForAWeek() {
        var v = EchoVerdicts(stored: nil)
        XCTAssertFalse(v.isKnownBad(speakers, now: 1000))
        XCTAssertTrue(v.recordFailure(speakers, now: 1000))          // news
        XCTAssertFalse(v.recordFailure(speakers, now: 1001))         // already known
        // The latest failure counts: a week after it, Always tries echo cancelling again.
        XCTAssertTrue(v.isKnownBad(speakers, now: 1001 + EchoVerdicts.retryAfter - 1))
        XCTAssertFalse(v.isKnownBad(speakers, now: 1001 + EchoVerdicts.retryAfter))
        let other = EchoVerdicts.key(route: .speakers, input: "Studio Display Microphone")
        XCTAssertFalse(v.isKnownBad(other, now: 1001))               // another mic is another setup
    }

    func testVerdictsRoundTripThroughUserDefaultsShapes() {
        var v = EchoVerdicts(stored: nil)
        v.recordFailure(speakers, now: 42)
        let back = EchoVerdicts(stored: v.stored as [String: Any])
        XCTAssertEqual(back, v)
        XCTAssertEqual(EchoVerdicts(stored: ["x": "not a number"]).failures, [:])
        XCTAssertEqual(EchoVerdicts(stored: "junk").failures, [:])
    }

    func testClearAllForgetsEverything() {
        var v = EchoVerdicts(stored: nil)
        v.recordFailure(speakers, now: 1)
        v.clearAll()
        XCTAssertFalse(v.isKnownBad(speakers, now: 2))
    }

    func testKeyNamesTheRouteAndTheMic() {
        XCTAssertEqual(EchoVerdicts.key(route: .speakers, input: " MacBook Pro Microphone "),
                       "speakers|MacBook Pro Microphone")
        XCTAssertEqual(EchoVerdicts.key(route: .unknown, input: nil), "unknown|default input")
    }

    func testAlwaysActsLikeHeadphonesOnlyWhereEchoCancellingFailed() {
        XCTAssertEqual(BargeInMode.always.effective(route: .speakers, echoUnavailable: true), .headphones)
        XCTAssertEqual(BargeInMode.always.effective(route: .speakers, echoUnavailable: false), .always)
        XCTAssertEqual(BargeInMode.always.effective(route: .headphones, echoUnavailable: true), .always)
        XCTAssertEqual(BargeInMode.off.effective(route: .speakers, echoUnavailable: true), .off)
        XCTAssertEqual(BargeInMode.headphones.effective(route: .speakers, echoUnavailable: true), .headphones)
    }

    func testActingLikeHeadphonesKeepsTheMicShutOverSpeechOnSpeakersAndUsesThePlainEngine() {
        let acting = BargeInMode.always.effective(route: .speakers, echoUnavailable: true)
        XCTAssertFalse(acting.allows(.speakers))
        XCTAssertFalse(acting.needsEchoCancellation(.speakers))
        XCTAssertEqual(MicEngine.choose(mode: acting, route: .speakers, handsFreeOn: true, handsFreeAvailable: true), .plain)
        XCTAssertTrue(acting.allows(.headphones))
    }

    func testTheSettingsLineSaysWhyAlwaysBehavesLikeHeadphones() {
        var s = SettingsSnapshot()
        s.bargeIn = .always
        XCTAssertEqual(s.bargeInCaption, BargeInMode.always.caption)
        s.echoUnavailable = true
        XCTAssertEqual(s.bargeInCaption, BargeInMode.echoUnavailableCaption)
        s.bargeIn = .headphones
        XCTAssertEqual(s.bargeInCaption, BargeInMode.headphones.caption)
    }
}
