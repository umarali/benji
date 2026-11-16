import Foundation
import XCTest
@testable import BenjiApp
import BenjiCore

/// The "Draw things in 3D" setting: flipping it changes the backend from the next message,
/// without relaunching. No window is made here: the stage is never shown.
final class FigureSwitchTests: XCTestCase {
    /// A backend that counts engine restarts.
    final class RestartCounting: CompanionBackend {
        var onEvent: ((_ run: Int, BackendEvent) -> Void)?
        var onFinished: ((_ run: Int, Int32) -> Void)?
        var approvalTimeout: TimeInterval = 60
        var restarts = 0
        var starts = 0
        func start(run: Int, task: String, imagePath: String?, memory: ConversationMemory, allowPointing: Bool,
                   spoken: Bool, screen: ScreenshotGeometry?) { starts += 1 }
        func resolveApproval(_ approved: Bool, from source: ApprovalSource) {}
        func cancel() {}
        func reset() {}
        func shutdown() {}
        func restartEngine() { restarts += 1 }
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: FigureStage.defaultsKey)
        unsetenv(FigureStageBackend.engineFlag)
    }

    private func model(_ backend: CompanionBackend) -> CompanionModel {
        let suite = UserDefaults(suiteName: "benji-figure-switch-\(UUID().uuidString)")!
        suite.set(ScreenMode.off.rawValue, forKey: ScreenModeState.defaultsKey)
        return CompanionModel(backend: backend, screenMode: ScreenModeStore(defaults: suite))
    }

    func testMatchingWrapsAndUnwrapsAndRestartsTheEngineOnlyOnAChange() {
        let bare = RestartCounting()
        UserDefaults.standard.set(false, forKey: FigureStage.defaultsKey)
        XCTAssertTrue(FigureStageBackend.matching(bare) === bare, "off and bare: nothing changes")
        XCTAssertEqual(bare.restarts, 0)

        UserDefaults.standard.set(true, forKey: FigureStage.defaultsKey)
        let wrapped = FigureStageBackend.matching(bare)
        XCTAssertTrue((wrapped as? FigureStageBackend)?.inner === bare)
        XCTAssertEqual(ProcessInfo.processInfo.environment[FigureStageBackend.engineFlag], "1")
        XCTAssertEqual(bare.restarts, 1)
        XCTAssertTrue(FigureStageBackend.matching(wrapped) === wrapped, "on and wrapped: nothing changes")
        XCTAssertEqual(bare.restarts, 1)

        UserDefaults.standard.set(false, forKey: FigureStage.defaultsKey)
        XCTAssertTrue(FigureStageBackend.matching(wrapped) === bare)
        XCTAssertNil(ProcessInfo.processInfo.environment[FigureStageBackend.engineFlag])
        XCTAssertEqual(bare.restarts, 2)
    }

    func testTheModelTakesTheNewBackendAtTheNextMessageAndHearsIt() {
        let first = FakeBackend(), second = FakeBackend()
        let m = model(first)
        m.backendForNextRun = { _ in second }
        m.composerText = "draw a lamp"
        m.submit()
        XCTAssertEqual(first.starts.count, 0)
        XCTAssertEqual(second.starts.count, 1)
        second.say(.answer("A lamp."))
        second.finish()
        XCTAssertEqual(m.state.lines.filter { $0.role == .assistant }.map(\.text), ["A lamp."])
        XCTAssertEqual(m.state.phase, .idle)
    }

    func testNoSwapWhileARunIsLive() {
        let first = FakeBackend(), second = FakeBackend()
        let m = model(first)
        var asked = 0
        m.backendForNextRun = { backend in asked += 1; return backend }
        m.composerText = "one"
        m.submit()
        XCTAssertEqual(asked, 1)
        m.backendForNextRun = { _ in second }
        first.say(.answer("Done."))
        first.finish()
        m.composerText = "two"
        m.submit()
        XCTAssertEqual(first.starts.count, 1)
        XCTAssertEqual(second.starts.count, 1, "swapped once the first run was over")
    }

    func testTheNoteShowsOnTheStatusLine() {
        let m = model(FakeBackend())
        m.showNote(FigureSetting.notice(on: true))
        XCTAssertEqual(m.statusNote, FigureSetting.notice(on: true))
    }
}
