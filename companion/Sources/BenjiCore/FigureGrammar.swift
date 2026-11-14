import Foundation

/// The figure block (D-107, D-108): a fenced JSON block at the end of a reply that describes a 3D
/// figure as named parts. Parsed case for case like `benji/figures.py`; both reduce a block to
/// the same canonical summary, checked on the shared cases in `companion/Tests/figure-cases.json`.
/// The grammar is written out in the figure-grammar implementation note.
public enum FigureGrammar {
    public static let maxParts = 40
    public static let maxLabels = 12
    public static let maxVertices = 120_000
    public static let maxTitle = 60
    public static let maxName = 40
    public static let maxLabelText = 40
    public static let maxSize = 1000.0
    public static let maxScale = 100.0
    public static let maxPathChars = 2000
    public static let maxPoints = 64
    public static let maxBlockChars = 60_000
    public static let maxBalls = 16
    public static let maxScatter = 64
    public static let maxRPM = 120.0
    public static let maxSections = 24
    /// Rings between two loft sections.
    public static let loftSteps = 6

    public static let kinds = ["box", "cyl", "cone", "sphere", "torus", "capsule", "tube", "lathe", "extrude", "blob", "loft"]
    public static let materials = ["steel", "aluminium", "chrome", "brass", "copper", "iron", "black", "rubber",
                                   "glass", "wood", "ceramic", "paper", "plastic", "matte"]
    public static let colours = ["red", "orange", "yellow", "green", "blue", "navy", "sky", "teal", "purple", "pink",
                                 "white", "grey", "gray", "black", "brown", "cream"]
    /// Near names the model reaches for, read as the nearest colour above.
    public static let colourAliases = ["beige": "cream", "ivory": "cream", "tan": "brown", "silver": "grey", "gold": "yellow",
                                       "maroon": "red", "crimson": "red", "lime": "green", "olive": "green", "cyan": "sky",
                                       "turquoise": "teal", "magenta": "pink", "violet": "purple", "lavender": "purple",
                                       "charcoal": "black"]
    public static let sides = ["left", "right", "top", "bottom"]
    static let axes: [String: SIMD3<Double>] = ["x": [1, 0, 0], "y": [0, 1, 0], "z": [0, 0, 1],
                                                "-x": [-1, 0, 0], "-y": [0, -1, 0], "-z": [0, 0, -1]]

    /// Segments around a round part (49 vertex columns: the seam is doubled), steps in a bevel arc.
    public static let round = 48
    public static let arcSteps = 4

    // MARK: finding the block

    private static let fence = try! NSRegularExpression(
        pattern: "^[ \\t]*```[ \\t]*([A-Za-z]*)[ \\t]*\\n(.*?)\\n[ \\t]*```[ \\t]*$",
        options: [.anchorsMatchLines, .dotMatchesLineSeparators, .useUnixLineSeparators])

    /// The reply without its figure block (the words before and after it joined), and the figure;
    /// (text, nil) when there is no block or it fails (then the text is returned unchanged).
    public static func parse(_ text: String) -> (text: String, figure: Figure?) {
        let ns = text as NSString
        var found: NSTextCheckingResult?
        for m in fence.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let info = ns.substring(with: m.range(at: 1)).lowercased()
            // A block marked figure counts wherever it is; one marked json only at the very end.
            let atEnd = { PointingTags.parse(ns.substring(from: m.range.location + m.range.length)).text
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            if info == "figure" || (info == "json" && atEnd()) { found = m }
        }
        guard let m = found else { return (text, nil) }
        let after = ns.substring(from: m.range.location + m.range.length)
        guard let figure = figure(json: ns.substring(with: m.range(at: 2))) else { return (text, nil) }
        let before = trimTrailing(ns.substring(to: m.range.location))
        let rest = after.trimmingCharacters(in: .whitespacesAndNewlines)
        return ((before + (rest.isEmpty ? "" : "\n" + rest)).trimmingCharacters(in: .whitespacesAndNewlines), figure)
    }

    public static func figure(json body: String) -> Figure? {
        guard body.unicodeScalars.count <= maxBlockChars,
              let value = try? JSONDecoder().decode(JSONValue.self, from: Data(body.utf8)),
              value.isFinite, case .object(let obj) = value, case .array(let parts)? = obj["parts"] else { return nil }
        return makeFigure(obj, parts)
    }

    private static func trimTrailing(_ s: String) -> String {
        var t = Substring(s)
        while let last = t.unicodeScalars.last, CharacterSet.whitespacesAndNewlines.contains(last) {
            t = Substring(t.unicodeScalars.dropLast())
        }
        return String(t)
    }

    // MARK: values

    static func num(_ v: JSONValue?) -> Double? {
        if case .number(let n)? = v { return n }
        return nil
    }

    static func size(_ v: JSONValue?) -> Double? {
        guard let n = num(v), n > 0, n <= maxSize else { return nil }
        return n
    }

    static func coord(_ v: JSONValue?) -> Double? {
        guard let n = num(v), abs(n) <= maxSize else { return nil }
        return n
    }

    static func vec3(_ v: JSONValue?) -> SIMD3<Double>? {
        guard case .array(let a)? = v, a.count == 3,
              let x = coord(a[0]), let y = coord(a[1]), let z = coord(a[2]) else { return nil }
        return [x, y, z]
    }

    static func direction(_ v: JSONValue?) -> SIMD3<Double>? {
        if case .string(let s)? = v { return axes[s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] }
        guard let vec = vec3(v) else { return nil }
        let length = (vec.x * vec.x + vec.y * vec.y + vec.z * vec.z).squareRoot()
        return length < 1e-9 ? nil : vec / length
    }

    static func text(_ v: JSONValue?, _ limit: Int) -> String {
        guard case .string(let s)? = v else { return "" }
        let cut = String(String.UnicodeScalarView(s.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.prefix(limit)))
        return cut.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func material(_ v: JSONValue?) -> String {
        guard case .string(let s)? = v else { return "matte" }
        let m = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if materials.contains(m) { return m }
        for prefix in ["paint:", "glow:"] where m.hasPrefix(prefix) {
            var colour = String(m.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            colour = colourAliases[colour] ?? colour
            if colours.contains(colour) || isHex(colour) { return prefix + colour }
        }
        return "matte"
    }

    static func isHex(_ s: String) -> Bool {
        s.unicodeScalars.count == 7 && s.hasPrefix("#")
            && s.unicodeScalars.dropFirst().allSatisfy { "0123456789abcdefABCDEF".unicodeScalars.contains($0) }
    }

    // MARK: parts

    private static func makeFigure(_ obj: [String: JSONValue], _ raws: [JSONValue]) -> Figure? {
        var parts: [FigurePart] = []
        var names: [String: FigurePart] = [:]
        var dropped = 0
        var total = 0
        for (i, raw) in raws.enumerated() {
            let number = i + 1
            guard i < maxParts, var part = makePart(raw, number: number, earlier: names),
                  total + part.budget * part.instances <= maxVertices else { dropped += 1; continue }
            total += part.budget * part.instances
            if names[part.name] != nil { part.name = "\(part.name) \(number)" }
            names[part.name] = part
            parts.append(part)
        }
        guard !parts.isEmpty else { return nil }
        return Figure(title: text(obj["title"], maxTitle), parts: parts, labels: labels(obj["labels"], parts),
                      view: view(obj["view"]), cut: cut(obj["cut"], parts, view: view(obj["view"])), dropped: dropped)
    }

    private static func makePart(_ raw: JSONValue, number: Int, earlier: [String: FigurePart]) -> FigurePart? {
        guard case .object(let o) = raw else { return nil }
        guard case .string(let k)? = o["kind"] else { return nil }
        let kind = k.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard kinds.contains(kind) else { return nil }
        var at = SIMD3<Double>(0, 0, 0)
        var axis = SIMD3<Double>(0, 1, 0)
        var span: Double?
        if ["cyl", "cone", "capsule"].contains(kind), o["from"] != nil, o["to"] != nil {
            guard let a = vec3(o["from"]), let b = vec3(o["to"]) else { return nil }
            let d = b - a
            let length = (d.x * d.x + d.y * d.y + d.z * d.z).squareRoot()
            guard length > 0, length <= maxSize else { return nil }
            span = length
            at = (a + b) / 2
            axis = d / length
        } else {
            if o["at"] != nil {
                guard let v = vec3(o["at"]) else { return nil }
                at = v
            }
            if o["axis"] != nil { axis = direction(o["axis"]) ?? [0, 1, 0] }
        }
        guard let recipe = recipe(kind, o, span: span) else { return nil }
        let name = text(o["name"], maxName)
        var parentPart: FigurePart?
        if case .string(let p)? = o["parent"] { parentPart = earlier[p.trimmingCharacters(in: .whitespacesAndNewlines)] }
        var part = FigurePart(number: number, name: name.isEmpty ? "part \(number)" : name, kind: kind,
                              recipe: recipe, mat: material(o["mat"]), at: at, axis: axis, rot: rot(o["rot"]),
                              scale: scale(o["scale"]), mirror: mirror(o["mirror"]), copies: copies(o["copies"]),
                              around: around(o["around"]), parent: parentPart?.name)
        part.scatter = scatter(o["scatter"])
        part.spin = spin(o["spin"])
        if case .bool(true)? = o["cut"] { part.cutMark = true }
        if case .object? = o["cut"] { part.cutMark = true }
        part.budget = budget(kind, recipe)
        let repeats: [Int] = [1 << part.mirror.count, part.copies?.count ?? 1, part.around?.count ?? 1,
                              part.scatter?.count ?? 1, parentPart?.instances ?? 1]
        part.instances = repeats.reduce(1, *)
        return part
    }

    private static func bevel(_ o: [String: JSONValue], smallest: Double, share: Double, cap: Double) -> Double {
        var b = num(o["bevel"]) ?? -1
        if b < 0 { b = smallest * share }
        return min(b, cap)
    }

    private static func recipe(_ kind: String, _ o: [String: JSONValue], span: Double?) -> FigureRecipe? {
        switch kind {
        case "box":
            var sides: [Double?]
            if num(o["size"]) != nil {
                sides = Array(repeating: size(o["size"]), count: 3)
            } else if case .array(let a)? = o["size"], a.count == 3 {
                sides = a.map { size($0) }
            } else { return nil }
            guard let w = sides[0], let h = sides[1], let d = sides[2] else { return nil }
            let smallest = min(w, h, d)
            return .box(size: [w, h, d], bevel: bevel(o, smallest: smallest, share: 0.06, cap: smallest / 2))
        case "cyl", "cone", "capsule":
            guard let r = size(o["r"]), let h = span ?? size(o["h"]) else { return nil }
            if kind == "capsule" { return .capsule(r: r, h: max(h, 2 * r)) }
            let b = bevel(o, smallest: min(2 * r, h), share: 0.06, cap: min(r, h / 2))
            if kind == "cyl" { return .cyl(r: r, h: h, bevel: b) }
            let r2 = num(o["r2"]).flatMap { $0 >= 0 && $0 <= maxSize ? $0 : nil } ?? 0
            return .cone(r: r, r2: r2, h: h, bevel: b)
        case "sphere":
            return size(o["r"]).map { .sphere(r: $0) }
        case "torus":
            guard let r = size(o["r"]) else { return nil }
            let tube = size(o["tube"]) ?? r / 4
            return tube < r ? .torus(r: r, tube: tube) : nil
        case "tube":
            guard let r = size(o["r"]), case .array(let a)? = o["path"], a.count >= 2, a.count <= maxPoints else { return nil }
            let points = a.compactMap { vec3($0) }
            // r2: the radius at the path's end, tapering from r (vessels, stems, horns, tails).
            let r2 = num(o["r2"]).flatMap { $0 >= 0 && $0 <= maxSize ? $0 : nil } ?? r
            return points.count == a.count ? .tube(r: r, path: points, r2: r2) : nil
        case "lathe":
            guard case .array(let a)? = o["profile"], a.count >= 2, a.count <= maxPoints else { return nil }
            var points: [SIMD2<Double>] = []
            for p in a {
                guard case .array(let pair) = p, pair.count == 2, let r = coord(pair[0]), let y = coord(pair[1]), r >= 0
                else { return nil }
                points.append([r, y])
            }
            return .lathe(profile: points)
        case "blob":
            // Spheres that melt into one smooth body (cells, organs, bodies, rocks), meshed in code.
            guard case .array(let a)? = o["balls"], !a.isEmpty, a.count <= maxBalls else { return nil }
            var balls: [SIMD4<Double>] = []
            for b in a {
                guard case .array(let q) = b, q.count == 4, let x = coord(q[0]), let y = coord(q[1]), let z = coord(q[2]),
                      let r = size(q[3]) else { return nil }
                balls.append([x, y, z, r])
            }
            let mean = balls.reduce(0) { $0 + $1.w } / Double(balls.count)
            let smooth = num(o["smooth"]).flatMap { $0 >= 0 && $0 <= maxSize ? $0 : nil } ?? 0.4 * mean
            let wobble = min(max(num(o["wobble"]) ?? 0, 0), 0.5)
            var chain = false
            if case .bool(true)? = o["chain"], balls.count > 1 { chain = true }
            return .blob(balls: balls, smooth: smooth, wobble: wobble, chain: chain)
        case "loft":
            // A smooth body through cross-sections along z (car bodies, hulls, fuselages, fish):
            // each [z, y, w, h] or [z, y, w, h, square], w and h half the width and height,
            // square 0 (an ellipse) to 1 (a rounded box).
            guard case .array(let a)? = o["sections"], a.count >= 2, a.count <= maxSections else { return nil }
            var sections: [[Double]] = []
            for item in a {
                guard case .array(let q) = item, q.count == 4 || q.count == 5,
                      let z = coord(q[0]), let y = coord(q[1]), let w = coord(q[2]), let h = coord(q[3]),
                      w >= 0, h >= 0 else { return nil }
                var square = 0.0
                if q.count == 5 { guard let s = num(q[4]) else { return nil }; square = min(max(s, 0), 1) }
                sections.append([z, y, w, h, square])
            }
            // Written front to back or back to front, but always one way along z.
            let rising = zip(sections, sections.dropFirst()).allSatisfy { $0[0] < $1[0] }
            let falling = zip(sections, sections.dropFirst()).allSatisfy { $0[0] > $1[0] }
            guard rising || falling, sections.contains(where: { $0[2] > 0 && $0[3] > 0 }) else { return nil }
            return .loft(sections: rising ? sections : sections.reversed())
        default:   // extrude
            guard case .string(let path)? = o["path"], path.unicodeScalars.count <= maxPathChars,
                  FigurePath.pointCount(path) != nil else { return nil }
            let depth = size(o["depth"]) ?? 0.2
            return .extrude(path: FigurePath.trimmed(path), depth: depth,
                            bevel: bevel(o, smallest: depth, share: 0.15, cap: depth / 2))
        }
    }

    private static func rot(_ v: JSONValue?) -> SIMD3<Double> {
        if let n = num(v) { return abs(n) <= 3600 ? [0, n, 0] : [0, 0, 0] }
        if case .array(let a)? = v, a.count == 3 {
            let xs = a.compactMap { num($0) }
            if xs.count == 3, xs.allSatisfy({ abs($0) <= 3600 }) { return [xs[0], xs[1], xs[2]] }
        }
        return [0, 0, 0]
    }

    private static func scale(_ v: JSONValue?) -> SIMD3<Double> {
        if let n = num(v) { return n > 0 && n <= maxScale ? [n, n, n] : [1, 1, 1] }
        if case .array(let a)? = v, a.count == 3 {
            let xs = a.compactMap { num($0) }
            if xs.count == 3, xs.allSatisfy({ $0 > 0 && $0 <= maxScale }) { return [xs[0], xs[1], xs[2]] }
        }
        return [1, 1, 1]
    }

    private static func mirror(_ v: JSONValue?) -> [String] {
        var items: [JSONValue] = []
        if case .string? = v { items = [v!] } else if case .array(let a)? = v { items = a }
        return ["x", "y", "z"].filter { axis in
            items.contains { if case .string(let s) = $0 { return s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == axis }
                             return false }
        }
    }

    private static func count(_ v: JSONValue?, top: Int) -> Int? {
        guard let n = num(v), n == n.rounded(.down), n >= 1, n <= Double(top) else { return nil }
        return Int(n)
    }

    private static func copies(_ v: JSONValue?) -> FigurePart.Copies? {
        guard case .object(let o)? = v, let n = count(o["count"], top: 24) else { return nil }
        let step: SIMD3<Double>? = o["step"] != nil ? vec3(o["step"]) : [0, 0, 0]
        let turn: Double? = o["turn"] != nil ? num(o["turn"]) : 0
        guard let step, let turn, abs(turn) <= 3600 else { return nil }
        return .init(count: n, step: step, turn: turn)
    }

    private static func around(_ v: JSONValue?) -> FigurePart.Around? {
        guard case .object(let o)? = v, let n = count(o["count"], top: 64) else { return nil }
        let axis: SIMD3<Double>? = o["axis"] != nil ? direction(o["axis"]) : [0, 1, 0]
        let center: SIMD3<Double>? = o["center"] != nil ? vec3(o["center"]) : [0, 0, 0]
        let arc: Double? = o["arc"] != nil ? num(o["arc"]) : 360
        guard let axis, let center, let arc, arc > 0, arc <= 360 else { return nil }
        return .init(count: n, axis: axis, center: center, arc: arc)
    }

    /// Copies at seeded random places inside an ellipsoid round the part, each turned at random.
    private static func scatter(_ v: JSONValue?) -> FigurePart.Scatter? {
        guard case .object(let o)? = v, let n = count(o["count"], top: maxScatter) else { return nil }
        var inside: SIMD3<Double>? = [1, 1, 1]
        if let r = num(o["in"]) {
            inside = size(.number(r)).map { [$0, $0, $0] }
        } else if case .array(let a)? = o["in"], a.count == 3 {
            let xs = a.compactMap { size($0) }
            inside = xs.count == 3 ? [xs[0], xs[1], xs[2]] : nil
        } else if o["in"] != nil {
            inside = nil
        }
        var seed = 1
        if o["seed"] != nil {
            guard let s = num(o["seed"]), s == s.rounded(.down), s >= 0, s <= 1_000_000 else { return nil }
            seed = Int(s)
        }
        guard let inside else { return nil }
        return .init(count: n, inside: inside, seed: seed)
    }

    /// A turn that keeps going once the figure is built: rpm, or {rpm, axis, center}.
    private static func spin(_ v: JSONValue?) -> FigurePart.Spin? {
        func rate(_ x: JSONValue?) -> Double? {
            guard let r = num(x), r != 0, abs(r) <= maxRPM else { return nil }
            return r
        }
        if let r = rate(v) { return .init(rpm: r, axis: nil, center: nil) }
        guard case .object(let o)? = v, let r = rate(o["rpm"]) else { return nil }
        let axis = o["axis"] != nil ? direction(o["axis"]) : nil
        let center = o["center"] != nil ? vec3(o["center"]) : nil
        if (o["axis"] != nil && axis == nil) || (o["center"] != nil && center == nil) { return nil }
        return .init(rpm: r, axis: axis, center: center)
    }

    private static func labels(_ v: JSONValue?, _ parts: [FigurePart]) -> [FigureLabel] {
        guard case .array(let a)? = v else { return [] }
        var out: [FigureLabel] = []
        for raw in a {
            if out.count == maxLabels { break }
            guard case .object(let o) = raw else { continue }
            var part: FigurePart?
            if case .string(let s)? = o["part"] {
                let name = s.trimmingCharacters(in: .whitespacesAndNewlines)
                part = parts.first { $0.name == name }
            } else if let n = num(o["part"]), n == n.rounded(.down), abs(n) < 1e9 {
                part = parts.first { $0.number == Int(n) }
            }
            let words = text(o["text"], maxLabelText)
            guard let part, !words.isEmpty else { continue }
            var side = ""
            if case .string(let s)? = o["side"] { side = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            out.append(FigureLabel(part: part.name, text: words, side: sides.contains(side) ? side : ""))
        }
        return out
    }

    private static func view(_ v: JSONValue?) -> FigureView {
        guard case .object(let o)? = v else { return FigureView() }
        var turn = num(o["turn"]).map { fmod($0, 360) } ?? 30
        if turn > 180 { turn -= 360 } else if turn < -180 { turn += 360 }
        func clamp(_ x: JSONValue?, _ lo: Double, _ hi: Double, _ d: Double) -> Double { num(x).map { min(max($0, lo), hi) } ?? d }
        return FigureView(turn: turn, tilt: clamp(o["tilt"], -80, 80, 20), zoom: clamp(o["zoom"], 0.5, 3, 1))
    }

    /// The level direction from the figure to the camera at its view.
    static func towardViewer(_ view: FigureView) -> SIMD3<Double> {
        let t = view.turn * .pi / 180
        return [sin(t), 0, cos(t)]
    }

    /// The top-level cut, plus any part that asked to be cut itself; a part-level cut alone
    /// opens toward the viewer through the origin.
    private static func cut(_ v: JSONValue?, _ parts: [FigurePart], view: FigureView) -> FigureCut? {
        var axis: SIMD3<Double>?
        var at = 0.0
        var listed: JSONValue?
        if case .object(let o)? = v {
            // No axis (or "view"): cut away the half toward the viewer, so the inside faces the camera.
            let raw = o["axis"] ?? .string("view")
            var viewward = false
            if case .string(let s) = raw { viewward = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "view" }
            axis = viewward ? towardViewer(view) : direction(raw)
            let offset: Double? = o["at"] != nil ? coord(o["at"]) : 0
            listed = o["parts"]
            if axis == nil || offset == nil { axis = nil; listed = nil } else { at = offset! }
        }
        let marked = Set(parts.filter(\.cutMark).map(\.name))
        if axis == nil {
            if marked.isEmpty { return nil }
            axis = towardViewer(view)
            at = 0
            listed = .array([])
        }
        var chosen = parts.map(\.name)
        if case .array(let list)? = listed {
            let names = Set(list.compactMap { v -> String? in
                if case .string(let s) = v { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
                return nil
            })
            chosen = parts.map(\.name).filter { marked.contains($0) || names.contains($0) }
        }
        return chosen.isEmpty ? nil : FigureCut(axis: axis!, at: at, parts: chosen)
    }

    // MARK: vertex budgets

    /// Vertices of one instance of a part's mesh: fixed by its recipe, an upper bound on what
    /// `FigureMesh` builds (checked in FigureMeshTests).
    public static func budget(_ kind: String, _ recipe: FigureRecipe) -> Int {
        let cols = round + 1
        let arc = arcSteps + 1
        switch recipe {
        case .box(_, let b): return b > 0 ? 600 : 24
        case .cyl(_, _, let b): return cols * 2 * (b > 0 ? 2 + 2 * arc : 4)
        case .cone(_, let r2, _, let b):
            let tip = r2 > 0 ? 1 : 0
            return cols * 2 * (b > 0 ? 2 + arc + tip : 3 + tip)
        case .sphere, .torus: return cols * 25
        case .capsule: return cols * 26
        case .tube(_, let path, _): return 17 * ((path.count - 1) * 4 + 1) + 36
        case .blob: return FigureBlob.budget
        case .loft(let sections): return ((sections.count - 1) * loftSteps + 1) * cols + 2 * (cols + 1)
        case .lathe(let profile): return cols * 2 * profile.count
        case .extrude(let path, _, let b):
            let m = FigurePath.pointCount(path) ?? 0
            return 2 * m + 4 * m * (b > 0 ? 3 : 1)
        }
    }

    // MARK: the summary both parsers agree on

    /// The canonical summary of a reply's figure, compared byte for byte with Python's.
    public static func summary(_ reply: String) -> String {
        let (rest, figure) = parse(reply)
        guard let f = figure else { return Canonical.json(.object(["ok": .bool(false), "text": .string(rest)])) }
        func v3(_ v: SIMD3<Double>) -> JSONValue { .array([.number(v.x), .number(v.y), .number(v.z)]) }
        func opt(_ s: String?) -> JSONValue { s.map { .string($0) } ?? .null }
        let parts: [JSONValue] = f.parts.map { p in
            var o: [String: JSONValue] = [
                "n": .number(Double(p.number)), "name": .string(p.name), "kind": .string(p.kind), "mat": .string(p.mat),
                "recipe": .string(p.recipe.canonical), "at": v3(p.at), "axis": v3(p.axis), "rot": v3(p.rot),
                "scale": v3(p.scale), "mirror": .array(p.mirror.map { .string($0) }),
                "instances": .number(Double(p.instances)), "budget": .number(Double(p.budget)), "parent": opt(p.parent),
                "copies": p.copies.map { .object(["count": .number(Double($0.count)), "step": v3($0.step), "turn": .number($0.turn)]) } ?? .null,
                "around": p.around.map { .object(["count": .number(Double($0.count)), "axis": v3($0.axis), "center": v3($0.center),
                                                  "arc": .number($0.arc)]) } ?? .null,
            ]
            // Only when used, so summaries of figures without them are unchanged.
            if let s = p.scatter {
                o["scatter"] = .object(["count": .number(Double(s.count)), "in": v3(s.inside), "seed": .number(Double(s.seed))])
            }
            if let s = p.spin {
                o["spin"] = .object(["rpm": .number(s.rpm), "axis": s.axis.map(v3) ?? .null, "center": s.center.map(v3) ?? .null])
            }
            return .object(o)
        }
        return Canonical.json(.object([
            "ok": .bool(true), "text": .string(rest), "title": .string(f.title), "dropped": .number(Double(f.dropped)),
            "vertices": .number(Double(f.vertices)), "parts": .array(parts),
            "labels": .array(f.labels.map { .object(["part": .string($0.part), "text": .string($0.text), "side": .string($0.side)]) }),
            "view": .object(["turn": .number(f.view.turn), "tilt": .number(f.view.tilt), "zoom": .number(f.view.zoom)]),
            "cut": f.cut.map { .object(["axis": v3($0.axis), "at": .number($0.at), "parts": .array($0.parts.map { .string($0) })]) } ?? .null,
        ]))
    }
}

// MARK: the parsed figure

public struct Figure: Equatable, Sendable {
    public var title: String
    public var parts: [FigurePart]
    public var labels: [FigureLabel]
    public var view: FigureView
    public var cut: FigureCut?
    /// Parts dropped while parsing (bad, past 40, past the vertex cap).
    public var dropped: Int

    public var vertices: Int { parts.reduce(0) { $0 + $1.budget * $1.instances } }
    public func part(named name: String) -> FigurePart? { parts.first { $0.name == name } }
}

public struct FigurePart: Equatable, Sendable {
    public struct Copies: Equatable, Sendable { public var count: Int; public var step: SIMD3<Double>; public var turn: Double }
    public struct Around: Equatable, Sendable {
        public var count: Int; public var axis: SIMD3<Double>; public var center: SIMD3<Double>; public var arc: Double
    }
    /// 1-based, in the order written.
    public var number: Int
    public var name: String
    public var kind: String
    public var recipe: FigureRecipe
    public var mat: String
    public var at: SIMD3<Double>
    public var axis: SIMD3<Double>
    /// Degrees about the figure's x, y, z, applied in that order after `axis`.
    public var rot: SIMD3<Double>
    /// Along the figure's own x, y, z.
    public var scale: SIMD3<Double>
    public var mirror: [String]
    public var copies: Copies?
    public var around: Around?
    public var parent: String?
    public struct Scatter: Equatable, Sendable { public var count: Int; public var inside: SIMD3<Double>; public var seed: Int }
    public struct Spin: Equatable, Sendable { public var rpm: Double; public var axis: SIMD3<Double>?; public var center: SIMD3<Double>? }
    /// Copies at seeded random places and turns (organelles, rivets, stars).
    public var scatter: Scatter?
    /// Keeps turning once the figure is built (fans, wheels, rotors).
    public var spin: Spin?
    /// The part said `"cut": true` (or an object) itself.
    public var cutMark = false
    public var instances = 1
    public var budget = 0
}

/// A part's shape after defaults: the mesh's cache key.
public enum FigureRecipe: Equatable, Hashable, Sendable {
    case box(size: SIMD3<Double>, bevel: Double)
    case cyl(r: Double, h: Double, bevel: Double)
    case cone(r: Double, r2: Double, h: Double, bevel: Double)
    case sphere(r: Double)
    case torus(r: Double, tube: Double)
    case capsule(r: Double, h: Double)
    /// r2: the radius at the end of the path (r when it does not taper).
    case tube(r: Double, path: [SIMD3<Double>], r2: Double)
    case lathe(profile: [SIMD2<Double>])
    case extrude(path: String, depth: Double, bevel: Double)
    /// Balls [x, y, z, r] joined by a smooth minimum of width `smooth`; `wobble` bumps the surface.
    /// `chain`: the balls joined in order into one tapered limb.
    case blob(balls: [SIMD4<Double>], smooth: Double, wobble: Double, chain: Bool)
    /// Cross-sections [z, y, w, h, square] in rising z, joined smoothly (FigureMesh.loft).
    case loft(sections: [[Double]])

    public var kind: String {
        switch self {
        case .box: return "box"
        case .cyl: return "cyl"
        case .cone: return "cone"
        case .sphere: return "sphere"
        case .torus: return "torus"
        case .capsule: return "capsule"
        case .tube: return "tube"
        case .lathe: return "lathe"
        case .extrude: return "extrude"
        case .blob: return "blob"
        case .loft: return "loft"
        }
    }

    /// Sorted keys, no spaces, numbers to 4 decimals: the same bytes as Python's.
    public var canonical: String {
        func n(_ x: Double) -> JSONValue { .number(x) }
        var o: [String: JSONValue] = ["kind": .string(kind)]
        switch self {
        case let .box(s, b): o["size"] = .array([n(s.x), n(s.y), n(s.z)]); o["bevel"] = n(b)
        case let .cyl(r, h, b): o["r"] = n(r); o["h"] = n(h); o["bevel"] = n(b)
        case let .cone(r, r2, h, b): o["r"] = n(r); o["r2"] = n(r2); o["h"] = n(h); o["bevel"] = n(b)
        case let .sphere(r): o["r"] = n(r)
        case let .torus(r, t): o["r"] = n(r); o["tube"] = n(t)
        case let .capsule(r, h): o["r"] = n(r); o["h"] = n(h)
        case let .tube(r, p, r2):
            o["r"] = n(r); o["path"] = .array(p.map { .array([n($0.x), n($0.y), n($0.z)]) })
            if r2 != r { o["r2"] = n(r2) }
        case let .lathe(p): o["profile"] = .array(p.map { .array([n($0.x), n($0.y)]) })
        case let .extrude(path, d, b): o["path"] = .string(path); o["depth"] = n(d); o["bevel"] = n(b)
        case let .blob(balls, k, w, chain):
            o["balls"] = .array(balls.map { .array([n($0.x), n($0.y), n($0.z), n($0.w)]) })
            o["smooth"] = n(k); o["wobble"] = n(w)
            if chain { o["chain"] = .bool(true) }
        case let .loft(sections): o["sections"] = .array(sections.map { .array($0.map(n)) })
        }
        return Canonical.json(.object(o))
    }
}

public struct FigureLabel: Equatable, Sendable {
    public var part: String
    public var text: String
    /// "", "left", "right", "top" or "bottom".
    public var side: String
}

public struct FigureView: Equatable, Sendable {
    public var turn = 30.0
    public var tilt = 20.0
    public var zoom = 1.0
    public init(turn: Double = 30, tilt: Double = 20, zoom: Double = 1) { self.turn = turn; self.tilt = tilt; self.zoom = zoom }
}

public struct FigureCut: Equatable, Sendable {
    /// The side cut away: everything with dot(p, axis) > at.
    public var axis: SIMD3<Double>
    public var at: Double
    public var parts: [String]
}

// MARK: JSON values and canonical text

public enum JSONValue: Equatable, Sendable, Decodable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let d = try? c.decode(Double.self) { self = .number(d) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    var isFinite: Bool {
        switch self {
        case .number(let n): return n.isFinite
        case .array(let a): return a.allSatisfy(\.isFinite)
        case .object(let o): return o.values.allSatisfy(\.isFinite)
        default: return true
        }
    }
}

public enum Canonical {
    /// Rounded half away from zero to 4 decimals, without trailing zeros; -0 is 0.
    public static func number(_ x: Double) -> String {
        let scaled = (abs(x) * 10000 + 0.5).rounded(.down)
        guard scaled < 1e15 else { return String(format: "%.0f", x) }
        let n = Int64(scaled)
        if n == 0 { return "0" }
        let whole = n / 10000, frac = n % 10000
        var s = String(whole)
        if frac != 0 {
            var f = String(frac)
            f = String(repeating: "0", count: 4 - f.count) + f
            while f.hasSuffix("0") { f.removeLast() }
            s += "." + f
        }
        return x < 0 ? "-" + s : s
    }

    public static func string(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case _ where u.value < 0x20: out += String(format: "\\u%04x", u.value)
            default: out.unicodeScalars.append(u)
            }
        }
        return out + "\""
    }

    public static func json(_ v: JSONValue) -> String {
        switch v {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return number(n)
        case .string(let s): return string(s)
        case .array(let a): return "[" + a.map(json).joined(separator: ",") + "]"
        case .object(let o):
            // Python sorts keys by code point; so does this (UTF-8 byte order matches code point order).
            let keys = o.keys.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
            return "{" + keys.map { string($0) + ":" + json(o[$0]!) }.joined(separator: ",") + "}"
        }
    }
}
