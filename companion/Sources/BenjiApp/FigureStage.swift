import AppKit
import BenjiCore
import SceneKit

/// A figure as a lit SceneKit scene (D-107 tier 1, D-108): physically based materials by name, a
/// key light with a soft shadow, a rim light, a small procedural environment for reflections,
/// ambient occlusion, an inverted-hull ink outline, a ground that catches the shadow, and an
/// optional cut. The same scene is drawn by the card's `SCNView` and by the offscreen renders
/// (`tools/figure-render`), so what the renders show is what the card shows.
final class FigureScene {
    let figure: Figure
    let scene = SCNScene()
    let timeline: FigureTimeline
    let centre: SIMD3<Double>
    let radius: Double
    /// The camera rig: idle turn (per frame) → view turn → view tilt → dolly (per frame) → camera.
    let idleNode = SCNNode(), turnNode = SCNNode(), tiltNode = SCNNode(), cameraNode = SCNNode()
    private(set) var view: FigureView
    /// What the user has done to the figure by hand (drag, zoom, reset), shared with the main thread.
    let handling: FigureHandling
    /// The handling version last applied, and the turn the framing fits were measured at.
    private var appliedHandling = 0
    private var fitsTurn = 0.0
    /// Per part, the nodes that scale in (one per copy).
    private var growNodes: [[SCNNode]] = []
    /// Per part, its samples in figure space (every copy), for labels and the model's box.
    private var samples: [[SIMD3<Double>]] = []
    /// Parts that keep turning once built: the node their copies hang from, and the line it turns about.
    private var spinners: [(node: SCNNode, axis: SIMD3<Float>, center: SIMD3<Float>, rpm: Double)] = []
    /// Per part, its triangles in figure space (every copy) and its cut, for finding what shows.
    private var surfaces: [FigureAnchors.Surface?] = []
    /// The label points last found visible, and when (see `labelAnchors`).
    private var visibleCache: (stamp: TimeInterval, wanted: [Int], points: [Int: SIMD3<Double>])?
    private let aspect: Double
    private let fullAspect: Double
    private let margin: Double
    /// Distance scale from the bounding sphere's framing to a tight fit, at 48 angles of the idle
    /// turn (eval spread: fitting the worst angle left long, thin things small at their own view).
    private(set) var fits = [Double](repeating: 1, count: 48)
    /// How much larger the figure shows at its own view than framed for its widest angle (the
    /// framing before the spread eval).
    var framingGain: Double { (fits.max() ?? 1) / fits[0] }
    /// Between the tilt and the camera: moves the camera in and out with the idle turn.
    let dollyNode = SCNNode()

    static let ink = NSColor(red: 0.06, green: 0.07, blue: 0.07, alpha: 1)
    /// Outline width as a share of the distance to the camera (about 1.3 pt at the card's size).
    static let outlineWidth: Float = 0.0019

    /// The meshes for a figure, built off the main thread through the shared cache.
    static func meshes(for figure: Figure, cache: FigureMeshCache = .shared) -> [String: FigureMesh] {
        var out: [String: FigureMesh] = [:]
        for p in figure.parts { out[p.name] = cache.mesh(for: p.recipe) }
        return out
    }

    /// `aspect`: the stage's width over height; `labelMargin`: the share of the width kept free
    /// for labels on each side (the camera frames the model in what is left).
    /// Loose groups the scene moved onto the object (FigureJoints); empty when nothing was loose.
    private(set) var joined: [FigureJoints.Loose] = []

    /// `closeGaps`: move parts that touch nothing onto the object (on unless a render compares).
    /// The pure work for a figure, done off the main thread (the card's build queue): its meshes,
    /// every copy's placement with gaps closed, and its bounds. No SceneKit here.
    struct Prepared {
        let figure: Figure
        let meshes: [String: FigureMesh]
        let transforms: [String: [FigureMatrix]]
        let joined: [FigureJoints.Loose]
        let centre: SIMD3<Double>
        let radius: Double
    }

    static func prepare(_ figure: Figure, meshes: [String: FigureMesh], closeGaps: Bool = true) -> Prepared {
        let (full, joined) = closeGaps ? FigureJoints.closingGaps(figure, meshes: meshes)
            : (FigurePlacement.fullTransforms(figure), [])
        let (centre, radius) = FigurePlacement.bounds(figure, meshes: meshes, transforms: full)
        return Prepared(figure: figure, meshes: meshes, transforms: full, joined: joined, centre: centre, radius: radius)
    }

    static func prepare(_ figure: Figure, cache: FigureMeshCache = .shared, closeGaps: Bool = true) -> Prepared {
        prepare(figure, meshes: meshes(for: figure, cache: cache), closeGaps: closeGaps)
    }

    /// `closeGaps`: move parts that touch nothing onto the object (on unless a render compares).
    convenience init(figure: Figure, meshes: [String: FigureMesh], aspect: Double, labelMargin: Double = 0.24,
                     closeGaps: Bool = true) {
        self.init(prepared: Self.prepare(figure, meshes: meshes, closeGaps: closeGaps), aspect: aspect, labelMargin: labelMargin)
    }

    /// The SceneKit side only: nodes, materials, lights, camera and framing.
    init(prepared p: Prepared, aspect: Double, labelMargin: Double = 0.24) {
        figure = p.figure
        view = p.figure.view
        handling = FigureHandling(base: p.figure.view)
        fullAspect = aspect
        margin = p.figure.labels.isEmpty ? 0.04 : labelMargin
        self.aspect = max(0.3, aspect * (1 - 2 * margin))
        timeline = FigureTimeline(parts: p.figure.parts.count)
        joined = p.joined
        (centre, radius) = (p.centre, p.radius)
        let meshes = p.meshes
        scene.background.contents = NSColor.clear
        buildParts(meshes, placed: FigurePlacement.instances(p.transforms))
        buildLights()
        buildGround()
        buildCamera()
    }

    // MARK: parts

    private func buildParts(_ meshes: [String: FigureMesh], placed: [String: [FigureInstance]]) {
        let root = SCNNode()
        scene.rootNode.addChildNode(root)
        var geometries: [String: (SCNGeometry, SCNGeometry?)] = [:]   // by recipe: plain, mirrored
        for part in figure.parts {
            guard let mesh = meshes[part.name], let list = placed[part.name] else {
                growNodes.append([]); samples.append([]); surfaces.append(nil); continue
            }
            let key = part.recipe.canonical
            if geometries[key] == nil { geometries[key] = (Self.geometry(mesh), nil) }
            if list.contains(where: \.mirrored), geometries[key]?.1 == nil { geometries[key]?.1 = Self.geometry(mesh.mirroredX()) }
            let cut = figure.cut.flatMap { $0.parts.contains(part.name) ? $0 : nil }
            let material = FigureMaterials.material(part.mat)
            let outline = Self.outlineMaterial(cut: cut)
            let inside = cut.map { Self.insideMaterial(cut: $0, mat: part.mat) }
            if let cut { Self.addCut(cut, to: material) }
            var grows: [SCNNode] = []
            var pts: [SIMD3<Double>] = []
            // A spinning part: each copy hangs from its own node, turned about its line each frame.
            let lines = part.spin.map { _ in FigurePlacement.spinLines(part, copies: list.map(\.transform)) }
            var surface = FigureAnchors.Surface(positions: [], indices: [],
                                                cutAxis: cut.map { SIMD3<Float>(Float($0.axis.x), Float($0.axis.y), Float($0.axis.z)) },
                                                cutAt: Float(cut?.at ?? 0))
            for (c, inst) in list.enumerated() {
                guard let base = inst.mirrored ? geometries[key]?.1 : geometries[key]?.0 else { continue }
                let holder = SCNNode()
                holder.simdTransform = Self.float4x4(inst.transform)
                let grow = SCNNode()
                grow.addChildNode(Self.node(base, material, name: part.name))
                let hull = Self.node(base, outline, name: part.name)
                hull.castsShadow = false
                hull.renderingOrder = -1
                grow.addChildNode(hull)
                if let inside {
                    let n = Self.node(base, inside, name: part.name)
                    n.castsShadow = false
                    grow.addChildNode(n)
                }
                grow.scale = SCNVector3(0.001, 0.001, 0.001)
                holder.addChildNode(grow)
                if let spin = part.spin, let line = lines?[c] {
                    let node = SCNNode()
                    node.addChildNode(holder)
                    root.addChildNode(node)
                    spinners.append((node, SIMD3<Float>(line.axis), SIMD3<Float>(line.center), spin.rpm))
                } else {
                    root.addChildNode(holder)
                }
                grows.append(grow)
                let s = inst.mirrored ? mesh.mirroredX().samples : mesh.samples
                pts += s.map { inst.transform.apply(SIMD3<Double>($0)) }
                let m = inst.mirrored ? mesh.mirroredX() : mesh
                let first = UInt32(surface.positions.count)
                surface.positions += m.positions.map { SIMD3<Float>(inst.transform.apply(SIMD3<Double>($0))) }
                surface.indices += m.indices.map { $0 + first }
            }
            growNodes.append(grows)
            samples.append(pts)
            surfaces.append(surface)
        }
    }

    private static func node(_ base: SCNGeometry, _ material: SCNMaterial, name: String) -> SCNNode {
        let g = base.copy() as! SCNGeometry   // shares the vertex data, own materials
        g.materials = [material]
        let n = SCNNode(geometry: g)
        n.name = name
        return n
    }

    static func geometry(_ m: FigureMesh) -> SCNGeometry {
        let pos = m.positions.map { SCNVector3(CGFloat($0.x), CGFloat($0.y), CGFloat($0.z)) }
        let nor = m.normals.map { SCNVector3(CGFloat($0.x), CGFloat($0.y), CGFloat($0.z)) }
        let element = SCNGeometryElement(indices: m.indices, primitiveType: .triangles)
        return SCNGeometry(sources: [SCNGeometrySource(vertices: pos), SCNGeometrySource(normals: nor)], elements: [element])
    }

    static func float4x4(_ t: FigureMatrix) -> simd_float4x4 {
        simd_float4x4(columns: (SIMD4(Float(t.m[0]), Float(t.m[1]), Float(t.m[2]), Float(t.m[3])),
                                SIMD4(Float(t.m[4]), Float(t.m[5]), Float(t.m[6]), Float(t.m[7])),
                                SIMD4(Float(t.m[8]), Float(t.m[9]), Float(t.m[10]), Float(t.m[11])),
                                SIMD4(Float(t.m[12]), Float(t.m[13]), Float(t.m[14]), Float(t.m[15]))))
    }

    // MARK: outline and cut

    private static let worldVarying = """
        #pragma varyings
        float3 figureWorld;
        """

    /// The inverted hull: back faces pushed out along their normals by a constant share of the
    /// distance to the camera (so the line keeps its width however near or scaled the part).
    static func outlineMaterial(cut: FigureCut?) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = ink
        m.cullMode = .front
        m.writesToDepthBuffer = true
        var geometry = """
            #pragma arguments
            float outlineWidth;
            #pragma body
            float4 viewPos = scn_node.modelViewTransform * _geometry.position;
            float3 viewN = normalize((scn_node.modelViewTransform * float4(_geometry.normal, 0.0)).xyz);
            viewPos.xyz += viewN * outlineWidth * max(-viewPos.z, 0.001);
            _geometry.position = scn_node.inverseModelViewTransform * viewPos;
            """
        if cut != nil {
            geometry = worldVarying + "\n" + geometry + "\nout.figureWorld = (scn_node.modelTransform * _geometry.position).xyz;"
        }
        m.shaderModifiers = [.geometry: geometry]
        m.setValue(NSNumber(value: outlineWidth), forKey: "outlineWidth")
        if let cut { addCutFragment(cut, to: m) }
        return m
    }

    static func addCut(_ cut: FigureCut, to m: SCNMaterial) {
        m.shaderModifiers = [.geometry: worldVarying + "\n#pragma body\nout.figureWorld = (scn_node.modelTransform * _geometry.position).xyz;"]
        addCutFragment(cut, to: m)
    }

    private static func addCutFragment(_ cut: FigureCut, to m: SCNMaterial) {
        var mods = m.shaderModifiers ?? [:]
        mods[.fragment] = """
            #pragma arguments
            float4 cutPlane;
            #pragma body
            if (dot(in.figureWorld, cutPlane.xyz) > cutPlane.w) discard_fragment();
            """
        m.shaderModifiers = mods
        m.setValue(NSValue(scnVector4: SCNVector4(cut.axis.x, cut.axis.y, cut.axis.z, cut.at)), forKey: "cutPlane")
    }

    /// The inside of a cut part, seen through the opening: the part's own colour in shade, flat,
    /// as the far wall of a hollow thing looks (no hatching: stripes on a curved wall read as
    /// contour lines, not as a cut).
    static func insideMaterial(cut: FigureCut, mat: String) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.cullMode = .front
        m.diffuse.contents = FigureMaterials.shade(mat)
        m.shaderModifiers = [
            .geometry: worldVarying + "\n#pragma body\nout.figureWorld = (scn_node.modelTransform * _geometry.position).xyz;",
            .fragment: """
                #pragma arguments
                float4 cutPlane;
                #pragma body
                if (dot(in.figureWorld, cutPlane.xyz) > cutPlane.w) discard_fragment();
                """,
        ]
        m.setValue(NSValue(scnVector4: SCNVector4(cut.axis.x, cut.axis.y, cut.axis.z, cut.at)), forKey: "cutPlane")
        return m
    }

    // MARK: light, ground, camera

    private func buildLights() {
        scene.lightingEnvironment.contents = FigureMaterials.environment
        scene.lightingEnvironment.intensity = 2.2
        let key = SCNLight()
        key.type = .directional
        key.intensity = 1300
        key.color = NSColor(red: 1, green: 0.97, blue: 0.92, alpha: 1)
        key.castsShadow = true
        key.shadowMode = .deferred
        key.shadowRadius = 6
        key.shadowSampleCount = 16
        key.shadowMapSize = CGSize(width: 2048, height: 2048)
        key.shadowColor = NSColor(white: 0, alpha: 0.55)
        key.orthographicScale = radius * 1.3
        key.automaticallyAdjustsShadowProjection = true
        let keyNode = SCNNode()
        keyNode.light = key
        keyNode.simdPosition = SIMD3<Float>(centre) + SIMD3<Float>(-0.5, 1, 0.65) * Float(radius * 3)
        keyNode.look(at: SCNVector3(centre.x, centre.y, centre.z))
        scene.rootNode.addChildNode(keyNode)

        let rim = SCNLight()
        rim.type = .directional
        rim.intensity = 1100
        rim.color = NSColor(red: 0.78, green: 0.92, blue: 1, alpha: 1)
        let rimNode = SCNNode()
        rimNode.light = rim
        rimNode.simdPosition = SIMD3<Float>(centre) + SIMD3<Float>(0.7, 0.6, -1) * Float(radius * 3)
        rimNode.look(at: SCNVector3(centre.x, centre.y, centre.z))
        scene.rootNode.addChildNode(rimNode)
    }

    private func buildGround() {
        let lowest = samples.joined().map(\.y).min() ?? (centre.y - radius)
        let plane = SCNPlane(width: radius * 8, height: radius * 8)
        let m = SCNMaterial()
        m.lightingModel = .constant   // the key light's deferred shadow still falls on it
        m.diffuse.contents = FigureMaterials.groundGlow   // fades out to the card's own black
        m.blendMode = .alpha
        m.writesToDepthBuffer = false
        plane.materials = [m]
        let node = SCNNode(geometry: plane)
        node.eulerAngles.x = -.pi / 2
        node.position = SCNVector3(centre.x, lowest - radius * 0.02, centre.z)
        node.castsShadow = false
        scene.rootNode.addChildNode(node)
    }

    private func buildCamera() {
        let camera = SCNCamera()
        camera.fieldOfView = FigureCamera.fieldOfView
        camera.projectionDirection = .vertical
        camera.zNear = max(0.01, radius * 0.05)
        camera.zFar = radius * 40
        camera.wantsHDR = true
        camera.wantsExposureAdaptation = false
        camera.exposureOffset = -0.35
        camera.minimumExposure = -2
        camera.maximumExposure = 2
        camera.screenSpaceAmbientOcclusionIntensity = 0.9
        camera.screenSpaceAmbientOcclusionRadius = radius * 0.08
        camera.screenSpaceAmbientOcclusionNormalThreshold = 0.3
        camera.screenSpaceAmbientOcclusionDepthThreshold = radius * 0.1
        camera.bloomIntensity = 0.35
        camera.bloomThreshold = 0.9
        camera.contrast = 0.08
        camera.saturation = 1.04
        cameraNode.camera = camera
        idleNode.simdPosition = SIMD3<Float>(centre)
        scene.rootNode.addChildNode(idleNode)
        idleNode.addChildNode(turnNode)
        turnNode.addChildNode(tiltNode)
        tiltNode.addChildNode(dollyNode)
        dollyNode.addChildNode(cameraNode)
        place(view, animated: false)
        fitTightly()
    }

    /// The bounding sphere frames loosely (a long thing fills little of it): at each of 48 angles
    /// of the idle turn, how far the camera may come in for the samples to fill the stage between
    /// the label margins. At its own view the figure fills the card; turning, the camera eases out
    /// just enough that it never runs into the labels or off the card. It never comes in further
    /// than 40% of the widest angle's distance (a long thing the model views nearly end-on, as the
    /// live jet engines were, needs about that), so the zoom stays a slow dolly.
    private func fitTightly() {
        let size = CGSize(width: 360 * fullAspect, height: 360)
        let target = CGSize(width: size.width * (1 - 2 * margin), height: size.height * 0.84)
        let asked = view
        fitsTurn = asked.turn
        fits = [Double](repeating: 1, count: fits.count)
        place(FigureView(turn: asked.turn, tilt: asked.tilt, zoom: 1), animated: false)
        // How much of the room the samples take at idle angle k with the camera at distance scale f
        // (measured about the centre, so an off-centre model still fits on both sides).
        func taken(_ k: Int, _ f: Double) -> Double {
            idleNode.eulerAngles.y = CGFloat(Double(k) / Double(fits.count) * 2 * .pi)
            dollyNode.position = SCNVector3(0, 0, baseDistance * (f - 1))
            let project = projector(viewSize: size, live: false)
            var box = CGRect.null
            for s in samples.joined() {
                let p = project(s)
                box = box.union(CGRect(x: p.x, y: p.y, width: 0, height: 0))
            }
            let w = 2 * max(size.width / 2 - box.minX, box.maxX - size.width / 2)
            let h = 2 * max(size.height / 2 - box.minY, box.maxY - size.height / 2)
            return max(w / target.width, h / target.height)
        }
        var needed: [Double] = []
        for k in 0..<fits.count {
            // First guess as if the view were flat; then, close up, perspective swells the near end,
            // so check at that distance and back off until it fits.
            var f = min(1, taken(k, 1))
            for _ in 0..<6 {
                let t = taken(k, f)
                if t <= 1.001 { break }
                f = min(1, f * t * 1.02)
            }
            needed.append(f)
        }
        idleNode.eulerAngles.y = 0
        dollyNode.position = SCNVector3(0, 0, 0)
        // Each angle takes the most its neighbours need, so the line between samples stays clear.
        let n = needed.count
        let envelope = (0..<n).map { max(needed[$0], needed[($0 + 1) % n], needed[($0 + n - 1) % n]) }
        let widest = envelope.max() ?? 1
        fits = envelope.map { min(1, max($0, 0.4 * widest, 0.2)) }
        place(asked, animated: false)
    }

    /// The fit at an idle-turn angle (radians), between the 48 samples.
    func fit(atIdle angle: Double) -> Double {
        let n = Double(fits.count)
        var x = angle / (2 * .pi) * n
        x = x - (x / n).rounded(.down) * n
        let i = Int(x) % fits.count, f = x - x.rounded(.down)
        return fits[i] * (1 - f) + fits[(i + 1) % fits.count] * f
    }

    private var baseDistance: Double { FigureCamera.distanceFor(radius: radius, aspect: aspect) }

    /// Turn, tilt and zoom to a view: at once, or with a 0.35 s tween.
    func place(_ v: FigureView, animated: Bool) {
        view = v
        SCNTransaction.begin()
        SCNTransaction.animationDuration = animated ? FigureTimeline.tween : 0
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        turnNode.eulerAngles.y = CGFloat(v.turn * .pi / 180)
        tiltNode.eulerAngles.x = CGFloat(-v.tilt * .pi / 180)
        cameraNode.position = SCNVector3(0, 0, baseDistance * fits[0] / v.zoom)
        SCNTransaction.commit()
    }

    // MARK: per frame

    /// The reveal and the idle turn at `t` seconds after the reveal began. Returns whether
    /// anything still grows (the idle turn aside).
    @discardableResult
    func apply(at t: Double, reduceMotion: Bool = false) -> Bool {
        for (k, nodes) in growNodes.enumerated() {
            let s = reduceMotion ? (t >= timeline.cues[k] ? 1 : 0.001) : max(0.001, timeline.scale(part: k, at: t))
            for n in nodes { n.scale = SCNVector3(s, s, s) }
        }
        // The user's pose (drag, zoom, reset) and the idle clock, paused while they handle it.
        let frame = handling.frame(at: t, settled: timeline.settled)
        if frame.version != appliedHandling {
            appliedHandling = frame.version
            place(frame.pose, animated: frame.animate)
            if frame.refit { fitTightly() }
        }
        // Spinning parts start once the whole figure is built; never with Reduce Motion.
        let spinTime = reduceMotion ? 0 : max(0, t - timeline.settled)
        for s in spinners {
            let angle = Float(s.rpm * 6 * spinTime * .pi / 180)
            let turn = simd_float4x4(simd_quatf(angle: angle, axis: simd_normalize(s.axis)))
            var to = matrix_identity_float4x4, back = matrix_identity_float4x4
            to.columns.3 = SIMD4(s.center, 1)
            back.columns.3 = SIMD4(-s.center, 1)
            s.node.simdTransform = to * turn * back
        }
        let idle = FigureTimeline.idleTurn(after: frame.turning, reduceMotion: reduceMotion) * .pi / 180
        idleNode.eulerAngles.y = CGFloat(idle)
        // The fits were measured around fitsTurn; the camera is now (view.turn - fitsTurn) further round.
        let around = idle + (view.turn - fitsTurn) * .pi / 180
        dollyNode.position = SCNVector3(0, 0, baseDistance * (fit(atIdle: around) - fits[0]) / view.zoom)
        return t < timeline.settled
    }

    /// Figure space to a view of `size` points (top-left origin, y down) with depth (smaller is
    /// nearer). `live`: read the camera as it is on screen, mid-tween included.
    func projector(viewSize size: CGSize, live: Bool) -> (SIMD3<Double>) -> SIMD3<Double> {
        let cam = live ? cameraNode.presentation : cameraNode
        let pv = simd_float4x4(cameraNode.camera!.projectionTransform(withViewportSize: size)) * cam.simdWorldTransform.inverse
        let w = Double(size.width), h = Double(size.height)
        return { p in
            let c = pv * SIMD4<Float>(Float(p.x), Float(p.y), Float(p.z), 1)
            let n = SIMD3<Double>(Double(c.x / c.w), Double(c.y / c.w), Double(c.z / c.w))
            return SIMD3((n.x + 1) / 2 * w, (1 - n.y) / 2 * h, n.z)
        }
    }

    /// How much of part k is showing (for labels: a part not yet grown has none).
    func shown(part k: Int) -> Bool { (growNodes[k].first?.scale.x ?? 0) > 0.5 }

    /// Part k's reveal scale this frame (every copy shares it), for a renderer that mirrors this scene.
    func growScale(part k: Int) -> Float { Float(growNodes[k].first?.scale.x ?? 0.001) }

    /// The camera in figure space; `live`: as on screen, mid-tween included.
    func cameraTransform(live: Bool) -> simd_float4x4 {
        (live ? cameraNode.presentation : cameraNode).simdWorldTransform
    }

    /// Where the labels point and the model's box, through `project` (figure space → view points,
    /// y down, with depth). A label points at the middle of what shows of its part
    /// (`FigureAnchors`); a part hidden from this side falls back to its sample nearest the
    /// camera. `time` (seconds): reuse the visibility found within the last 0.12 s, the live card's
    /// per-frame call; nil always looks again.
    func labelAnchors(_ project: (SIMD3<Double>) -> SIMD3<Double>, viewSize: CGSize,
                      time: TimeInterval? = nil) -> (anchors: [CGPoint?], model: CGRect) {
        var box = CGRect.null
        var nearestByPart: [String: CGPoint] = [:]
        var shownParts: [String: Int] = [:]
        for (k, part) in figure.parts.enumerated() where shown(part: k) {
            shownParts[part.name] = k
            var nearest: SIMD3<Double>?
            for s in samples[k] {
                let p = project(s)
                box = box.union(CGRect(x: p.x, y: p.y, width: 0, height: 0))
                if nearest == nil || p.z < nearest!.z { nearest = p }
            }
            if let n = nearest { nearestByPart[part.name] = CGPoint(x: n.x, y: n.y) }
        }
        let wanted = Array(Set(figure.labels.compactMap { shownParts[$0.part] })).sorted()
        var points: [Int: SIMD3<Double>] = [:]
        if let c = visibleCache, let time, c.wanted == wanted, time - c.stamp >= 0, time - c.stamp < 0.12 {
            points = c.points
        } else if !wanted.isEmpty {
            points = FigureAnchors.visiblePoints(of: wanted, surfaces: surfaces,
                                                 viewSize: (Double(viewSize.width), Double(viewSize.height)), project: project)
            visibleCache = (time ?? 0, wanted, points)
        }
        let anchors: [CGPoint?] = figure.labels.map { label in
            if let k = shownParts[label.part], let p = points[k] {
                let q = project(p)
                return CGPoint(x: q.x, y: q.y)
            }
            return nearestByPart[label.part]
        }
        return (anchors, box.isNull ? .zero : box.insetBy(dx: -6, dy: -6))
    }
}

/// Materials by name: physically based, roughness and metalness presets; `paint:` tints a
/// gloss with a clear coat; `glow:` is emissive. Colours are Benji's own picks of what real
/// things of that name look like.
enum FigureMaterials {
    static let tones: [String: (Double, Double, Double)] = [
        "red": (0.78, 0.13, 0.11), "orange": (0.93, 0.45, 0.10), "yellow": (0.96, 0.78, 0.18), "green": (0.22, 0.55, 0.26),
        "blue": (0.16, 0.36, 0.72), "navy": (0.10, 0.15, 0.36), "sky": (0.47, 0.71, 0.90), "teal": (0.10, 0.55, 0.55),
        "purple": (0.45, 0.25, 0.62), "pink": (0.93, 0.55, 0.66), "white": (0.92, 0.92, 0.90), "grey": (0.52, 0.53, 0.54),
        "gray": (0.52, 0.53, 0.54), "black": (0.06, 0.06, 0.07), "brown": (0.42, 0.26, 0.15), "cream": (0.93, 0.88, 0.76),
    ]

    /// base colour, metalness, roughness
    static let presets: [String: ((Double, Double, Double), Double, Double)] = [
        "steel": ((0.62, 0.63, 0.65), 1, 0.36), "aluminium": ((0.84, 0.85, 0.87), 1, 0.30),
        "chrome": ((0.92, 0.93, 0.94), 1, 0.07), "brass": ((0.84, 0.66, 0.34), 1, 0.30),
        "copper": ((0.86, 0.50, 0.34), 1, 0.30), "iron": ((0.40, 0.40, 0.41), 1, 0.62),
        "black": ((0.05, 0.05, 0.055), 0, 0.42), "rubber": ((0.07, 0.07, 0.07), 0, 0.88),
        "glass": ((0.24, 0.32, 0.38), 0, 0.02), "wood": ((0.58, 0.38, 0.21), 0, 0.72),
        "ceramic": ((0.93, 0.92, 0.89), 0, 0.22), "paper": ((0.95, 0.94, 0.90), 0, 0.92),
        "plastic": ((0.86, 0.86, 0.84), 0, 0.40), "matte": ((0.76, 0.77, 0.76), 0, 0.82),
    ]

    static func colour(_ name: String) -> NSColor {
        if name.hasPrefix("#"), let v = UInt32(name.dropFirst(), radix: 16) {
            return NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                           blue: CGFloat(v & 0xff) / 255, alpha: 1)
        }
        let t = tones[name] ?? (0.7, 0.7, 0.7)
        return NSColor(srgbRed: t.0, green: t.1, blue: t.2, alpha: 1)
    }

    /// The colour a material shows in shade: the inside wall of a cut part.
    static func shade(_ mat: String) -> NSColor {
        let base: NSColor
        if mat.hasPrefix("paint:") { base = colour(String(mat.dropFirst(6))) }
        else if mat.hasPrefix("glow:") { base = colour(String(mat.dropFirst(5))) }
        else { let p = (presets[mat] ?? presets["matte"]!).0; base = NSColor(srgbRed: p.0, green: p.1, blue: p.2, alpha: 1) }
        let c = base.usingColorSpace(.sRGB) ?? base
        return NSColor(srgbRed: c.redComponent * 0.42, green: c.greenComponent * 0.38, blue: c.blueComponent * 0.38, alpha: 1)
    }

    static func material(_ mat: String) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        if mat.hasPrefix("paint:") {
            // Car-paint style: a softer base under a full, near-mirror clear coat.
            m.diffuse.contents = colour(String(mat.dropFirst(6)))
            m.metalness.contents = 0.0
            m.roughness.contents = 0.45
            m.clearCoat.contents = 1.0
            m.clearCoatRoughness.contents = 0.03
        } else if mat.hasPrefix("glow:") {
            let c = colour(String(mat.dropFirst(5)))
            m.diffuse.contents = c
            m.emission.contents = c
            m.emission.intensity = 1.6
            m.metalness.contents = 0.0
            m.roughness.contents = 0.5
        } else {
            let p = presets[mat] ?? presets["matte"]!
            m.diffuse.contents = NSColor(srgbRed: p.0.0, green: p.0.1, blue: p.0.2, alpha: 1)
            m.metalness.contents = p.1
            m.roughness.contents = p.2
            if mat == "glass" {
                // Tinted and mostly reflective, as glass looks from outside: what shows is the
                // studio in it, with the inside faintly through.
                m.transparency = 0.6
                m.transparencyMode = .dualLayer
                m.blendMode = .alpha
            }
        }
        return m
    }

    /// A dark photo studio for reflections (equirectangular, drawn once): a large soft box
    /// overhead, long strip lights either side at shoulder height, a faint horizon and a black
    /// floor. Bright shapes on a dark surround are what make paint, glass and metal read as real:
    /// an evenly lit grey room reflects as flat plastic.
    static let environment: NSImage = {
        let w = 1024, h = 512
        let img = NSImage(size: NSSize(width: w, height: h))
        img.lockFocus()
        // y up: 0 is straight down, h straight up; the horizon at h/2.
        func row(_ elevation: Double) -> CGFloat { CGFloat((elevation + 90) / 180 * Double(h)) }
        func col(_ longitude: Double) -> CGFloat { CGFloat(longitude / 360 * Double(w)) }
        let surround = NSGradient(colors: [NSColor(white: 0.05, alpha: 1), NSColor(white: 0.09, alpha: 1),
                                           NSColor(white: 0.36, alpha: 1), NSColor(white: 0.24, alpha: 1),
                                           NSColor(white: 0.32, alpha: 1)],
                                  atLocations: [0, 0.45, 0.5, 0.62, 1], colorSpace: .sRGB)!
        surround.draw(in: NSRect(x: 0, y: 0, width: w, height: h), angle: 90)
        func box(_ lon: ClosedRange<Double>, _ el: ClosedRange<Double>, _ c: NSColor, round: CGFloat) {
            c.setFill()
            let r = NSRect(x: col(lon.lowerBound), y: row(el.lowerBound),
                           width: col(lon.upperBound) - col(lon.lowerBound), height: row(el.upperBound) - row(el.lowerBound))
            NSBezierPath(roundedRect: r, xRadius: round, yRadius: round).fill()
        }
        let warm = NSColor(red: 1, green: 0.97, blue: 0.92, alpha: 1)
        let cool = NSColor(red: 0.82, green: 0.92, blue: 1, alpha: 1)
        // The overhead soft box: the top of the sky, with a brighter core.
        box(0...360, 62...90, NSColor(white: 0.55, alpha: 1), round: 0)
        box(20...160, 68...90, warm, round: 12)
        box(200...340, 70...90, NSColor(white: 0.8, alpha: 1), round: 12)
        // Strip lights: long and thin, so they draw clean lines along a body or a can.
        box(30...150, 14...22, warm, round: 6)
        box(210...330, 18...24, cool.withAlphaComponent(0.85), round: 6)
        // Two tall strips for an edge light on whatever faces away.
        box(168...176, 4...52, NSColor(white: 0.9, alpha: 1), round: 4)
        box(352...358, 4...46, cool.withAlphaComponent(0.7), round: 3)
        img.unlockFocus()
        return img
    }()

    /// The ground: a soft pool of light under the figure, fading to nothing, so the shadow has
    /// something to fall on inside the black card.
    static let groundGlow: NSImage = {
        let s = 256
        let img = NSImage(size: NSSize(width: s, height: s))
        img.lockFocus()
        // Fades to clear, not to black: the camera's grading lifts black a little, and the plane's
        // far edge showed as a horizon against the card.
        let g = NSGradient(colors: [NSColor(white: 0.24, alpha: 1), NSColor(white: 0.11, alpha: 1),
                                    NSColor(white: 0, alpha: 0)],
                           atLocations: [0, 0.16, 0.31], colorSpace: .sRGB)!
        g.draw(in: NSRect(x: 0, y: 0, width: s, height: s), relativeCenterPosition: .zero)
        img.unlockFocus()
        return img
    }()
}

/// The user's hand on the figure, written on the main thread (mouse and trackpad) and read once a
/// frame on SceneKit's render thread, under a lock.
final class FigureHandling: @unchecked Sendable {
    struct Frame { var pose: FigureView; var turning: Double; var version: Int; var animate: Bool; var refit: Bool }

    private let lock = NSLock()
    private var startTime: Double?
    private var orbit: FigureOrbit
    private var clock = FigureIdleClock()
    private var version = 0
    private var animateNext = false
    private var refitNext = false
    private var tiltAtDragStart: Double?

    init(base: FigureView) { orbit = FigureOrbit(base: base) }

    /// The renderer's time of the figure's first frame (its own clock starts there).
    var start: Double? {
        get { lock.lock(); defer { lock.unlock() }; return startTime }
        set { lock.lock(); startTime = newValue; lock.unlock() }
    }

    var isMoved: Bool { lock.lock(); defer { lock.unlock() }; return orbit.isMoved }
    var pose: FigureView { lock.lock(); defer { lock.unlock() }; return orbit.view }

    /// Change the pose at time t (seconds on the figure's own clock); the idle turn pauses.
    func handle(at t: Double, _ change: (inout FigureOrbit) -> Void) {
        lock.lock(); defer { lock.unlock() }
        if tiltAtDragStart == nil { tiltAtDragStart = orbit.view.tilt }
        change(&orbit)
        clock.touch(at: t)
        version += 1
    }

    /// A drag ended: if the tilt changed, the framing is measured again for the new height.
    func endDrag() {
        lock.lock(); defer { lock.unlock() }
        if let start = tiltAtDragStart, start != orbit.view.tilt { refitNext = true; version += 1 }
        tiltAtDragStart = nil
    }

    /// Back to the model's view, with the usual 0.35 s tween.
    func reset(at t: Double) {
        lock.lock(); defer { lock.unlock() }
        let tiltChanged = orbit.view.tilt != orbit.base.tilt
        orbit.reset()
        clock.touch(at: t)
        animateNext = true
        refitNext = refitNext || tiltChanged
        version += 1
    }

    func frame(at t: Double, settled: Double) -> Frame {
        lock.lock(); defer { lock.unlock() }
        let f = Frame(pose: orbit.view, turning: clock.turning(at: t, from: settled), version: version,
                      animate: animateNext, refit: refitNext)
        animateNext = false
        refitNext = false
        return f
    }

    func isPaused(at t: Double) -> Bool { lock.lock(); defer { lock.unlock() }; return clock.isPaused(at: t) }
}
