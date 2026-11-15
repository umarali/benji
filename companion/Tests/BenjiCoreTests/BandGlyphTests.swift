import XCTest
@testable import BenjiCore

final class BandGlyphTests: XCTestCase {
    /// Every symbol the band and the sidebar's icon column draw (CompanionView).
    private let bandSymbols = ["house", "square.and.pencil", "stop.fill", "gearshape",
                               "chevron.backward", "sidebar.left", "chevron.up"]

    func testEveryBandSymbolHasAMeasuredScale() {
        for symbol in bandSymbols {
            XCTAssertNotNil(BandGlyph.scales[symbol], "\(symbol) has no entry")
        }
    }

    func testScalesStaySane() {
        for (symbol, scale) in BandGlyph.scales {
            XCTAssertGreaterThanOrEqual(scale, 0.8, symbol)
            XCTAssertLessThanOrEqual(scale, 1.4, symbol)
        }
    }

    func testFontSizeIsTheBandSizeTimesTheScale() {
        XCTAssertEqual(BandGlyph.fontSize(for: "chevron.up"), BandLayout.symbolSize, accuracy: 0.001)
        XCTAssertEqual(BandGlyph.fontSize(for: "sidebar.left"), BandLayout.symbolSize * 0.93, accuracy: 0.001)
        XCTAssertEqual(BandGlyph.scale(for: "unlisted.symbol"), 1)
    }

    /// Conversation rows in the sidebar and Home keep the bubble.
    func testTheRowBubbleKeepsItsScale() {
        XCTAssertEqual(BandGlyph.scale(for: "bubble.left"), 1)
    }

    func testCollapseAndBackShareOneSize() {
        XCTAssertEqual(BandGlyph.scale(for: "chevron.up"), 1)
        XCTAssertEqual(BandGlyph.scale(for: "chevron.backward"), BandGlyph.scale(for: "chevron.up"))
    }

    /// The band does not draw the boxed expand and shrink arrows, the pebble or the bubble.
    func testRetiredGlyphsHaveNoScale() {
        XCTAssertNil(BandGlyph.scales["arrow.up.left.and.arrow.down.right.square"])
        XCTAssertNil(BandGlyph.scales["arrow.down.right.and.arrow.up.left.square"])
    }
}
