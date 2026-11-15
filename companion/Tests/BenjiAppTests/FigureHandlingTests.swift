import Foundation
import XCTest
@testable import BenjiApp
import BenjiCore

/// Turning the figure by hand, through the scene: what the card's
/// input panel writes (FigureHandling) reaches the camera on the next frame, the idle turn holds
/// still while handled, reset returns to the model's view. A scene is built and projected; nothing
/// is rendered and no window is made.
final class FigureHandlingTests: XCTestCase {
    static func scene() throws -> FigureScene {
        let f = try FigureFramingTests.figure("airliner")
        return FigureScene(figure: f, meshes: FigureScene.meshes(for: f, cache: FigureMeshCache()),
                           aspect: Double(FigureFramingTests.stage.width / FigureFramingTests.stage.height))
    }

    func testADragReachesTheCameraOnTheNextFrame() throws {
        let fs = try Self.scene()
        let base = fs.figure.view
        let t = fs.timeline.settled + 1
        fs.apply(at: t)
        XCTAssertEqual(fs.view, base)
        fs.handling.handle(at: t) { $0.drag(dx: 100, dy: 0) }
        fs.apply(at: t + 0.016)
        XCTAssertEqual(fs.view.turn, base.turn - 40, accuracy: 1e-9)
        XCTAssertEqual(Double(fs.turnNode.eulerAngles.y), (base.turn - 40) * .pi / 180, accuracy: 1e-5)
        XCTAssertTrue(fs.handling.isMoved)
    }

    func testTheIdleTurnHoldsWhileHandledAndResumesAfter() throws {
        let fs = try Self.scene()
        let t0 = fs.timeline.settled + 10
        fs.apply(at: t0)
        let before = Double(fs.idleNode.eulerAngles.y)
        fs.handling.handle(at: t0) { $0.drag(dx: 5, dy: 0) }
        fs.apply(at: t0 + 1)
        fs.apply(at: t0 + 2.9)
        XCTAssertEqual(Double(fs.idleNode.eulerAngles.y), before, accuracy: 1e-9, "held still while handled")
        fs.apply(at: t0 + 3 + 8)
        let after = Double(fs.idleNode.eulerAngles.y)
        XCTAssertEqual(after - before, 8.0 / FigureTimeline.idleRevolution * 2 * .pi, accuracy: 1e-6,
                       "resumes 3 s after the last touch, from where it stopped")
    }

    func testResetReturnsToTheModelsView() throws {
        let fs = try Self.scene()
        let t = fs.timeline.settled + 1
        fs.handling.handle(at: t) { $0.drag(dx: -200, dy: 120); $0.scroll(dy: 40) }
        fs.handling.endDrag()
        fs.apply(at: t + 0.1)
        XCTAssertNotEqual(fs.view, fs.figure.view)
        fs.handling.reset(at: t + 0.2)
        fs.apply(at: t + 0.3)
        XCTAssertEqual(fs.view, fs.figure.view)
        XCTAssertFalse(fs.handling.isMoved)
    }

    /// After a tilt by hand, the framing is measured again for the new height: at zoom 1 the figure
    /// still stays on the stage through a whole idle turn.
    func testAfterATiltByHandTheFigureStillStaysOnTheStage() throws {
        let fs = try Self.scene()
        let card = CGRect(origin: .zero, size: FigureFramingTests.stage.size)
        fs.handling.handle(at: 0) { $0.drag(dx: 0, dy: -200) }    // down: from well above (tilt 80)
        fs.handling.endDrag()
        for k in 0..<72 {   // from 4 s after settling: past the 3 s pause
            let b = FigureFramingTests.box(fs, after: 4 + Double(k) / 72 * FigureTimeline.idleRevolution)
            XCTAssertTrue(card.insetBy(dx: -1, dy: -1).contains(b), "at \(Double(k) * 5)° of the turn: \(b)")
        }
        XCTAssertEqual(fs.view.tilt, 80)
    }

    func testAPlainFigureBehavesAsBefore() throws {
        // No handling: the idle angle is the same function of time as before the hand came in.
        let fs = try Self.scene()
        for t in [0.0, 5, 30, 79] {
            fs.apply(at: fs.timeline.settled + t)
            XCTAssertEqual(Double(fs.idleNode.eulerAngles.y), t / FigureTimeline.idleRevolution * 2 * .pi, accuracy: 1e-6)
        }
    }
}
