import Foundation

/// One part's mesh as plain arrays (no SceneKit types), so a later renderer of Benji's own can
/// reuse it (D-107 tier 2). Local space: the part's up (its length) is +y, centred on the origin
/// except tubes, lathes, extrusions and lofts, which keep their own coordinates.
public struct FigureMesh: Equatable, Sendable {
    public var positions: [SIMD3<Float>] = []
    public var normals: [SIMD3<Float>] = []
    public var indices: [UInt32] = []
    /// A few points on the surface, for framing the camera and anchoring labels.
    public var samples: [SIMD3<Float>] = []

    public var vertexCount: Int { positions.count }
    public var triangleCount: Int { indices.count / 3 }
    /// Bytes of vertex and index data (positions and normals as 3 floats each).
    public var bytes: Int { positions.count * 24 + indices.count * 4 }

    public static let sampleCount = 24

    /// The mesh for a recipe. Every result has at most `FigureGrammar.budget` vertices.
    public static func build(_ recipe: FigureRecipe) -> FigureMesh {
        var m: FigureMesh
        switch recipe {
        case let .box(size, bevel): m = box(size, bevel: bevel)
        case let .cyl(r, h, bevel): m = lathe(cylinderProfile(r: r, r2: r, h: h, bevel: bevel))
        case let .cone(r, r2, h, bevel): m = lathe(cylinderProfile(r: r, r2: r2, h: h, bevel: bevel))
        case let .sphere(r): m = lathe(arc(centre: [0, 0], radius: r, from: -90, to: 90, steps: 24))
        case let .capsule(r, h):
            let half = h / 2 - r
            m = lathe(arc(centre: [0, -half], radius: r, from: -90, to: 0, steps: 12)
                      + arc(centre: [0, half], radius: r, from: 0, to: 90, steps: 12))
        case let .torus(r, tube): m = torus(r: r, tube: tube)
        case let .tube(r, path, r2): m = tube(r: r, path: path, r2: r2)
        case let .blob(balls, k, w, chain): m = FigureBlob.mesh(balls: balls, smooth: k, wobble: w, chain: chain)
        case let .lathe(profile): m = lathe(userProfile(profile))
        case let .extrude(path, depth, bevel): m = extrude(path, depth: depth, bevel: bevel)
        case let .loft(sections): m = loft(sections)
        }
        m.orientTriangles()
        m.samples = m.pickSamples()
        return m
    }

    /// The same mesh reflected across its own x = 0 plane, wound the other way, for mirrored
    /// copies (so every placement stays a proper rotation and back-face culling still works).
    public func mirroredX() -> FigureMesh {
        var m = self
        m.positions = positions.map { SIMD3(-$0.x, $0.y, $0.z) }
        m.normals = normals.map { SIMD3(-$0.x, $0.y, $0.z) }
        m.samples = samples.map { SIMD3(-$0.x, $0.y, $0.z) }
        for t in stride(from: 0, to: indices.count, by: 3) { m.indices.swapAt(t + 1, t + 2) }
        return m
    }

    // MARK: profiles revolved about y

    /// A profile point: radius, height, and the profile's outward normal there.
    struct ProfilePoint { var r: Double; var y: Double; var n: SIMD2<Double> }

    static func arc(centre: SIMD2<Double>, radius: Double, from a0: Double, to a1: Double, steps: Int) -> [ProfilePoint] {
        (0...steps).map { k in
            let a = (a0 + (a1 - a0) * Double(k) / Double(steps)) * .pi / 180
            let n = SIMD2(cos(a), sin(a))
            return ProfilePoint(r: max(0, centre.x + radius * n.x), y: centre.y + radius * n.y, n: n)
        }
    }

    /// A cylinder (r2 == r) or a cone, bevelled at its base rim and (a cylinder) its top rim.
    static func cylinderProfile(r: Double, r2: Double, h: Double, bevel b: Double) -> [ProfilePoint] {
        let lo = -h / 2, hi = h / 2
        let down = SIMD2<Double>(0, -1), up = SIMD2<Double>(0, 1)
        let side = normalize2(SIMD2(h, r - r2))
        let sideAngle = atan2(side.y, side.x) * 180 / .pi
        var p = [ProfilePoint(r: 0, y: lo, n: down)]
        if b > 0 {
            p += arc(centre: [r - b, lo + b], radius: b, from: -90, to: sideAngle, steps: FigureGrammar.arcSteps)
            if r2 == r {
                p += arc(centre: [r - b, hi - b], radius: b, from: 0, to: 90, steps: FigureGrammar.arcSteps)
                p.append(ProfilePoint(r: 0, y: hi, n: up))
                return p
            }
        } else {
            p += [ProfilePoint(r: r, y: lo, n: down), ProfilePoint(r: r, y: lo, n: side)]
        }
        if r2 > 0 {
            p += [ProfilePoint(r: r2, y: hi, n: side), ProfilePoint(r: r2, y: hi, n: up), ProfilePoint(r: 0, y: hi, n: up)]
        } else {
            p.append(ProfilePoint(r: 0, y: hi, n: side))
        }
        return p
    }

    /// A model-written profile: normals from its own segments, a corner sharper than 40° split in
    /// two rows; walked either way round (normals point away from the area it encloses with the axis).
    static func userProfile(_ points: [SIMD2<Double>]) -> [ProfilePoint] {
        var pts = points
        let closed = pts.count > 3 && pts.first == pts.last
        if closed { pts.removeLast() }
        let n = pts.count
        // Signed area of the profile closed along the axis: negative means walked clockwise.
        var area = 0.0
        let ring = closed ? pts : [SIMD2(0, pts[0].y)] + pts + [SIMD2(0, pts[n - 1].y)]
        for i in ring.indices {
            let a = ring[i], b = ring[(i + 1) % ring.count]
            area += a.x * b.y - b.x * a.y
        }
        let flip = area < 0 ? -1.0 : 1.0
        func segNormal(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> SIMD2<Double> {
            let d = b - a
            return normalize2(SIMD2(d.y, -d.x) * flip)
        }
        var out: [ProfilePoint] = []
        for i in 0..<n {
            let prev: SIMD2<Double>? = i > 0 ? segNormal(pts[i - 1], pts[i]) : (closed ? segNormal(pts[n - 1], pts[0]) : nil)
            let next: SIMD2<Double>? = i < n - 1 ? segNormal(pts[i], pts[i + 1]) : (closed ? segNormal(pts[n - 1], pts[0]) : nil)
            let p = pts[i]
            switch (prev, next) {
            case let (a?, b?) where simdDot(a, b) < cos(40 * Double.pi / 180):
                out += [ProfilePoint(r: p.x, y: p.y, n: a), ProfilePoint(r: p.x, y: p.y, n: b)]
            case let (a?, b?): out.append(ProfilePoint(r: p.x, y: p.y, n: normalize2(a + b)))
            case let (a?, nil): out.append(ProfilePoint(r: p.x, y: p.y, n: a))
            case let (nil, b?): out.append(ProfilePoint(r: p.x, y: p.y, n: b))
            default: out.append(ProfilePoint(r: p.x, y: p.y, n: [1, 0]))
            }
        }
        if closed, let first = out.first { out.append(first) }
        return out
    }

    static func lathe(_ profile: [ProfilePoint]) -> FigureMesh {
        var m = FigureMesh()
        let cols = FigureGrammar.round + 1
        for p in profile {
            for c in 0..<cols {
                let a = Double(c) / Double(FigureGrammar.round) * 2 * .pi
                let s = sin(a), co = cos(a)
                m.positions.append(SIMD3(Float(p.r * s), Float(p.y), Float(p.r * co)))
                m.normals.append(normalize3(SIMD3(Float(p.n.x * s), Float(p.n.y), Float(p.n.x * co))))
            }
        }
        for row in 0..<(profile.count - 1) {
            let a = profile[row], b = profile[row + 1]
            if a.r == b.r && a.y == b.y { continue }      // a split corner: no band between its two rows
            for c in 0..<(cols - 1) {
                let i0 = UInt32(row * cols + c), i1 = i0 + 1, j0 = i0 + UInt32(cols), j1 = j0 + 1
                m.indices += [i0, j0, i1, i1, j0, j1]
            }
        }
        return m
    }

    // MARK: box

    static func box(_ size: SIMD3<Double>, bevel b: Double) -> FigureMesh {
        var m = FigureMesh()
        let h = size / 2
        // Grid coordinates along each axis: the bevel arc in equal angle steps to 45° (the other
        // half of the arc belongs to the neighbouring face), then the flat middle.
        func coords(_ half: Double) -> [Double] {
            if b <= 0 { return [-half, half] }
            let steps = (0...FigureGrammar.arcSteps).map { tan(Double($0) / Double(FigureGrammar.arcSteps) * .pi / 4) }
            return steps.reversed().map { -half + b - b * $0 } + steps.map { half - b + b * $0 }
        }
        let inner = h - b
        for axis in 0..<3 {
            for sign in [-1.0, 1.0] {
                let u = (axis + 1) % 3, v = (axis + 2) % 3
                let cu = coords(h[u]), cv = coords(h[v])
                let base = UInt32(m.positions.count)
                for x in cu {
                    for y in cv {
                        var p = SIMD3<Double>(0, 0, 0)
                        p[axis] = sign * h[axis]; p[u] = x; p[v] = y
                        if b > 0 {
                            let c = SIMD3(min(max(p.x, -inner.x), inner.x), min(max(p.y, -inner.y), inner.y),
                                          min(max(p.z, -inner.z), inner.z))
                            let n = normalize3d(p - c)
                            m.positions.append(SIMD3<Float>(c + n * b))
                            m.normals.append(SIMD3<Float>(n))
                        } else {
                            var n = SIMD3<Double>(0, 0, 0); n[axis] = sign
                            m.positions.append(SIMD3<Float>(p))
                            m.normals.append(SIMD3<Float>(n))
                        }
                    }
                }
                let nv = UInt32(cv.count)
                for i in 0..<UInt32(cu.count - 1) {
                    for j in 0..<(nv - 1) {
                        let a = base + i * nv + j
                        m.indices += [a, a + nv, a + 1, a + 1, a + nv, a + nv + 1]
                    }
                }
            }
        }
        return m
    }

    // MARK: torus

    static func torus(r: Double, tube: Double) -> FigureMesh {
        var m = FigureMesh()
        let cols = FigureGrammar.round + 1, rows = 25
        for row in 0..<rows {
            let b = Double(row) / Double(rows - 1) * 2 * .pi
            for c in 0..<cols {
                let a = Double(c) / Double(FigureGrammar.round) * 2 * .pi
                let n = SIMD3(cos(b) * sin(a), sin(b), cos(b) * cos(a))
                m.positions.append(SIMD3<Float>(SIMD3(r * sin(a), 0, r * cos(a)) + n * tube))
                m.normals.append(SIMD3<Float>(n))
            }
        }
        for row in 0..<(rows - 1) {
            for c in 0..<(cols - 1) {
                let i0 = UInt32(row * cols + c), j0 = i0 + UInt32(cols)
                m.indices += [i0, j0, i0 + 1, i0 + 1, j0, j0 + 1]
            }
        }
        return m
    }

    // MARK: tube along a path

    static func tube(r: Double, path: [SIMD3<Double>], r2: Double? = nil) -> FigureMesh {
        // Catmull-Rom through the points, 4 steps a segment; frames carried along the curve.
        var pts: [SIMD3<Double>] = []
        for i in 0..<(path.count - 1) {
            let p0 = path[max(i - 1, 0)], p1 = path[i], p2 = path[i + 1], p3 = path[min(i + 2, path.count - 1)]
            for k in 0..<4 {
                let t = Double(k) / 4, t2 = t * t, t3 = t2 * t
                let a: SIMD3<Double> = 2 * p1
                let b: SIMD3<Double> = (p2 - p0) * t
                let c2: SIMD3<Double> = 2 * p0 - 5 * p1
                let c: SIMD3<Double> = (c2 + 4 * p2 - p3) * t2
                let d2: SIMD3<Double> = 3 * p1 - p0
                let d: SIMD3<Double> = (d2 - 3 * p2 + p3) * t3
                pts.append(0.5 * (a + b + c + d))
            }
        }
        pts.append(path[path.count - 1])
        var tangents: [SIMD3<Double>] = pts.indices.map { i in
            normalize3d(pts[min(i + 1, pts.count - 1)] - pts[max(i - 1, 0)])
        }
        for i in tangents.indices where simdLength(tangents[i]) == 0 { tangents[i] = i > 0 ? tangents[i - 1] : [0, 1, 0] }
        var normal = abs(tangents[0].y) < 0.9 ? normalize3d(cross3(tangents[0], [0, 1, 0])) : normalize3d(cross3(tangents[0], [1, 0, 0]))
        let ring = 16
        // The radius at each point: r at the start to r2 at the end, by length along the curve.
        var along = [0.0]
        for i in 1..<pts.count { along.append(along[i - 1] + simdLength(pts[i] - pts[i - 1])) }
        let total = max(along.last ?? 0, 1e-9)
        let radius = along.map { r + ((r2 ?? r) - r) * $0 / total }
        var m = FigureMesh()
        var frames: [(SIMD3<Double>, SIMD3<Double>)] = []
        for i in pts.indices {
            if i > 0 {   // parallel transport
                normal = normal - tangents[i] * simdDot3(normal, tangents[i])
                if simdLength(normal) < 1e-9 { normal = abs(tangents[i].y) < 0.9 ? cross3(tangents[i], [0, 1, 0]) : cross3(tangents[i], [1, 0, 0]) }
                normal = normalize3d(normal)
            }
            let binormal = cross3(tangents[i], normal)
            frames.append((normal, binormal))
            for k in 0...ring {
                let a = Double(k) / Double(ring) * 2 * .pi
                let n = normal * cos(a) + binormal * sin(a)
                m.positions.append(SIMD3<Float>(pts[i] + n * radius[i]))
                m.normals.append(SIMD3<Float>(n))
            }
        }
        let cols = UInt32(ring + 1)
        for i in 0..<UInt32(pts.count - 1) {
            for k in 0..<UInt32(ring) {
                let a = i * cols + k
                m.indices += [a, a + cols, a + 1, a + 1, a + cols, a + cols + 1]
            }
        }
        for (end, sign) in [(0, -1.0), (pts.count - 1, 1.0)] {
            let n = tangents[end] * sign
            let centre = UInt32(m.positions.count)
            m.positions.append(SIMD3<Float>(pts[end])); m.normals.append(SIMD3<Float>(n))
            let (fn, fb) = frames[end]
            for k in 0...ring {
                let a = Double(k) / Double(ring) * 2 * .pi
                m.positions.append(SIMD3<Float>(pts[end] + (fn * cos(a) + fb * sin(a)) * radius[end]))
                m.normals.append(SIMD3<Float>(n))
            }
            for k in 0..<UInt32(ring) { m.indices += [centre, centre + 1 + k, centre + 2 + k] }
        }
        return m
    }

    // MARK: extrusion

    static func extrude(_ path: String, depth: Double, bevel b: Double) -> FigureMesh {
        var m = FigureMesh()
        guard let outlines = FigurePath.outlines(path) else { return m }
        let front = depth / 2
        for raw in outlines {
            // The outline is in the part's x-y plane with y up (as the model writes it). Wind anticlockwise.
            var o = raw
            if signedArea(o) < 0 { o.reverse() }
            let n = o.count
            let edgeN: [SIMD2<Double>] = (0..<n).map { i in
                let d = o[(i + 1) % n] - o[i]
                return normalize2(SIMD2(d.y, -d.x))
            }
            // Vertex normals: smooth across a gentle turn (a flattened curve), sharp at a corner.
            func cornerNormal(_ i: Int, edge: Int) -> SIMD2<Double> {
                let a = edgeN[(i + n - 1) % n], c = edgeN[i]
                return simdDot(a, c) > cos(30 * Double.pi / 180) ? normalize2(a + c) : edgeN[edge]
            }
            let inset: [SIMD2<Double>] = (0..<n).map { i in
                let a = edgeN[(i + n - 1) % n], c = edgeN[i]
                let mid = normalize2(a + c)
                let miter = min(1 / max(simdDot(mid, c), 0.3), 2.5)
                return o[i] - mid * b * miter
            }
            let bands: [(Double, Double, Double, Double, Bool)] = b > 0
                ? [(front, front - b, 1, 0, true), (front - b, -front + b, 0, 0, false), (-front + b, -front, -1, 1, true)]
                : [(front, -front, 0, 0, false)]
            for (z0, z1, nz, _, chamfer) in bands {
                for i in 0..<n {
                    let j = (i + 1) % n
                    let base = UInt32(m.positions.count)
                    let ends = [(i, i), (j, i)]
                    for (z, isFront) in [(z0, true), (z1, false)] {
                        for (k, edge) in ends {
                            let useInset = chamfer && ((nz > 0) == isFront)
                            let p = useInset ? inset[k] : o[k]
                            let side = k == i ? cornerNormal(i, edge: edge) : cornerNormal(j, edge: edge)
                            m.positions.append(SIMD3(Float(p.x), Float(p.y), Float(z)))
                            m.normals.append(normalize3(SIMD3(Float(side.x), Float(side.y), Float(nz))))
                        }
                    }
                    m.indices += [base, base + 2, base + 1, base + 1, base + 2, base + 3]
                }
            }
            for (z, nz) in [(front, Float(1)), (-front, Float(-1))] {
                let base = UInt32(m.positions.count)
                let cap = b > 0 ? inset : o
                for p in cap {
                    m.positions.append(SIMD3(Float(p.x), Float(p.y), Float(z)))
                    m.normals.append(SIMD3(0, 0, nz))
                }
                m.indices += earClip(cap).map { base + UInt32($0) }
            }
        }
        return m
    }

    static func signedArea(_ o: [SIMD2<Double>]) -> Double {
        var a = 0.0
        for i in o.indices { let p = o[i], q = o[(i + 1) % o.count]; a += p.x * q.y - q.x * p.y }
        return a / 2
    }

    /// Triangles of a simple anticlockwise polygon; a fan if it is not simple.
    static func earClip(_ poly: [SIMD2<Double>]) -> [Int] {
        var idx = Array(poly.indices)
        var out: [Int] = []
        func cross(_ o: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var guardCount = 0
        while idx.count > 3 && guardCount < poly.count * poly.count {
            guardCount += 1
            var clipped = false
            for k in idx.indices {
                let i0 = idx[(k + idx.count - 1) % idx.count], i1 = idx[k], i2 = idx[(k + 1) % idx.count]
                let a = poly[i0], b = poly[i1], c = poly[i2]
                guard cross(a, b, c) > 1e-12 else { continue }
                let inside = idx.contains { j in
                    guard j != i0 && j != i1 && j != i2 else { return false }
                    let p = poly[j]
                    return cross(a, b, p) >= 0 && cross(b, c, p) >= 0 && cross(c, a, p) >= 0
                }
                if inside { continue }
                out += [i0, i1, i2]
                idx.remove(at: k)
                clipped = true
                break
            }
            if !clipped { break }
        }
        if idx.count == 3 { out += idx }
        else if idx.count > 3 { for k in 1..<(idx.count - 1) { out += [idx[0], idx[k], idx[k + 1]] } }
        return out
    }

    // MARK: finishing

    /// Every triangle wound so its face points the way its vertex normals do (so culling and the
    /// outline pass agree whatever order a generator emitted).
    mutating func orientTriangles() {
        for t in stride(from: 0, to: indices.count, by: 3) {
            let a = positions[Int(indices[t])], b = positions[Int(indices[t + 1])], c = positions[Int(indices[t + 2])]
            let face = crossF(b - a, c - a)
            let n = normals[Int(indices[t])] + normals[Int(indices[t + 1])] + normals[Int(indices[t + 2])]
            if face.x * n.x + face.y * n.y + face.z * n.z < 0 { indices.swapAt(t + 1, t + 2) }
        }
    }

    func pickSamples() -> [SIMD3<Float>] {
        guard !positions.isEmpty else { return [] }
        let step = max(1, positions.count / Self.sampleCount)
        return stride(from: 0, to: positions.count, by: step).prefix(Self.sampleCount).map { positions[$0] }
    }
}

// MARK: small vector helpers (no simd module: BenjiCore also builds on Linux)

@inline(__always) func simdDot(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double { a.x * b.x + a.y * b.y }
@inline(__always) func simdDot3(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double { a.x * b.x + a.y * b.y + a.z * b.z }
@inline(__always) func simdLength(_ a: SIMD3<Double>) -> Double { simdDot3(a, a).squareRoot() }
func normalize2(_ v: SIMD2<Double>) -> SIMD2<Double> {
    let l = simdDot(v, v).squareRoot()
    return l > 0 ? v / l : v
}
func normalize3d(_ v: SIMD3<Double>) -> SIMD3<Double> {
    let l = simdLength(v)
    return l > 0 ? v / l : v
}
func normalize3(_ v: SIMD3<Float>) -> SIMD3<Float> {
    let l = (v.x * v.x + v.y * v.y + v.z * v.z).squareRoot()
    return l > 0 ? v / l : v
}
func cross3(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> SIMD3<Double> {
    SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
}
func crossF(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> {
    SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
}

/// Meshes built once per recipe (its canonical JSON), shared by every part, copy and mirror
/// that uses it, across figures. Thread-safe: the stage builds on a background queue.
public final class FigureMeshCache: @unchecked Sendable {
    public static let shared = FigureMeshCache()
    private let lock = NSLock()
    private var meshes: [String: FigureMesh] = [:]
    private var order: [String] = []
    public let capacity: Int

    public init(capacity: Int = 256) { self.capacity = capacity }

    public func mesh(for recipe: FigureRecipe) -> FigureMesh {
        let key = recipe.canonical
        lock.lock()
        if let m = meshes[key] { lock.unlock(); return m }
        lock.unlock()
        let m = FigureMesh.build(recipe)
        lock.lock()
        defer { lock.unlock() }
        if meshes[key] == nil {
            meshes[key] = m
            order.append(key)
            if order.count > capacity { meshes[order.removeFirst()] = nil }
        }
        return m
    }

    public var count: Int { lock.lock(); defer { lock.unlock() }; return meshes.count }
}
