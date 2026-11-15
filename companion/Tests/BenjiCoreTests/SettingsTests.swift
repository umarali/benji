import XCTest
@testable import BenjiCore

/// The settings sections and the slim menu-bar menu.
final class SettingsTests: XCTestCase {
    func testTheMenuBarMenuIsShort() {
        XCTAssertEqual(StatusMenuItem.menu(setupComplete: true), [.showHide, .separator, .settings, .separator, .quit])
        XCTAssertEqual(StatusMenuItem.menu(setupComplete: true).filter { $0 != .separator }.map(\.title),
                       ["Show / Hide Benji", "Settings…", "Quit Benji"])
    }

    func testFinishSetupShowsOnlyWhileAPermissionIsMissing() {
        XCTAssertEqual(StatusMenuItem.menu(setupComplete: false),
                       [.showHide, .separator, .settings, .finishSetup, .separator, .quit])
        XCTAssertEqual(StatusMenuItem.finishSetup.title, "Finish Setup…")
    }

    func testMenuKeysAreTheMacConventions() {
        XCTAssertEqual(StatusMenuItem.settings.keyEquivalent, ",")
        XCTAssertEqual(StatusMenuItem.quit.keyEquivalent, "q")
        XCTAssertEqual(StatusMenuItem.showHide.keyEquivalent, "p", "unchanged from the old menu")
    }

    func testSectionsInOrderWithSymbols() {
        XCTAssertEqual(SettingsSection.allCases.map(\.title), ["General", "Voice", "Screen", "Browser", "Shortcuts", "Permissions"])
        XCTAssertTrue(SettingsSection.allCases.allSatisfy { !$0.symbol.isEmpty && $0.subtitle.hasSuffix(".") })
        XCTAssertEqual(Set(SettingsSection.allCases.map(\.symbol)).count, SettingsSection.allCases.count)
    }

    func testSetupIsCompleteOnlyWhenEveryPermissionIsGranted() {
        var s = SettingsSnapshot()
        XCTAssertTrue(s.setupComplete, "nothing listed, nothing missing")
        s.permissions = [.init(permission: .microphone, granted: true), .init(permission: .accessibility, granted: false)]
        XCTAssertFalse(s.setupComplete)
        s.permissions = [.init(permission: .microphone, granted: true)]
        XCTAssertTrue(s.setupComplete)
    }

    func testTalkOverBenjiIsAChoiceWithACaptionEach() {
        XCTAssertEqual(SettingsSnapshot().bargeIn, .headphones)
        XCTAssertTrue(BargeInMode.allCases.allSatisfy { $0.caption.hasSuffix(".") })
        XCTAssertNotEqual(SettingsChange.bargeIn(.always), .bargeIn(.off))
    }

    func testQuietSpellNames() {
        XCTAssertEqual(SettingsSnapshot.minutes(60), "1 Minute")
        XCTAssertEqual(SettingsSnapshot.minutes(900), "15 Minutes")
    }
}
