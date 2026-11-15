import Foundation

// Saved conversations: each conversation's panel lines (your messages, Benji's answers, errors
// and approval outcomes; never tool steps or screenshots), kept on this Mac in
// `~/.benji/conversations/<id>.json` so it can be opened and continued later. The folder is the
// user's only (0700) and each file too (0600). The engine reads the same files for the recent
// titles it shows the model as background (benji/conversations.py); the shared sample is
// Tests/conversation-sample.json.

/// One saved line of a conversation.
public struct SavedLine: Codable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable {
        case user, assistant, error, system
    }

    public let role: Role
    public let text: String
    /// When the line was said. Optional and written only when known, so a file without times
    /// still decodes (no time, so no date lines) and the engine, which reads only titles and
    /// dates, ignores it.
    public let at: Date?

    public init(role: Role, text: String, at: Date? = nil) {
        self.role = role
        self.text = text
        self.at = at
    }

    /// The panel line's saved form, or nil for what is never saved (tool steps, screenshots).
    public init?(_ line: TranscriptLine) {
        let role: Role
        switch line.role {
        case .user: role = .user
        case .assistant: role = .assistant
        case .error: role = .error
        case .system: role = .system
        case .tool, .attachment: return nil
        }
        let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        self.init(role: role, text: text, at: line.at)
    }

    /// Back into a panel line (a new identity; the panel never sees the old one).
    public var transcriptLine: TranscriptLine {
        let r: TranscriptRole
        switch role {
        case .user: r = .user
        case .assistant: r = .assistant
        case .error: r = .error
        case .system: r = .system
        }
        return TranscriptLine(role: r, text: text, at: at)
    }
}

/// One conversation as it is stored.
public struct SavedConversation: Codable, Equatable, Sendable {
    public static let formatVersion = 1

    public var version = SavedConversation.formatVersion
    public let id: String
    public var title: String
    public var started: Date
    public var updated: Date
    public var lines: [SavedLine]

    public init(id: String, title: String, started: Date, updated: Date, lines: [SavedLine]) {
        self.id = id
        self.title = title
        self.started = started
        self.updated = updated
        self.lines = lines
    }

    /// What of the panel is saved, in order.
    public static func lines(from transcript: [TranscriptLine]) -> [SavedLine] {
        transcript.compactMap(SavedLine.init)
    }

    /// Worth keeping: at least one answer. A question that never got one isn't a conversation yet,
    /// and nothing is written for it.
    public static func worthSaving(_ lines: [SavedLine]) -> Bool {
        lines.contains { $0.role == .assistant }
    }

    /// The exchanges to hand the engine when this conversation is continued: each message with
    /// the answer that followed it; a message that got no answer is left out, as live (the
    /// budget of `ConversationMemory` applies, exchange by exchange as they happened).
    public var memory: ConversationMemory {
        var memory = ConversationMemory()
        var question: String?
        for line in lines {
            switch line.role {
            case .user:
                question = line.text
            case .assistant:
                if let q = question { memory.record(user: q, assistant: line.text) }
                question = nil
            case .error, .system:
                continue
            }
        }
        return memory
    }

    public var summary: ConversationSummary {
        ConversationSummary(id: id, title: title, started: started, updated: updated,
                            messages: lines.filter { $0.role == .user }.count)
    }
}

/// What the lists show of a conversation.
public struct ConversationSummary: Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let started: Date
    public let updated: Date
    /// Your messages in it.
    public let messages: Int

    public init(id: String, title: String, started: Date, updated: Date, messages: Int) {
        self.id = id
        self.title = title
        self.started = started
        self.updated = updated
        self.messages = messages
    }

    /// Newest first: last changed, then last started, then id, so the order never wobbles.
    public static func newestFirst(_ a: ConversationSummary, _ b: ConversationSummary) -> Bool {
        if a.updated != b.updated { return a.updated > b.updated }
        if a.started != b.started { return a.started > b.started }
        return a.id > b.id
    }
}

// MARK: - Titles

/// A conversation's title: its first question, shortened. No model call.
public enum ConversationTitle {
    public static let maxLength = 48
    public static let untitled = "Untitled conversation"

    /// Openers that say nothing about the topic: a first message made only of these doesn't name
    /// the conversation if a later message does.
    static let greetings: Set<String> = [
        "hey", "hi", "hello", "yo", "hiya", "morning", "evening", "afternoon", "good", "benji", "benjy", "benjie", "there",
        "ok", "okay", "thanks", "thank", "you",
    ]

    /// From the saved lines: the first message that is more than a greeting, else the first one.
    public static func make(_ lines: [SavedLine]) -> String {
        let questions = lines.filter { $0.role == .user }.map(\.text)
        guard let first = questions.first else { return untitled }
        return shorten(questions.first { !isGreeting($0) } ?? first)
    }

    public static func isGreeting(_ text: String) -> Bool {
        let words = text.lowercased().split { !$0.isLetter }.map(String.init)
        return !words.isEmpty && words.count <= 3 && words.allSatisfy(greetings.contains)
    }

    /// One line, at most `maxLength` characters, cut at a word with "…", first letter capitalised,
    /// without a closing full stop or comma.
    public static func shorten(_ text: String) -> String {
        var t = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        while let last = t.last, ".,;:".contains(last) { t.removeLast() }
        guard !t.isEmpty else { return untitled }
        if t.count > maxLength {
            // The space after a word that ends right at the limit counts: that word fits.
            let cut = t.prefix(maxLength)
            var head = cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? ""
            if head.count < maxLength / 2 { head = String(t.prefix(maxLength - 1)) }
            while let last = head.last, " ,.;:-".contains(last) { head.removeLast() }
            t = head + "…"
        }
        return t.prefix(1).uppercased() + t.dropFirst()
    }
}

// MARK: - The store

/// The folder of saved conversations. Plain file reads and writes; the app calls it off the main
/// thread. Unreadable or foreign files are skipped, never deleted by a listing.
public struct ConversationStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// `~/.benji/conversations`, beside the engine's working files (under `BENJI_WORKDIR` when that is set).
    public static func standard(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                environment: [String: String] = ProcessInfo.processInfo.environment) -> ConversationStore {
        ConversationStore(directory: WorkingFolder.url(environment: environment, home: home).appendingPathComponent("conversations"))
    }

    /// Ids are UUIDs, so a file name can never point outside the folder.
    public static func isValidID(_ id: String) -> Bool { UUID(uuidString: id) != nil }

    public static func newID() -> String { UUID().uuidString }

    /// `date` on a whole millisecond, the precision a saved record keeps, so a time held in memory
    /// orders exactly as the one read back from disk. A hair past the millisecond, so a formatter
    /// that truncates and one that rounds write the same digits.
    public static func onMillisecond(_ date: Date) -> Date {
        let ms = (date.timeIntervalSince1970 * 1000).rounded(.down)
        return Date(timeIntervalSince1970: ms / 1000 + 0.0002)
    }

    /// A save time for the conversation just used: `now` on its millisecond, and a millisecond
    /// later than `newestOther` (another conversation's last change) when it would tie with or
    /// precede it, so the one just used is always first, also after a round trip through disk.
    public static func saveTime(_ now: Date, after newestOther: Date?) -> Date {
        let at = onMillisecond(now)
        guard let newestOther else { return at }
        let floor = onMillisecond(newestOther)
        return at > floor ? at : onMillisecond(floor.addingTimeInterval(0.001))
    }

    func url(_ id: String) -> URL { directory.appendingPathComponent(id + ".json") }

    /// ISO 8601 in UTC with milliseconds, so two answers in one second still order; read with or
    /// without them. (ISO8601DateFormatter is thread-safe.)
    static let withMilliseconds: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let wholeSeconds = ISO8601DateFormatter()

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(withMilliseconds.string(from: date))
        }
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = withMilliseconds.date(from: text) ?? wholeSeconds.date(from: text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not ISO 8601: \(text)"))
            }
            return date
        }
        return d
    }()

    /// Every readable conversation, newest first.
    public func list() -> [ConversationSummary] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.compactMap { name -> ConversationSummary? in
            guard name.hasSuffix(".json") else { return nil }
            return load(String(name.dropLast(5)))?.summary
        }
        .sorted(by: ConversationSummary.newestFirst)
    }

    public func load(_ id: String) -> SavedConversation? {
        guard Self.isValidID(id), let data = try? Data(contentsOf: url(id)),
              let c = try? Self.decoder.decode(SavedConversation.self, from: data), c.id == id else { return nil }
        return c
    }

    /// Writes the whole conversation in one step (a new file renamed over the old), readable by
    /// this user only, in a folder only this user can open.
    public func save(_ conversation: SavedConversation) throws {
        guard Self.isValidID(conversation.id) else { throw CocoaError(.fileWriteInvalidFileName) }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let data = try Self.encoder.encode(conversation)
        let temp = directory.appendingPathComponent(".\(conversation.id).\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        if rename(temp.path, url(conversation.id).path) != 0 {
            try? fm.removeItem(at: temp)
            throw CocoaError(.fileWriteUnknown)
        }
    }

    /// Removes the file itself (not to the Trash).
    public func delete(_ id: String) throws {
        guard Self.isValidID(id) else { return }
        let target = url(id)
        if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
    }

    /// Removes every saved conversation; files that aren't conversations are left alone.
    /// Returns how many were removed.
    @discardableResult
    public func deleteAll() throws -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        var removed = 0
        for name in names where name.hasSuffix(".json") && Self.isValidID(String(name.dropLast(5))) {
            try FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            removed += 1
        }
        return removed
    }
}
