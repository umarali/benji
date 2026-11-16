import XCTest
@testable import BenjiCore

/// The taint a conversation carries, on the engine's pipe and in the saved file, and who answered an approval.
final class CarriedTaintTests: XCTestCase {
    private func text(_ r: ServeRequest) -> String { String(decoding: r.line(), as: UTF8.self) }
    let web = CarriedTaint(kinds: ["web"], note: "a web page earlier in this conversation")

    func testAnAnswerNamesTheTaintAndAPlainOneNamesNone() {
        let tainted = #"{"type":"answer","id":"t1","text":"Done.","targets":[],"taints":["web"],"taint_note":"a web page earlier in this conversation"}"#
        XCTAssertEqual(ServeEvent.decode(tainted), .answer(id: "t1", text: "Done.", targets: [], taint: web))
        XCTAssertEqual(ServeEvent.decode(#"{"type":"answer","id":"t1","text":"Done.","targets":[]}"#),
                       .answer(id: "t1", text: "Done.", targets: [], taint: nil))
    }

    func testRestoreGivesTheTaintBackAndAClearOneSaysNothing() {
        let line = text(.restore([.init(user: "u", assistant: "a")], taint: web))
        XCTAssertTrue(line.contains(#""taints":["web"]"#))
        XCTAssertTrue(line.contains(#""taint_note":"a web page earlier in this conversation""#))
        XCTAssertFalse(text(.restore([.init(user: "u", assistant: "a")])).contains("taint"))
    }

    func testTheSavedFileKeepsTheTaintAndAnOlderFileIsClean() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let saved = SavedConversation(id: "A", title: "T", started: now, updated: now,
                                      lines: [SavedLine(role: .user, text: "q"), SavedLine(role: .assistant, text: "a")], taint: web)
        let data = try JSONEncoder().encode(saved)
        let back = try JSONDecoder().decode(SavedConversation.self, from: data)
        XCTAssertEqual(back.taint, web)
        XCTAssertEqual(back.memory.taint, web)
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        old["taint"] = nil
        let older = try JSONDecoder().decode(SavedConversation.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertNil(older.taint)
        XCTAssertNil(older.memory.taint)
    }

    func testANewConversationClearsTheTaint() {
        var memory = ConversationMemory()
        memory.record(user: "q", assistant: "a")
        memory.taint = web
        memory.clear()
        XCTAssertNil(memory.taint)
    }

    func testAJobsThreadCarriesWhatTheJobReadButNotTheScreen() {
        func job(_ tainted: Bool, _ taint: String) -> JobSnapshot {
            JobSnapshot(id: UUID().uuidString, title: "J", state: .done, tainted: tainted, taint: taint)
        }
        XCTAssertEqual(JobThread.taint(of: job(true, "screen+web"))?.kinds, ["web"])
        XCTAssertNil(JobThread.taint(of: job(true, "screen")))
        XCTAssertNil(JobThread.taint(of: job(false, "")))
        XCTAssertEqual(JobThread.taint(of: job(true, ""))?.kinds, ["file"])
    }

    func testAnAnswerSaysWhoGaveItAndOnlyTheCardSaysCard() {
        XCTAssertEqual(text(.approve(id: "t1", request: "a1", approved: true, viaCard: true)),
                       #"{"decision":"yes","id":"t1","request":"a1","type":"approve","via":"card"}"# + "\n")
        XCTAssertEqual(text(.approve(id: "t1", request: "a1", approved: true, viaCard: false, source: .phone)),
                       #"{"decision":"yes","from":"phone","id":"t1","request":"a1","type":"approve"}"# + "\n")
        XCTAssertEqual(text(.approve(id: "t1", request: "a1", approved: false, viaCard: false, source: .timeout)),
                       #"{"decision":"no","from":"timeout","id":"t1","request":"a1","type":"approve"}"# + "\n")
    }
}
