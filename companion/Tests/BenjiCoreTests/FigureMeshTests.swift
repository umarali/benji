import Foundation
import XCTest
@testable import BenjiCore

/// Mesh generators, placements, the reveal clock and label placement for figures.
final class FigureMeshTests: XCTestCase {
    static func figure(_ name: String) throws -> Figure {
        let reply = try FigureGrammarTests.cases().first { $0.name == name }!.reply
        return try XCTUnwrap(FigureGrammar.parse(reply).figure)
    }

    static func allParts() throws -> [FigurePart] {
        try FigureGrammarTests.cases().compactMap { FigureGrammar.parse($0.reply).figure }.flatMap(\.parts)
    }

    func testEveryMeshStaysWithinItsBudgetAndIsWellFormed() throws {
        let parts = try Self.allParts()
        XCTAssertGreaterThan(parts.count, 100)
        for p in parts {
            let m = FigureMesh.build(p.recipe)
            XCTAssertGreaterThan(m.vertexCount, 0, p.recipe.canonical)
            XCTAssertLessThanOrEqual(m.vertexCount, p.budget, p.recipe.canonical)
            XCTAssertEqual(m.normals.count, m.vertexCount)
            XCTAssertEqual(m.indices.count % 3, 0)
            XCTAssertTrue(m.indices.allSatisfy { Int($0) < m.vertexCount })
            XCTAssertTrue(m.normals.allSatisfy { abs(($0 * $0).sum().squareRoot() - 1) < 1e-3 }, p.recipe.canonical)
            XCTAssertTrue(m.positions.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
            XCTAssertFalse(m.samples.isEmpty)
            XCTAssertLessThanOrEqual(m.samples.count, FigureMesh.sampleCount)
        }
    }

    func testRoundPartsFillTheirBudgetExactly() {
        XCTAssertEqual(FigureMesh.build(.sphere(r: 1)).vertexCount, 49 * 25)
        XCTAssertEqual(FigureMesh.build(.torus(r: 1, tube: 0.2)).vertexCount, 49 * 25)
        XCTAssertEqual(FigureMesh.build(.capsule(r: 0.5, h: 3)).vertexCount, 49 * 26)
        XCTAssertEqual(FigureMesh.build(.box(size: [1, 2, 3], bevel: 0.1)).vertexCount, 600)
        XCTAssertEqual(FigureMesh.build(.box(size: [1, 2, 3], bevel: 0)).vertexCount, 24)
        XCTAssertEqual(FigureMesh.build(.tube(r: 0.1, path: [[0, 0, 0], [1, 0, 0], [1, 1, 0]], r2: 0.1)).vertexCount, 17 * 9 + 36)
    }

    /// Closed convex parts: every triangle faces away from the centre, so culling and the
    /// outline pass are right; sizes come out as asked.
    func testConvexPartsFaceOutwardAndHaveTheirSize() {
        let recipes: [FigureRecipe] = [.sphere(r: 1), .box(size: [2, 1, 0.5], bevel: 0.1), .box(size: [1, 1, 1], bevel: 0),
                                       .cyl(r: 0.5, h: 2, bevel: 0.05), .cyl(r: 0.5, h: 2, bevel: 0),
                                       .cone(r: 1, r2: 0, h: 2, bevel: 0.1), .cone(r: 1, r2: 0.4, h: 1, bevel: 0),
                                       .capsule(r: 0.3, h: 2)]
        for r in recipes {
            let m = FigureMesh.build(r)
            var outward = 0, total = 0
            for t in stride(from: 0, to: m.indices.count, by: 3) {
                let a = m.positions[Int(m.indices[t])], b = m.positions[Int(m.indices[t + 1])], c = m.positions[Int(m.indices[t + 2])]
                let n = crossF(b - a, c - a)
                guard (n * n).sum() > 1e-12 else { continue }
                total += 1
                if ((a + b + c) / 3 * n).sum() > 0 { outward += 1 }
            }
            XCTAssertEqual(outward, total, r.canonical)
            let lo = m.positions.reduce(SIMD3<Float>(repeating: .infinity)) { pointwiseMin($0, $1) }
            let hi = m.positions.reduce(SIMD3<Float>(repeating: -.infinity)) { pointwiseMax($0, $1) }
            let size = hi - lo
            switch r {
            case let .box(s, _): XCTAssertEqual(Double(size.x), s.x, accuracy: 1e-5); XCTAssertEqual(Double(size.y), s.y, accuracy: 1e-5)
            case let .cyl(rad, h, _): XCTAssertEqual(Double(size.y), h, accuracy: 1e-5); XCTAssertEqual(Double(size.x), 2 * rad, accuracy: 1e-3)
            case let .capsule(_, h): XCTAssertEqual(Double(size.y), h, accuracy: 1e-5)
            case let .sphere(rad): XCTAssertEqual(Double(size.y), 2 * rad, accuracy: 1e-5)
            default: break
            }
        }
    }

    func testMirroredMeshReflectsAndRewinds() {
        let m = FigureMesh.build(.cone(r: 1, r2: 0.2, h: 1, bevel: 0.1))
        let w = m.mirroredX()
        XCTAssertEqual(w.positions.first.map { -$0.x }, m.positions.first?.x)
        XCTAssertEqual(w.indices[1], m.indices[2])
        XCTAssertEqual(w.mirroredX(), m)
    }

    func testExtrudeAndLatheFromPaths() {
        let roof = FigureMesh.build(.extrude(path: "M-2.4 0 L2.4 0 L0 1.6 Z", depth: 3.4, bevel: 0.05))
        XCTAssertEqual(roof.vertexCount, 2 * 3 + 4 * 3 * 3)
        let ys = roof.positions.map(\.y)
        XCTAssertEqual(ys.max()!, 1.6, accuracy: 1e-5, "outlines are y up: the apex stands up")
        XCTAssertEqual(ys.min()!, 0, accuracy: 1e-5)
        let letter = FigureMesh.build(.extrude(path: "M0 0 L2 0 C2 2 0 2 0 0 Z", depth: 0.5, bevel: 0))
        XCTAssertEqual(letter.vertexCount, 2 * 9 + 4 * 9)
        // A profile walked down the outside still faces out.
        let down = FigureMesh.build(.lathe(profile: [[0, 1], [1, 1], [1, -1], [0, -1]]))
        let side = down.positions.indices.filter { down.positions[$0].x > 0.99 && abs(down.positions[$0].z) < 0.01 }
        XCTAssertTrue(side.contains { down.normals[$0].x > 0.99 })
        XCTAssertFalse(side.contains { down.normals[$0].x < -0.5 })
        let top = down.positions.indices.filter { down.positions[$0] == SIMD3(0, 1, 0) }
        XCTAssertTrue(!top.isEmpty && top.allSatisfy { down.normals[$0].y > 0.99 })
    }

    func testCacheSharesOneMeshPerRecipe() throws {
        let cache = FigureMeshCache()
        let f = try Self.figure("airliner")
        for p in f.parts { _ = cache.mesh(for: p.recipe) }
        let unique = Set(f.parts.map(\.recipe.canonical)).count
        XCTAssertEqual(cache.count, unique)
        _ = cache.mesh(for: f.parts[0].recipe)
        XCTAssertEqual(cache.count, unique)
        // Six spheres of one size, in different materials and places: one mesh.
        let spheres = FigureGrammar.parse(try FigureGrammarTests.cases().first { $0.name == "materials" }!.reply).figure!
        let shared = FigureMeshCache()
        for p in spheres.parts { _ = shared.mesh(for: p.recipe) }
        XCTAssertEqual(spheres.parts.count, 6)
        XCTAssertEqual(shared.count, 1)
    }

    /// Mesh build time for each hand-written figure, cold (no cache). The target: an airliner of
    /// about a dozen parts well under 100 ms.
    func testBuildTimes() throws {
        for name in ["airliner", "house", "jet engine with a cut"] {
            let f = try Self.figure(name)
            let start = Date()
            let cache = FigureMeshCache()
            for p in f.parts { _ = cache.mesh(for: p.recipe) }
            let ms = Date().timeIntervalSince(start) * 1000
            print("[figure-build] \(name): \(f.parts.count) parts, \(cache.count) meshes, \(String(format: "%.1f", ms)) ms")
            XCTAssertLessThan(ms, 100, name)
        }
    }

    // MARK: placements

    func testMirrorAroundCopiesAndParent() throws {
        let f = try Self.figure("airliner")
        let all = FigurePlacement.instances(f)
        let wing = try XCTUnwrap(all["wing"])
        XCTAssertEqual(wing.count, 2)
        XCTAssertEqual(wing.map(\.mirrored), [false, true])
        let p0 = wing[0].transform.apply([0, 0, 0]), p1 = wing[1].transform.apply([0, 0, 0])
        XCTAssertEqual(p0.x, 2.4, accuracy: 1e-9); XCTAssertEqual(p1.x, -2.4, accuracy: 1e-9)
        XCTAssertTrue(all.values.joined().allSatisfy { $0.transform.determinant3 > 0 })
        XCTAssertEqual(all["cabin windows"]?.count, 32)
        // from/to: the cylinder's ends land on the points given.
        let engine = try XCTUnwrap(all["engine"]?.first)
        let ends = [engine.transform.apply([0, 0.65, 0]), engine.transform.apply([0, -0.65, 0])]
        XCTAssertTrue(ends.contains { simdLength($0 - [1.9, -0.68, 1.3]) < 1e-9 })
        XCTAssertTrue(ends.contains { simdLength($0 - [1.9, -0.68, 0]) < 1e-9 })

        let jet = try Self.figure("jet engine with a cut")
        let blades = try XCTUnwrap(FigurePlacement.instances(jet)["fan blade"])
        XCTAssertEqual(blades.count, 18)
        let tip0 = blades[0].transform.apply([0, 0, 0]), tip1 = blades[1].transform.apply([0, 0, 0])
        let angle = acos(simdDot3(normalize3d(SIMD3(tip0.x, tip0.y, 0)), normalize3d(SIMD3(tip1.x, tip1.y, 0)))) * 180 / .pi
        XCTAssertEqual(angle, 20, accuracy: 1e-6)

        let reply = try FigureGrammarTests.cases().first { $0.name == "placements and parent" }!.reply
        let pp = FigureGrammar.parse(reply).figure!
        let placed = FigurePlacement.instances(pp)
        XCTAssertEqual(placed["hub"]?.count, 4)
        XCTAssertEqual(placed["blade"]?.count, 24)
        XCTAssertEqual(placed["bolt"]?.count, 4)
        for p in pp.parts { XCTAssertEqual(placed[p.name]?.count, p.instances, p.name) }
    }

    func testBoundsCoverTheFigure() throws {
        let f = try Self.figure("airliner")
        var meshes: [String: FigureMesh] = [:]
        for p in f.parts { meshes[p.name] = FigureMesh.build(p.recipe) }
        let b = FigurePlacement.bounds(f, meshes: meshes)
        XCTAssertEqual(b.radius, 5, accuracy: 0.6)   // a 9.2-long fuselage, 9.4 of wingspan
        XCTAssertLessThan(simdLength(b.centre), 0.6)
    }

    // MARK: motion

    func testPartsAppearInOrderWithAFloor() {
        let t = FigureTimeline(parts: 10)
        XCTAssertEqual(t.cues.first, 0)
        XCTAssertEqual(t.cues[1], FigureTimeline.partFloor, accuracy: 1e-12)
        XCTAssertEqual(t.scale(part: 3, at: t.cues[3]), 0)
        XCTAssertEqual(t.scale(part: 3, at: t.cues[3] + FigureTimeline.grow), 1)
        XCTAssertGreaterThan((1...9).map { t.scale(part: 0, at: Double($0) * 0.035) }.max()!, 1, "a small overshoot")
        XCTAssertLessThan((1...9).map { t.scale(part: 0, at: Double($0) * 0.035) }.max()!, 1.1)
        XCTAssertEqual(t.settled, 9 * 0.25 + 0.35, accuracy: 1e-12)
        let paced = FigureTimeline(parts: 4, span: 3)
        XCTAssertEqual(paced.cues, [0, 0.75, 1.5, 2.25])
        XCTAssertEqual(FigureTimeline(parts: 40, span: 3).cues[1], FigureTimeline.partFloor)
        XCTAssertEqual(FigureTimeline.idleTurn(after: 80, reduceMotion: false), 360, accuracy: 1e-9)
        XCTAssertEqual(FigureTimeline.idleTurn(after: 80, reduceMotion: true), 0)
    }

    func testCameraTurnsRightAndRaisesWithTilt() {
        let front = FigureCamera.position(view: FigureView(turn: 0, tilt: 0), centre: .zero, radius: 1)
        XCTAssertGreaterThan(front.z, 0); XCTAssertEqual(front.x, 0, accuracy: 1e-12)
        let right = FigureCamera.position(view: FigureView(turn: 90, tilt: 0), centre: .zero, radius: 1)
        XCTAssertGreaterThan(right.x, 0)
        let above = FigureCamera.position(view: FigureView(turn: 0, tilt: 60), centre: .zero, radius: 1)
        XCTAssertGreaterThan(above.y, 0)
        let near = FigureCamera.position(view: FigureView(turn: 0, tilt: 0, zoom: 2), centre: .zero, radius: 1)
        XCTAssertEqual(simdLength(near) * 2, simdLength(front), accuracy: 1e-9)
    }

    // MARK: labels

    func testLabelsSitInTheMarginsInAnchorOrderAndNeverOverTheModel() {
        let model = CGRect(x: 200, y: 60, width: 200, height: 240)
        let area = CGRect(x: 12, y: 12, width: 576, height: 340)
        let size = CGSize(width: 90, height: 22)
        let items = [FigureLabelLayout.Item(anchor: CGPoint(x: 250, y: 200), size: size, side: ""),
                     .init(anchor: CGPoint(x: 260, y: 100), size: size, side: ""),
                     .init(anchor: CGPoint(x: 255, y: 105), size: size, side: ""),
                     .init(anchor: CGPoint(x: 380, y: 120), size: size, side: ""),
                     .init(anchor: CGPoint(x: 380, y: 120), size: size, side: "left"),
                     .init(anchor: CGPoint(x: 300, y: 70), size: size, side: "top")]
        let frames = FigureLabelLayout.place(items, model: model, area: area)
        XCTAssertTrue(frames.allSatisfy { $0 != nil })
        let f = frames.map { $0! }
        XCTAssertTrue(f.allSatisfy { !$0.intersects(model) && area.contains($0) })
        XCTAssertLessThan(f[0].maxX, model.minX); XCTAssertLessThan(f[1].maxX, model.minX)
        XCTAssertGreaterThan(f[3].minX, model.maxX)
        XCTAssertLessThan(f[4].maxX, model.minX, "a side hint wins")
        XCTAssertLessThan(f[5].maxY, model.minY)
        // Column order follows the anchors, without overlaps.
        XCTAssertLessThan(f[1].maxY, f[2].minY + 0.01)
        XCTAssertLessThan(f[2].maxY, f[0].minY + 0.01)
        for a in f.indices { for b in f.indices where a < b { XCTAssertFalse(f[a].intersects(f[b]), "\(a) \(b)") } }
    }

    func testALabelWithNoRoomOnItsSideTriesTheOther() {
        let area = CGRect(x: 0, y: 0, width: 600, height: 300)
        let model = CGRect(x: 60, y: 40, width: 300, height: 200)   // little room on the left
        let frames = FigureLabelLayout.place([.init(anchor: CGPoint(x: 100, y: 100), size: CGSize(width: 120, height: 22), side: "")],
                                             model: model, area: area)
        let f = try! XCTUnwrap(frames[0])
        XCTAssertGreaterThan(f.minX, model.maxX)
    }

    func testTheCardIsCentredAndKeepsClearOfBenjisPanel() {
        let visible = CGRect(x: 0, y: 64, width: 1512, height: 885)            // AppKit: y up
        let size = CGSize(width: 600, height: 400)
        let free = FigureCardPlacement.frame(cardSize: size, visible: visible, avoid: [])
        XCTAssertEqual(free.midX, visible.midX, accuracy: 0.5)
        XCTAssertEqual(free.midY, visible.midY, accuracy: 0.5)
        let panel = CGRect(x: 556, y: 600, width: 400, height: 382)              // a tall open notch panel
        let moved = FigureCardPlacement.frame(cardSize: size, visible: visible, avoid: [panel])
        XCTAssertLessThanOrEqual(moved.maxY, panel.minY - FigureCardPlacement.margin, "below the panel, y up")
        XCTAssertTrue(visible.contains(moved))
        let flipped = FigureCardPlacement.frame(cardSize: size, visible: CGRect(x: 0, y: 33, width: 1512, height: 885),
                                                avoid: [CGRect(x: 556, y: 0, width: 400, height: 300)], flipped: true)
        XCTAssertGreaterThanOrEqual(flipped.minY, 300 + FigureCardPlacement.margin, "below the panel, y down")
    }

    func testALabelWithNoRoomIsNotDrawn() {
        let area = CGRect(x: 0, y: 0, width: 300, height: 200)
        let model = CGRect(x: 10, y: 10, width: 280, height: 180)   // the model fills the stage
        let frames = FigureLabelLayout.place([.init(anchor: CGPoint(x: 50, y: 50), size: CGSize(width: 80, height: 20), side: "")],
                                             model: model, area: area)
        XCTAssertNil(frames[0])
    }
}
