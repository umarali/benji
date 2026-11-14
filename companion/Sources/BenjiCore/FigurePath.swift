import Foundation

/// An extrude part's outline: an SVG-style path (M L H V C Q Z, either case), read exactly as
/// `benji/figures.py` reads it (`path_points`) and flattened for the mesh: a line command adds
/// one point, a C or Q curve eight; a closing repeat of a subpath's first point is dropped and
/// subpaths under 3 points are ignored. The outline is in the part's x-y plane, y up.
public enum FigurePath {
    public static let curveSteps = 8

    private static let token = try! NSRegularExpression(
        pattern: "[ \\t\\r\\n]*,?[ \\t\\r\\n]*([MLHVCQZmlhvcqz]|-?(?:[0-9]+\\.?[0-9]*|\\.[0-9]+)(?:[eE][-+]?[0-9]+)?)")

    public static func trimmed(_ path: String) -> String {
        path.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n"))
    }

    /// Outline points once flattened; nil when the path does not parse or has no outline.
    public static func pointCount(_ path: String) -> Int? {
        outlines(path).map { $0.reduce(0) { $0 + $1.count } }
    }

    /// The flattened subpaths (each at least 3 points, not closed by a repeated point), in the
    /// part's x-y plane; nil when the path does not parse or has no outline.
    public static func outlines(_ path: String) -> [[SIMD2<Double>]]? {
        guard let tokens = tokens(trimmed(path)) else { return nil }
        var result: [[SIMD2<Double>]] = []
        var sub: [SIMD2<Double>] = []
        var cur = SIMD2<Double>(0, 0)
        var start = SIMD2<Double>(0, 0)
        var cmd: Character?
        var i = 0

        func close() {
            var pts = sub
            if pts.count > 1, pts.last == pts.first { pts.removeLast() }
            if pts.count >= 3 { result.append(pts) }
            sub = []
        }

        while i < tokens.count {
            let t = tokens[i]
            if let c = t.first, c.isLetter {
                cmd = c
                i += 1
                if c == "Z" || c == "z" { close(); cur = start; continue }
            } else if cmd == nil || cmd == "Z" || cmd == "z" {
                return nil
            }
            guard let command = cmd else { return nil }
            let rel = command.isLowercase
            let c = Character(command.uppercased())
            let arity: Int = ["M": 2, "L": 2, "H": 1, "V": 1, "C": 6, "Q": 4][c] ?? 0
            guard i + arity <= tokens.count else { return nil }
            var vals: [Double] = []
            for k in i..<(i + arity) {
                guard let v = Double(tokens[k]) else { return nil }
                vals.append(v)
            }
            i += arity
            let origin = rel ? cur : SIMD2<Double>(0, 0)
            let from = cur
            switch c {
            case "H": cur = SIMD2(vals[0] + (rel ? cur.x : 0), cur.y)
            case "V": cur = SIMD2(cur.x, vals[0] + (rel ? cur.y : 0))
            default: cur = SIMD2(vals[arity - 2], vals[arity - 1]) + origin
            }
            guard vals.allSatisfy({ abs($0) <= FigureGrammar.maxSize }),
                  abs(cur.x) <= FigureGrammar.maxSize, abs(cur.y) <= FigureGrammar.maxSize else { return nil }
            switch c {
            case "M":
                if !sub.isEmpty { close() }
                start = cur
                sub = [cur]
                cmd = rel ? "l" : "L"
            case "C":
                let c1 = SIMD2(vals[0], vals[1]) + origin, c2 = SIMD2(vals[2], vals[3]) + origin
                for k in 1...curveSteps {
                    let t = Double(k) / Double(curveSteps), u = 1 - t
                    sub.append(k == curveSteps ? cur
                               : u * u * u * from + 3 * u * u * t * c1 + 3 * u * t * t * c2 + t * t * t * cur)
                }
            case "Q":
                let c1 = SIMD2(vals[0], vals[1]) + origin
                for k in 1...curveSteps {
                    let t = Double(k) / Double(curveSteps), u = 1 - t
                    sub.append(k == curveSteps ? cur : u * u * from + 2 * u * t * c1 + t * t * cur)
                }
            default:
                sub.append(cur)
            }
        }
        close()
        return result.isEmpty ? nil : result
    }

    private static func tokens(_ s: String) -> [String]? {
        let ns = s as NSString
        var out: [String] = []
        var pos = 0
        while pos < ns.length {
            guard let m = token.firstMatch(in: s, options: [.anchored], range: NSRange(location: pos, length: ns.length - pos)),
                  m.range.length > 0 else { return nil }
            out.append(ns.substring(with: m.range(at: 1)))
            pos = m.range.location + m.range.length
        }
        return out
    }
}
