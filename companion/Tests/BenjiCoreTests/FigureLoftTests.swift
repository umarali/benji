import XCTest
@testable import BenjiCore

/// Lofts (D-167): one smooth skin through cross-sections along z.
final class FigureLoftTests: XCTestCase {
    private let cols = FigureGrammar.round + 1

    private func loft(_ sections: [[Double]]) -> FigureMesh { FigureMesh.build(.loft(sections: sections)) }

    func testAStraightLoftIsAnEllipticTubeWithCapsAndFillsItsBudget() {
        let sections: [[Double]] = [[-1, 0.2, 0.5, 0.25, 0], [1, 0.2, 0.5, 0.25, 0]]
        let m = loft(sections)
        XCTAssertEqual(m.vertexCount, FigureGrammar.budget("loft", .loft(sections: sections)))   // both ends capped
        let skin = m.positions.prefix((FigureGrammar.loftSteps + 1) * cols)
        for p in skin {
            let e = pow(Double(p.x) / 0.5, 2) + pow((Double(p.y) - 0.2) / 0.25, 2)
            XCTAssertEqual(e, 1, accuracy: 1e-4)
            XCTAssertTrue((-1.0001...1.0001).contains(Double(p.z)))
        }
    }

    func testSquareMakesARoundedBox() {
        func corner(_ square: Double) -> Double {
            let m = loft([[-1, 0, 1, 1, square], [1, 0, 1, 1, square]])
            return m.positions.map { min(abs(Double($0.x)), abs(Double($0.y))) }.max() ?? 0
        }
        XCTAssertEqual(corner(0), 0.707, accuracy: 0.01)     // an ellipse: cos 45°
        XCTAssertGreaterThan(corner(1), 0.8)                 // fills out toward the corner
        XCTAssertLessThan(corner(1), 1)                      // but stays rounded
    }

    func testAPointedEndClosesWithoutACap() {
        let sections: [[Double]] = [[-2, 0, 0, 0, 0], [0, 0, 1, 0.6, 0.3], [2, 0, 0.6, 0.4, 0.3]]
        let m = loft(sections)
        XCTAssertEqual(m.vertexCount, FigureGrammar.budget("loft", .loft(sections: sections)) - (cols + 1))
        let tip = m.positions.prefix(cols)
        XCTAssertTrue(tip.allSatisfy { $0 == SIMD3<Float>(0, 0, -2) })
        XCTAssertTrue(m.normals.prefix(cols).allSatisfy { $0.z < -0.99 })
    }

    func testNormalsAndTrianglesFaceOut() {
        let m = loft([[-2, 0.3, 0.2, 0.1, 0], [-1, 0.4, 0.9, 0.5, 0.6], [1, 0.5, 1, 0.5, 0.6], [2, 0.3, 0.3, 0.2, 0]])
        let rings = 3 * FigureGrammar.loftSteps + 1
        // The skin's middle rings: lit from outside (away from the body's centre line).
        for r in 2..<(rings - 2) {
            for c in 0..<cols {
                let p = SIMD3<Double>(m.positions[r * cols + c]), n = SIMD3<Double>(m.normals[r * cols + c])
                let out = SIMD3<Double>(p.x, p.y - 0.45, 0)
                XCTAssertGreaterThan(simdDot3(normalize3d(out), n), 0.2, "ring \(r) column \(c)")
            }
        }
        // Every triangle wound the way its normals face.
        for t in stride(from: 0, to: m.indices.count, by: 3) {
            let i = (0..<3).map { Int(m.indices[t + $0]) }
            let a = SIMD3<Double>(m.positions[i[0]]), b = SIMD3<Double>(m.positions[i[1]]), c = SIMD3<Double>(m.positions[i[2]])
            let face = cross3(b - a, c - a)
            guard simdLength(face) > 1e-9 else { continue }
            let n = i.map { SIMD3<Double>(m.normals[$0]) }.reduce(SIMD3<Double>.zero, +)
            XCTAssertGreaterThanOrEqual(simdDot3(face, n), 0)
        }
    }

    func testTheSkinPassesThroughEverySection() {
        let sections: [[Double]] = [[-2, 0, 0.3, 0.2, 0], [-0.5, 0.4, 1, 0.5, 0], [0.7, 0.2, 0.6, 0.3, 0], [2, 0, 0.2, 0.1, 0]]
        let m = loft(sections)
        for (k, s) in sections.enumerated() {
            let ring = Array(m.positions[(k * FigureGrammar.loftSteps * cols)..<((k * FigureGrammar.loftSteps + 1) * cols)])
            XCTAssertEqual(Double(ring[0].z), s[0], accuracy: 1e-5)
            XCTAssertEqual(Double(ring.map(\.x).max()!), s[2], accuracy: 1e-5)
            XCTAssertEqual(Double(ring.map(\.y).max()!), s[1] + s[3], accuracy: 1e-5)
        }
    }

    func testParsingReversesBackToFrontAndRejectsFolds() {
        func recipe(_ sections: String) -> FigureRecipe? {
            FigureGrammar.figure(json: #"{"parts":[{"kind":"loft","sections":\#(sections)}]}"#)?.parts.first?.recipe
        }
        XCTAssertEqual(recipe("[[1,0,0.5,0.5],[0,0,0.6,0.6,2]]"), .loft(sections: [[0, 0, 0.6, 0.6, 1], [1, 0, 0.5, 0.5, 0]]))
        XCTAssertNil(recipe("[[0,0,1,1],[1,0,1,1],[0.5,0,1,1]]"))     // folds back
        XCTAssertNil(recipe("[[0,0,0,0],[1,0,0,1]]"))                 // no section with both width and height
        XCTAssertNil(recipe("[[0,0,1,1]]"))                           // one section
    }
}
