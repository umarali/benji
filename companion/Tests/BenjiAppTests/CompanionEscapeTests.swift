import XCTest
import AppKit
@testable import BenjiApp
import BenjiCore

/// Escape through the presenter, plus the menu toggle through a hidden panel. No permissions.
final class CompanionEscapeTests: XCTestCase {
    var backend: FakeBackend!
    var model: CompanionModel!
    var presenter: NotchPresenter!
    var voiceCancels = 0

    override func setUp() {
        backend = FakeBackend()
        let defaults = UserDefaults(suiteName: "benji-escape-tests-\(UUID().uuidString)")!
        defaults.set(ScreenMode.off.rawValue, forKey: ScreenModeState.defaultsKey)
        model = CompanionModel(backend: backend, screenMode: ScreenModeStore(defaults: defaults))
        model.onCancel = { [unowned self] in self.voiceCancels += 1 }
        presenter = NotchPresenter(model: model,
                                   layout: NotchLayoutInfo(notch: nil, screenFrame: .zero),
                                   accessibility: NotchAccessibility(reduceMotion: true))
    }

    private func start() {
        model.composerText = "explain this"
        model.submit()
    }

    func testEscapeStopsTheTurnBeforeFoldingAndDropsLateEvents() {
        start()
        var cancelsAtFold: Int?
        model.onExpandedChange = { open, _ in
            if !open { cancelsAtFold = self.backend.cancels }
        }
        presenter.escape()
        XCTAssertEqual(cancelsAtFold, 1)
        XCTAssertEqual(voiceCancels, 1)
        XCTAssertEqual(model.state.phase, .idle)
        XCTAssertFalse(model.expanded)
        backend.say(.answer("too late"))
        backend.finish()
        XCTAssertFalse(model.state.lines.contains { $0.text == "too late" })
        presenter.escape()
        XCTAssertEqual(backend.cancels, 1, "an idle Escape only folds")
        XCTAssertEqual(voiceCancels, 1)
    }

    func testEscapeStopsSpeechAfterTheBackendHasFinished() {
        start()
        backend.say(.answer("an answer"))
        model.voiceSpeaking(true)
        backend.finish()
        XCTAssertEqual(model.state.phase, .speaking)
        presenter.escape()
        XCTAssertEqual(voiceCancels, 1)
        XCTAssertEqual(backend.cancels, 0, "the completed engine needs no cancellation")
        XCTAssertEqual(model.state.phase, .idle)
        XCTAssertFalse(model.expanded)
    }

    func testApprovalEscapeMeansNoAndKeepsTheTurnAndPanelOpen() {
        start()
        backend.say(.approval(action: "write a file", target: "notes.txt"))
        presenter.escape()
        XCTAssertEqual(backend.approvals, [false])
        XCTAssertEqual(backend.cancels, 0)
        XCTAssertEqual(voiceCancels, 0)
        XCTAssertEqual(model.state.phase, .thinking)
        XCTAssertTrue(model.expanded)
    }

    func testSettingsEscapeGoesBackWithoutStoppingTheTurn() {
        start()
        model.openSettings()
        presenter.escape()
        XCTAssertFalse(model.settingsOpen)
        XCTAssertTrue(model.expanded)
        XCTAssertEqual(backend.cancels, 0)
        XCTAssertEqual(model.state.phase, .thinking)
    }

    func testIdleEscapeFoldsWithoutCancelling() {
        model.setExpanded(true)
        presenter.escape()
        XCTAssertFalse(model.expanded)
        XCTAssertEqual(voiceCancels, 0)
        XCTAssertEqual(backend.cancels, 0)
    }

    func testListEscapeGoesHomeWithoutFolding() {
        model.setExpanded(true)
        model.showPage(.list)
        presenter.escape()
        XCTAssertEqual(model.panelPage, .home)
        XCTAssertTrue(model.expanded)
    }

    func testMenuFoldingDoesNotStopTheAnswer() {
        _ = NSApplication.shared
        let panel = CompanionPanel(model: model)
        panel.presenter.accessibility = NotchAccessibility(reduceMotion: true)
        defer { panel.close() }
        start()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(panel.presenter.size, .open)
        XCTAssertFalse(panel.isVisible, "construct the panel without showing or focusing it")
        panel.toggleOpen()
        XCTAssertFalse(model.expanded)
        XCTAssertEqual(backend.cancels, 0)
        XCTAssertEqual(voiceCancels, 0)
        XCTAssertEqual(model.state.phase, .thinking)
        XCTAssertFalse(panel.isVisible)
    }
}
