import XCTest
@testable import BenjiCore

/// The screenshot's notch, menu bar and size in its own pixels (ScreenshotGeometry).
final class ScreenshotGeometryTests: XCTestCase {
    /// A 14-inch MacBook Pro at its default size: 1512 × 982 pt, 2× backing, a 200 × 32 pt notch.
    let frame = CGRect(x: 0, y: 0, width: 1512, height: 982)
    lazy var notch = CGRect(x: 656, y: 982 - 32, width: 200, height: 32)
    /// ScreenCapturePolicy's size for a 3024 × 1964 capture.
    lazy var sent = ScreenCapturePolicy.targetSize(for: CGSize(width: 3024, height: 1964))

    func testNotchMapsThroughTheCaptureScale() throws {
        let g = try XCTUnwrap(ScreenshotGeometry.make(pixelSize: sent, screenFrame: frame, notch: notch,
                                                      menuBarHeight: 32, builtIn: true, displayCount: 1))
        XCTAssertEqual(g.width, Int(sent.width))
        XCTAssertEqual(g.height, Int(sent.height))
        let s = sent.width / frame.width
        let n = try XCTUnwrap(g.notch)
        XCTAssertEqual(n.x1, Int((656 * s).rounded(.down)))
        XCTAssertEqual(n.x2, Int((856 * s).rounded(.up)))
        XCTAssertEqual(n.y1, 0)
        XCTAssertEqual(n.y2, Int((32 * sent.height / frame.height).rounded(.up)))
        XCTAssertEqual(g.menuBarHeight, n.y2)
        // Centred like the hardware notch.
        XCTAssertEqual(CGFloat(n.x1 + n.x2) / 2, sent.width / 2, accuracy: 1)
    }

    func testNotchRoundsOutwardsAndStaysInsideTheImage() throws {
        // A notch reported a little past the top and side of the display.
        let odd = CGRect(x: -10, y: 970, width: 30.3, height: 20)
        let g = try XCTUnwrap(ScreenshotGeometry.make(pixelSize: CGSize(width: 1000, height: 650),
                                                      screenFrame: frame, notch: odd, menuBarHeight: 24,
                                                      builtIn: true, displayCount: 1))
        let n = try XCTUnwrap(g.notch)
        XCTAssertEqual(n.x1, 0)
        XCTAssertEqual(n.y1, 0)
        XCTAssertEqual(n.x2, Int((20.3 * 1000 / 1512).rounded(.up)))
        XCTAssertEqual(n.y2, Int((12 * 650 / 982.0).rounded(.up)))
    }

    func testSecondDisplayUsesItsOwnOrigin() throws {
        // An external display to the right of the built-in one, taller, no notch.
        let ext = CGRect(x: 1512, y: -200, width: 2560, height: 1440)
        let g = try XCTUnwrap(ScreenshotGeometry.make(pixelSize: CGSize(width: 1418, height: 797), screenFrame: ext,
                                                      notch: nil, menuBarHeight: 25, builtIn: false, displayCount: 2))
        XCTAssertNil(g.notch)
        XCTAssertEqual(g.menuBarHeight, Int((25 * 797 / 1440.0).rounded(.up)))
        XCTAssertEqual(g.object["display"] as? String, "external")
        XCTAssertEqual(g.object["displays"] as? Int, 2)
        XCTAssertNil(g.object["notch"])
        // A notch on another display doesn't land on this one.
        let other = ScreenshotGeometry.make(pixelSize: CGSize(width: 1418, height: 797), screenFrame: ext,
                                            notch: notch, menuBarHeight: 25, builtIn: false, displayCount: 2)
        XCTAssertNil(other?.notch)
    }

    func testHiddenMenuBarAndEmptyImage() {
        let g = ScreenshotGeometry.make(pixelSize: sent, screenFrame: frame, notch: nil, menuBarHeight: 0,
                                        builtIn: true, displayCount: 0)
        XCTAssertEqual(g?.menuBarHeight, 0)
        XCTAssertEqual(g?.displayCount, 1)
        XCTAssertNil(ScreenshotGeometry.make(pixelSize: .zero, screenFrame: frame, notch: notch, menuBarHeight: 32,
                                             builtIn: true, displayCount: 1))
    }

    func testJSONIsWhatTheEngineReads() throws {
        let g = ScreenshotGeometry(width: 1330, height: 864, notch: .init(x1: 577, y1: 0, x2: 753, y2: 28),
                                   menuBarHeight: 33, builtIn: true, displayCount: 1)
        XCTAssertEqual(g.json(), #"{"display":"built-in","displays":1,"height":864,"menu_bar":33,"#
                       + #""notch":[577,0,753,28],"width":1330}"#)
    }
}
