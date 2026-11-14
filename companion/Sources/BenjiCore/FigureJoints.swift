import Foundation

/// Parts that touch nothing (D-108, after the live evals): the model often places a part a little
/// off the one it should meet (a backrest above its seat, a wing off its body). Each copy of each
/// part gets its box in figure space; two copies touch when their boxes, grown by a small share of
/// the figure, overlap. The largest connected group (by box volume) is the object; every other
/// group is loose, with the gap to the object and the shift that would close it.
///
/// Boxes are axis-aligned in figure space, so a rotated thin part looks bigger than it is: the
/// check can miss a loose part, but it does not call two parts apart that touch.
public enum FigureJoints {
    /// Boxes grow by this share of the figure's radius before they are compared.
    public static let tolerance = 0.02

    public struct Piece: Equatable, Sendable {
        public var part: String
        public var copy: Int
        public var lo: SIMD3<Double>
        public var hi: SIMD3<Double>
    }

    public struct Loose: Equatable, Sendable {
        /// The parts of one loose group, in part order.
        public var parts: [String]
        /// The copies in the group, as (part, copy index).
        public var pieces: [Piece]
        /// The gap between the group and the object, in figure units.
        public var gap: Double
        /// The same gap as a share of the figure's radius.
        public var share: Double
        /// The translation that closes the gap (moves the group onto the object's nearest piece).
        public var shift: SIMD3<Double>
    }

    public static func pieces(_ figure: Figure, meshes: [String: FigureMesh],
                              transforms: [String: [FigureMatrix]]? = nil) -> [Piece] {
        let all = transforms ?? FigurePlacement.fullTransforms(figure)
        var out: [Piece] = []
        for p in figure.parts {
            guard let mesh = meshes[p.name], let list = all[p.name] else { continue }
            for (i, t) in list.enumerated() {
                var lo = SIMD3<Double>(repeating: .infinity), hi = SIMD3<Double>(repeating: -.infinity)
                for v in mesh.positions {
                    let w = t.apply(SIMD3<Double>(v))
                    lo = SIMD3(min(lo.x, w.x), min(lo.y, w.y), min(lo.z, w.z))
                    hi = SIMD3(max(hi.x, w.x), max(hi.y, w.y), max(hi.z, w.z))
                }
                if lo.x.isFinite { out.append(Piece(part: p.name, copy: i, lo: lo, hi: hi)) }
            }
        }
        return out
    }

    /// The gap per axis from box a to box b (0 where they overlap), signed so that adding it to a
    /// moves a onto b.
    static func shift(from a: Piece, to b: Piece) -> SIMD3<Double> {
        var s = SIMD3<Double>(0, 0, 0)
        for k in 0..<3 {
            if b.lo[k] > a.hi[k] { s[k] = b.lo[k] - a.hi[k] }
            else if a.lo[k] > b.hi[k] { s[k] = b.hi[k] - a.lo[k] }
        }
        return s
    }

    public static func loose(_ figure: Figure, meshes: [String: FigureMesh],
                             transforms: [String: [FigureMatrix]]? = nil) -> [Loose] {
        let ps = pieces(figure, meshes: meshes, transforms: transforms)
        let radius = FigurePlacement.bounds(figure, meshes: meshes, transforms: transforms).radius
        return loose(ps, radius: radius, order: figure.parts.map(\.name))
    }

    /// The same, on pieces already measured (`order`: part names in part order).
    static func loose(_ ps: [Piece], radius: Double, order names: [String]) -> [Loose] {
        guard ps.count > 1 else { return [] }
        let grow = SIMD3<Double>(repeating: radius * tolerance)
        // Union-find over pieces whose grown boxes overlap.
        var parent = Array(ps.indices)
        func root(_ i: Int) -> Int { var i = i; while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }; return i }
        for i in ps.indices {
            for j in (i + 1)..<ps.count {
                let a = ps[i], b = ps[j]
                var apart = false
                for k in 0..<3 {
                    let g = 2 * grow[k]
                    if a.lo[k] - b.hi[k] > g || b.lo[k] - a.hi[k] > g { apart = true }
                }
                if !apart { parent[root(i)] = root(j) }
            }
        }
        var groups: [Int: [Int]] = [:]
        for i in ps.indices { groups[root(i), default: []].append(i) }
        func volume(_ ids: [Int]) -> Double {
            ids.reduce(0) { acc, i in let d = ps[i].hi - ps[i].lo; return acc + max(d.x, 1e-6) * max(d.y, 1e-6) * max(d.z, 1e-6) }
        }
        let order = Dictionary(uniqueKeysWithValues: names.enumerated().map { ($1, $0) })
        // The object: the largest group; on a tie, the one holding the earliest-written part
        // (so the answer never depends on dictionary order).
        func first(_ ids: [Int]) -> Int { ids.map { order[ps[$0].part, default: 0] }.min() ?? 0 }
        guard groups.count > 1, let main = groups.values.max(by: { a, b in
            let va = volume(a), vb = volume(b)
            return va != vb ? va < vb : first(a) > first(b)
        }) else { return [] }
        var out: [Loose] = []
        for (_, ids) in groups where ids != main {
            var best: (gap: Double, shift: SIMD3<Double>) = (.infinity, .zero)
            for i in ids {
                for j in main {
                    let s = shift(from: ps[i], to: ps[j])
                    let g = simdLength(s)
                    if g < best.gap { best = (g, s) }
                }
            }
            let names = Array(Set(ids.map { ps[$0].part })).sorted { order[$0, default: 0] < order[$1, default: 0] }
            out.append(Loose(parts: names, pieces: ids.map { ps[$0] }, gap: best.gap, share: best.gap / radius, shift: best.shift))
        }
        return out.sorted { order[$0.parts[0], default: 0] < order[$1.parts[0], default: 0] }
    }

    /// Every copy's transform with loose groups moved onto the object: the nearest group first,
    /// by the shortest shift that makes its box overlap the object's nearest piece by the
    /// tolerance, then the check again (a group may join through one just moved), at most 12 times.
    /// Returns the transforms and what was moved (empty: nothing was loose).
    public static func closingGaps(_ figure: Figure, meshes: [String: FigureMesh])
        -> (transforms: [String: [FigureMatrix]], moved: [Loose]) {
        var full = FigurePlacement.fullTransforms(figure)
        var moved: [Loose] = []
        let radius = FigurePlacement.bounds(figure, meshes: meshes).radius
        let names = figure.parts.map(\.name)
        // Measured once: a move is a pure shift, so a moved piece's box shifts with it.
        var ps = pieces(figure, meshes: meshes, transforms: full)
        for _ in 0..<12 {
            guard let g = loose(ps, radius: radius, order: names).min(by: { $0.gap < $1.gap }) else { break }
            // Close the gap and sink in by the tolerance, along the axes that were apart.
            var s = g.shift
            for k in 0..<3 where s[k] != 0 { s[k] += (s[k] > 0 ? 1 : -1) * radius * tolerance }
            let move = FigureMatrix.translation(s)
            for piece in g.pieces {
                guard var list = full[piece.part] else { continue }
                list[piece.copy] = move * list[piece.copy]
                full[piece.part] = list
                if let i = ps.firstIndex(where: { $0.part == piece.part && $0.copy == piece.copy }) {
                    ps[i].lo += s
                    ps[i].hi += s
                }
            }
            moved.append(g)
        }
        return (full, moved)
    }
}
