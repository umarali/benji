import Foundation

/// A loft: one smooth skin through cross-sections along z. Each section is
/// [z, y, w, h, square]: centred at height y, half-width w (along x), half-height h, its outline a
/// superellipse from an ellipse (square 0) to a rounded box (square 1). Between sections the
/// height, size and squareness follow a Catmull-Rom curve, so a few sections make a body with no
/// creases; a section with no width or height closes the body to a point. Open ends get a flat cap.
extension FigureMesh {
    static func loft(_ sections: [[Double]]) -> FigureMesh {
        let steps = FigureGrammar.loftSteps
        let round = FigureGrammar.round
        let cols = round + 1
        // Every ring's section, interpolated.
        var rings: [[Double]] = []
        for i in 0..<(sections.count - 1) {
            let p0 = sections[max(i - 1, 0)], p1 = sections[i], p2 = sections[i + 1]
            let p3 = sections[min(i + 2, sections.count - 1)]
            for k in 0..<steps {
                let t = Double(k) / Double(steps)
                var r = (0..<5).map { catmullRom(p0[$0], p1[$0], p2[$0], p3[$0], t) }
                r[0] = p1[0] + (p2[0] - p1[0]) * t      // z: straight, so rings never fold back
                r[2] = max(r[2], 0); r[3] = max(r[3], 0); r[4] = min(max(r[4], 0), 1)
                rings.append(r)
            }
        }
        rings.append(sections[sections.count - 1])

        func point(_ r: [Double], _ c: Int) -> SIMD3<Double> {
            let a = Double(c % round) / Double(round) * 2 * .pi
            let e = 2 / (2 + 6 * r[4])     // 1 for an ellipse, 0.25 for the squarest box
            func bend(_ v: Double) -> Double { v == 0 ? 0 : (v < 0 ? -1 : 1) * pow(abs(v), e) }
            return [r[2] * bend(cos(a)), r[1] + r[3] * bend(sin(a)), r[0]]
        }
        // The grammar keeps at least one section with width and height, so there is a surface.
        let grid: [[SIMD3<Double>]] = rings.map { r in (0..<cols).map { point(r, $0) } }

        var m = FigureMesh()
        let last = rings.count - 1
        for (i, ring) in grid.enumerated() {
            for c in 0..<cols {
                // Along the ring (the seam wraps) and along the body, from the neighbours.
                let around = ring[(c + 1) % round] - ring[(c + round - 1) % round]
                let along = grid[min(i + 1, last)][c] - grid[max(i - 1, 0)][c]
                var n = normalize3d(cross3(around, along))
                let centre = SIMD3<Double>(0, rings[i][1], rings[i][0])
                let out = ring[c] - centre
                if simdLength(n) < 1e-9 || simdLength(out) < 1e-9 {
                    // A point (a closed tip): face along the body, away from it.
                    n = [0, 0, i == 0 ? -1 : (i == last ? 1 : 0)]
                    if n.z == 0 { n = normalize3d(out) }
                } else if simdDot3(n, out) < 0 {
                    n = -n
                }
                m.positions.append(SIMD3<Float>(ring[c]))
                m.normals.append(SIMD3<Float>(n))
            }
        }
        for i in 0..<UInt32(last) {
            for c in 0..<UInt32(round) {
                let a = i * UInt32(cols) + c, b = a + UInt32(cols)
                m.indices += [a, b, a + 1, a + 1, b, b + 1]
            }
        }
        // Flat caps on open ends.
        for (i, sign) in [(0, -1.0), (last, 1.0)] where rings[i][2] > 1e-9 && rings[i][3] > 1e-9 {
            let n = SIMD3<Float>(0, 0, Float(sign))
            let centre = UInt32(m.positions.count)
            m.positions.append(SIMD3<Float>(SIMD3<Double>(0, rings[i][1], rings[i][0])))
            m.normals.append(n)
            for c in 0..<cols { m.positions.append(SIMD3<Float>(grid[i][c])); m.normals.append(n) }
            for c in 0..<UInt32(round) { m.indices += [centre, centre + 1 + c, centre + 2 + c] }
        }
        return m
    }

    private static func catmullRom(_ p0: Double, _ p1: Double, _ p2: Double, _ p3: Double, _ t: Double) -> Double {
        let t2 = t * t, t3 = t2 * t
        return 0.5 * (2 * p1 + (p2 - p0) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 + (3 * p1 - p0 - 3 * p2 + p3) * t3)
    }
}
