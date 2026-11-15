import XCTest
@testable import BenjiCore

/// The memory budget: the shared cases in Tests/history-cases.json are also run by selftest.py
/// against benji/history.py and serve.py's trimmed(): both sides keep the same exchanges.
final class HistoryBudgetTests: XCTestCase {
    /// One side of an exchange: that many "x", or `repeat` written `times` times.
    enum Text: Decodable {
        case count(Int)
        case repeated(String, Int)

        private enum Keys: String, CodingKey { case `repeat`, times }

        init(from decoder: Decoder) throws {
            if let n = try? decoder.singleValueContainer().decode(Int.self) {
                self = .count(n)
                return
            }
            let c = try decoder.container(keyedBy: Keys.self)
            self = .repeated(try c.decode(String.self, forKey: .repeat), try c.decode(Int.self, forKey: .times))
        }

        var string: String {
            switch self {
            case .count(let n): return String(repeating: "x", count: n)
            case let .repeated(s, n): return String(repeating: s, count: n)
            }
        }
    }

    /// `keep`: chosen from all of them at once. `keepOneAtATime`: recorded one by one, choosing
    /// after each, as the app records them (a drop goes down to three quarters of the budget, so
    /// what is kept depends on what was kept before).
    struct Case: Decodable {
        let name: String
        let exchanges: [[Text]]
        let keep: Int
        let keepOneAtATime: Int

        enum CodingKeys: String, CodingKey {
            case name, exchanges, keep
            case keepOneAtATime = "keep_one_at_a_time"
        }
    }

    static func cases() throws -> [Case] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("history-cases.json")
        return try JSONDecoder().decode([Case].self, from: Data(contentsOf: url))
    }

    func testSharedCasesKeepTheSameExchangesAsPython() throws {
        let cases = try Self.cases()
        XCTAssertGreaterThanOrEqual(cases.count, 10)
        for c in cases {
            let all = c.exchanges.map { ConversationMemory.Exchange(user: $0[0].string, assistant: $0[1].string) }
            XCTAssertEqual(ConversationMemory.keptCount(sizes: all.map(ConversationMemory.size)), c.keep, c.name)
            var m = ConversationMemory()
            for e in all { m.record(user: e.user, assistant: e.assistant) }
            XCTAssertEqual(m.exchanges, Array(all.suffix(c.keepOneAtATime)), c.name)
            XCTAssertEqual(m.droppedEarlier, c.keepOneAtATime < all.count, c.name)
            // What the app keeps, the engine keeps as it is (serve `restore`).
            XCTAssertEqual(ConversationMemory.keptCount(sizes: m.exchanges.map(ConversationMemory.size)),
                           m.exchanges.count, c.name)
        }
    }

    func testTheBudgetAndTheFloorMatchTheEngine() {
        XCTAssertEqual(ConversationMemory.historyBudgetChars, 24_000)
        XCTAssertEqual(ConversationMemory.historyTrimToChars, 18_000)
        XCTAssertEqual(ConversationMemory.minimumExchanges, 10)
    }

    func testSizesAreUnicodeScalars() {
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        XCTAssertEqual(family.count, 1)
        XCTAssertEqual(ConversationMemory.size(.init(user: family, assistant: "e\u{301}")), 7)
    }

    func testNewConversationForgetsThatOlderOnesWereDropped() {
        var m = ConversationMemory()
        for _ in 0..<12 { m.record(user: String(repeating: "q", count: 3000), assistant: "a") }
        XCTAssertTrue(m.droppedEarlier)
        XCTAssertEqual(m.exchanges.count, 10)
        m.clear()
        XCTAssertFalse(m.droppedEarlier)
    }

    func testTheRestoreRequestSaysWhenOlderOnesAreGone() throws {
        let one = [ConversationMemory.Exchange(user: "u", assistant: "a")]
        let plain = String(decoding: ServeRequest.restore(one).line(), as: UTF8.self)
        XCTAssertFalse(plain.contains("dropped"))
        let dropped = String(decoding: ServeRequest.restore(one, droppedEarlier: true).line(), as: UTF8.self)
        XCTAssertEqual(dropped, #"{"dropped":true,"exchanges":[{"assistant":"a","user":"u"}],"type":"restore"}"# + "\n")
    }
}
