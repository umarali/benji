import Foundation
import XCTest
@testable import BenjiCore

/// Turning the figure by hand: drag, scroll, pinch, reset, and
/// the idle turn pausing while the user handles it.
final class FigureOrbitTests: XCTestCase {
    func testDraggingTurnsAndTiltsLikeGrabbingTheObject() {
        var o = FigureOrbit(base: FigureView(turn: 30, tilt: 20, zoom: 1))
        o.drag(dx: 100, dy: 0)                 // right: the figure's front turns right, the camera left
        XCTAssertEqual(o.view.turn, 30 - 40, accuracy: 1e-9)
        XCTAssertEqual(o.view.tilt, 20)
        o.drag(dx: 0, dy: 50)                  // up (AppKit y up): more of the underside
        XCTAssertEqual(o.view.tilt, 20 - 15, accuracy: 1e-9)
        o.drag(dx: 0, dy: -100)                // down: more of the top
        XCTAssertEqual(o.view.tilt, 5 + 30, accuracy: 1e-9)
        XCTAssertEqual(o.view.zoom, 1, "dragging never zooms")
        XCTAssertTrue(o.isMoved)
    }

    func testTurnWrapsAndTiltStopsAtTheViewsLimits() {
        var o = FigureOrbit(base: FigureView(turn: 170, tilt: 70, zoom: 1))
        o.drag(dx: -50, dy: -200)              // +20° turn, +60° tilt
        XCTAssertEqual(o.view.turn, -170, accuracy: 1e-9, "190° is -170°")
        XCTAssertEqual(o.view.tilt, 80, "tilt stops at 80, like a figure block's view")
        o.drag(dx: 0, dy: 10_000)
        XCTAssertEqual(o.view.tilt, -80)
        o.drag(dx: 900 * 4, dy: 0)             // four full turns and back where it was
        XCTAssertEqual(o.view.turn, -170, accuracy: 1e-6)
    }

    func testScrollAndPinchZoomWithinTheViewsRange() {
        var o = FigureOrbit(base: FigureView(turn: 0, tilt: 0, zoom: 1))
        o.scroll(dy: 30)
        XCTAssertEqual(o.view.zoom, exp(0.3), accuracy: 1e-9, "scrolling up zooms in")
        o.scroll(dy: -30)
        XCTAssertEqual(o.view.zoom, 1, accuracy: 1e-9, "and back down is where it was")
        o.pinch(0.5)
        XCTAssertEqual(o.view.zoom, 1.5, accuracy: 1e-9)
        o.scroll(dy: 100_000)
        XCTAssertEqual(o.view.zoom, 3)
        o.pinch(-0.99)
        o.pinch(-0.99)
        XCTAssertEqual(o.view.zoom, 0.5)
        o.zoom(by: .nan)
        o.zoom(by: -2)
        XCTAssertEqual(o.view.zoom, 0.5, "nonsense factors are ignored")
    }

    func testResetReturnsToTheModelsView() {
        let base = FigureView(turn: 60, tilt: 15, zoom: 1.2)
        var o = FigureOrbit(base: base)
        o.drag(dx: 123, dy: -45)
        o.scroll(dy: 40)
        XCTAssertTrue(o.isMoved)
        o.reset()
        XCTAssertEqual(o.view, base)
        XCTAssertFalse(o.isMoved)
    }

    // MARK: the idle turn

    func testWithoutTouchesTheIdleTurnRunsAsBefore() {
        var c = FigureIdleClock()
        XCTAssertEqual(c.turning(at: 0, from: 2), 0)
        XCTAssertEqual(c.turning(at: 2, from: 2), 0)
        XCTAssertEqual(c.turning(at: 12, from: 2), 10)
        XCTAssertEqual(c.turning(at: 82, from: 2), 80, "one revolution in 80 s, as FigureTimeline says")
    }

    func testItPausesWhileTouchedAndResumesThreeSecondsAfterTheLastTouch() {
        var c = FigureIdleClock()
        XCTAssertEqual(c.turning(at: 10, from: 0), 10)
        c.touch(at: 10)
        c.touch(at: 11)
        c.touch(at: 12)                        // a drag from 10 s to 12 s
        XCTAssertTrue(c.isPaused(at: 14.9))
        XCTAssertEqual(c.turning(at: 13, from: 0), 10, "held still while handled")
        XCTAssertEqual(c.turning(at: 14.9, from: 0), 10, accuracy: 1e-9, "and for 3 s after the last touch")
        XCTAssertFalse(c.isPaused(at: 15))
        XCTAssertEqual(c.turning(at: 15, from: 0), 10, accuracy: 1e-9, "resumes from where it stopped")
        XCTAssertEqual(c.turning(at: 20, from: 0), 15, accuracy: 1e-9)
        c.touch(at: 30)                        // a second, separate touch
        XCTAssertEqual(c.turning(at: 31, from: 0), 25, accuracy: 1e-9)
        XCTAssertEqual(c.turning(at: 40, from: 0), 25 + 7, accuracy: 1e-9)
    }

    func testTouchingWhileThePartsGrowDoesNotBorrowTime() {
        var c = FigureIdleClock()
        c.touch(at: 0.5)                       // the figure settles at 2 s
        XCTAssertEqual(c.turning(at: 2, from: 2), 0)
        XCTAssertEqual(c.turning(at: 3.4, from: 2), 0, "still within 3 s of the touch")
        XCTAssertEqual(c.turning(at: 3.5, from: 2), 0, accuracy: 1e-9)
        XCTAssertEqual(c.turning(at: 5.5, from: 2), 2, accuracy: 1e-9)
    }
}
