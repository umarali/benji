import Foundation
import XCTest
@testable import BenjiApp
import BenjiCore

/// The figure hook: with the setting off the app's backend is used as it is; on, the
/// figure block is taken out of answers (so the panel and the voice never see it) and the figure
/// goes to the stage. No window is made here: the stage is never shown.
final class FigureStageBackendTests: XCTestCase {
    let reply = "Here it is.\n```figure\n{\"title\": \"Ball\", \"parts\": [{\"name\": \"ball\", \"kind\": \"sphere\", \"r\": 1}]}\n```"

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: FigureStage.defaultsKey)
        unsetenv(FigureStageBackend.engineFlag)
    }

    /// On by default (the model draws in 3D when the question calls for it); off turns 3D off.
    func testOnByDefaultOffLeavesTheBackendUntouched() {
        UserDefaults.standard.removeObject(forKey: FigureStage.defaultsKey)
        let wrapped = FakeBackend()
        XCTAssertFalse(FigureStageBackend.wrap(wrapped) === wrapped)
        XCTAssertEqual(ProcessInfo.processInfo.environment[FigureStageBackend.engineFlag], "1")
        unsetenv(FigureStageBackend.engineFlag)
        UserDefaults.standard.set(false, forKey: FigureStage.defaultsKey)
        let fake = FakeBackend()
        XCTAssertTrue(FigureStageBackend.wrap(fake) === fake)
        XCTAssertNil(ProcessInfo.processInfo.environment[FigureStageBackend.engineFlag])
    }

    func testOnTheBlockIsTakenOutAndTheEngineIsTold() {
        UserDefaults.standard.set(true, forKey: FigureStage.defaultsKey)
        let original = FakeBackend()
        XCTAssertFalse(FigureStageBackend.wrap(original) === original)
        XCTAssertEqual(ProcessInfo.processInfo.environment[FigureStageBackend.engineFlag], "1")
        // Events go through a wrapper with no stage, so no window can be made in a test.
        let fake = FakeBackend()
        let quiet = FigureStageBackend(fake, stage: { nil })
        var seen: [BackendEvent] = []
        quiet.onEvent = { _, e in seen.append(e) }
        fake.onEvent?(1, .answer(reply + "\n[POINT:10,20:Ball]"))
        fake.onEvent?(1, .pointedAnswer(text: reply, targets: []))
        fake.onEvent?(1, .answer("No figure here."))
        fake.onEvent?(1, .answer("Broken.\n```figure\n{oops\n```"))
        XCTAssertEqual(seen, [.answer("Here it is.\n[POINT:10,20:Ball]"), .pointedAnswer(text: "Here it is.", targets: []),
                              .answer("No figure here."), .answer("Broken.\n```figure\n{oops\n```")])
    }

    func testEverythingElsePassesThrough() {
        let fake = FakeBackend()
        let wrapped = FigureStageBackend(fake, stage: { nil })
        var finished: [Int32] = []
        wrapped.onFinished = { _, code in finished.append(code) }
        wrapped.start(run: 3, task: "t", imagePath: nil, memory: ConversationMemory(), allowPointing: false, spoken: true, screen: nil)
        wrapped.resolveApproval(true)
        wrapped.cancel()
        fake.finish(0)
        XCTAssertEqual(fake.starts.map(\.run), [3])
        XCTAssertEqual(fake.approvals, [true])
        XCTAssertEqual(fake.cancels, 1)
        XCTAssertEqual(finished, [0])
    }
}
