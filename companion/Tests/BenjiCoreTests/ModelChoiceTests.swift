import XCTest
@testable import BenjiCore

/// Settings › General › Model: Haiku by default (nothing set), Sonnet through BENJI_MODEL.
final class ModelChoiceTests: XCTestCase {
    func testHaikuUnlessSonnetWasChosen() {
        XCTAssertEqual(ModelChoice.from(nil), .haiku)
        XCTAssertEqual(ModelChoice.from("sonnet"), .sonnet)
        XCTAssertEqual(ModelChoice.from("opus"), .haiku)
        XCTAssertEqual(ModelChoice.from(1), .haiku)
        XCTAssertEqual(ModelChoice.defaultsKey, "modelChoice")
        XCTAssertEqual(ModelChoice.engineVariable, "BENJI_MODEL")
    }

    func testTheTitlesTheUserAskedFor() {
        XCTAssertEqual(ModelChoice.allCases.map(\.title),
                       ["Haiku 5.5 (default, cheapest)", "Sonnet 5.5 (better figures, about 20× the price)"])
    }

    func testTheDefaultSetsNothingSoTheEnginesOwnDefaultRules() {
        XCTAssertNil(ModelChoice.haiku.engineModel)
        XCTAssertEqual(ModelChoice.sonnet.engineModel, "claude-sonnet-5-5")
        XCTAssertNil(ModelChoice.haiku.environmentChange(current: nil, setByApp: nil))
    }

    func testSonnetSetsTheVariableOnce() {
        XCTAssertEqual(ModelChoice.sonnet.environmentChange(current: nil, setByApp: nil), .set("claude-sonnet-5-5"))
        XCTAssertNil(ModelChoice.sonnet.environmentChange(current: "claude-sonnet-5-5", setByApp: "claude-sonnet-5-5"))
        XCTAssertEqual(ModelChoice.sonnet.environmentChange(current: "claude-opus-5-5", setByApp: nil),
                       .set("claude-sonnet-5-5"), "an explicit choice wins over what the app was started with")
    }

    func testBackToTheDefaultClearsOnlyWhatTheAppSet() {
        XCTAssertEqual(ModelChoice.haiku.environmentChange(current: "claude-sonnet-5-5", setByApp: "claude-sonnet-5-5"),
                       .clear)
        XCTAssertNil(ModelChoice.haiku.environmentChange(current: "claude-opus-5-5", setByApp: nil),
                     "a BENJI_MODEL the app was started with is left alone")
    }

    func testOnlyForAnthropic() {
        XCTAssertTrue(ModelChoice.applies(provider: nil))
        XCTAssertTrue(ModelChoice.applies(provider: "claude"))
        XCTAssertFalse(ModelChoice.applies(provider: "openai"))
        XCTAssertFalse(ModelChoice.applies(provider: "localhost:11434"))
    }

    func testTheNoticeSaysWhenItApplies() {
        XCTAssertEqual(ModelChoice.sonnet.notice, "Sonnet 5.5 from your next message.")
    }
}
