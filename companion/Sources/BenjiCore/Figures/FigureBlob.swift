import Foundation

/// The `blob` part: balls that melt into one smooth body, for the organic things primitives
/// draw badly (a cell, a heart, a kidney, a rock, a car's body, a tree's crown). The model writes a
/// few balls; this turns them into a closed mesh: a signed distance field (each ball's distance,
/// joined by a polynomial smooth minimum of width `smooth`, bumped by `wobble`), sampled on a grid
/// and meshed by surface nets, each vertex pulled onto the surface and lit by the field's gradient.
/// Deterministic: the same recipe always gives the same mesh (the mesh cache relies on it).
public enum FigureBlob {
    /// Vertices of one blob at most (the grid is coarsened until the mesh fits).
    public static let budget = 8000
    /// Grid points along the longest side to start with.
    static let startResolution = 56

    /// `chain`: the balls are joined in order by tapered segments, one smooth limb through them
    /// (blades, arms, tails, tentacles), instead of each ball standing on its own.
    public static func mesh(balls: [SIMD4<Double>], smooth k: Double, wobble: Double, chain: Bool = false) -> FigureMesh {
        guard !balls.isEmpty else { return FigureMesh() }
        let field = Field(balls: balls, k: k, wobble: wobble, chain: chain)
        // A cheap coarse pass predicts the finest grid that fits the budget (vertices grow with the
        // square of the resolution), then one full pass; coarser again only if it still overshoots.
        let probe = 20
        let estimate = max(1, surfaceNets(field, resolution: probe, project: false).vertexCount)
        var n = min(startResolution, max(8, Int(Double(probe) * (0.9 * Double(budget) / Double(estimate)).squareRoot())))
        while true {
            let m = surfaceNets(field, resolution: n)
            if m.vertexCount <= budget || n <= 8 { return m }
            n = max(8, Int(Double(n) * (Double(budget) / Double(m.vertexCount)).squareRoot() * 0.95))
        }
    }

    struct Field {
        let balls: [SIMD4<Double>]
        let k: Double
        let wobble: Double
        let chain: Bool
        let meanR: Double
        let lo: SIMD3<Double>
        let hi: SIMD3<Double>

        init(balls: [SIMD4<Double>], k: Double, wobble: Double, chain: Bool = false) {
            self.balls = balls
            self.k = k
            self.wobble = wobble
            self.chain = chain && balls.count > 1
            meanR = balls.reduce(0) { $0 + $1.w } / Double(balls.count)
            // Every surface point lies within each ball grown by the blend and the bumps.
            let grow = k / 4 + wobble * meanR
            var lo = SIMD3<Double>(repeating: .infinity), hi = SIMD3<Double>(repeating: -.infinity)
            for b in balls {
                let c = SIMD3(b.x, b.y, b.z), r = b.w + grow
                lo = SIMD3(min(lo.x, c.x - r), min(lo.y, c.y - r), min(lo.z, c.z - r))
                hi = SIMD3(max(hi.x, c.x + r), max(hi.y, c.y + r), max(hi.z, c.z + r))
            }
            self.lo = lo
            self.hi = hi
        }

        /// Negative inside, positive outside; about the distance to the surface near it.
        func value(_ p: SIMD3<Double>) -> Double {
            var d = Double.infinity
            for i in 0..<(chain ? balls.count - 1 : balls.count) {
                let b = balls[i]
                var e = simdLength(p - SIMD3(b.x, b.y, b.z)) - b.w
                if chain {
                    // The segment to the next ball, its radius tapering between the two.
                    let c = balls[i + 1]
                    let a = SIMD3(b.x, b.y, b.z), ab = SIMD3(c.x, c.y, c.z) - a
                    let t = max(0, min(1, simdDot3(p - a, ab) / max(simdDot3(ab, ab), 1e-12)))
                    e = simdLength(p - (a + ab * t)) - (b.w + (c.w - b.w) * t)
                }
                if d == .infinity { d = e; continue }
                if k > 0 {
                    let h = max(k - abs(d - e), 0) / k
                    d = min(d, e) - h * h * k / 4
                } else {
                    d = min(d, e)
                }
            }
            if wobble > 0 {
                let q = p * (2.2 / meanR)
                let n = sin(1.7 * q.x + 1.3 * q.y + 0.5) * sin(1.9 * q.y + 0.7 * q.z + 1.1) * sin(1.3 * q.z + 2.1 * q.x + 0.4)
                d += wobble * meanR * 0.6 * n
            }
            return d
        }

        func gradient(_ p: SIMD3<Double>, _ h: Double) -> SIMD3<Double> {
            SIMD3(value(p + [h, 0, 0]) - value(p - [h, 0, 0]),
                  value(p + [0, h, 0]) - value(p - [0, h, 0]),
                  value(p + [0, 0, h]) - value(p - [0, 0, h])) / (2 * h)
        }
    }

    /// Naive surface nets: one vertex per grid cell the surface passes through (at the mean of
    /// the crossings on its edges), one quad per grid edge the surface crosses.
    static func surfaceNets(_ f: Field, resolution: Int, project: Bool = true) -> FigureMesh {
        let extent = f.hi - f.lo
        let cell = max(extent.x, extent.y, extent.z) / Double(resolution)
        let origin = f.lo - SIMD3(repeating: cell * 1.5)   // a margin, so the surface is closed
        let nx = Int((extent.x / cell).rounded(.up)) + 4
        let ny = Int((extent.y / cell).rounded(.up)) + 4
        let nz = Int((extent.z / cell).rounded(.up)) + 4
        func at(_ i: Int, _ j: Int, _ l: Int) -> SIMD3<Double> { origin + SIMD3(Double(i), Double(j), Double(l)) * cell }
        var values = [Double](repeating: 0, count: nx * ny * nz)
        func idx(_ i: Int, _ j: Int, _ l: Int) -> Int { (l * ny + j) * nx + i }
        for l in 0..<nz { for j in 0..<ny { for i in 0..<nx { values[idx(i, j, l)] = f.value(at(i, j, l)) } } }

        var m = FigureMesh()
        var cellVertex = [Int32](repeating: -1, count: nx * ny * nz)   // by the cell's lowest corner
        let corners: [(Int, Int, Int)] = [(0, 0, 0), (1, 0, 0), (0, 1, 0), (1, 1, 0), (0, 0, 1), (1, 0, 1), (0, 1, 1), (1, 1, 1)]
        let edges: [(Int, Int)] = [(0, 1), (2, 3), (4, 5), (6, 7), (0, 2), (1, 3), (4, 6), (5, 7), (0, 4), (1, 5), (2, 6), (3, 7)]
        for l in 0..<(nz - 1) {
            for j in 0..<(ny - 1) {
                for i in 0..<(nx - 1) {
                    let v = corners.map { values[idx(i + $0.0, j + $0.1, l + $0.2)] }
                    let inside = v.map { $0 < 0 }
                    if inside.allSatisfy({ $0 }) || !inside.contains(true) { continue }
                    var sum = SIMD3<Double>(0, 0, 0)
                    var crossings = 0.0
                    for (a, b) in edges where inside[a] != inside[b] {
                        let t = v[a] / (v[a] - v[b])
                        let pa = at(i + corners[a].0, j + corners[a].1, l + corners[a].2)
                        let pb = at(i + corners[b].0, j + corners[b].1, l + corners[b].2)
                        sum += pa + (pb - pa) * t
                        crossings += 1
                    }
                    var p = sum / crossings
                    // Two Newton steps onto the surface, never more than half a cell.
                    for _ in 0..<(project ? 2 : 0) {
                        let g = f.gradient(p, cell * 0.25)
                        let g2 = simdDot3(g, g)
                        guard g2 > 1e-12 else { break }
                        var step = g * (f.value(p) / g2)
                        let s = simdLength(step)
                        if s > cell * 0.5 { step *= cell * 0.5 / s }
                        p -= step
                    }
                    let g = f.gradient(p, cell * 0.25)
                    let gl = simdLength(g)
                    cellVertex[idx(i, j, l)] = Int32(m.positions.count)
                    m.positions.append(SIMD3<Float>(p))
                    m.normals.append(SIMD3<Float>(gl > 1e-12 ? g / gl : [0, 1, 0]))
                }
            }
        }
        // A quad round each crossed grid edge, wound so it faces out (along the field's gradient).
        func quad(_ cells: [(Int, Int, Int)]) {
            let ids = cells.map { cellVertex[idx($0.0, $0.1, $0.2)] }
            guard ids.allSatisfy({ $0 >= 0 }) else { return }
            let u = ids.map { UInt32($0) }
            let p = u.map { SIMD3<Double>(m.positions[Int($0)]) }
            let face = cross3(p[1] - p[0], p[2] - p[0]) + cross3(p[2] - p[0], p[3] - p[0])
            let out = u.reduce(SIMD3<Double>(0, 0, 0)) { $0 + SIMD3<Double>(m.normals[Int($1)]) }
            if simdDot3(face, out) >= 0 {
                m.indices += [u[0], u[1], u[2], u[0], u[2], u[3]]
            } else {
                m.indices += [u[0], u[2], u[1], u[0], u[3], u[2]]
            }
        }
        for l in 1..<(nz - 1) {
            for j in 1..<(ny - 1) {
                for i in 1..<(nx - 1) {
                    let here = values[idx(i, j, l)] < 0
                    if i + 1 < nx, here != (values[idx(i + 1, j, l)] < 0) {
                        quad([(i, j - 1, l - 1), (i, j, l - 1), (i, j, l), (i, j - 1, l)])
                    }
                    if j + 1 < ny, here != (values[idx(i, j + 1, l)] < 0) {
                        quad([(i - 1, j, l - 1), (i, j, l - 1), (i, j, l), (i - 1, j, l)])
                    }
                    if l + 1 < nz, here != (values[idx(i, j, l + 1)] < 0) {
                        quad([(i - 1, j - 1, l), (i, j - 1, l), (i, j, l), (i - 1, j, l)])
                    }
                }
            }
        }
        return m
    }
}
