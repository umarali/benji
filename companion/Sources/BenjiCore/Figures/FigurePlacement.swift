import Foundation

/// A 4×4 transform, column-major, in doubles (no simd module: BenjiCore also builds on Linux).
public struct FigureMatrix: Equatable, Sendable {
    public var m: [Double]   // 16, column-major: m[col * 4 + row]

    public static let identity = FigureMatrix(m: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1])

    public init(m: [Double]) { self.m = m }

    public subscript(row: Int, col: Int) -> Double {
        get { m[col * 4 + row] }
        set { m[col * 4 + row] = newValue }
    }

    public static func * (a: FigureMatrix, b: FigureMatrix) -> FigureMatrix {
        var r = FigureMatrix(m: Array(repeating: 0, count: 16))
        for i in 0..<4 { for j in 0..<4 {
            var s = 0.0
            for k in 0..<4 { s += a[i, k] * b[k, j] }
            r[i, j] = s
        } }
        return r
    }

    public static func translation(_ t: SIMD3<Double>) -> FigureMatrix {
        var r = identity; r[0, 3] = t.x; r[1, 3] = t.y; r[2, 3] = t.z; return r
    }

    public static func scale(_ s: SIMD3<Double>) -> FigureMatrix {
        var r = identity; r[0, 0] = s.x; r[1, 1] = s.y; r[2, 2] = s.z; return r
    }

    /// Right-handed rotation by `degrees` about a unit axis.
    public static func rotation(_ axis: SIMD3<Double>, degrees: Double) -> FigureMatrix {
        let a = degrees * .pi / 180, c = cos(a), s = sin(a), t = 1 - c
        let x = axis.x, y = axis.y, z = axis.z
        return FigureMatrix(m: [t * x * x + c, t * x * y + s * z, t * x * z - s * y, 0,
                                t * x * y - s * z, t * y * y + c, t * y * z + s * x, 0,
                                t * x * z + s * y, t * y * z - s * x, t * z * z + c, 0,
                                0, 0, 0, 1])
    }

    /// The rotation that takes +y to `axis` (a unit vector).
    public static func aligning(yTo axis: SIMD3<Double>) -> FigureMatrix {
        let d = max(-1, min(1, axis.y))
        if d > 0.999999 { return identity }
        if d < -0.999999 { return rotation([1, 0, 0], degrees: 180) }
        let c = normalize3d(cross3([0, 1, 0], axis))
        return rotation(c, degrees: acos(d) * 180 / .pi)
    }

    public func apply(_ p: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(self[0, 0] * p.x + self[0, 1] * p.y + self[0, 2] * p.z + self[0, 3],
              self[1, 0] * p.x + self[1, 1] * p.y + self[1, 2] * p.z + self[1, 3],
              self[2, 0] * p.x + self[2, 1] * p.y + self[2, 2] * p.z + self[2, 3])
    }

    public var determinant3: Double {
        self[0, 0] * (self[1, 1] * self[2, 2] - self[1, 2] * self[2, 1])
            - self[0, 1] * (self[1, 0] * self[2, 2] - self[1, 2] * self[2, 0])
            + self[0, 2] * (self[1, 0] * self[2, 1] - self[1, 1] * self[2, 0])
    }
}

/// One drawn copy of a part: a transform with a positive determinant, and whether it uses the
/// part's mirrored mesh (`FigureMesh.mirroredX`) to stand for a reflection.
public struct FigureInstance: Equatable, Sendable {
    public var transform: FigureMatrix
    public var mirrored: Bool
}

public enum FigurePlacement {
    /// The part's own transform: axis, then `rot` (x, y, z in figure axes), then `scale` along
    /// the figure's axes, then `at`.
    public static func local(_ p: FigurePart) -> FigureMatrix {
        let rot = FigureMatrix.rotation([0, 0, 1], degrees: p.rot.z) * FigureMatrix.rotation([0, 1, 0], degrees: p.rot.y)
            * FigureMatrix.rotation([1, 0, 0], degrees: p.rot.x)
        return .translation(p.at) * .scale(p.scale) * rot * .aligning(yTo: p.axis)
    }

    /// Every copy of every part, as full transforms (reflections included), in part order.
    public static func fullTransforms(_ figure: Figure) -> [String: [FigureMatrix]] {
        var out: [String: [FigureMatrix]] = [:]
        for p in figure.parts {
            let base = local(p)
            var own: [FigureMatrix] = []
            let mirrors: [FigureMatrix] = p.mirror.reduce([FigureMatrix.identity]) { acc, axis in
                var r = FigureMatrix.identity
                switch axis { case "x": r[0, 0] = -1; case "y": r[1, 1] = -1; default: r[2, 2] = -1 }
                return acc + acc.map { r * $0 }
            }
            let around = p.around
            let steps = around?.count ?? 1
            let delta: Double = {
                guard let a = around, a.count > 1 else { return 0 }
                return a.arc >= 360 ? a.arc / Double(a.count) : a.arc / Double(a.count - 1)
            }()
            let scattered = p.scatter.map(Self.scatter) ?? [(.zero, .identity)]
            for mirror in mirrors {
                for j in 0..<steps {
                    let ring: FigureMatrix = around.map {
                        .translation($0.center) * .rotation($0.axis, degrees: Double(j) * delta) * .translation(-$0.center)
                    } ?? .identity
                    for i in 0..<(p.copies?.count ?? 1) {
                        let c = p.copies
                        for (offset, turn) in scattered {
                            // Each copy carries its own ring: spokes written once for the front wheel
                            // and copied to the rear turn round the rear hub, not the front one.
                            let row = ring * base * turn * .rotation([0, 1, 0], degrees: (c?.turn ?? 0) * Double(i))
                            own.append(mirror * .translation((c?.step ?? .zero) * Double(i) + offset) * row)
                        }
                    }
                }
            }
            if let parent = p.parent, let parents = out[parent] {
                out[p.name] = parents.flatMap { pt in own.map { pt * $0 } }
            } else {
                out[p.name] = own
            }
        }
        return out
    }

    /// Where each scattered copy sits (inside the ellipsoid round the part) and how it is turned:
    /// a seeded generator, so a figure always comes out the same.
    public static func scatter(_ s: FigurePart.Scatter) -> [(SIMD3<Double>, FigureMatrix)] {
        var rng = SplitMix64(seed: UInt64(s.seed) &+ 0x9E37_79B9)
        return (0..<s.count).map { _ in
            // Uniform in the unit ball: a direction, and a radius by the cube root.
            let z = rng.unit() * 2 - 1, a = rng.unit() * 2 * .pi, rad = cbrt(rng.unit())
            let w = (1 - z * z).squareRoot()
            let offset = SIMD3(w * cos(a), z, w * sin(a)) * rad * s.inside
            let tz = rng.unit() * 2 - 1, ta = rng.unit() * 2 * .pi, tw = (1 - tz * tz).squareRoot()
            let turn = FigureMatrix.rotation([tw * cos(ta), tz, tw * sin(ta)], degrees: rng.unit() * 360)
            return (offset, turn)
        }
    }

    /// The line each copy of a spinning part turns about, in figure space, one per transform in
    /// `copies` (the part's full transforms). Blades round a hub (`around`) and a part that gave a
    /// centre turn together about one line; anything else turns each copy about its own centre,
    /// along the axis it gave or its own length (wheels in pairs, fans, rotors).
    public static func spinLines(_ p: FigurePart, copies: [FigureMatrix]) -> [(axis: SIMD3<Double>, center: SIMD3<Double>)] {
        if let center = p.spin?.center {
            let axis = p.spin?.axis ?? lengthAxis(local(p))
            return copies.map { _ in (axis, center) }
        }
        if let ring = p.around {
            // The ring goes with each copy (and its mirror image), so each copy turns about its own hub.
            let outers = outerPlacements(p)
            guard outers.count == copies.count else { return copies.map { _ in (p.spin?.axis ?? ring.axis, ring.center) } }
            return outers.map { o in
                let axis = p.spin?.axis ?? ring.axis
                let a = o.apply(axis) - o.apply([0, 0, 0])
                return (simdLength(a) > 1e-12 ? normalize3d(a) : axis, o.apply(ring.center))
            }
        }
        return copies.map { t in (p.spin?.axis ?? lengthAxis(t), t.apply([0, 0, 0])) }
    }

    /// Per copy, in `fullTransforms` order, what is applied outside the part's ring: its mirror
    /// image and its copy offset (no parent).
    static func outerPlacements(_ p: FigurePart) -> [FigureMatrix] {
        guard p.parent == nil else { return [] }
        let mirrors: [FigureMatrix] = p.mirror.reduce([FigureMatrix.identity]) { acc, axis in
            var r = FigureMatrix.identity
            switch axis { case "x": r[0, 0] = -1; case "y": r[1, 1] = -1; default: r[2, 2] = -1 }
            return acc + acc.map { r * $0 }
        }
        let scattered = p.scatter.map(Self.scatter) ?? [(.zero, .identity)]
        var out: [FigureMatrix] = []
        for mirror in mirrors {
            for _ in 0..<(p.around?.count ?? 1) {
                for i in 0..<(p.copies?.count ?? 1) {
                    for (offset, _) in scattered {
                        out.append(mirror * .translation((p.copies?.step ?? .zero) * Double(i) + offset))
                    }
                }
            }
        }
        return out
    }

    static func lengthAxis(_ t: FigureMatrix) -> SIMD3<Double> {
        let y = SIMD3(t[0, 1], t[1, 1], t[2, 1])
        return simdLength(y) > 1e-12 ? normalize3d(y) : [0, 1, 0]
    }

    /// The copies to draw: a reflection becomes the mirrored mesh under a proper transform.
    public static func instances(_ figure: Figure) -> [String: [FigureInstance]] {
        instances(fullTransforms(figure))
    }

    public static func instances(_ full: [String: [FigureMatrix]]) -> [String: [FigureInstance]] {
        full.mapValues { list in
            list.map { t in
                t.determinant3 < 0 ? FigureInstance(transform: t * .scale([-1, 1, 1]), mirrored: true)
                    : FigureInstance(transform: t, mirrored: false)
            }
        }
    }

    /// The bounding sphere of every sample of every copy: what the camera frames.
    public static func bounds(_ figure: Figure, meshes: [String: FigureMesh],
                              transforms: [String: [FigureMatrix]]? = nil) -> (centre: SIMD3<Double>, radius: Double) {
        var lo = SIMD3<Double>(repeating: .infinity), hi = SIMD3<Double>(repeating: -.infinity)
        var points: [SIMD3<Double>] = []
        for (name, list) in transforms ?? fullTransforms(figure) {
            guard let mesh = meshes[name] else { continue }
            for t in list {
                for s in mesh.samples {
                    let p = t.apply(SIMD3<Double>(s))
                    points.append(p)
                    lo = SIMD3(min(lo.x, p.x), min(lo.y, p.y), min(lo.z, p.z))
                    hi = SIMD3(max(hi.x, p.x), max(hi.y, p.y), max(hi.z, p.z))
                }
            }
        }
        guard !points.isEmpty else { return ([0, 0, 0], 1) }
        let centre = (lo + hi) / 2
        let radius = points.map { simdLength($0 - centre) }.max() ?? 1
        return (centre, max(radius, 1e-3))
    }
}

/// A small seeded generator (SplitMix64): the same seed gives the same scatter on every Mac.
struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    /// In [0, 1).
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}
