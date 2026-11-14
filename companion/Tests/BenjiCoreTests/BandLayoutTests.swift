import XCTest
@testable import BenjiCore

/// The open panel's band: nothing ever overlaps the status word, on any notch a Mac has.
final class BandLayoutTests: XCTestCase {
    /// The status words at the wing font, measured (tools: NSAttributedString, 11 pt semibold rounded).
    let words: [String: CGFloat] = ["Ready": 34.5, "Listening": 51.3, "Working": 45.7, "Speaking": 51.7,
                                    "Transcribing": 69.3, "Approval": 49.5, "Error": 27.3, "Done": 28.8, "Looking": 44.1]
    /// No hardware notch (the 185 pt stand-in) up to the widest MacBook notch, with room to spare.
    let notches: [CGFloat] = [150, 170, 185, 190, 200, 205]

    func testTheWordAlwaysFitsItsOwnRoom() {
        for notch in notches {
            let room = BandLayout.wordWidth(wing: BandLayout.wing(openWidth: PanelGeometry.openSize.width, notchWidth: notch))
            for (word, width) in words {
                XCTAssertGreaterThanOrEqual(room, width * BandLayout.minimumWordScale, "\(word) at a \(notch) pt notch")
            }
        }
        XCTAssertEqual(BandLayout.widestWord, words.values.max())
    }

    func testAtTheUsualNotchOnlyTheLongestWordShrinks() {
        let room = BandLayout.wordWidth(wing: BandLayout.wing(openWidth: PanelGeometry.openSize.width, notchWidth: 190))
        XCTAssertEqual(words.filter { $0.value > room }.map(\.key), ["Transcribing"])
    }

    func testTheRightSideAddsUpWithoutOverlap() {
        for notch in notches {
            let wing = BandLayout.wing(openWidth: PanelGeometry.openSize.width, notchWidth: notch)
            let used = BandLayout.notchGap + BandLayout.wordWidth(wing: wing) + BandLayout.wordGap
                + BandLayout.rightGroupWidth + BandLayout.edge
            XCTAssertEqual(used, wing, accuracy: 0.001)
        }
    }

    /// D-133: the left group (Home, New conversation, Settings) starts at the panel's edge and
    /// never reaches the Screen On dot by the notch. (Was "fits listening with Screen On": the
    /// mic and its meter left the band for the composer, so listening no longer widens it.)
    func testTheLeftGroupFromTheEdgeClearsTheScreenOnDot() {
        XCTAssertEqual(BandLayout.leftGroupWidth(), 12 + 22 * 3 + 4 * 2)
        for size in [PanelGeometry.openSize, PanelGeometry.settingsSize, PanelGeometry.expandedSize] {
            for notch in notches {
                let wing = BandLayout.wing(openWidth: size.width, notchWidth: notch)
                XCTAssertLessThanOrEqual(BandLayout.leftNeeded(screenOn: true), wing, "\(size) at a \(notch) pt notch")
            }
        }
    }

    func testTheExpandedSizeHasRoomForEveryWord() {
        let wing = BandLayout.wing(openWidth: PanelGeometry.expandedSize.width, notchWidth: 205)
        XCTAssertGreaterThanOrEqual(BandLayout.wordWidth(wing: wing), BandLayout.widestWord)
    }

    /// The sidebar's icon column sits under the band's first glyphs: both start at the edge.
    func testTheSidebarIconsLineUpWithTheBand() {
        XCTAssertEqual(PanelGeometry.sidebarIconColumn, BandLayout.edge)
        XCTAssertLessThan(PanelGeometry.sidebarWidth, PanelGeometry.expandedSize.width / 2)
        XCTAssertGreaterThanOrEqual(PanelGeometry.sidebarWidth, BandLayout.leftGroupWidth(glyphs: 2) + 100,
                                    "room for a title beside the icon column")
    }

    func testTheSettingsSizeHasMoreRoomStill() {
        let wing = BandLayout.wing(openWidth: PanelGeometry.settingsSize.width, notchWidth: 205)
        XCTAssertGreaterThanOrEqual(BandLayout.wordWidth(wing: wing), BandLayout.widestWord)
    }

    func testOneGlyphGrid() {
        XCTAssertEqual(BandLayout.slot, 22)
        XCTAssertEqual(BandLayout.symbolSize, 13)
        XCTAssertEqual(BandLayout.spacing, 4)
        XCTAssertEqual(BandLayout.rightGroupWidth, 48)
    }
}
