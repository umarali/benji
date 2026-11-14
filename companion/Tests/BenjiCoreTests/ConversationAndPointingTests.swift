import XCTest
@testable import BenjiCore

final class ConversationAndPointingTests: XCTestCase {
    func testMemoryKeepsShortExchangesPastTenAndSkipsEmpty() throws {
        var m = ConversationMemory()
        m.record(user: "  ", assistant: "x")
        XCTAssertTrue(m.isEmpty)
        for i in 0..<12 { m.record(user: "q\(i)", assistant: "a\(i)") }
        XCTAssertEqual(m.exchanges.count, 12, "all 12 fit the budget")
        XCTAssertEqual(m.exchanges.first?.user, "q0")
        let json = try JSONSerialization.jsonObject(with: m.jsonData()) as? [[String: String]]
        XCTAssertEqual(json?.last, ["user": "q11", "assistant": "a11"])
        m.clear()
        XCTAssertTrue(m.isEmpty)
    }

    func testNewConversationClearsOnlyWhenIdle() {
        var s = CompanionState()
        reduce(&s, .submitText("hi"))
        reduce(&s, .newConversation)
        XCTAssertEqual(s.lines.count, 1, "ignored while working")
        reduce(&s, .assistantAnswer("hello"))
        reduce(&s, .backendFinished(0))
        reduce(&s, .newConversation)
        XCTAssertTrue(s.lines.isEmpty)
        XCTAssertEqual(s.phase, .idle)
    }

    func testPointTagParsedAndStripped() {
        let r = PointingTag.parse("Click Share, top right. [POINT:1180,42:Share button]")
        XCTAssertEqual(r.text, "Click Share, top right.")
        XCTAssertEqual(r.target, PointTarget(x: 1180, y: 42, label: "Share button"))
    }

    func testPointTagWithoutLabelAndNoTag() {
        XCTAssertEqual(PointingTag.parse("Here. [POINT:10, 20]").target, PointTarget(x: 10, y: 20, label: ""))
        let none = PointingTag.parse("Nothing to point at.")
        XCTAssertEqual(none.text, "Nothing to point at.")
        XCTAssertNil(none.target)
        XCTAssertNil(PointingTag.parse("[POINT:1,2:x] then more text").target, "only a trailing tag counts")
    }

    func testMappingToScreenPoints() {
        // 1512x982-pt display sent as a 1568x1018 image; external display offset left and up.
        let builtIn = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let p = PointMapping.screenPoint(for: PointTarget(x: 784, y: 509, label: ""),
                                         pixelSize: CGSize(width: 1568, height: 1018), screenFrame: builtIn)
        XCTAssertEqual(p!.x, 756, accuracy: 0.5)
        XCTAssertEqual(p!.y, 491, accuracy: 0.5)   // flipped: top-left pixels → bottom-left points

        let external = CGRect(x: -205, y: 982, width: 1920, height: 1080)
        let top = PointMapping.screenPoint(for: PointTarget(x: 0, y: 0, label: ""),
                                           pixelSize: CGSize(width: 1568, height: 882), screenFrame: external)
        XCTAssertEqual(top, CGPoint(x: -205, y: 2062))
        XCTAssertNil(PointMapping.screenPoint(for: PointTarget(x: 2000, y: 5, label: ""),
                                              pixelSize: CGSize(width: 1568, height: 882), screenFrame: external))
    }
}
