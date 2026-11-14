import XCTest
@testable import BenjiCore

final class PermissionPolicyTests: XCTestCase {
    func testGrantedNeedsNothing() {
        XCTAssertEqual(PermissionRequestRoute.route(granted: true, canPrompt: true, promptedThisLaunch: false), .alreadyGranted)
    }

    func testPromptOnceThenSettings() {
        XCTAssertEqual(PermissionRequestRoute.route(granted: false, canPrompt: true, promptedThisLaunch: false), .systemPrompt)
        XCTAssertEqual(PermissionRequestRoute.route(granted: false, canPrompt: true, promptedThisLaunch: true), .systemSettings)
    }

    func testDeniedGoesToSettings() {
        XCTAssertEqual(PermissionRequestRoute.route(granted: false, canPrompt: false, promptedThisLaunch: false), .systemSettings)
    }

    func testScreenGrantRemembered() {
        XCTAssertTrue(ScreenRecordingGrant.treatAsGranted(preflight: false, previouslyConfirmed: true))
        XCTAssertTrue(ScreenRecordingGrant.treatAsGranted(preflight: true, previouslyConfirmed: false))
        XCTAssertFalse(ScreenRecordingGrant.treatAsGranted(preflight: false, previouslyConfirmed: false))
    }
}
