import AppKit
import BenjiCore
import Metal
import RealityKit

/// The figure drawn by RealityKit instead of SceneKit (macOS 15+). `FigureScene` stays the figure's
/// logic: the reveal, the camera rig and its framing, the user's hand and the labels. This class
/// builds the same parts as RealityKit entities and copies the reveal scales and the camera from it
/// each frame, so the two renderers can be compared on exactly the same picture (the card and
/// `tools/figure-render` both use it).
///
/// What differs from the SceneKit scene: the cut is made on the CPU (triangles clipped at the plane,
/// the inside seen through the opening drawn flat, without SceneKit's hatching); the ink outline is an
/// inverted hull pushed out on the CPU by a width set from the camera's resting distance (SceneKit
/// pushes it in a shader, constant on screen); RealityKit has no screen-space ambient occlusion or
/// bloom here, and adds grounding shadows instead.
@available(macOS 15.0, *)
@MainActor
final class FigureRealityScene {
    let source: FigureScene
    let renderer: RealityRenderer
    let camera = Entity()
    private let root = Entity()
    /// Per part, the entities that scale in (one per copy).
    private var grows: [[Entity]] = []

    init(source: FigureScene, prepared: FigureScene.Prepared) throws {
        self.source = source
        renderer = try RealityRenderer()
        renderer.cameraSettings.colorBackground = .color(CGColor(gray: 0, alpha: 0))
        renderer.cameraSettings.isToneMappingEnabled = true
        renderer.cameraSettings.antialiasing = .multisample4X
        if let env = Self.environment { renderer.lighting.resource = env }
        renderer.lighting.intensityExponent = 0.6

        let radius = Float(source.radius)
        let restDistance = simd_length(source.cameraTransform(live: false).columns.3.xyz - SIMD3<Float>(source.centre))
        buildParts(prepared, outlineWidth: FigureScene.outlineWidth * restDistance)
        buildLights(centre: SIMD3<Float>(source.centre), radius: radius)
        buildGround(prepared, radius: radius)

        camera.components.set(PerspectiveCameraComponent(near: max(0.01, radius * 0.05), far: radius * 40,
                                                          fieldOfViewInDegrees: Float(FigureCamera.fieldOfView),
                                                          fieldOfViewOrientation: .vertical))
        root.addChild(camera)
        renderer.entities.append(root)
        renderer.activeCamera = camera
        sync(live: false)
    }

    // MARK: parts

    private func buildParts(_ p: FigureScene.Prepared, outlineWidth: Float) {
        let placed = FigurePlacement.instances(p.transforms)
        var plain: [String: MeshResource] = [:]   // by recipe (and mirroring), shared by copies
        for part in p.figure.parts {
            guard let mesh = p.meshes[part.name], let list = placed[part.name] else { grows.append([]); continue }
            let cut = p.figure.cut.flatMap { $0.parts.contains(part.name) ? $0 : nil }
            let material = Self.material(part.mat)
            var copies: [Entity] = []
            for inst in list {
                let m = inst.mirrored ? mesh.mirroredX() : mesh
                let t = FigureScene.float4x4(inst.transform)
                let holder = Entity()
                holder.transform = Transform(matrix: t)
                let grow = Entity()
                grow.scale = SIMD3(repeating: 0.001)
                // The cut is fixed in figure space, so a cut part is clipped per copy, in its own space.
                let shown = cut.map { Self.clipped(m, by: $0, transform: t) } ?? m
                let key = part.recipe.canonical + (inst.mirrored ? "|m" : "")
                guard let body = cut == nil ? (plain[key] ?? Self.resource(shown)) : Self.resource(shown) else { continue }
                if cut == nil { plain[key] = body }
                let model = ModelEntity(mesh: body, materials: [material])
                model.components.set(GroundingShadowComponent(castsShadow: true))
                grow.addChild(model)
                // Outline: the inverted hull, its width in this copy's own units.
                let scale = Self.meanScale(t)
                if let hull = Self.resource(Self.inflated(shown, by: outlineWidth / max(scale, 1e-4))) {
                    grow.addChild(ModelEntity(mesh: hull, materials: [Self.ink]))
                }
                if cut != nil, let inside = Self.resource(shown) {
                    grow.addChild(ModelEntity(mesh: inside, materials: [Self.insideMaterial]))
                }
                holder.addChild(grow)
                root.addChild(holder)
                copies.append(grow)
            }
            grows.append(copies)
        }
    }

    static func resource(_ m: FigureMesh) -> MeshResource? {
        guard !m.indices.isEmpty else { return nil }
        var d = MeshDescriptor()
        d.positions = MeshBuffer(m.positions)
        d.normals = MeshBuffer(m.normals)
        d.primitives = .triangles(m.indices)
        return try? MeshResource.generate(from: [d])
    }

    /// Every vertex pushed out along its normal: drawn with front faces culled, its back shows as a
    /// line around the part.
    static func inflated(_ m: FigureMesh, by w: Float) -> FigureMesh {
        var out = m
        out.positions = zip(m.positions, m.normals).map { $0 + $1 * w }
        return out
    }

    static func meanScale(_ t: simd_float4x4) -> Float {
        (simd_length(t.columns.0.xyz) + simd_length(t.columns.1.xyz) + simd_length(t.columns.2.xyz)) / 3
    }

    /// The mesh with everything on the cut-away side removed (dot(world, axis) > at), the plane
    /// brought into the copy's own space; triangles that cross it are split at the plane.
    static func clipped(_ m: FigureMesh, by cut: FigureCut, transform t: simd_float4x4) -> FigureMesh {
        let n = SIMD3<Float>(Float(cut.axis.x), Float(cut.axis.y), Float(cut.axis.z))
        let linear = simd_float3x3(t.columns.0.xyz, t.columns.1.xyz, t.columns.2.xyz)
        let localN = linear.transpose * n
        let localD = Float(cut.at) - simd_dot(n, t.columns.3.xyz)
        var out = m
        out.positions = []; out.normals = []; out.indices = []
        func add(_ p: SIMD3<Float>, _ nor: SIMD3<Float>) -> UInt32 {
            out.positions.append(p); out.normals.append(nor); return UInt32(out.positions.count - 1)
        }
        for k in stride(from: 0, to: m.indices.count - 2, by: 3) {
            let ids = [Int(m.indices[k]), Int(m.indices[k + 1]), Int(m.indices[k + 2])]
            let pts = ids.map { (m.positions[$0], m.normals[$0], simd_dot(localN, m.positions[$0]) - localD) }
            if pts.allSatisfy({ $0.2 <= 0 }) {
                let a = add(pts[0].0, pts[0].1), b = add(pts[1].0, pts[1].1), c = add(pts[2].0, pts[2].1)
                out.indices += [a, b, c]
                continue
            }
            if pts.allSatisfy({ $0.2 > 0 }) { continue }
            // Sutherland–Hodgman against one plane: a triangle becomes a triangle or a quad.
            var poly: [(SIMD3<Float>, SIMD3<Float>)] = []
            for i in 0..<3 {
                let (p, pn, pd) = pts[i], (q, qn, qd) = pts[(i + 1) % 3]
                if pd <= 0 { poly.append((p, pn)) }
                if (pd <= 0) != (qd <= 0) {
                    let s = pd / (pd - qd)
                    poly.append((p + (q - p) * s, simd_normalize(pn + (qn - pn) * s)))
                }
            }
            guard poly.count >= 3 else { continue }
            let first = add(poly[0].0, poly[0].1)
            var prev = add(poly[1].0, poly[1].1)
            for i in 2..<poly.count {
                let cur = add(poly[i].0, poly[i].1)
                out.indices += [first, prev, cur]
                prev = cur
            }
        }
        return out
    }

    // MARK: materials

    /// The same names and values as `FigureMaterials` (SceneKit), as RealityKit materials.
    static func material(_ mat: String) -> PhysicallyBasedMaterial {
        var m = PhysicallyBasedMaterial()
        if mat.hasPrefix("paint:") {
            m.baseColor = .init(tint: FigureMaterials.colour(String(mat.dropFirst(6))))
            m.metallic = 0.0
            m.roughness = 0.32
            m.clearcoat = .init(floatLiteral: 0.7)
            m.clearcoatRoughness = .init(floatLiteral: 0.12)
        } else if mat.hasPrefix("glow:") {
            let c = FigureMaterials.colour(String(mat.dropFirst(5)))
            m.baseColor = .init(tint: c)
            m.emissiveColor = .init(color: c)
            m.emissiveIntensity = 1.6
            m.metallic = 0.0
            m.roughness = 0.5
        } else {
            let p = FigureMaterials.presets[mat] ?? FigureMaterials.presets["matte"]!
            m.baseColor = .init(tint: NSColor(srgbRed: p.0.0, green: p.0.1, blue: p.0.2, alpha: 1))
            m.metallic = .init(floatLiteral: Float(p.1))
            m.roughness = .init(floatLiteral: Float(p.2))
            if mat == "glass" { m.blending = .transparent(opacity: 0.45) }
        }
        return m
    }

    static var ink: UnlitMaterial {
        var m = UnlitMaterial(color: FigureScene.ink)
        m.faceCulling = .front
        return m
    }

    /// The inside of a cut part, seen through the opening (SceneKit's colour, without the hatching).
    static var insideMaterial: UnlitMaterial {
        var m = UnlitMaterial(color: NSColor(red: 0.80, green: 0.36, blue: 0.30, alpha: 1))
        m.faceCulling = .front
        return m
    }

    /// SceneKit's small studio, as an image-based light.
    static let environment: EnvironmentResource? = {
        guard let cg = FigureMaterials.environment.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return try? EnvironmentResource(equirectangular: cg)
    }()

    // MARK: light and ground

    private func buildLights(centre: SIMD3<Float>, radius: Float) {
        func light(_ intensity: Float, _ colour: NSColor, from dir: SIMD3<Float>, shadow: Bool) {
            let e = Entity()
            e.components.set(DirectionalLightComponent(color: colour, intensity: intensity))
            if shadow {
                var s = DirectionalLightComponent.Shadow(maximumDistance: radius * 8, depthBias: 2)
                s.shadowProjection = .automatic(maximumDistance: radius * 8)
                e.components.set(s)
            }
            e.look(at: centre, from: centre + dir * radius * 3, relativeTo: nil)
            root.addChild(e)
        }
        light(4200, NSColor(red: 1, green: 0.97, blue: 0.92, alpha: 1), from: SIMD3(-0.5, 1, 0.65), shadow: true)
        light(3200, NSColor(red: 0.78, green: 0.92, blue: 1, alpha: 1), from: SIMD3(0.7, 0.6, -1), shadow: false)
    }

    private func buildGround(_ p: FigureScene.Prepared, radius: Float) {
        let placed = FigurePlacement.instances(p.transforms)
        var lowest = Float(p.centre.y - p.radius)
        var found = false
        for part in p.figure.parts {
            guard let mesh = p.meshes[part.name] else { continue }
            for inst in placed[part.name] ?? [] {
                let t = FigureScene.float4x4(inst.transform)
                for s in (inst.mirrored ? mesh.mirroredX() : mesh).samples {
                    let y = (t * SIMD4(s, 1)).y
                    lowest = found ? min(lowest, y) : y
                    found = true
                }
            }
        }
        // Unlit, like SceneKit's ground: a pool of light fading to the card's black. The key light's
        // shadow does not fall on an unlit surface, so the parts' grounding shadows darken it instead.
        var m = UnlitMaterial(color: NSColor(white: 0.12, alpha: 1))
        do {
            let tex = try TextureResource(image: Self.groundImage, options: .init(semantic: .color))
            m.color = .init(tint: .white, texture: .init(tex))
        } catch {
            FileHandle.standardError.write("figure ground texture: \(error)\n".data(using: .utf8)!)
        }
        let ground = ModelEntity(mesh: .generatePlane(width: radius * 4, depth: radius * 4), materials: [m])
        ground.position = SIMD3(Float(p.centre.x), lowest - radius * 0.02, Float(p.centre.z))
        root.addChild(ground)
    }

    /// SceneKit's ground glow drawn straight into a bitmap (an `NSImage` drawn lazily has no
    /// backing image to hand to RealityKit).
    static let groundImage: CGImage = {
        let s = 256
        let ctx = CGContext(data: nil, width: s, height: s, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))
        let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                           colors: [CGColor(gray: 0.24, alpha: 1), CGColor(gray: 0.12, alpha: 1), CGColor(gray: 0, alpha: 1)] as CFArray,
                           locations: [0, 0.35, 0.78])!
        let c = CGPoint(x: s / 2, y: s / 2)
        ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: CGFloat(s) / 2, options: [])
        return ctx.makeImage()!
    }()

    // MARK: per frame

    /// Copy this frame's reveal scales and camera from the SceneKit scene.
    func sync(live: Bool) {
        for (k, copies) in grows.enumerated() {
            let s = source.growScale(part: k)
            for e in copies { e.scale = SIMD3(repeating: s) }
        }
        camera.transform = Transform(matrix: source.cameraTransform(live: live))
    }

    /// Draw into `texture` (a render target); `done` runs when the GPU has finished.
    func render(into texture: MTLTexture, deltaTime: TimeInterval, done: (@Sendable () -> Void)? = nil) throws {
        let output = try RealityRenderer.CameraOutput(.singleProjection(colorTexture: texture))
        try renderer.updateAndRender(deltaTime: deltaTime, cameraOutput: output, onComplete: { _ in done?() })
    }
}

private extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> { SIMD3(x, y, z) }
}
