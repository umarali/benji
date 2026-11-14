import XCTest
@testable import BenjiCore

/// The higher-level parts (D-158): blobs, tapered tubes, scattered copies and spinning parts.
final class FigurePartsTests: XCTestCase {
    func testOneBallIsASphereFacingOut() {
        let m = FigureBlob.mesh(balls: [[0, 0, 0, 1]], smooth: 0.4, wobble: 0)
        XCTAssertGreaterThan(m.vertexCount, 500)
        for (p, n) in zip(m.positions, m.normals) {
            let d = SIMD3<Double>(p)
            XCTAssertEqual(simdLength(d), 1, accuracy: 0.03)          // on the surface
            XCTAssertGreaterThan(simdDot3(normalize3d(d), SIMD3<Double>(n)), 0.95)   // lit from outside
        }
        // Every triangle faces out: its winding agrees with the outward direction.
        for t in stride(from: 0, to: m.indices.count, by: 3) {
            let a = SIMD3<Double>(m.positions[Int(m.indices[t])]), b = SIMD3<Double>(m.positions[Int(m.indices[t + 1])])
            let c = SIMD3<Double>(m.positions[Int(m.indices[t + 2])])
            XCTAssertGreaterThan(simdDot3(cross3(b - a, c - a), a + b + c), 0)
        }
    }

    func testABlobIsClosed() {
        // A closed surface: every edge belongs to exactly two triangles.
        let m = FigureBlob.mesh(balls: [[0, 0, 0, 1], [1.3, 0.2, 0, 0.7], [-0.8, 0.6, 0.4, 0.6]], smooth: 0.5, wobble: 0.15)
        var edges: [UInt64: Int] = [:]
        for t in stride(from: 0, to: m.indices.count, by: 3) {
            for (a, b) in [(m.indices[t], m.indices[t + 1]), (m.indices[t + 1], m.indices[t + 2]), (m.indices[t + 2], m.indices[t])] {
                edges[UInt64(min(a, b)) << 32 | UInt64(max(a, b)), default: 0] += 1
            }
        }
        XCTAssertFalse(edges.isEmpty)
        XCTAssertTrue(edges.values.allSatisfy { $0 == 2 }, "open edges: \(edges.values.filter { $0 != 2 }.count)")
    }

    func testTheSmoothBlendFillsTheNeck() {
        // Two balls just touching: with a blend the neck between them is filled in.
        let hard = FigureBlob.Field(balls: [[-1, 0, 0, 1], [1, 0, 0, 1]], k: 0, wobble: 0)
        let soft = FigureBlob.Field(balls: [[-1, 0, 0, 1], [1, 0, 0, 1]], k: 0.8, wobble: 0)
        XCTAssertGreaterThan(hard.value([0, 0.3, 0]), 0)    // outside without a blend
        XCTAssertLessThan(soft.value([0, 0.3, 0]), 0)       // inside with one
    }

    func testTheBudgetHoldsForTheWorstBlob() {
        let balls: [SIMD4<Double>] = (0..<16).map { i in
            let a = Double(i) * 0.7
            return [cos(a) * Double(i) * 0.6, sin(a * 1.3) * 3, sin(a) * Double(i) * 0.4, 0.5 + Double(i % 3) * 0.4]
        }
        let m = FigureBlob.mesh(balls: balls, smooth: 1, wobble: 0.5)
        XCTAssertLessThanOrEqual(m.vertexCount, FigureBlob.budget)
        XCTAssertGreaterThan(m.vertexCount, 1000)
        XCTAssertEqual(FigureGrammar.budget("blob", .blob(balls: balls, smooth: 1, wobble: 0.5, chain: false)), FigureBlob.budget)
    }

    func testAChainJoinsBallsThatDoNotTouch() {
        // Balls 1 apart with radii 0.2: alone they are beads; chained they are one limb.
        let balls: [SIMD4<Double>] = [[0, 0, 0, 0.2], [0, 1, 0, 0.2], [0, 2, 0, 0.1]]
        let beads = FigureBlob.Field(balls: balls, k: 0.2, wobble: 0)
        let limb = FigureBlob.Field(balls: balls, k: 0.2, wobble: 0, chain: true)
        XCTAssertGreaterThan(beads.value([0, 0.5, 0]), 0)
        XCTAssertLessThan(limb.value([0, 0.5, 0]), 0)
        XCTAssertLessThan(limb.value([0, 1.5, 0.12]), 0)       // tapering: 0.15 halfway up the last segment
        XCTAssertGreaterThan(limb.value([0, 1.5, 0.2]), 0)
        let m = FigureBlob.mesh(balls: balls, smooth: 0.2, wobble: 0, chain: true)
        XCTAssertGreaterThan(m.vertexCount, 300)
    }

    func testABlobIsTheSameEveryTime() {
        let a = FigureBlob.mesh(balls: [[0, 0, 0, 1], [0.9, 0.3, 0, 0.6]], smooth: 0.3, wobble: 0.2)
        let b = FigureBlob.mesh(balls: [[0, 0, 0, 1], [0.9, 0.3, 0, 0.6]], smooth: 0.3, wobble: 0.2)
        XCTAssertEqual(a, b)
    }

    func testATubeTapersFromRToR2() {
        let m = FigureMesh.build(.tube(r: 0.4, path: [[0, 0, 0], [0, 2, 0]], r2: 0.1))
        let start = m.positions.filter { abs($0.y) < 1e-4 && simdLength(SIMD3<Double>($0)) > 1e-3 }
        let end = m.positions.filter { abs($0.y - 2) < 1e-4 && hypot(Double($0.x), Double($0.z)) > 1e-3 }
        XCTAssertFalse(start.isEmpty); XCTAssertFalse(end.isEmpty)
        for p in start { XCTAssertEqual(hypot(Double(p.x), Double(p.z)), 0.4, accuracy: 1e-4) }
        for p in end { XCTAssertEqual(hypot(Double(p.x), Double(p.z)), 0.1, accuracy: 1e-4) }
        XCTAssertLessThanOrEqual(m.vertexCount, FigureGrammar.budget("tube", .tube(r: 0.4, path: [[0, 0, 0], [0, 2, 0]], r2: 0.1)))
    }

    func testScatterIsSeededAndStaysInside() {
        let s = FigurePart.Scatter(count: 50, inside: [2, 1, 0.5], seed: 7)
        let a = FigurePlacement.scatter(s), b = FigurePlacement.scatter(s)
        XCTAssertEqual(a.count, 50)
        XCTAssertEqual(a.map(\.0), b.map(\.0))
        for (o, _) in a {
            let q = o / s.inside
            XCTAssertLessThanOrEqual(simdDot3(q, q), 1 + 1e-9)
        }
        // Another seed gives other places.
        XCTAssertNotEqual(FigurePlacement.scatter(.init(count: 50, inside: [2, 1, 0.5], seed: 8)).map(\.0), a.map(\.0))
        // Spread out, not bunched: the mean is near the middle.
        let mean = a.reduce(SIMD3<Double>(0, 0, 0)) { $0 + $1.0 } / 50
        XCTAssertLessThan(simdLength(mean), 0.5)
    }

    func testScatteredCopiesArePlaced() throws {
        let reply = "x\n```figure\n{\"parts\":[{\"name\":\"dots\",\"kind\":\"sphere\",\"r\":0.1,\"at\":[5,0,0],\"scatter\":{\"count\":12,\"in\":1}}]}\n```"
        let f = try XCTUnwrap(FigureGrammar.parse(reply).figure)
        let t = try XCTUnwrap(FigurePlacement.fullTransforms(f)["dots"])
        XCTAssertEqual(t.count, 12)
        for m in t {
            let c = m.apply([0, 0, 0])
            XCTAssertLessThanOrEqual(simdLength(c - [5, 0, 0]), 1 + 1e-9)   // round the part's own place
        }
        XCTAssertGreaterThan(Set(t.map { Canonical.number($0.apply([0, 0, 0]).x) }).count, 6)
    }

    func testARingIsCopiedWithItsPart() throws {
        // Five spokes round the front hub, copied 2.65 back: the copies circle the rear hub.
        let reply = "x\n```figure\n{\"parts\":[{\"name\":\"spoke\",\"kind\":\"box\",\"size\":[0.05,0.4,0.05],\"at\":[0,0.56,1.3],"
            + "\"copies\":{\"count\":2,\"step\":[0,0,-2.65]},\"around\":{\"count\":5,\"axis\":\"z\",\"center\":[0,0.36,1.3]}}]}\n```"
        let f = try XCTUnwrap(FigureGrammar.parse(reply).figure)
        let t = try XCTUnwrap(FigurePlacement.fullTransforms(f)["spoke"])
        XCTAssertEqual(t.count, 10)
        for m in t {
            let p = m.apply([0, 0, 0])
            let hub: SIMD3<Double> = p.z > 0 ? [0, 0.36, 1.3] : [0, 0.36, -1.35]
            XCTAssertEqual(simdLength(p - hub), 0.2, accuracy: 1e-9, "every spoke sits 0.2 from its own hub")
        }
        // Spinning, each copy turns about its own hub too.
        var spun = f.parts[0]
        spun.spin = .init(rpm: 20, axis: nil, center: nil)
        let lines = FigurePlacement.spinLines(spun, copies: t)
        XCTAssertEqual(Set(lines.map { Canonical.number($0.center.z) }), ["1.3", "-1.35"])
    }

    func testSpinLines() throws {
        let reply = """
        x
        ```figure
        {"parts":[{"name":"blade","kind":"box","size":[0.2,1.5,0.05],"at":[0,0.9,0],"around":{"count":3,"axis":"z","center":[0,0,0.2]},"spin":12},
        {"name":"wheels","kind":"cyl","r":0.4,"h":0.3,"axis":"x","at":[1,0.4,1.2],"mirror":"x","copies":{"count":2,"step":[0,0,-2.4]},"spin":30},
        {"name":"rotor","kind":"cyl","r":1,"h":0.1,"at":[0,4,0],"spin":{"rpm":20,"axis":"y","center":[0,5,0]}}]}
        ```
        """
        let f = try XCTUnwrap(FigureGrammar.parse(reply).figure)
        let full = FigurePlacement.fullTransforms(f)
        // Blades round a hub turn together about the ring's line.
        let blade = FigurePlacement.spinLines(try XCTUnwrap(f.part(named: "blade")), copies: full["blade"]!)
        XCTAssertEqual(blade.count, 3)
        for l in blade { XCTAssertEqual(l.axis, [0, 0, 1]); XCTAssertEqual(l.center, [0, 0, 0.2]) }
        // Four wheels: each turns about its own axle, along x.
        let wheels = FigurePlacement.spinLines(try XCTUnwrap(f.part(named: "wheels")), copies: full["wheels"]!)
        XCTAssertEqual(Set(wheels.map { "\(Canonical.number($0.center.x)),\(Canonical.number($0.center.z))" }),
                       ["1,1.2", "-1,1.2", "1,-1.2", "-1,-1.2"])
        for l in wheels { XCTAssertEqual(abs(l.axis.x), 1, accuracy: 1e-9) }
        // A centre as written: one line for the part.
        let rotor = FigurePlacement.spinLines(try XCTUnwrap(f.part(named: "rotor")), copies: full["rotor"]!)
        XCTAssertEqual(rotor.first?.axis, [0, 1, 0]); XCTAssertEqual(rotor.first?.center, [0, 5, 0])
    }
}
