import XCTest
@testable import BenjiCore

final class PanelGeometryTests: XCTestCase {
    let idle = CGSize(width: 220, height: 40)
    let expanded = CGSize(width: 420, height: 320)

    func notchScreen() -> ScreenMetrics {
        // A 1512×982 notch laptop at origin (0,0); notch/menu ~ 37pt.
        ScreenMetrics(fullFrame: CGRect(x: 0, y: 0, width: 1512, height: 982), topInset: 37)
    }

    func externalScreen() -> ScreenMetrics {
        // A second display to the right with a 24pt menu bar, no notch.
        ScreenMetrics(fullFrame: CGRect(x: 1512, y: 0, width: 1920, height: 1080), topInset: 24)
    }

    func testHorizontallyCentered() {
        let l = PanelGeometry.layout(screen: notchScreen(), idleSize: idle, expandedSize: expanded)
        XCTAssertEqual(l.idleFrame.midX, 1512 / 2, accuracy: 0.5)
        XCTAssertEqual(l.expandedFrame.midX, 1512 / 2, accuracy: 0.5)
    }

    func testSharedTopEdge() {
        let l = PanelGeometry.layout(screen: notchScreen(), idleSize: idle, expandedSize: expanded)
        XCTAssertEqual(l.idleFrame.maxY, l.expandedFrame.maxY, accuracy: 0.5)
        // Top edge sits below the notch inset.
        XCTAssertLessThanOrEqual(l.idleFrame.maxY, 982 - 37)
    }

    func testExpandsDownward() {
        let l = PanelGeometry.layout(screen: notchScreen(), idleSize: idle, expandedSize: expanded)
        XCTAssertLessThan(l.expandedFrame.minY, l.idleFrame.minY)
        XCTAssertGreaterThan(l.expandedFrame.height, l.idleFrame.height)
    }

    func testStaysWithinDisplay() {
        let s = notchScreen()
        let l = PanelGeometry.layout(screen: s, idleSize: idle, expandedSize: expanded)
        for f in [l.idleFrame, l.expandedFrame] {
            XCTAssertGreaterThanOrEqual(f.minX, s.fullFrame.minX)
            XCTAssertLessThanOrEqual(f.maxX, s.fullFrame.maxX)
            XCTAssertGreaterThanOrEqual(f.minY, s.fullFrame.minY)
            XCTAssertLessThanOrEqual(f.maxY, s.fullFrame.maxY)
        }
    }

    func testSecondaryDisplayOffset() {
        let s = externalScreen()
        let l = PanelGeometry.layout(screen: s, idleSize: idle, expandedSize: expanded)
        // Frames land on the external display, not the primary.
        XCTAssertGreaterThanOrEqual(l.expandedFrame.minX, 1512)
        XCTAssertEqual(l.expandedFrame.midX, 1512 + 1920 / 2, accuracy: 0.5)
        XCTAssertLessThanOrEqual(l.expandedFrame.maxX, 1512 + 1920)
    }
}
