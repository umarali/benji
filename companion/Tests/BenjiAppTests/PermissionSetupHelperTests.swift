import XCTest
@testable import BenjiApp
import BenjiCore

/// The setup window's Accessibility helper, from an injected probe and recorded actions: no
/// permission API, System Settings or window is used.
final class PermissionSetupHelperTests: XCTestCase {
    private var statuses: [CompanionPermission: PermissionStatus] = [:]
    private var opened: [SetupStep] = []
    private var prompts = 0
    private var closes = 0
    private var heard: [String] = []

    @MainActor private func make() -> PermissionSetupModel {
        statuses = [:]
        opened = []
        prompts = 0
        closes = 0
        heard = []
        let actions = PermissionSetupActions(openSettings: { [unowned self] in self.opened.append($0) },
                                             promptAccessibility: { [unowned self] in self.prompts += 1 },
                                             close: { [unowned self] in self.closes += 1 })
        let model = PermissionSetupModel(probe: { [unowned self] in self.statuses }, actions: actions,
                                         appIcon: NSImage(), appURL: URL(fileURLWithPath: "/Applications/Benji.app"))
        model.onAnnounce = { [unowned self] in self.heard.append($0) }
        return model
    }

    @MainActor func testOpeningSettingsShowsTheHelperButGrantsNothing() {
        let model = make()
        XCTAssertFalse(model.showsHelper)
        model.openAccessibilitySettings()
        XCTAssertEqual(opened, [.accessibility])
        XCTAssertTrue(model.showsHelper)
        model.refresh()   // the poll: macOS still says no
        XCTAssertTrue(model.showsHelper)
        XCTAssertEqual(model.progress.current, .accessibility)
        XCTAssertEqual(model.progress.status(of: .accessibility), .notYet, "opening Settings is not a grant")
        XCTAssertTrue(heard.isEmpty)
    }

    @MainActor func testTheProbeReportingAccessMovesSetupOnAndTheFullWindowReturns() {
        let model = make()
        model.openAccessibilitySettings()
        statuses[.accessibility] = .granted
        model.refresh()
        XCTAssertFalse(model.showsHelper)
        XCTAssertEqual(model.progress.current, .voice)
        XCTAssertEqual(model.progress.stepNumber, 2)
        XCTAssertEqual(heard, ["Accessibility granted. Next: Microphone and Speech Recognition."])
        statuses[.accessibility] = .notYet   // switched off again later: setup asks again, in the full window
        model.refresh()
        XCTAssertEqual(model.progress.current, .accessibility)
        XCTAssertFalse(model.showsHelper, "the helper comes back only when the user opens Settings again")
    }

    @MainActor func testTheHelperKeepsAKeyboardRouteABackRouteAndNotNow() {
        let model = make()
        model.openAccessibilitySettings()
        model.actions.promptAccessibility()
        XCTAssertEqual(prompts, 1)
        XCTAssertTrue(model.showsHelper, "asking macOS instead keeps the helper until the probe says yes")
        model.showFullSetup()
        XCTAssertFalse(model.showsHelper)
        XCTAssertEqual(model.progress.current, .accessibility)
        model.openAccessibilitySettings()
        model.actions.close()
        XCTAssertEqual(closes, 1)
        XCTAssertEqual(opened, [.accessibility, .accessibility])
    }

    @MainActor func testADeniedStepIsPassedOverAndTheHelperNeverShowsForAnotherStep() {
        let model = make()
        statuses = [.accessibility: .granted, .microphone: .denied, .speechRecognition: .granted]
        model.refresh()
        XCTAssertEqual(model.progress.current, .screenRecording)
        XCTAssertEqual(model.progress.deniedSteps, [.voice])
        model.openAccessibilitySettings()
        XCTAssertFalse(model.showsHelper)
    }
}
