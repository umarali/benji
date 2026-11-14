import XCTest
@testable import BenjiCore

/// Saved conversations (D-121): what is kept of the panel, titles, what a reopened conversation
/// sends to the engine, and the folder itself (order, permissions, real deletion).
final class ConversationStoreTests: XCTestCase {
    var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("benji-store-\(UUID().uuidString)")
            .appendingPathComponent("conversations")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder.deletingLastPathComponent())
    }

    static func sampleURL() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("conversation-sample.json")
    }

    func conversation(_ title: String, updated: TimeInterval, started: TimeInterval? = nil,
                      lines: [SavedLine] = [SavedLine(role: .user, text: "q"), SavedLine(role: .assistant, text: "a")])
    -> SavedConversation {
        SavedConversation(id: ConversationStore.newID(), title: title,
                          started: Date(timeIntervalSince1970: started ?? updated),
                          updated: Date(timeIntervalSince1970: updated), lines: lines)
    }

    // MARK: what is kept

    func testOnlyTheConversationIsKeptNeverToolStepsOrScreenshots() {
        let lines = [
            TranscriptLine(role: .user, text: "  tidy my desktop "),
            TranscriptLine(role: .attachment, text: "Screen attached · sent to Anthropic", attachmentID: "x"),
            TranscriptLine(role: .tool, text: "run_shell ls ~/Desktop"),
            TranscriptLine(role: .system, text: "Approved: move files"),
            TranscriptLine(role: .assistant, text: "Moved 12 files into Desktop/Old."),
            TranscriptLine(role: .error, text: "Cut off before it finished."),
            TranscriptLine(role: .assistant, text: "   "),
        ]
        // Each saved line keeps its time (D-133, for the date lines).
        XCTAssertEqual(SavedConversation.lines(from: lines), [
            SavedLine(role: .user, text: "tidy my desktop", at: lines[0].at),
            SavedLine(role: .system, text: "Approved: move files", at: lines[3].at),
            SavedLine(role: .assistant, text: "Moved 12 files into Desktop/Old.", at: lines[4].at),
            SavedLine(role: .error, text: "Cut off before it finished.", at: lines[5].at),
        ])
    }

    func testNothingIsSavedUntilThereIsAnAnswer() {
        XCTAssertFalse(SavedConversation.worthSaving([]))
        XCTAssertFalse(SavedConversation.worthSaving([SavedLine(role: .user, text: "hi"),
                                                      SavedLine(role: .error, text: "No API key")]))
        XCTAssertTrue(SavedConversation.worthSaving([SavedLine(role: .user, text: "hi"),
                                                     SavedLine(role: .assistant, text: "Hey.")]))
    }

    func testSavedLinesComeBackAsPanelLines() {
        let back = SavedConversation.lines(from: [TranscriptLine(role: .user, text: "a"),
                                                  TranscriptLine(role: .assistant, text: "b")])
            .map(\.transcriptLine)
        XCTAssertEqual(back.map(\.role), [.user, .assistant])
        XCTAssertEqual(back.map(\.text), ["a", "b"])
    }

    // MARK: titles

    func testTheTitleIsTheFirstRealQuestionShortened() {
        let lines: [SavedLine] = [.init(role: .user, text: "Hey Benji"), .init(role: .assistant, text: "Hey."),
                                  .init(role: .user, text: "what's on my calendar tomorrow?")]
        XCTAssertEqual(ConversationTitle.make(lines), "What's on my calendar tomorrow?")
        XCTAssertEqual(ConversationTitle.make([.init(role: .user, text: "hello")]), "Hello", "only a greeting: that")
        XCTAssertEqual(ConversationTitle.make([.init(role: .assistant, text: "x")]), ConversationTitle.untitled)
    }

    func testLongTitlesAreCutAtAWord() {
        let t = ConversationTitle.shorten("plan a weekend in Lisbon for two, mid-November, not too touristy please")
        XCTAssertEqual(t, "Plan a weekend in Lisbon for two, mid-November…")
        XCTAssertLessThanOrEqual(t.count, ConversationTitle.maxLength)
        XCTAssertEqual(ConversationTitle.shorten("rename\n\nthese   files."), "Rename these files")
        let word = String(repeating: "x", count: 80)
        XCTAssertEqual(ConversationTitle.shorten(word).count, ConversationTitle.maxLength, "one long word is cut too")
        XCTAssertTrue(ConversationTitle.isGreeting("Good morning, Benji!"))
        XCTAssertFalse(ConversationTitle.isGreeting("hi can you check my mail"))
        // "Hey Benji" as speech recognition hears it is still a greeting.
        XCTAssertTrue(ConversationTitle.isGreeting("Hey clicky"))
        XCTAssertTrue(ConversationTitle.isGreeting("Hey chili."))
        XCTAssertEqual(ConversationTitle.make([.init(role: .user, text: "Hey clicky"),
                                               .init(role: .user, text: "How does Tesla's new Roadster fly?")]),
                       "How does Tesla's new Roadster fly?")
    }

    func testTheSharedSampleMatchesTheTitleRule() throws {
        let sample = try ConversationStore.decoder.decode(SavedConversation.self, from: Data(contentsOf: Self.sampleURL()))
        XCTAssertEqual(ConversationTitle.make(sample.lines), sample.title)
        XCTAssertEqual(sample.version, SavedConversation.formatVersion)
        XCTAssertTrue(ConversationStore.isValidID(sample.id))
    }

    // MARK: what a reopened conversation sends

    func testAReopenedConversationSendsItsAnsweredExchanges() throws {
        let sample = try ConversationStore.decoder.decode(SavedConversation.self, from: Data(contentsOf: Self.sampleURL()))
        let memory = sample.memory
        XCTAssertEqual(memory.exchanges.map(\.user), ["hey", "Plan a weekend in Lisbon for two, mid-November, not too touristy"],
                       "the cut-off \"save that\" has no answer and isn't sent")
        XCTAssertEqual(memory.exchanges.last?.assistant.hasPrefix("Stay in Graça"), true)
        XCTAssertFalse(memory.droppedEarlier)
    }

    func testAReopenedConversationKeepsTheLiveBudget() {
        var lines: [SavedLine] = []
        var live = ConversationMemory()
        for i in 0..<30 {
            let q = "question \(i) " + String(repeating: "q", count: 600)
            let a = "answer \(i) " + String(repeating: "a", count: 900)
            lines += [SavedLine(role: .user, text: q), SavedLine(role: .assistant, text: a)]
            live.record(user: q, assistant: a)
        }
        let reopened = conversation("long", updated: 0, lines: lines).memory
        XCTAssertEqual(reopened, live, "exactly what the panel would have kept had it stayed open")
        XCTAssertTrue(reopened.droppedEarlier)
        XCTAssertLessThan(reopened.exchanges.count, 30)
    }

    // MARK: the folder

    func testSaveListLoadNewestFirst() throws {
        let store = ConversationStore(directory: folder)
        let old = conversation("Old", updated: 100)
        let new = conversation("New", updated: 300)
        let mid = conversation("Mid", updated: 200)
        for c in [old, new, mid] { try store.save(c) }
        XCTAssertEqual(store.list().map(\.title), ["New", "Mid", "Old"])
        XCTAssertEqual(store.load(mid.id), mid)
        var changed = old
        changed.updated = Date(timeIntervalSince1970: 400)
        changed.lines.append(SavedLine(role: .user, text: "more"))
        try store.save(changed)
        XCTAssertEqual(store.list().map(\.title), ["Old", "New", "Mid"], "carrying on moves it to the top")
        XCTAssertEqual(store.list().first?.messages, 2)
    }

    func testTheFolderAndFilesAreTheUsersOnly() throws {
        let store = ConversationStore(directory: folder)
        let c = conversation("Private", updated: 1)
        try store.save(c)
        let dir = try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int
        let file = try FileManager.default.attributesOfItem(atPath: store.url(c.id).path)[.posixPermissions] as? Int
        XCTAssertEqual(dir, 0o700)
        XCTAssertEqual(file, 0o600)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".tmp") }
        XCTAssertEqual(leftovers, [], "the write goes through a temporary file renamed over the old one")
    }

    func testDeletionIsRealAndLeavesOtherFilesAlone() throws {
        let store = ConversationStore(directory: folder)
        let a = conversation("A", updated: 1), b = conversation("B", updated: 2)
        try store.save(a)
        try store.save(b)
        let notes = folder.appendingPathComponent("notes.txt")
        try "mine".write(to: notes, atomically: true, encoding: .utf8)
        try store.delete(a.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(a.id).path))
        XCTAssertNil(store.load(a.id))
        XCTAssertEqual(try store.deleteAll(), 1)
        XCTAssertEqual(store.list(), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: notes.path))
    }

    func testIdsCantNameAPathAndBrokenFilesAreSkipped() throws {
        let store = ConversationStore(directory: folder)
        XCTAssertFalse(ConversationStore.isValidID("../memory"))
        XCTAssertNil(store.load("../memory"))
        XCTAssertThrowsError(try store.save(SavedConversation(id: "../x", title: "", started: Date(), updated: Date(), lines: [])))
        try store.save(conversation("Fine", updated: 1))
        try "{".write(to: folder.appendingPathComponent("\(UUID().uuidString).json"), atomically: true, encoding: .utf8)
        XCTAssertEqual(store.list().map(\.title), ["Fine"])
        XCTAssertEqual(ConversationStore(directory: folder.appendingPathComponent("missing")).list(), [])
    }

    func testTheStandardFolderIsBesideTheEnginesFiles() {
        let home = URL(fileURLWithPath: "/Users/someone")
        XCTAssertEqual(ConversationStore.standard(home: home).directory.path, "/Users/someone/.benji/conversations")
        XCTAssertEqual(ProfileMemory.standardURL(home: home).path, "/Users/someone/.benji/memory.jsonl")
    }

    // MARK: opening one in the panel

    func testOpeningReplacesThePanelOnlyWhileNothingRuns() {
        var s = CompanionState()
        reduce(&s, .submitText("first"))
        reduce(&s, .assistantAnswer("one"))
        let saved = [TranscriptLine(role: .user, text: "old"), TranscriptLine(role: .assistant, text: "reply")]
        reduce(&s, .openConversation(saved))
        XCTAssertEqual(s.lines.map(\.text), ["first", "one"], "thinking: ignored")
        reduce(&s, .backendFinished(0))
        reduce(&s, .openConversation(saved))
        XCTAssertEqual(s.lines, saved)
        XCTAssertEqual(s.turns, [])
        reduce(&s, .micStarted)
        reduce(&s, .openConversation([]))
        XCTAssertEqual(s.lines, [])
        XCTAssertEqual(s.phase, .listening, "a listening mic stays on")
        reduce(&s, .backendError("oops"))
        reduce(&s, .openConversation(saved))
        XCTAssertEqual(s.phase, .idle)
        XCTAssertNil(s.lastError)
    }
}

/// Two conversations saved within one millisecond still order newest first after a round trip
/// through disk (the merge found `testNewConversationStartsANewOne` flaky without this).
final class ConversationSaveTimeTests: XCTestCase {
    func testTheConversationJustUsedIsNewerEvenWithinOneMillisecond() throws {
        let t = Date(timeIntervalSince1970: 1_761_930_000.123_456)
        let first = ConversationStore.saveTime(t, after: nil)
        let second = ConversationStore.saveTime(t.addingTimeInterval(0.0001), after: first)
        XCTAssertGreaterThan(second, first)
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("benji-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = ConversationStore(directory: parent.appendingPathComponent("conversations"))
        let lines = [SavedLine(role: .user, text: "a"), SavedLine(role: .assistant, text: "b")]
        try store.save(SavedConversation(id: ConversationStore.newID(), title: "First", started: first, updated: first, lines: lines))
        try store.save(SavedConversation(id: ConversationStore.newID(), title: "Second", started: second, updated: second, lines: lines))
        XCTAssertEqual(store.list().map(\.title), ["Second", "First"])
    }

    func testAnEarlierClockStillSavesAfterTheNewest() {
        let newest = Date(timeIntervalSince1970: 1_761_930_000.500)
        let at = ConversationStore.saveTime(newest.addingTimeInterval(-5), after: newest)
        XCTAssertGreaterThan(at, ConversationStore.onMillisecond(newest))
    }
}
