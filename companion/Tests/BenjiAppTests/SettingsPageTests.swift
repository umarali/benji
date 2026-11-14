import XCTest
@testable import BenjiApp
import BenjiCore

/// The settings page inside the open panel: how it opens and closes, and how changes reach the app.
final class SettingsPageTests: XCTestCase {
    var backend: FakeBackend!
    var model: CompanionModel!

    override func setUp() {
        backend = FakeBackend()
        let suite = UserDefaults(suiteName: "benji-settings-page-\(UUID().uuidString)")!
        suite.set(ScreenMode.off.rawValue, forKey: ScreenModeState.defaultsKey)
        model = CompanionModel(backend: backend, screenMode: ScreenModeStore(defaults: suite))
    }

    func testOpeningSettingsOpensThePanelOnTheChosenSection() {
        XCTAssertFalse(model.settingsOpen)
        model.openSettings(.voice)
        XCTAssertTrue(model.settingsOpen)
        XCTAssertTrue(model.expanded)
        XCTAssertEqual(model.settings.section, .voice)
        model.closeSettings()
        XCTAssertFalse(model.settingsOpen)
        XCTAssertTrue(model.expanded, "back to the conversation, still open")
    }

    func testClosingThePanelLeavesSettingsSoTheNextOpenShowsTheConversation() {
        model.openSettings()
        model.setExpanded(false)
        XCTAssertFalse(model.settingsOpen)
    }

    func testAnApprovalTakesThePanelBack() {
        model.composerText = "tidy my downloads"
        model.submit()
        model.openSettings()
        backend.say(.approval(action: "move files", target: "~/Downloads"))
        XCTAssertNotNil(model.state.pendingApproval)
        XCTAssertFalse(model.settingsOpen)
    }

    func testCopyDiagnosticsIsAChangeTheAppHandlesAndTheStatusComesBackThroughTheSnapshot() {
        var stored = SettingsSnapshot()
        var applied: [SettingsChange] = []
        let settings = SettingsModel(load: { stored }, apply: { change in
            applied.append(change)
            if case .copyDiagnostics = change { stored.diagnostics = .copied }
        })
        XCTAssertEqual(settings.snapshot.diagnostics, .idle)
        settings.change(.copyDiagnostics)
        XCTAssertEqual(applied, [.copyDiagnostics])
        XCTAssertEqual(settings.snapshot.diagnostics, .copied)
        XCTAssertEqual(settings.snapshot.diagnostics.note, DiagnosticsCopy.copiedNote)
    }

    func testAChangeIsAppliedThenReadBack() {
        var stored = SettingsSnapshot()
        var applied: [SettingsChange] = []
        let settings = SettingsModel(load: { stored }, apply: { change in
            applied.append(change)
            if case .figures(let on) = change { stored.figures = on }
            // A refused permission: applied, but nothing changes.
        })
        settings.toggle(\.figures, SettingsChange.figures).wrappedValue = true
        XCTAssertEqual(applied, [.figures(true)])
        XCTAssertTrue(settings.snapshot.figures)
        settings.change(.requestPermission(.screenRecording))
        XCTAssertEqual(applied.last, .requestPermission(.screenRecording))
        XCTAssertEqual(settings.snapshot, stored)
    }
}
