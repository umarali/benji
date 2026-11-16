import XCTest
@testable import BenjiCore

/// Settings › Phone: which addresses the listener can serve, the approvals switch, and what the phone is shown.
final class PhoneControlTests: XCTestCase {
    func testAPastedTailscaleAddressKeepsNoPathAndOneTrailingSlashIsDropped() {
        XCTAssertEqual(PhoneControl.normalizedAddress(" https://mac.example.ts.net/\n"), "https://mac.example.ts.net")
        XCTAssertEqual(PhoneControl.normalizedAddress("http://127.0.0.1:8765"), "http://127.0.0.1:8765")
        for bad in ["https://mac.example.ts.net/path", "https://mac.example.ts.net//", "https://mac.example.ts.net@example.com",
                    "http://mac.example.ts.net", "https://example.com", "https://ts.net", "https://mac.example.ts.net:443",
                    "http://0.0.0.0:8765", "http://127.0.0.1:8766", "http://localhost:8765"] {
            XCTAssertNil(PhoneControl.normalizedAddress(bad), bad)
        }
    }

    func testThePhoneMayAnswerApprovalsUnlessTurnedOff() {
        XCTAssertTrue(PhoneApprovals.isOn(nil))
        XCTAssertTrue(PhoneApprovals.isOn(true))
        XCTAssertFalse(PhoneApprovals.isOn(false))
        XCTAssertTrue(PhoneApprovals.isOn("no"), "only a stored false turns it off")
        XCTAssertTrue(SettingsSnapshot().phoneApprovals)
        XCTAssertEqual(PhoneApprovals.defaultsKey, "phoneAnswersApprovals")
    }

    func testLongTextIsShortenedWithANoteAndShortTextIsKept() {
        XCTAssertEqual(PhoneControl.shown("short"), "short")
        let long = PhoneControl.shown(String(repeating: "x", count: 3000))
        XCTAssertTrue(long.hasPrefix(String(repeating: "x", count: PhoneControl.shownScalars) + "\n"))
        XCTAssertTrue(long.contains("Shortened"))
    }

    func testOnlyScreenAndDriveEventsActOnTheScreen() {
        XCTAssertTrue(BackendEvent.driveApproval(goal: "Click", seconds: 30).actsOnTheScreen)
        XCTAssertTrue(BackendEvent.screenAction(request: "s1", step: nil).actsOnTheScreen)
        XCTAssertFalse(BackendEvent.approval(action: "write file", target: "notes.txt").actsOnTheScreen)
        XCTAssertFalse(BackendEvent.answer("Done").actsOnTheScreen)
    }

    func testThePhoneHasItsOwnSettingsSectionAfterMemory() {
        XCTAssertEqual(SettingsSection.phone.title, "Phone")
        let titles = SettingsPane.all.map(\.title)
        XCTAssertEqual(titles.firstIndex(of: "Phone"), titles.firstIndex(of: "Memory").map { $0 + 1 })
    }
}
