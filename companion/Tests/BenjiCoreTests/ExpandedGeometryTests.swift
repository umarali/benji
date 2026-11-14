import XCTest
@testable import BenjiCore

/// D-133: Expand grows the open object to 720 × 560, still hanging from the notch; Shrink returns
/// to 460 × 380; closed and peek never change.
final class ExpandedGeometryTests: XCTestCase {
    let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let notch = CGRect(x: 663, y: 950, width: 186, height: 32)

    func testTheSizes() {
        XCTAssertEqual(PanelGeometry.expandedSize, CGSize(width: 720, height: 560))
        XCTAssertEqual(PanelGeometry.openSize, CGSize(width: 460, height: 380))
        XCTAssertEqual(PanelGeometry.openSize(settings: false, expanded: false), PanelGeometry.openSize)
        XCTAssertEqual(PanelGeometry.openSize(settings: true, expanded: false), PanelGeometry.settingsSize)
        XCTAssertEqual(PanelGeometry.openSize(settings: false, expanded: true), PanelGeometry.expandedSize)
        XCTAssertEqual(PanelGeometry.openSize(settings: true, expanded: true), PanelGeometry.expandedSize,
                       "expanded already has room for settings")
    }

    func testExpandGrowsOnlyTheOpenSizeFromTheNotch() {
        let open = PanelGeometry.notchShape(.open, notch: notch, screenFrame: screen, expanded: true)
        XCTAssertEqual(open.frame.size, PanelGeometry.expandedSize)
        XCTAssertEqual(open.frame.midX, notch.midX, "centred on the notch")
        XCTAssertEqual(open.frame.maxY, screen.maxY, "flush with the top of the display")
        XCTAssertEqual(open.bottomRadius, PanelGeometry.bottomRadius(.open))
        for size in [NotchSize.closed, .peek] {
            XCTAssertEqual(PanelGeometry.notchShape(size, notch: notch, screenFrame: screen, expanded: true),
                           PanelGeometry.notchShape(size, notch: notch, screenFrame: screen))
        }
        XCTAssertEqual(PanelGeometry.notchShape(.open, notch: notch, screenFrame: screen, expanded: false).frame.size,
                       PanelGeometry.openSize, "Shrink is the usual size again")
    }

    func testExpandedFitsTheSmallestDisplaysAndTheShadowIsFull() {
        let small = CGRect(x: 0, y: 0, width: 1280, height: 800)
        let open = PanelGeometry.notchShape(.open, notch: nil, screenFrame: small, expanded: true)
        XCTAssertTrue(small.contains(open.frame))
        XCTAssertEqual(open.shadowOpacity, 1, "past the usual open height the shadow stays at full strength")
    }
}
