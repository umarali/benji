import XCTest
@testable import BenjiCore

/// Benji beside the pointer.
final class PointerCompanionTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)

    func testItIsOnUnlessTurnedOff() {
        XCTAssertTrue(PointerCompanion.isOn(from: nil))
        XCTAssertFalse(PointerCompanion.isOn(from: false))
    }

    func testItShowsWhileBenjiIsActiveOrWaitingOnYou() {
        for phase in [CompanionPhase.listening, .transcribing, .thinking, .speaking, .awaitingApproval] {
            XCTAssertTrue(PointerCompanion.shows(phase: phase, enabled: true), phase.rawValue)
            XCTAssertFalse(PointerCompanion.shows(phase: phase, enabled: false), phase.rawValue)
        }
        for phase in [CompanionPhase.idle, .error] { XCTAssertFalse(PointerCompanion.shows(phase: phase, enabled: true), phase.rawValue) }
    }

    func testTheArrowTipSitsBesideThePointerAndTheWordOnItsRight() {
        let placed = PointerCompanion.placement(pointer: CGPoint(x: 300, y: 400), screen: screen)
        XCTAssertTrue(placed.wordOnRight)
        XCTAssertEqual(placed.frame.minX + PointerCompanion.tip.x, 300 + PointerCompanion.offset.dx)
        XCTAssertEqual(placed.frame.maxY - PointerCompanion.tip.y, 400 - PointerCompanion.offset.dy)
        XCTAssertEqual(placed.frame.size, PointerCompanion.panelSize)
    }

    func testNearTheRightEdgeTheWordMovesLeftAndStaysOnTheDisplay() {
        let placed = PointerCompanion.placement(pointer: CGPoint(x: 990, y: 400), screen: screen)
        XCTAssertFalse(placed.wordOnRight)
        XCTAssertLessThanOrEqual(placed.frame.maxX, screen.maxX)
    }

    func testItStaysOnTheDisplayAtTheCorners() {
        for point in [CGPoint(x: 0, y: 0), CGPoint(x: 999, y: 799), CGPoint(x: 0, y: 799)] {
            XCTAssertTrue(screen.contains(PointerCompanion.placement(pointer: point, screen: screen).frame), "\(point)")
        }
    }
}
