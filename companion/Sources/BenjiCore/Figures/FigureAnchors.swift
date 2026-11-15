import Foundation

/// Where a label's line lands on its part. The sample nearest the camera won't do: on most
/// figures it is a point the viewer cannot see (a wing's root inside the fuselage, an engine's far
/// side, a floor under seats), so the label would name one part and point at another. Instead the
/// figure is drawn once into a small depth buffer (every triangle of
/// every part, the cut applied like the shader does) and the label goes to the middle of what of
/// its part is actually showing: the visible pixel farthest from the part's own edge, then back
/// to a point in figure space so the line follows the part as the figure turns.
///
/// Pure arrays, no SceneKit: the stage hands it each part's triangles and the camera's projection.
public enum FigureAnchors {
    /// One part's triangles in figure space (every copy), and the plane that cuts it open.
    public struct Surface: Sendable {
        public var positions: [SIMD3<Float>]
        public var indices: [UInt32]
        /// Everything with dot(p, axis) > at is cut away (as the card's shader discards it).
        public var cutAxis: SIMD3<Float>?
        public var cutAt: Float

        public init(positions: [SIMD3<Float>], indices: [UInt32], cutAxis: SIMD3<Float>? = nil, cutAt: Float = 0) {
            self.positions = positions
            self.indices = indices
            self.cutAxis = cutAxis
            self.cutAt = cutAt
        }
    }

    /// Columns of the depth buffer: enough that a thin tube still covers a few pixels.
    public static let columns = 192

    /// For each wanted part (an index into `surfaces`), the point of its surface to point the label
    /// at; a part with none showing is left out (the caller falls back to its nearest sample).
    /// `project` maps figure space to a view of `viewSize` points (y down) with depth, smaller
    /// being nearer.
    public static func visiblePoints(of wanted: [Int], surfaces: [Surface?], viewSize: (width: Double, height: Double),
                                     project: (SIMD3<Double>) -> SIMD3<Double>) -> [Int: SIMD3<Double>] {
        guard !wanted.isEmpty, viewSize.width > 1, viewSize.height > 1 else { return [:] }
        let cols = columns
        let rows = max(8, Int((Double(cols) * viewSize.height / viewSize.width).rounded()))
        let sx = Double(cols) / viewSize.width, sy = Double(rows) / viewSize.height
        var depth = [Float](repeating: .infinity, count: cols * rows)
        var owner = [Int16](repeating: -1, count: cols * rows)
        var world = [SIMD3<Float>](repeating: .zero, count: cols * rows)

        for (k, surface) in surfaces.enumerated() {
            guard let s = surface, !s.indices.isEmpty, k < Int(Int16.max) else { continue }
            var px: [SIMD3<Float>] = []
            px.reserveCapacity(s.positions.count)
            for p in s.positions {
                let q = project(SIMD3<Double>(p))
                px.append(SIMD3(Float(q.x * sx), Float(q.y * sy), Float(q.z)))
            }
            for t in stride(from: 0, to: s.indices.count - 2, by: 3) {
                let i0 = Int(s.indices[t]), i1 = Int(s.indices[t + 1]), i2 = Int(s.indices[t + 2])
                guard i0 < px.count, i1 < px.count, i2 < px.count else { continue }
                let a = px[i0], b = px[i1], c = px[i2]
                guard a.z.isFinite, b.z.isFinite, c.z.isFinite, a.x.isFinite, b.x.isFinite, c.x.isFinite,
                      a.y.isFinite, b.y.isFinite, c.y.isFinite else { continue }
                let area = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
                if abs(area) < 1e-6 { continue }
                let x0 = max(0, Int((min(a.x, b.x, c.x) - 0.5).rounded(.down)))
                let x1 = min(cols - 1, Int((max(a.x, b.x, c.x) + 0.5).rounded(.up)))
                let y0 = max(0, Int((min(a.y, b.y, c.y) - 0.5).rounded(.down)))
                let y1 = min(rows - 1, Int((max(a.y, b.y, c.y) + 0.5).rounded(.up)))
                if x0 > x1 || y0 > y1 { continue }
                let p0 = s.positions[i0], p1 = s.positions[i1], p2 = s.positions[i2]
                for y in y0...y1 {
                    for x in x0...x1 {
                        let cx = Float(x) + 0.5, cy = Float(y) + 0.5
                        let w0 = ((b.x - cx) * (c.y - cy) - (b.y - cy) * (c.x - cx)) / area
                        let w1 = ((c.x - cx) * (a.y - cy) - (c.y - cy) * (a.x - cx)) / area
                        let w2 = 1 - w0 - w1
                        if w0 < 0 || w1 < 0 || w2 < 0 { continue }
                        let z = w0 * a.z + w1 * b.z + w2 * c.z
                        let idx = y * cols + x
                        if z >= depth[idx] { continue }
                        let wp = p0 * w0 + p1 * w1 + p2 * w2
                        if let axis = s.cutAxis, (wp.x * axis.x + wp.y * axis.y + wp.z * axis.z) > s.cutAt { continue }
                        depth[idx] = z
                        owner[idx] = Int16(k)
                        world[idx] = wp
                    }
                }
            }
        }

        var out: [Int: SIMD3<Double>] = [:]
        for k in Set(wanted) {
            if let i = deepestPixel(of: k, owner: owner, cols: cols, rows: rows) {
                out[k] = SIMD3<Double>(world[i])
            }
        }
        return out
    }

    /// The part's visible pixel farthest from the edge of what shows (ties and near-ties go to the
    /// one nearest the middle), by a two-pass distance transform over the part's own window.
    static func deepestPixel(of part: Int, owner: [Int16], cols: Int, rows: Int) -> Int? {
        var minX = cols, maxX = -1, minY = rows, maxY = -1
        for y in 0..<rows {
            for x in 0..<cols where Int(owner[y * cols + x]) == part {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        let w = maxX - minX + 3, h = maxY - minY + 3   // one pixel of outside all round
        let far: Float = 1e6
        var d = [Float](repeating: 0, count: w * h)
        var sumX = 0.0, sumY = 0.0, n = 0.0
        for y in minY...maxY {
            for x in minX...maxX where Int(owner[y * cols + x]) == part {
                d[(y - minY + 1) * w + (x - minX + 1)] = far
                sumX += Double(x); sumY += Double(y); n += 1
            }
        }
        let diag: Float = 1.4142
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) where d[y * w + x] > 0 {
                d[y * w + x] = min(d[y * w + x], d[y * w + x - 1] + 1, d[(y - 1) * w + x] + 1,
                                   d[(y - 1) * w + x - 1] + diag, d[(y - 1) * w + x + 1] + diag)
            }
        }
        for y in stride(from: h - 2, through: 1, by: -1) {
            for x in stride(from: w - 2, through: 1, by: -1) where d[y * w + x] > 0 {
                d[y * w + x] = min(d[y * w + x], d[y * w + x + 1] + 1, d[(y + 1) * w + x] + 1,
                                   d[(y + 1) * w + x + 1] + diag, d[(y + 1) * w + x - 1] + diag)
            }
        }
        let best = d.max() ?? 0
        let (mx, my) = (sumX / n, sumY / n)
        var pick: (score: Double, index: Int)?
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) where d[y * w + x] > 0 && d[y * w + x] >= max(1, best * 0.7) {
                let gx = Double(x - 1 + minX), gy = Double(y - 1 + minY)
                let dist = (gx - mx) * (gx - mx) + (gy - my) * (gy - my)
                if pick == nil || dist < pick!.score { pick = (dist, (y - 1 + minY) * cols + (x - 1 + minX)) }
            }
        }
        return pick?.index
    }
}
