import XCTest
@testable import BenjiCore

final class EngineEventTests: XCTestCase {
    func testParsesApprovalWithActionAndTarget() {
        let line = "\u{1}BENJI-APPROVE\u{1}run a potentially destructive shell command: rm -rf build\u{1}"
        guard case let .approval(action, target) = EngineEventParser.parse(line) else {
            return XCTFail("expected approval")
        }
        XCTAssertEqual(action, "run a potentially destructive shell command")
        XCTAssertEqual(target, "rm -rf build")
    }

    func testParsesApprovalWithoutColon() {
        let line = "\u{1}BENJI-APPROVE\u{1}run the Shortcut 'Pay Rent'\u{1}"
        guard case let .approval(action, target) = EngineEventParser.parse(line) else {
            return XCTFail("expected approval")
        }
        XCTAssertEqual(action, "run the Shortcut 'Pay Rent'")
        XCTAssertEqual(target, "")
    }

    func testParsesToolEvent() {
        let line = "\u{1}BENJI-EVENT\u{1}{\"type\":\"tool\",\"name\":\"list_dir\",\"detail\":\".\"}\u{1}"
        XCTAssertEqual(EngineEventParser.parse(line), .tool(name: "list_dir", detail: "."))
    }

    func testParsesAnswerEvent() {
        let line = "\u{1}BENJI-EVENT\u{1}{\"type\":\"answer\",\"text\":\"Done.\"}\u{1}"
        XCTAssertEqual(EngineEventParser.parse(line), .answer("Done."))
    }

    func testParsesErrorEvent() {
        let line = "\u{1}BENJI-EVENT\u{1}{\"type\":\"error\",\"text\":\"boom\"}\u{1}"
        XCTAssertEqual(EngineEventParser.parse(line), .error("boom"))
    }

    func testPlainLineIsRaw() {
        XCTAssertEqual(EngineEventParser.parse("Benji 0.1.0 · provider=claude"),
                       .raw("Benji 0.1.0 · provider=claude"))
    }

    func testMalformedEventFallsBackToRaw() {
        let line = "\u{1}BENJI-EVENT\u{1}not json\u{1}"
        XCTAssertEqual(EngineEventParser.parse(line), .raw(line))
    }
}
