import XCTest
@testable import BenjiApp
import BenjiCore

/// Saved conversations through the coordinator: saved as they go, a new conversation
/// starts a new one, a reopened one is continued with its exchanges, the home page shows when it
/// should, and deletion is real.
final class ConversationHistoryTests: XCTestCase {
    var backend: FakeBackend!
    var model: CompanionModel!
    var history: ConversationHistory!
    var store: ConversationStore!
    var defaults: UserDefaults!
    var root: URL!

    override func setUp() {
        backend = FakeBackend()
        defaults = UserDefaults(suiteName: "benji-history-tests-\(UUID().uuidString)")!
        defaults.set(ScreenMode.off.rawValue, forKey: ScreenModeState.defaultsKey)
        root = FileManager.default.temporaryDirectory.appendingPathComponent("benjy-history-\(UUID().uuidString)")
        store = ConversationStore(directory: root.appendingPathComponent("conversations"))
        history = ConversationHistory(store: store, defaults: defaults)
        model = CompanionModel(backend: backend, screenMode: ScreenModeStore(defaults: defaults), history: history)
    }

    override func tearDown() {
        history.flush()
        try? FileManager.default.removeItem(at: root)
    }

    private func turn(_ question: String, _ answer: String) {
        model.composerText = question
        model.submit()
        backend.say(.answer(answer))
        backend.finish(0)
    }

    /// Lets the history's folder read reach the main thread.
    private func settle() {
        history.flush()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    func testAConversationIsSavedAsItGoesUnderOneId() throws {
        model.composerText = "what's the weather in Lahore"
        model.submit()
        history.flush()
        XCTAssertEqual(store.list(), [], "a question with no answer yet isn't saved")
        backend.say(.tool(name: "web_search", detail: "lahore weather"))
        backend.say(.answer("Sunny, 24°C."))
        backend.finish(0)
        turn("and tomorrow?", "Cloudy, 21°C.")
        history.flush()
        let saved = store.list()
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.title, "What's the weather in Lahore")
        XCTAssertEqual(saved.first?.id, history.currentID)
        let lines = try XCTUnwrap(store.load(saved[0].id)).lines
        XCTAssertEqual(lines.map(\.role), [.user, .assistant, .user, .assistant], "no tool steps")
        XCTAssertEqual(history.summaries.map(\.id), saved.map(\.id), "the home list knows at once")
    }

    func testNewConversationStartsANewOne() {
        turn("first topic", "One.")
        let first = history.currentID
        model.newConversation()
        XCTAssertNil(history.currentID)
        turn("second topic", "Two.")
        history.flush()
        XCTAssertNotEqual(history.currentID, first)
        XCTAssertEqual(store.list().map(\.title), ["Second topic", "First topic"])
    }

    func testNewConversationWhileListeningDropsHeardWordsAndClears() {
        turn("first topic", "One.")
        var dropped = 0
        model.onDropHeardWords = { dropped += 1 }
        model.voiceListeningStarted()
        XCTAssertEqual(model.state.phase, .listening)
        XCTAssertTrue(model.canStartNewConversation)
        model.newConversation()
        XCTAssertEqual(dropped, 1)
        XCTAssertTrue(model.state.lines.isEmpty)
        XCTAssertNil(history.currentID)
        XCTAssertEqual(model.state.phase, .idle, "the voice controller reopens the mic for a conversation that is on")
    }

    func testSavingOffWritesNothing() {
        history.setSaving(false)
        XCTAssertFalse(MemorySettings.savesConversations(defaults.object(forKey: MemorySettings.saveKey)))
        turn("private thing", "Noted.")
        history.flush()
        XCTAssertEqual(store.list(), [])
        history.setSaving(true)
        turn("now saved", "Yes.")
        history.flush()
        XCTAssertEqual(store.list().first?.messages, 2, "on again: the conversation is saved from its next change")
    }

    func testReopeningShowsItsLinesAndTheNextMessageCarriesItsExchanges() {
        turn("plan a trip to Hunza", "Go in late September.")
        let trip = history.currentID!
        model.newConversation()
        turn("fix my printer", "Restart it.")
        XCTAssertEqual(backend.starts.last?.memoryEmpty, true, "a new conversation starts with no memory")
        model.showPage(.home)
        XCTAssertEqual(model.panelPage, .home)
        model.openConversation(trip)
        XCTAssertEqual(model.panelPage, .conversation)
        XCTAssertEqual(model.state.lines.map(\.text), ["plan a trip to Hunza", "Go in late September."])
        XCTAssertEqual(history.currentID, trip)
        turn("and what should I pack?", "Layers.")
        XCTAssertEqual(backend.starts.last?.memoryEmpty, false, "the reopened exchanges go to the engine")
        history.flush()
        XCTAssertEqual(store.list().first?.id, trip, "continuing it moves it to the top")
        XCTAssertEqual(store.load(trip)?.lines.count, 4)
        XCTAssertEqual(store.list().count, 2, "nothing was copied into a new one")
    }

    func testReopeningWaitsWhileBenjiWorks() {
        turn("old", "Old answer.")
        let old = history.currentID!
        model.newConversation()
        model.composerText = "something new"
        model.submit()
        model.openConversation(old)
        XCTAssertEqual(model.state.lines.map(\.text), ["something new"])
        XCTAssertFalse(model.canSwitchConversation)
    }

    func testThePanelGoesHomeWhenEmptyAndBackForATurn() {
        XCTAssertEqual(model.panelPage, .home)
        model.voiceListeningStarted()
        XCTAssertEqual(model.panelPage, .home, "listening with no words yet")
        model.voicePartial("what")
        XCTAssertEqual(model.panelPage, .conversation)
        model.voiceCancelled()
        turn("hello there", "Hi.")
        XCTAssertEqual(model.panelPage, .conversation)
        model.showPage(.home)
        XCTAssertEqual(model.panelPage, .home)
        model.composerText = "one more"
        model.submit()
        XCTAssertEqual(model.panelPage, .conversation, "a new message shows where it goes")
        XCTAssertNil(history.requestedPage, "and the request is forgotten, so the answer stays in view")
        backend.say(.answer("Sure."))
        backend.finish(0)
        XCTAssertEqual(model.panelPage, .conversation)
        model.newConversation()
        XCTAssertEqual(model.panelPage, .home)
    }

    func testDeletingTheOpenConversationClearsThePanel() {
        turn("delete me", "Okay.")
        let id = history.currentID!
        model.showPage(.list)
        model.deleteConversation(id)
        history.flush()
        XCTAssertNil(store.load(id))
        XCTAssertEqual(model.state.lines, [])
        XCTAssertNil(history.currentID)
        XCTAssertEqual(model.panelPage, .home)
        turn("after", "Fresh.")
        history.flush()
        XCTAssertEqual(store.list().map(\.title), ["After"], "it isn't written back")
    }

    func testDeleteAllRemovesEveryFile() {
        turn("one", "1")
        model.newConversation()
        turn("two", "2")
        model.deleteAllConversations()
        history.flush()
        XCTAssertEqual(store.list(), [])
        XCTAssertEqual(history.summaries, [])
        XCTAssertEqual(model.state.lines, [])
    }

    func testTheListIsReadAtLaunch() throws {
        let c = SavedConversation(id: ConversationStore.newID(), title: "From yesterday", started: Date(timeIntervalSinceNow: -86_400),
                                  updated: Date(timeIntervalSinceNow: -86_000),
                                  lines: [SavedLine(role: .user, text: "q"), SavedLine(role: .assistant, text: "a")])
        try store.save(c)
        history = ConversationHistory(store: store, defaults: defaults)
        settle()
        XCTAssertEqual(history.summaries.map(\.title), ["From yesterday"])
        XCTAssertNil(ConversationHistory(store: nil).open(c.id), "no store, nothing read")
    }
}
