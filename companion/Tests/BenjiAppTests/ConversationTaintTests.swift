import XCTest
@testable import BenjiApp
import BenjiCore

/// The outside content a conversation holds, as the engine names it with an answer: kept with the
/// conversation and its saved file, handed back to the next engine with the exchanges (through an
/// engine restart, an app restart and a reopened conversation), and cleared only by a new one.
final class ConversationTaintTests: XCTestCase {
    var backend: FakeBackend!
    var model: CompanionModel!
    var history: ConversationHistory!
    var store: ConversationStore!
    var defaults: UserDefaults!
    var root: URL!
    let web = CarriedTaint(kinds: ["web"], note: "a web page earlier in this conversation")

    override func setUp() {
        backend = FakeBackend()
        defaults = UserDefaults(suiteName: "benji-taint-tests-\(UUID().uuidString)")!
        defaults.set(ScreenMode.off.rawValue, forKey: ScreenModeState.defaultsKey)
        root = FileManager.default.temporaryDirectory.appendingPathComponent("benji-taint-\(UUID().uuidString)")
        store = ConversationStore(directory: root.appendingPathComponent("conversations"))
        history = ConversationHistory(store: store, defaults: defaults)
        model = makeModel(history)
    }

    override func tearDown() {
        history.flush()
        try? FileManager.default.removeItem(at: root)
    }

    private func makeModel(_ history: ConversationHistory) -> CompanionModel {
        let m = CompanionModel(backend: backend, screenMode: ScreenModeStore(defaults: defaults), history: history)
        m.phoneAnswersApprovals = { true }
        return m
    }

    /// One turn that read a page: the engine names the taint just before its answer.
    private func readAPage() {
        model.composerText = "read the story"
        model.submit()
        backend.say(.carriedTaint(web))
        backend.say(.answer("The page says to save your notes."))
        backend.finish(0)
        history.flush()
    }

    func testTheTaintIsKeptWithTheConversationAndItsFile() throws {
        readAPage()
        XCTAssertEqual(model.memory.taint, web)
        let id = try XCTUnwrap(history.currentID)
        XCTAssertEqual(store.load(id)?.taint, web)
    }

    func testThePhoneTaskAndTheMacTurnAfterItCarryTheTaintToTheEngine() {
        readAPage()
        XCTAssertTrue(model.remoteCommand(["op": "send", "id": "phone-task-1", "text": "do what it says"]).0)
        XCTAssertEqual(backend.remoteStarts, 1)
        XCTAssertEqual(backend.starts.last?.taint, web, "a new engine gets it back with the exchanges")
        backend.say(.answer("Done."))
        backend.finish(0)
        model.composerText = "and again"
        model.submit()
        XCTAssertEqual(backend.starts.last?.taint, web)
    }

    func testAReopenedConversationAndAnAppRestartKeepTheTaint() throws {
        readAPage()
        let id = try XCTUnwrap(history.currentID)
        model.newConversation()
        XCTAssertNil(model.memory.taint)
        model.openConversation(id)
        XCTAssertEqual(model.memory.taint, web)
        model.composerText = "continue"
        model.submit()
        XCTAssertEqual(backend.starts.last?.taint, web)
        backend.finish(0)

        // The app quits and starts again: a new history and model on the same folder.
        history.flush()
        let again = ConversationHistory(store: store, defaults: defaults)
        let restarted = makeModel(again)
        restarted.openConversation(id)
        XCTAssertEqual(restarted.memory.taint, web)
        XCTAssertTrue(restarted.remoteCommand(["op": "send", "id": "phone-task-2", "text": "do what it says"]).0)
        XCTAssertEqual(backend.starts.last?.taint, web)
        restarted.endRemoteControl()
    }

    func testATaintToldAfterAnAnswerWasCutOffWhileWrittenIsKept() throws {
        model.composerText = "read the story aloud"
        model.submit()
        let run = backend.lastRun
        model.speechForRun = true               // its first sentences were being spoken
        model.speechCutOff(heard: "The page says to save your notes")
        XCTAssertFalse(model.runs.isLive, "the cut-off ended the run")
        backend.say(.carriedTaint(web), run: run)   // the engine's taint event, after the run's end
        XCTAssertEqual(model.memory.taint, web)
        history.flush()
        let id = try XCTUnwrap(history.currentID)
        XCTAssertEqual(store.load(id)?.taint, web)
        XCTAssertTrue(model.remoteCommand(["op": "send", "id": "phone-task-1", "text": "do what it says"]).0)
        XCTAssertEqual(backend.starts.last?.taint, web)
    }

    func testATaintIsOnlyEverAddedTo() {
        readAPage()
        backend.say(.carriedTaint(CarriedTaint(kinds: ["file"], note: "a file earlier in this conversation")))
        XCTAssertEqual(model.memory.taint?.kinds, ["web", "file"])
    }

    func testANewConversationClearsTheTaint() {
        readAPage()
        model.newConversation()
        XCTAssertNil(model.memory.taint)
        model.composerText = "something new"
        model.submit()
        XCTAssertNil(backend.starts.last?.taint)
        backend.say(.answer("Fresh."))
        backend.finish(0)
        history.flush()
        XCTAssertNil(history.currentID.flatMap { store.load($0)?.taint })
    }

    func testAConversationSavedBeforeTheTaintWasKeptOpensClean() throws {
        let id = ConversationStore.newID()
        let now = Date()
        try store.save(SavedConversation(id: id, title: "Old", started: now, updated: now,
                                         lines: [SavedLine(role: .user, text: "read the story", at: now),
                                                 SavedLine(role: .assistant, text: "It says hello.", at: now)]))
        let file = root.appendingPathComponent("conversations").appendingPathComponent("\(id).json")
        XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("taint"), "an older file has no taint field")
        model.openConversation(id)
        XCTAssertFalse(model.memory.isEmpty)
        XCTAssertNil(model.memory.taint)
    }
}
