import XCTest
@testable import BenjiCore

final class DrawingCaptureTests: XCTestCase {
    func testOffUnlessTurnedOn() {
        XCTAssertFalse(DrawingCapture.shown(from: nil))
        XCTAssertFalse(DrawingCapture.shown(from: "yes"))
        XCTAssertFalse(DrawingCapture.shown(from: false))
        XCTAssertTrue(DrawingCapture.shown(from: true))
        XCTAssertTrue(DrawingCapture.shown(from: NSNumber(value: true)))
    }

    func testScreenshotClearsOnlyWhileHidden() {
        XCTAssertTrue(DrawingCapture.clearsOnScreenshot(shown: false))
        XCTAssertFalse(DrawingCapture.clearsOnScreenshot(shown: true))
    }
}
