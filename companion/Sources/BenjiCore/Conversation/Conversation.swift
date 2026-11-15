import Foundation

/// The recent exchanges the app passes to each new engine run (`--history`), so
/// follow-up questions have context. Kept in memory only; "New conversation" clears it.
/// How much is kept: everything while the user+assistant text fits in `historyBudgetChars`; once
/// over, whole exchanges are dropped, oldest first, until the rest fits in `historyTrimToChars`
/// (three quarters of the budget), never below the last `minimumExchanges`. Dropping in a chunk
/// keeps the start of the conversation the same for several turns, so it stays cacheable. The engine keeps the same ones (benji/history.py `kept_count`; shared cases in
/// Tests/history-cases.json). Lengths are Unicode scalars, as Python counts code points.
public struct ConversationMemory: Equatable, Sendable {
    /// User+assistant text of the kept exchanges, about 6,000 tokens (HISTORY_BUDGET_CHARS).
    public static let historyBudgetChars = 24_000
    /// Where a drop stops: three quarters of the budget (HISTORY_TRIM_TO_CHARS).
    public static let historyTrimToChars = historyBudgetChars * 3 / 4
    /// The fewest exchanges kept, even when they are long (MIN_EXCHANGES).
    public static let minimumExchanges = 10

    public struct Exchange: Codable, Equatable, Sendable {
        public let user: String
        public let assistant: String

        public init(user: String, assistant: String) {
            self.user = user
            self.assistant = assistant
        }
    }

    public private(set) var exchanges: [Exchange] = []
    /// Older exchanges of this conversation were dropped; the engine tells the model so.
    public private(set) var droppedEarlier = false

    public init() {}

    public var isEmpty: Bool { exchanges.isEmpty }

    public mutating func record(user: String, assistant: String) {
        let u = user.trimmingCharacters(in: .whitespacesAndNewlines)
        let a = assistant.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !u.isEmpty, !a.isEmpty else { return }
        exchanges.append(Exchange(user: u, assistant: a))
        let kept = Self.keptCount(sizes: exchanges.map(Self.size))
        if kept < exchanges.count {
            exchanges.removeFirst(exchanges.count - kept)
            droppedEarlier = true
        }
    }

    public mutating func clear() {
        exchanges.removeAll()
        droppedEarlier = false
    }

    /// The last answer was cut off: keep `reply` (`CutOffReply.reply`) in its place.
    public mutating func cutOffLast(reply: String) {
        guard let last = exchanges.last else { return }
        let r = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !r.isEmpty else { return }
        exchanges[exchanges.count - 1] = Exchange(user: last.user, assistant: r)
    }

    /// An exchange's user+assistant length in Unicode scalars.
    public static func size(_ exchange: Exchange) -> Int {
        exchange.user.unicodeScalars.count + exchange.assistant.unicodeScalars.count
    }

    /// How many of the newest exchanges to keep, given each one's size, oldest first: all of them
    /// while they fit in `historyBudgetChars`; otherwise as many as fit in `historyTrimToChars`
    /// counting back from the newest (stopping at the first that doesn't), but never fewer than
    /// the last `minimumExchanges`.
    public static func keptCount(sizes: [Int]) -> Int {
        if sizes.reduce(0, +) <= historyBudgetChars { return sizes.count }
        var total = 0, kept = 0
        for size in sizes.reversed() {
            if total + size > historyTrimToChars { break }
            total += size
            kept += 1
        }
        return max(kept, min(minimumExchanges, sizes.count))
    }

    /// The `--history` file format the engine reads: [{"user": "...", "assistant": "..."}].
    public func jsonData() throws -> Data {
        try JSONEncoder().encode(exchanges)
    }
}
