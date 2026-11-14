import XCTest
@testable import BenjiCore

/// While Settings shows, the open object grows to `settingsSize`; closed and peek never change.
final class SettingsGeometryTests: XCTestCase {
    let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let notch = CGRect(x: 663, y: 950, width: 186, height: 32)

    func testSettingsWidensOnlyTheOpenSize() {
        let open = PanelGeometry.notchShape(.open, notch: notch, screenFrame: screen, settings: true)
        XCTAssertEqual(open.frame.size, PanelGeometry.settingsSize)
        XCTAssertEqual(open.frame.midX, notch.midX)
        XCTAssertEqual(open.frame.maxY, screen.maxY, "flush with the top of the display")
        for size in [NotchSize.closed, .peek] {
            XCTAssertEqual(PanelGeometry.notchShape(size, notch: notch, screenFrame: screen, settings: true),
                           PanelGeometry.notchShape(size, notch: notch, screenFrame: screen))
        }
        XCTAssertEqual(PanelGeometry.notchShape(.open, notch: notch, screenFrame: screen).frame.size, PanelGeometry.openSize)
    }

    func testSettingsFitsTheSmallestDisplays() {
        let small = CGRect(x: 0, y: 0, width: 1280, height: 800)
        let open = PanelGeometry.notchShape(.open, notch: nil, screenFrame: small, settings: true)
        XCTAssertTrue(small.contains(open.frame))
        XCTAssertGreaterThan(PanelGeometry.settingsSize.width, PanelGeometry.openSize.width)
        XCTAssertGreaterThan(PanelGeometry.settingsSize.height, PanelGeometry.openSize.height)
    }
}
