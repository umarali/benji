import XCTest
@testable import BenjiCore

final class ApprovalPolicyTests: XCTestCase {
    func testReturnAndEscapeMeanNo() {
        XCTAssertEqual(ApprovalPolicy.choice(keyCode: 36, command: false, otherModifiers: false), .no)
        XCTAssertEqual(ApprovalPolicy.choice(keyCode: 76, command: false, otherModifiers: false), .no, "keypad Enter")
        XCTAssertEqual(ApprovalPolicy.choice(keyCode: 53, command: false, otherModifiers: false), .no)
        XCTAssertEqual(ApprovalPolicy.choice(keyCode: 53, command: true, otherModifiers: false), .no, "⌘Escape is still No")
    }

    func testOnlyCommandReturnMeansYes() {
        XCTAssertEqual(ApprovalPolicy.choice(keyCode: 36, command: true, otherModifiers: false), .yes)
        XCTAssertEqual(ApprovalPolicy.choice(keyCode: 76, command: true, otherModifiers: false), .yes)
        XCTAssertEqual(ApprovalPolicy.choice(keyCode: 36, command: true, otherModifiers: true), .no, "⌘⇧Return is not Yes")
        XCTAssertEqual(ApprovalPolicy.choice(keyCode: 36, command: false, otherModifiers: true), .no, "⇧Return is No")
    }

    func testOtherKeysAreNotTheCards() {
        XCTAssertNil(ApprovalPolicy.choice(keyCode: 16, command: false, otherModifiers: false), "y types into the composer")
        XCTAssertNil(ApprovalPolicy.choice(keyCode: 49, command: false, otherModifiers: false), "Space")
        XCTAssertNil(ApprovalPolicy.choice(keyCode: 48, command: false, otherModifiers: false), "Tab moves focus")
    }

    func testTimedOutWording() {
        XCTAssertEqual(ApprovalPolicy.timedOutLine, "Timed out, so I didn't do it.")
        XCTAssertEqual(ApprovalPolicy.timedOutRecord(action: "Move 12 files"), "Timed out, so I didn't do it: Move 12 files")
    }

    func testAdjustPrefillsTheActionAndTarget() {
        let req = ApprovalRequest(id: "1", action: "Move 12 files to Archive", target: "~/Desktop/*.png")
        XCTAssertEqual(ApprovalPolicy.adjustText(for: req), "Move 12 files to Archive: ~/Desktop/*.png")
        XCTAssertEqual(ApprovalPolicy.adjustText(for: ApprovalRequest(id: "2", action: " Send the email ", target: "")),
                       "Send the email")
        XCTAssertEqual(ApprovalPolicy.adjustText(for: ApprovalRequest(id: "3", action: "", target: "rm -rf build")),
                       "rm -rf build")
    }

    func testTimeoutEndsBeforeTheEngines() {
        XCTAssertEqual(ServeProtocol.approvalTimeout(engineTimeout: nil), 60)
        XCTAssertEqual(ServeProtocol.approvalTimeout(engineTimeout: 300), 60)
        XCTAssertLessThan(ServeProtocol.approvalTimeout(engineTimeout: 30), 30)
    }

    func testTheCardSaysUpFrontThatNoAnswerMeansNo() {
        XCTAssertEqual(ApprovalPolicy.expiryLine(timeout: 55), "No answer in 55 s means No.")
        XCTAssertEqual(ApprovalPolicy.expiryLine(timeout: ServeProtocol.approvalTimeout(engineTimeout: 90)),
                       "No answer in 60 s means No.")
        XCTAssertEqual(ApprovalPolicy.expiryLine(timeout: 0.2), "No answer in 1 s means No.")
    }

    /// A long command or a whole AppleScript is on the card in full: closed it shows three lines
    /// and offers "Show all" (the 2026-11-01 security review §(c) 5 and 10).
    func testALongTargetCanBeOpenedOnTheCard() {
        XCTAssertFalse(ApprovalPolicy.targetNeedsOpening("rm -rf build"))
        XCTAssertTrue(ApprovalPolicy.targetNeedsOpening("tell application \"Notes\"\nset x to 1\nget x\nend tell"))
        XCTAssertTrue(ApprovalPolicy.targetNeedsOpening(String(repeating: "a", count: 161)))
        XCTAssertEqual(ApprovalPolicy.collapsedTargetLines, 3)
    }
}
