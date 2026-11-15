import XCTest
@testable import BenjiApp
import BenjiCore

/// App offers through the real CompanionModel and a fake backend: the card answers,
/// Try it only fills the message box, and anything else wanting the notch withdraws the offer.
final class CompanionModelAppOfferTests: XCTestCase {
    typealias StepBackend = CompanionModelScreenStepTests.StepBackend

    var backend: StepBackend!
    var model: CompanionModel!
    var answers: [(AppOffer, AppOfferAnswer)] = []
    var openedForTyping = 0
    let offer = AppOfferCatalog.offer(for: "com.apple.iCal")!

    override func setUp() {
        backend = StepBackend()
        let suite = UserDefaults(suiteName: "benji-offer-tests-\(UUID().uuidString)")!
        model = CompanionModel(backend: backend, screenMode: ScreenModeStore(defaults: suite))
        answers = []
        openedForTyping = 0
        model.onAppOfferAnswered = { [unowned self] in answers.append(($0, $1)) }
        model.onOpenForTyping = { [unowned self] in openedForTyping += 1 }
    }

    func testAnOfferWaitsForAnAnswer() {
        model.showAppOffer(offer)
        XCTAssertEqual(model.appOffer, offer)
        XCTAssertTrue(answers.isEmpty)
    }

    func testNoAndNotNowPutNothingInTheMessageBox() {
        for answer in [AppOfferAnswer.no, .notNow] {
            model.showAppOffer(offer)
            model.answerAppOffer(answer)
            XCTAssertNil(model.appOffer)
            XCTAssertEqual(answers.last?.1, answer)
            XCTAssertEqual(model.composerText, "")
            XCTAssertEqual(openedForTyping, 0)
        }
    }

    func testTryItFillsTheMessageBoxAndSendsNothing() {
        model.showAppOffer(offer)
        model.answerAppOffer(.tryIt)
        XCTAssertEqual(model.composerText, offer.examples[0])
        XCTAssertEqual(openedForTyping, 1)
        XCTAssertEqual(model.state.phase, .idle, "nothing was sent")
        XCTAssertTrue(model.state.lines.isEmpty, "nothing was sent")
    }

    func testPickingARowFillsTheMessageBoxWithThatRow() {
        model.showAppOffer(offer)
        model.answerAppOffer(.tryIt, example: offer.examples[2])
        XCTAssertEqual(model.composerText, offer.examples[2])
    }

    func testNoOfferAppearsOverAnOpenPanel() {
        model.setExpanded(true)
        model.showAppOffer(offer)
        XCTAssertNil(model.appOffer)
    }

    func testOpeningThePanelWithdrawsTheOffer() {
        model.showAppOffer(offer)
        model.setExpanded(true)
        model.withdrawAppOfferIfBusy()
        XCTAssertNil(model.appOffer)
        XCTAssertEqual(answers.last?.1, .notNow)
    }

    func testAnAnswerWithNoOfferDoesNothing() {
        model.answerAppOffer(.tryIt)
        XCTAssertTrue(answers.isEmpty)
        XCTAssertEqual(model.composerText, "")
    }
}
