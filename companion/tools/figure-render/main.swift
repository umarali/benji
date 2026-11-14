// Renders figure blocks offscreen (D-108): each reply in tools/figure-render/replies is parsed with
// the app's own parser, its meshes built, and the app's own FigureScene drawn with SCNRenderer
// (no window, no permission) into Benji's card at 1200×800 px, then placed over the synthetic
// screen of tools/overlay-render. Also measures build time, time to the first part, frame time
// while turning and the scene's memory. Run with tools/figure-render/render.sh <output dir>.
import AppKit
import BenjiCore
import Metal
import SceneKit
import SwiftUI

let here = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let out = URL(fileURLWithPath: CommandLine.arguments[1])
let repliesDir = URL(fileURLWithPath: CommandLine.arguments[2])
let scale: CGFloat = 2
let device = MTLCreateSystemDefaultDevice()!

func footprint() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
}

func ms(_ since: DispatchTime) -> Double { Double(DispatchTime.now().uptimeNanoseconds - since.uptimeNanoseconds) / 1e6 }

/// The card at 2×: black card, title, the scene's snapshot in the stage, the labels.
/// `reality`: draw the stage with RealityKit (`FigureRealityScene`) instead of SceneKit.
@MainActor
func renderCard(_ fs: FigureScene, renderer: SCNRenderer, at t: Double, view: FigureView? = nil, reality: AnyObject? = nil) -> NSImage {
    if let view { fs.place(view, animated: false) }
    fs.apply(at: t)
    let card = CGRect(origin: .zero, size: FigureCardDrawing.size)
    let stage = FigureCardDrawing.stageRect(in: card)
    let pixels = CGSize(width: stage.width * scale, height: stage.height * scale)
    let shot: NSImage
    if #available(macOS 15.0, *), let rs = reality as? FigureRealityScene {
        shot = realityShot(rs, pixels: pixels)
    } else {
        shot = renderer.snapshot(atTime: 0, with: pixels, antialiasingMode: .multisampling4X)
    }
    let project = fs.projector(viewSize: stage.size, live: false)
    let (anchors, model) = fs.labelAnchors(project, viewSize: stage.size)
    let placed = FigureCardDrawing.place(fs, anchors: anchors, model: model, stage: stage)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(card.width * scale), pixelsHigh: Int(card.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = card.size
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx.cgContext, flipped: true)
    ctx.cgContext.translateBy(x: 0, y: card.height)
    ctx.cgContext.scaleBy(x: 1, y: -1)
    FigureCardDrawing.drawCard(title: fs.figure.title, in: card)
    // The stage: clip to the card's lower corners, draw the snapshot upright.
    NSBezierPath(roundedRect: card, xRadius: FigureCardDrawing.radius, yRadius: FigureCardDrawing.radius).addClip()
    shot.draw(in: stage, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    FigureCardDrawing.drawLabels(placed, origin: stage.origin)
    if fs.handling.isMoved { FigureCardDrawing.drawReset(in: FigureCardDrawing.resetRect(in: card)) }
    NSGraphicsContext.restoreGraphicsState()
    let img = NSImage(size: card.size)
    img.addRepresentation(rep)
    return img
}

/// One RealityKit frame of the stage, read back from the GPU.
@available(macOS 15.0, *)
@MainActor
func realityShot(_ rs: FigureRealityScene, pixels: CGSize) -> NSImage {
    rs.sync(live: false)
    let w = Int(pixels.width), h = Int(pixels.height)
    let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: w, height: h, mipmapped: false)
    desc.usage = [.renderTarget, .shaderRead]
    desc.storageMode = .shared
    let tex = device.makeTexture(descriptor: desc)!
    // Twice: the first frame after a change can still be loading what it draws.
    for _ in 0..<2 {
        let done = DoneFlag()
        try! rs.render(into: tex, deltaTime: 1.0 / 60) { done.set() }
        while !done.isSet { RunLoop.current.run(until: Date().addingTimeInterval(0.002)) }
    }
    var bytes = [UInt8](repeating: 0, count: w * h * 4)
    tex.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                     space: CGColorSpace(name: CGColorSpace.sRGB)!,
                     bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                     provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
    return NSImage(cgImage: cg, size: NSSize(width: w, height: h))
}

final class DoneFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// Two images side by side with a caption over each (SceneKit left, RealityKit right).
@MainActor
func pair(_ left: NSImage, _ right: NSImage, captions: (String, String)) -> NSImage {
    let cell = left.size, pad: CGFloat = 12, caption: CGFloat = 26
    let size = CGSize(width: cell.width * 2 + pad * 3, height: cell.height + caption + pad * 2)
    let img = NSImage(size: size)
    img.lockFocusFlipped(true)
    NSColor(white: 0.93, alpha: 1).setFill()
    NSRect(origin: .zero, size: size).fill()
    for (i, (im, text)) in [(left, captions.0), (right, captions.1)].enumerated() {
        let x = pad + CGFloat(i) * (cell.width + pad)
        (text as NSString).draw(at: CGPoint(x: x, y: pad), withAttributes: [.font: NSFont.systemFont(ofSize: 15, weight: .semibold)])
        im.draw(in: CGRect(x: x, y: pad + caption, width: cell.width, height: cell.height), from: .zero, operation: .sourceOver,
                fraction: 1, respectFlipped: true, hints: nil)
    }
    img.unlockFocus()
    return img
}

func writePNG(_ image: NSImage, _ name: String) {
    let rep = image.representations.first as? NSBitmapImageRep
        ?? NSBitmapImageRep(data: image.tiffRepresentation!)!
    try! rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
}

/// The card over the synthetic screen, centred in the visible area below Benji's panel.
@MainActor
func onDesktop(_ card: NSImage) -> NSImage {
    let r = ImageRenderer(content: Desktop(dark: false, showPanel: true))
    r.scale = scale
    let desk = r.cgImage!
    let size = CGSize(width: screen.width, height: screen.height)
    let img = NSImage(size: size)
    img.lockFocusFlipped(true)
    NSGraphicsContext.current!.cgContext.saveGState()
    NSGraphicsContext.current!.cgContext.translateBy(x: 0, y: size.height)
    NSGraphicsContext.current!.cgContext.scaleBy(x: 1, y: -1)
    NSGraphicsContext.current!.cgContext.draw(desk, in: CGRect(origin: .zero, size: size))
    NSGraphicsContext.current!.cgContext.restoreGState()
    let frame = FigureCardPlacement.frame(cardSize: FigureCardDrawing.size, visible: CGRect(x: 0, y: menuBar, width: screen.width, height: visible.height),
                                          avoid: [CGRect(x: panel.minX, y: 0, width: panel.width, height: panel.height + 32)], flipped: true)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(white: 0, alpha: 0.45)
    shadow.shadowBlurRadius = 30
    shadow.shadowOffset = NSSize(width: 0, height: 12)
    shadow.set()
    card.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    img.unlockFocus()
    return img
}

@MainActor
func sheet(_ images: [(String, NSImage)], columns: Int, cell: CGSize) -> NSImage {
    let rows = (images.count + columns - 1) / columns
    let pad: CGFloat = 16, caption: CGFloat = 22
    let size = CGSize(width: CGFloat(columns) * (cell.width + pad) + pad, height: CGFloat(rows) * (cell.height + caption + pad) + pad)
    let img = NSImage(size: size)
    img.lockFocusFlipped(true)
    NSColor(white: 0.93, alpha: 1).setFill()
    NSRect(origin: .zero, size: size).fill()
    for (i, (name, im)) in images.enumerated() {
        let x = pad + CGFloat(i % columns) * (cell.width + pad), y = pad + CGFloat(i / columns) * (cell.height + caption + pad)
        (name as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium)])
        im.draw(in: CGRect(x: x, y: y + caption, width: cell.width, height: cell.height), from: .zero, operation: .sourceOver,
                fraction: 1, respectFlipped: true, hints: nil)
    }
    img.unlockFocus()
    return img
}

@MainActor
func renderAll() {
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    var report: [String] = []
    var sheetImages: [(String, NSImage)] = []
    var airlinerScene: (FigureScene, SCNRenderer)?
    var compareImages: [(String, NSImage)] = []
    // The first figure pays for compiling SceneKit's shaders; the last one repeats it warm.
    let asked = Array(CommandLine.arguments.dropFirst(3))
    for name in asked.isEmpty ? ["airliner", "house", "jet-engine", "prompt-example", "airliner (warm)"] : asked {
        let file = name.components(separatedBy: " ")[0]
        let warmRepeat = file != name
        let reply = try! String(contentsOf: repliesDir.appendingPathComponent(file + ".txt"), encoding: .utf8)
        let memBefore = footprint()
        let t0 = DispatchTime.now()
        guard let figure = FigureGrammar.parse(reply).figure else {
            report.append("\(name): no figure block that parses")
            continue
        }
        let tParse = ms(t0)
        let t1 = DispatchTime.now()
        let meshes = FigureScene.meshes(for: figure, cache: FigureMeshCache())
        let tMesh = ms(t1)
        // FIGURE_RENDER_RAW=1: as the model placed it, loose parts left where they are.
        let tc = DispatchTime.now()
        let prepared = FigureScene.prepare(figure, meshes: meshes, closeGaps: ProcessInfo.processInfo.environment["FIGURE_RENDER_RAW"] != "1")
        let tClose = ms(tc)
        let t2 = DispatchTime.now()
        let fs = FigureScene(prepared: prepared,
                             aspect: Double(FigureCardDrawing.size.width / (FigureCardDrawing.size.height - FigureCardDrawing.header)))
        for l in fs.joined {
            report.append(String(format: "%@: joined %@ (gap %.0f%% of the figure's radius)", name, l.parts.joined(separator: ", "), l.share * 100))
        }
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = fs.scene
        renderer.pointOfView = fs.cameraNode
        let tScene = ms(t2)
        let t3 = DispatchTime.now()
        fs.apply(at: 0.2)    // part 1 growing
        _ = renderer.snapshot(atTime: 0, with: CGSize(width: 1200, height: 720), antialiasingMode: .multisampling4X)
        let tFirst = ms(t3)
        let full = renderCard(fs, renderer: renderer, at: fs.timeline.settled + 0.01)
        // FIGURE_RENDER_COMPARE=1: the same card drawn by RealityKit, beside SceneKit's.
        if !warmRepeat, ProcessInfo.processInfo.environment["FIGURE_RENDER_COMPARE"] == "1" {
            if #available(macOS 15.0, *) {
                let tr = DispatchTime.now()
                let rs = try! FigureRealityScene(source: fs, prepared: prepared)
                let tBuild = ms(tr)
                let real = renderCard(fs, renderer: renderer, at: fs.timeline.settled + 0.01, reality: rs)
                writePNG(real, "\(name)-realitykit.png")
                compareImages.append((name, pair(full, real, captions: ("\(name): SceneKit (today)", "\(name): RealityKit"))))
                report.append(String(format: "%@: RealityKit scene built in %.1f ms", name, tBuild))
                for (n, v) in [("side", FigureView(turn: 90, tilt: 6, zoom: 1)), ("above", FigureView(turn: 35, tilt: 40, zoom: 1))] {
                    let a = renderCard(fs, renderer: renderer, at: fs.timeline.settled + 0.01, view: v)
                    let b = renderCard(fs, renderer: renderer, at: fs.timeline.settled + 0.01, view: v, reality: rs)
                    compareImages.append(("\(name), \(n)", pair(a, b, captions: ("SceneKit, \(n)", "RealityKit, \(n)"))))
                }
                fs.place(fs.figure.view, animated: false)
            }
        }
        if !warmRepeat {
            writePNG(full, "\(name).png")
            sheetImages.append((name, full))
            // FIGURE_RENDER_TURNS=1: also a quarter and a half of the idle turn later, to see the
            // framing follow the turn.
            if ProcessInfo.processInfo.environment["FIGURE_RENDER_TURNS"] == "1" {
                for quarter in [1, 2] {
                    let t = fs.timeline.settled + Double(quarter) / 4 * FigureTimeline.idleRevolution
                    let im = renderCard(fs, renderer: renderer, at: t)
                    writePNG(im, "\(name)-turn\(quarter * 90).png")
                    sheetImages.append(("\(name), turned \(quarter * 90)°", im))
                }
            }
        }
        let memAfter = footprint()
        let unique = Dictionary(grouping: figure.parts, by: \.recipe.canonical).compactMap { meshes[$0.value[0].name] }
        let vertexBytes = unique.reduce(0) { $0 + $1.bytes }
        let drawn = figure.parts.reduce(0) { $0 + (meshes[$1.name]?.vertexCount ?? 0) * $1.instances }
        report.append(String(format: "%@: %d parts, %d copies drawn, %d vertices drawn (budget %d), %d unique meshes, %.0f KB mesh data | parse %.2f ms, meshes %.1f ms, gaps %.1f ms (off main), scene %.1f ms (main), first frame %.1f ms, to first part %.1f ms | footprint +%.1f MB",
                             name, figure.parts.count, figure.parts.reduce(0) { $0 + $1.instances }, drawn, figure.vertices, unique.count,
                             Double(vertexBytes) / 1024, tParse, tMesh, tClose, tScene, tFirst, tParse + tMesh + tClose + tScene + tFirst, memAfter - memBefore))
        if name == "airliner" {
            airlinerScene = (fs, renderer)
            writePNG(onDesktop(full), "airliner-on-desktop.png")
        }
    }
    // The airliner from three more views, and one frame mid-reveal.
    if let (fs, renderer) = airlinerScene {
        let views: [(String, FigureView)] = [("airliner-side", FigureView(turn: 90, tilt: 6, zoom: 1)),
                                             ("airliner-top", FigureView(turn: 20, tilt: 72, zoom: 1)),
                                             ("airliner-rear", FigureView(turn: 205, tilt: 18, zoom: 1.1))]
        for (n, v) in views {
            let im = renderCard(fs, renderer: renderer, at: fs.timeline.settled + 0.01, view: v)
            writePNG(im, n + ".png")
            sheetImages.append((n, im))
        }
        fs.place(fs.figure.view, animated: false)
        let mid = fs.timeline.cues[4] + 0.12
        let im = renderCard(fs, renderer: renderer, at: mid)
        writePNG(im, "airliner-mid-reveal.png")
        sheetImages.append((String(format: "airliner-mid-reveal (t = %.2f s)", mid), im))

        // Frame time while turning: 120 frames at the card's stage size, 2×, each waited on.
        let size = CGSize(width: 1200, height: 720)
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Int(size.width), height: Int(size.height), mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .private
        let target = device.makeTexture(descriptor: desc)!
        let queue = device.makeCommandQueue()!
        var times: [Double] = []
        for i in 0..<130 {
            fs.apply(at: fs.timeline.settled + Double(i) / 60 * 30)   // 30× the idle speed, to really turn
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            let cb = queue.makeCommandBuffer()!
            let t = DispatchTime.now()
            renderer.render(atTime: Double(i) / 60, viewport: CGRect(origin: .zero, size: size), commandBuffer: cb, passDescriptor: pass)
            cb.commit()
            cb.waitUntilCompleted()
            if i >= 10 { times.append(ms(t)) }
        }
        times.sort()
        let gpuNote = "CPU encode + GPU, waited per frame"
        report.append(String(format: "frame while turning (airliner, 1200×720 px, %@): median %.2f ms, p95 %.2f ms, max %.2f ms over %d frames",
                             gpuNote, times[times.count / 2], times[Int(Double(times.count) * 0.95)], times.last!, times.count))

        // Turned by hand, as the card's input panel does it: a drag right and down (AppKit y up),
        // let go (the framing is measured again for the new tilt), then a scroll in.
        fs.place(fs.figure.view, animated: false)
        fs.handling.handle(at: 0) { $0.drag(dx: 160, dy: -90) }
        fs.handling.endDrag()
        fs.handling.handle(at: 0) { $0.scroll(dy: 25) }
        let pose = fs.handling.pose
        let dragged = renderCard(fs, renderer: renderer, at: fs.timeline.settled + 0.01)
        writePNG(dragged, "airliner-dragged.png")
        sheetImages.append((String(format: "airliner, dragged by hand (turn %.0f, tilt %.0f, zoom %.2f)", pose.turn, pose.tilt, pose.zoom), dragged))
    }
    writePNG(sheet(sheetImages, columns: 3, cell: CGSize(width: 600, height: 400)), "contact-sheet.png")
    for (i, (name, im)) in compareImages.enumerated() {
        writePNG(im, String(format: "compare-%02d-%@.png", i, name.replacingOccurrences(of: ", ", with: "-")))
    }
    let text = report.joined(separator: "\n") + "\n"
    try! text.write(to: out.appendingPathComponent("measurements.txt"), atomically: true, encoding: .utf8)
    print(text, terminator: "")
}

MainActor.assumeIsolated { renderAll() }
