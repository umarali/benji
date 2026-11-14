import XCTest
@testable import BenjiCore

final class FigureAnchorsTests: XCTestCase {
    /// A camera on +z looking at -z, x right, y up, 20 view points to a unit; nearer is smaller.
    private func project(_ p: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3((p.x + 5) * 20, (5 - p.y) * 20, -p.z)
    }
    private let size = (width: 200.0, height: 200.0)

    /// A box part at `at`, as a surface.
    private func box(_ size: SIMD3<Double>, at: SIMD3<Double>, cutAxis: SIMD3<Float>? = nil, cutAt: Float = 0) -> FigureAnchors.Surface {
        let m = FigureMesh.build(.box(size: size, bevel: 0))
        let moved = m.positions.map { SIMD3<Float>(Float(at.x) + $0.x, Float(at.y) + $0.y, Float(at.z) + $0.z) }
        return FigureAnchors.Surface(positions: moved, indices: m.indices, cutAxis: cutAxis, cutAt: cutAt)
    }

    func testAnAnchorIsOnWhatShowsNotOnWhatIsNearest() {
        // A long wing running behind a body that covers its middle: only the two ends show.
        let wing = box([8, 0.4, 2], at: [0, 0, -1])
        let body = box([2, 2, 2], at: [0, 0, 1])
        let points = FigureAnchors.visiblePoints(of: [0, 1], surfaces: [wing, body], viewSize: size, project: project)
        let w = points[0]!
        XCTAssertGreaterThan(abs(w.x), 1.0, "the wing's label lands on a tip, not under the body")
        let b = points[1]!
        XCTAssertEqual(b.x, 0, accuracy: 0.3)
        XCTAssertEqual(b.z, 2, accuracy: 0.05, "the body's label is on its near face")
    }

    func testAPartWhollyBehindAnotherHasNoAnchor() {
        let hidden = box([1, 1, 1], at: [0, 0, -3])
        let front = box([4, 4, 1], at: [0, 0, 1])
        let points = FigureAnchors.visiblePoints(of: [0], surfaces: [hidden, front], viewSize: size, project: project)
        XCTAssertNil(points[0])
    }

    func testACutOpensTheCasingSoThePartInsideShows() {
        // The casing is cut away on its viewer side (z > 0): the part inside shows through.
        let inner = box([1, 1, 1], at: [0, 0, 0])
        let casing = box([4, 4, 4], at: [0, 0, 0], cutAxis: [0, 0, 1], cutAt: 0.2)
        let open = FigureAnchors.visiblePoints(of: [0], surfaces: [inner, casing], viewSize: size, project: project)
        XCTAssertNotNil(open[0])
        let closed = FigureAnchors.visiblePoints(of: [0], surfaces: [inner, box([4, 4, 4], at: [0, 0, 0])], viewSize: size, project: project)
        XCTAssertNil(closed[0], "without the cut the casing hides it")
    }

    func testAThinPartStillGetsAPointOnItself() {
        let rod = box([0.06, 6, 0.06], at: [0, 0, 0])
        let points = FigureAnchors.visiblePoints(of: [0], surfaces: [rod], viewSize: size, project: project)
        let p = points[0]
        XCTAssertNotNil(p)
        XCTAssertEqual(p?.x ?? 9, 0, accuracy: 0.1)
        XCTAssertEqual(p?.y ?? 9, 0, accuracy: 1.0, "the middle of the rod, not its tip")
    }

    func testAMiddleBeatsAnEdge() {
        let slab = box([6, 2, 1], at: [0, 0, 0])
        let p = FigureAnchors.visiblePoints(of: [0], surfaces: [slab], viewSize: size, project: project)[0]!
        XCTAssertEqual(p.x, 0, accuracy: 0.6)
        XCTAssertEqual(p.y, 0, accuracy: 0.4)
    }
}
