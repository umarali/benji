// Renders the pointer overlay offscreen over a synthetic screen drawn here (never a capture of
// the real screen), at exact moments of the reveal, glide and erase, for every display variant.
// Build and run with tools/overlay-render/render.sh <output dir> [drawing]; with "drawing" it
// renders Benji's pen marks instead (circle, arrow, underline, highlight, path, note); with
// "pictures", whole answers that draw (D-97): tags parsed and mapped as the app does, each part
// revealed when the sequence says.
import AppKit
import BenjiCore
import SwiftUI

// MARK: rendering

@MainActor
func image<V: View>(_ view: V, scale: CGFloat) -> CGImage {
    let r = ImageRenderer(content: view)
    r.scale = scale
    return r.cgImage!
}

@MainActor
func writePNG(_ cg: CGImage, _ url: URL) {
    let rep = NSBitmapImageRep(cgImage: cg)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

struct Shot {
    let name: String
    let caption: String
    var dark = false
    let marks: [ShownMark]
    var sketches: [ShownSketch] = []
    var appearance = OverlayAppearance.standard
    let now: Double
    /// Crop, in drawn (top-left) points; nil for the whole screen.
    var crop: CGRect?
    /// A drawing's board (AppKit global points).
    var board: CGRect? = nil
}

func shown(_ mark: PointingMark, id: Int = 1, step: MarkStep = .reveal, start: Double = 0, end: Double? = nil,
           replaced: Bool = false, previous: PointingMark? = nil, appearance: OverlayAppearance = .standard) -> ShownMark {
    let label = mark.label.isEmpty ? nil
        : OverlayLayout.labelFrame(size: OverlayLabelMetrics.size(mark.label), for: mark, visibleFrame: visible,
                                   avoid: [panel, notch], appearance: appearance)
    var s = ShownMark(id: id, index: id - 1, mark: mark, labelFrame: label, step: step, start: start, end: end, replaced: replaced)
    if let previous {
        s.previousLabel = previous.label
        s.previousLabelFrame = OverlayLayout.labelFrame(size: OverlayLabelMetrics.size(previous.label), for: previous,
                                                        visibleFrame: visible, avoid: [panel, notch], appearance: appearance)
    }
    return s
}

/// A crop of `size` points centred on a global point.
func around(_ p: CGPoint, _ w: CGFloat = 340, _ h: CGFloat = 170) -> CGRect {
    CGRect(x: p.x - w / 2, y: screen.height - p.y - h / 2 + 18, width: w, height: h)
}

let shareRing = PointingMark.ring(center: share, label: "Share")
let syncRing = PointingMark.ring(center: syncFiles, label: "Sync files")
let photosRing = PointingMark.ring(center: includePhotos, label: "Include photos")
let gridRegion = PointingMark.region(rect: photoGrid, label: "Recent photos")
let saveRing = PointingMark.ring(center: saveButton, label: "Save")
let runRing = PointingMark.ring(center: run, label: "Run the build again")
let wifiRing = PointingMark.ring(center: wifi, label: "Wi‑Fi")

let ic = OverlayAppearance(increaseContrast: true)
let rt = OverlayAppearance(reduceTransparency: true)
let rm = OverlayAppearance(reduceMotion: true)
let gridCrop = CGRect(x: photoGrid.minX - 40, y: screen.height - photoGrid.maxY - 40, width: 500, height: 300)
let stepsCrop = CGRect(x: 280, y: 160, width: 560, height: 300)

let shots: [Shot] = [
    Shot(name: "01-ring-draw-100ms", caption: "Ring, 100 ms: stroke and keylines drawing clockwise from 12 o'clock; label fading in (from 85 ms)",
         marks: [shown(shareRing)], now: 0.10, crop: around(share)),
    Shot(name: "02-ring-pulse-450ms", caption: "Ring, 450 ms: stroke settled; the one pulse (halo copy growing 10 pt, fading)",
         marks: [shown(shareRing)], now: 0.45, crop: around(share)),
    Shot(name: "03-ring-rest", caption: "Ring at rest (from ≈ 875 ms): nothing moves until it is erased",
         marks: [shown(shareRing)], now: 3, crop: around(share)),
    Shot(name: "04-region-draw-250ms", caption: "Region, 250 ms: drawing from the top centre with motion-open",
         marks: [shown(gridRegion)], now: 0.25, crop: gridCrop),
    Shot(name: "05-region-rest-busy", caption: "Region at rest over busy content: material band under the halo, interior untouched",
         marks: [shown(gridRegion)], now: 3, crop: gridCrop),
    Shot(name: "06-glide-120ms", caption: "Step 2 within 220 pt: the ring glides (motion-follow); old label fading, new one not yet",
         marks: [shown(photosRing, id: 2, step: .glide(from: syncFiles), previous: syncRing)], now: 0.12, crop: stepsCrop),
    Shot(name: "07-glide-rest", caption: "Step 2 at rest after the glide and its arrival pulse",
         marks: [shown(photosRing, id: 2, step: .glide(from: syncFiles), previous: syncRing)], now: 3, crop: stepsCrop),
    Shot(name: "08-step3-crossfade-90ms", caption: "Step 3 is a region-to-ring hop over 220 pt: old mark fades out while the new one draws",
         marks: [shown(gridRegion, id: 2, start: -3, end: 0, replaced: true), shown(saveRing, id: 3)], now: 0.09, crop: gridCrop.insetBy(dx: 0, dy: -40)),
    Shot(name: "09-dark-corner", caption: "Dark app at the bottom-right: below doesn't fit, so the label goes above and slides left",
         dark: true, marks: [shown(runRing)], now: 3, crop: CGRect(x: 1512 - 420, y: 982 - 260, width: 420, height: 260)),
    Shot(name: "10-menu-bar-item", caption: "A menu-bar target: the ring sits on it, the label goes into the safe area below",
         marks: [shown(wifiRing)], now: 3, crop: CGRect(x: wifi.x - 200, y: 0, width: 400, height: 140)),
    Shot(name: "11-increase-contrast", caption: "Increase Contrast: 4 pt mint growing inward, opaque 1.5 pt black keylines; opaque bordered label",
         marks: [shown(shareRing, appearance: ic)], appearance: ic, now: 3, crop: around(share)),
    Shot(name: "12-reduce-transparency", caption: "Reduce Transparency: no halo or material; 2 pt notch-raised keylines; opaque label",
         marks: [shown(shareRing, appearance: rt)], appearance: rt, now: 3, crop: around(share)),
    Shot(name: "13-region-increase-contrast", caption: "Region with Increase Contrast",
         marks: [shown(gridRegion, appearance: ic)], appearance: ic, now: 3, crop: gridCrop),
    Shot(name: "14-reduce-motion-100ms", caption: "Reduce Motion, 100 ms: the whole mark fades in at once (no drawing, no pulse)",
         marks: [shown(shareRing)], appearance: rm, now: 0.10, crop: around(share)),
    Shot(name: "15-reduce-motion-step", caption: "Reduce Motion step: crossfade (motion-reduce) instead of a glide, 100 ms",
         marks: [shown(syncRing, id: 1, start: -3, end: 0, replaced: true), shown(photosRing, id: 2)], appearance: rm, now: 0.10, crop: stepsCrop),
    Shot(name: "16-erase-80ms", caption: "Erase (Escape, a click on the target, …), 80 ms into the motion-fade",
         marks: [shown(shareRing, start: -3, end: 0)], now: 0.08, crop: around(share)),
]

@MainActor
func render(_ shot: Shot, to dir: URL, scale: CGFloat) -> CGImage {
    let desktop = Desktop(dark: shot.dark)
    let backdrop = Image(decorative: image(desktop, scale: 2), scale: 2)
    let full = ZStack(alignment: .topLeading) {
        desktop
        OverlayFrame(marks: shot.marks, sketches: shot.sketches, screenFrame: screen, appearance: shot.appearance,
                     now: shot.now, backdrop: .picture(backdrop), board: shot.board)
    }
    .frame(width: screen.width, height: screen.height, alignment: .topLeading)
    let crop = shot.crop ?? CGRect(origin: .zero, size: screen.size)
    let view = full
        .offset(x: -crop.minX, y: -crop.minY)
        .frame(width: crop.width, height: crop.height, alignment: .topLeading)
        .clipped()
    let cg = image(view, scale: scale)
    writePNG(cg, dir.appendingPathComponent(shot.name + ".png"))
    return cg
}

// MARK: drawing

/// A pen mark as the overlay shows it, revealed at `start`; ids follow the answer's order.
func sketched(_ sketch: Sketch, id: Int = 1, start: Double = 0, end: Double? = nil) -> ShownSketch {
    var noteFrame: CGRect?
    if case let .note(p, text) = sketch {
        let local = CGRect(x: visible.minX, y: screen.height - visible.maxY, width: visible.width, height: visible.height)
        noteFrame = SketchLayout.noteFrame(size: OverlayNoteMetrics.size(text), at: CGPoint(x: p.x, y: screen.height - p.y),
                                           bounds: local)
    }
    return ShownSketch(id: id, index: id - 1, sketch: sketch, seed: PenRandom.seed(index: id - 1, sketch: sketch),
                       noteFrame: noteFrame, start: start, end: end)
}

let nameField = g(CGRect(x: contentX + 104, y: firstRowY - 8 + 3 * 30 + 4, width: 220, height: 24))
let backupTitle = g(CGRect(x: contentX, y: 90 + 44 + 24 - 2, width: 72, height: 26))
let circleName = Sketch.circle(rect: nameField, label: "Customer name")
let arrowToSave = Sketch.arrow(from: g(contentX + 250, gridTop + 120), to: g(saveButton.x - 34, screen.height - saveButton.y - 4),
                               label: "Save")
let underlineTitle = Sketch.underline(from: g(contentX, 90 + 44 + 24 + 26), to: g(contentX + 74, 90 + 44 + 24 + 26), label: "Backup")
let highlightRows = Sketch.highlight(rect: g(CGRect(x: contentX + 22, y: firstRowY + 22, width: 104, height: 18)), label: "Include photos")
let pathThrough = Sketch.path(points: [g(contentX + 8, firstRowY), g(contentX - 30, firstRowY + 30), g(contentX + 8, firstRowY + 60),
                                       g(contentX + 60, firstRowY + 92)], label: "these steps")
let noteSave = Sketch.note(at: g(saveButton.x + 30, screen.height - saveButton.y), text: "Then press Save")
let runArrow = Sketch.arrow(from: g(1200, 700), to: g(run.x - 30, screen.height - run.y), label: "Run")
let runCircle = Sketch.circle(rect: g(CGRect(x: 1512 - 36 - 30, y: 982 - 95 - 14, width: 60, height: 28)), label: "Run")

let formCrop = CGRect(x: contentX - 70, y: 130, width: 520, height: 210)
let lowerCrop = CGRect(x: contentX - 20, y: gridTop - 20, width: 660, height: 280)
let darkCrop = CGRect(x: 1512 - 420, y: 982 - 360, width: 420, height: 330)
let dur = { (s: Sketch) in SketchTimeline.drawDuration(s) }

let drawingShots: [Shot] = [
    Shot(name: "d01-circle-pen-40pct", caption: "Circle, pen at 40%: the loop starts upper left, mint over a dark edge, tapering in",
         marks: [], sketches: [sketched(circleName)], now: dur(circleName) * 0.4, crop: formCrop),
    Shot(name: "d02-circle-rest", caption: "Circle at rest: carried past its start so the ends cross; clears the field's corners",
         marks: [], sketches: [sketched(circleName)], now: 5, crop: formCrop),
    Shot(name: "d03-arrow-pen-60pct", caption: "Arrow, pen at 60%: the shaft bows slightly; the head comes last",
         marks: [], sketches: [sketched(arrowToSave)], now: dur(arrowToSave) * 0.6, crop: lowerCrop),
    Shot(name: "d04-arrow-rest", caption: "Arrow at rest: two barbs drawn from the tip, over busy content",
         marks: [], sketches: [sketched(arrowToSave)], now: 5, crop: lowerCrop),
    Shot(name: "d05-underline", caption: "Underline at rest: one tapered stroke under the title",
         marks: [], sketches: [sketched(underlineTitle)], now: 5, crop: formCrop),
    Shot(name: "d06-highlight-pen-50pct", caption: "Highlight, half drawn: a translucent mint band sweeping left to right",
         marks: [], sketches: [sketched(highlightRows)], now: dur(highlightRows) * 0.5, crop: formCrop),
    Shot(name: "d07-highlight-rest", caption: "Highlight at rest: the words stay readable through it",
         marks: [], sketches: [sketched(highlightRows)], now: 5, crop: formCrop),
    Shot(name: "d08-path", caption: "Freehand path through four points: its turns are sharper than 60°, so they stay corners (D-97)",
         marks: [], sketches: [sketched(pathThrough)], now: 5, crop: formCrop),
    Shot(name: "d09-note-writing", caption: "Note being written in (pen at 55%): a dot where it belongs, words to its right",
         marks: [], sketches: [sketched(noteSave)], now: dur(noteSave) * 0.55, crop: lowerCrop),
    Shot(name: "d10-note-rest", caption: "Note at rest: rounded mint words on a dark chip, legible on any background",
         marks: [], sketches: [sketched(noteSave)], now: 5, crop: lowerCrop),
    Shot(name: "d11-together", caption: "An answer that draws: circle, then arrow, then note, all up together",
         marks: [], sketches: [sketched(circleName, id: 1, start: -6), sketched(arrowToSave, id: 2, start: -4),
                               sketched(noteSave, id: 3, start: -2)], now: 5,
         crop: CGRect(x: contentX - 70, y: 130, width: 700, height: 470)),
    Shot(name: "d12-dark-background", caption: "On a dark window: the same mint; the dark edge blends in and the mint carries it",
         dark: true, marks: [], sketches: [sketched(runArrow, id: 1, start: -4), sketched(runCircle, id: 2, start: -2)],
         now: 5, crop: darkCrop),
    Shot(name: "d13-increase-contrast", caption: "Increase Contrast: thicker pen, solid black edge, note on a solid chip",
         marks: [], sketches: [sketched(circleName, id: 1, start: -6), sketched(noteSave, id: 2, start: -2)],
         appearance: ic, now: 5, crop: CGRect(x: contentX - 70, y: 130, width: 700, height: 470)),
    Shot(name: "d14-reduce-motion-100ms", caption: "Reduce Motion, 100 ms: no pen movement, the whole mark fades in",
         marks: [], sketches: [sketched(arrowToSave)], appearance: rm, now: 0.1, crop: lowerCrop),
    Shot(name: "d15-erase-80ms", caption: "Erase (Escape, click, scroll, window change, next message), 80 ms into the fade",
         marks: [], sketches: [sketched(circleName, start: -5, end: 0)], now: 0.08, crop: formCrop),
    Shot(name: "d16-with-ring", caption: "A ring and a drawing in one answer: both stay up (no replace or glide when drawing)",
         marks: [shown(saveRing, id: 2, start: -3)], sketches: [sketched(circleName, id: 1, start: -5)], now: 5,
         crop: CGRect(x: contentX - 70, y: 130, width: 700, height: 470)),
]

// MARK: pictures

/// An answer as the model writes it, through the app's own parser, mapping and sequence: the
/// sketches with the moments they are revealed (the screenshot is the synthetic screen, 1:1).
func answer(_ reply: String) -> [ShownSketch] {
    let (text, targets) = PointingTags.parse(reply)
    guard let plan = PointingPlan(targets: targets, text: text, speaking: false, pixelSize: screen.size,
                                  screenFrame: screen, displayID: nil) else { fatalError("nothing drawn: \(reply)") }
    var seq = plan.sequence(reduceMotion: false, now: 0)
    var out: [ShownSketch] = []
    while let d = seq.deadline(), out.count < plan.items.count {
        for case let .reveal(i) in seq.advance(to: d) {
            guard let sketch = plan.items[i].sketch else { continue }
            var s = sketched(sketch, id: i + 1, start: d)
            if case let .callout(p, text) = sketch {
                let local = CGRect(x: visible.minX, y: screen.height - visible.maxY, width: visible.width, height: visible.height)
                s = ShownSketch(id: s.id, index: s.index, sketch: sketch, seed: s.seed,
                                noteFrame: SketchLayout.calloutFrame(size: OverlayNoteMetrics.calloutSize(text),
                                                                     at: CGPoint(x: p.x, y: screen.height - p.y), bounds: local),
                                start: d)
            }
            out.append(s)
        }
    }
    return out
}

func finished(_ s: [ShownSketch]) -> Double {
    (s.map { $0.start + SketchTimeline.drawDuration($0.sketch) }.max() ?? 0) + 1
}

let airplane = answer("""
An airliner, nose to the right. [SHAPE:1100,262,1400,258,1446,268,1466,282,1446,295,1400,302,1120,302,1104,290:body] \
[SHAPE:1112,262,1088,192,1116,192,1170,262:tail fin] [SHAPE:1250,262,1222,212,1246,212,1312,262:far wing] \
[SHAPE:1240,292,1190,372,1224,372,1318,292:wing] [SHAPE:1114,288,1088,316,1108,316,1152,290:tailplane] \
[SHAPE:1416,268,1440,268,1452,279,1420,279:cockpit] [OVAL:1290,270,1300,280:window] [OVAL:1310,270,1320,280:window] \
[OVAL:1330,270,1340,280:window] [OVAL:1350,270,1360,280:window] [OVAL:1370,270,1380,280:window] \
[LINE:1200,290,1380,290:stripe]
""")
let house = answer("""
A house with a chimney. [SHAPE:1160,262,1400,262,1400,430,1160,430:walls] [SHAPE:1136,266,1280,150,1424,266:roof] \
[LINE:1350,218,1350,166,1378,166,1378,240:chimney] [LINE:1256,430,1256,350,1306,350,1306,430:door] \
[OVAL:1292,388,1298,394:door knob] [SHAPE:1186,290,1236,290,1236,336,1186,336:window] [LINE:1211,290,1211,336:frame] \
[LINE:1186,313,1236,313:frame] [SHAPE:1326,290,1376,290,1376,336,1326,336:window] [LINE:1351,290,1351,336:frame] \
[LINE:1326,313,1376,313:frame] [PATH:1364,158,1356,146,1358,132,1368,120,1372,106,1366,92,1368,78,1378,66:smoke]
""")
let smiley = answer("""
A smiley. [OVAL:1150,150,1430,430:face] [OVAL:1222,232,1250,276:left eye] [OVAL:1330,232,1358,276:right eye] \
[PATH:1206,326,1246,366,1290,380,1334,366,1374,326:smile]
""")
let sidebar = answer("""
Your folders are in the sidebar, and the customer name goes here. [GROUP:160,146,320,282:sidebar] \
[CALLOUT:326,250:Your folders] [CIRCLE:\(Int(nameField.minX) - 4),\(Int(screen.height - nameField.maxY) - 2),\(Int(nameField.maxX) + 4),\(Int(screen.height - nameField.minY) + 2):Customer name]
""")
/// The old way (D-67): every path smoothed through its corners, at most eight points a path.
let oldAirplane = [sketched(.path(points: [g(1100, 280), g(1160, 262), g(1112, 192), g(1250, 262), g(1200, 372),
                                           g(1320, 292), g(1466, 282), g(1100, 300)], label: "airplane"))]

let pictureCrop = CGRect(x: 1040, y: 50, width: 472, height: 420)
let pictureShots: [Shot] = [
    Shot(name: "p01-airplane", caption: "\"Draw an airplane\": body, fin, wings and tailplane as closed shapes, windows as small ovals, corners kept",
         marks: [], sketches: airplane, now: finished(airplane), crop: pictureCrop),
    Shot(name: "p02-airplane-drawing", caption: "The same, being drawn: one part after another, as a hand would",
         marks: [], sketches: airplane, now: airplane[4].start + 0.2, crop: pictureCrop),
    Shot(name: "p03-house", caption: "A house: walls and roof as shapes, door and chimney as straight lines, smoke as a smooth path",
         marks: [], sketches: house, now: finished(house), crop: pictureCrop),
    Shot(name: "p04-smiley", caption: "A smiley: an oval face and eyes (closed, no crossing ends), a smoothed smile",
         marks: [], sketches: smiley, now: finished(smiley), crop: pictureCrop),
    Shot(name: "p05-sidebar-callout", caption: "Pointing at a region: a dashed group round the sidebar, a callout pointing at it, and a loop round one field",
         marks: [], sketches: sidebar, now: finished(sidebar), crop: CGRect(x: 130, y: 100, width: 600, height: 300)),
    Shot(name: "p06-old-airplane", caption: "Before (D-67 rules): one smoothed path through 8 points; the corners overshoot into loops",
         marks: [], sketches: oldAirplane, now: 5, crop: pictureCrop),
]

// MARK: whiteboard (chilly-whiteboard)

/// A beats-form answer as the app reads it: tags between sentences, each part released on its
/// sentence by `OverlayBeats` on the estimate clock (no voice), optionally moved onto a board.
struct Board {
    var sketches: [ShownSketch]
    var board: CGRect?
    var drawing: DrawingParts
    var end: Double
}

func localVisible() -> CGRect { CGRect(x: visible.minX, y: screen.height - visible.maxY, width: visible.width, height: visible.height) }

func noteFrame(_ sketch: Sketch) -> CGRect? {
    switch sketch {
    case let .text(p, text, size):
        return SketchLayout.textFrame(size: OverlayHandwriting.size(text, size), at: CGPoint(x: p.x, y: screen.height - p.y),
                                      bounds: localVisible())
    case let .callout(p, text):
        return SketchLayout.calloutFrame(size: OverlayNoteMetrics.calloutSize(text), at: CGPoint(x: p.x, y: screen.height - p.y),
                                         bounds: localVisible())
    default:
        return nil
    }
}

/// The synthetic desktop's busy map, measured the way the app measures a screenshot.
@MainActor
func desktopBusy() -> BusyMap {
    let cg = image(Desktop(), scale: 1)
    let w = cg.width, h = cg.height
    var luma = [UInt8](repeating: 0, count: w * h)
    luma.withUnsafeMutableBytes { buf in
        let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    return BusyMap.measure(luma: luma, width: w, height: h, pointsWide: screen.width)!
}

@MainActor
func whiteboard(_ reply: String, busy: BusyMap?) -> Board {
    let (text, targets) = PointingTags.split(reply)
    guard let plan = PointingPlan(targets: targets, text: text, speaking: false, pixelSize: screen.size,
                                  screenFrame: screen, displayID: nil),
          var beats = plan.beats(reduceMotion: false, now: 0) else { fatalError("not a beats-form drawing: \(reply)") }
    var drawing = DrawingParts()
    drawing.append(plan.items)
    var boardRect: CGRect?
    if let extent = drawing.extent {
        let local = CGRect(x: extent.minX, y: screen.height - extent.maxY, width: extent.width, height: extent.height)
        let prefer = CGPoint(x: panel.midX, y: screen.height - panel.minY + ExplainCardPlacement.margin)
        let keepOut = [CGRect(x: panel.minX, y: screen.height - panel.maxY, width: panel.width, height: panel.height)]
        if let placed = DrawingBoard.place(drawing: local, visible: localVisible(), busy: busy, prefer: prefer, avoid: keepOut) {
            drawing.shift(by: CGVector(dx: placed.offset.dx, dy: -placed.offset.dy))
            boardRect = g(placed.frame)
        }
    }
    var out: [ShownSketch] = []
    var t = 0.0
    while !beats.isDone && t < 60 {
        for i in beats.advance(now: t) {
            guard let sketch = drawing.parts[i].item.sketch else { continue }
            var s = ShownSketch(id: i + 1, index: i, sketch: sketch, seed: PenRandom.seed(index: i, sketch: sketch),
                                noteFrame: noteFrame(sketch), start: beats.releasedAt(i) ?? t)
            s.pace = beats.pace(i)
            out.append(s)
        }
        t += 0.01
    }
    return Board(sketches: out, board: boardRect, drawing: drawing, end: (out.map { $0.start + SketchTimeline.drawDuration($0.sketch) * $0.pace }.max() ?? 0) + 1)
}

/// The Pythagoras ask of the live round, as the beats form: each part right after its sentence.
func pythagoras(x: Int, y: Int) -> String {
    func p(_ dx: Int, _ dy: Int) -> String { "\(x + dx),\(y + dy)" }
    return """
    A right triangle has two short sides that meet at a square corner.
    [LINE:\(p(0, 0)),\(p(0, 240)):a] [LINE:\(p(0, 240)),\(p(320, 240)):b] [LINE:\(p(0, 216)),\(p(24, 216)),\(p(24, 240)):corner]
    Call them a and b.
    [TEXT:\(p(-34, 112)):large:a] [TEXT:\(p(150, 262)):large:b]
    The long side across from the corner is the hypotenuse, c.
    [LINE:\(p(0, 0)),\(p(320, 240)):c] [TEXT:\(p(176, 92)):large:c]
    Pythagoras says a squared plus b squared equals c squared.
    [TEXT:\(p(40, -46)):large:a² + b² = c²]
    """
}

@MainActor
func whiteboardShots() -> [Shot] {
    let calm = whiteboard(pythagoras(x: 1060, y: 250), busy: desktopBusy())
    let busyOne = whiteboard(pythagoras(x: 300, y: 300), busy: desktopBusy())
    // "Make the hypotenuse longer": p6 (legs p1 p2, corner p3, labels p4 p5, then the hypotenuse)
    // grows by a third, in orange, gliding there.
    var edited = calm
    let hyp = 5   // p6
    let changes = edited.drawing.apply(DrawingEdit.parse("EDIT:p6:scale 1.3")!, pointsPerPixel: CGSize(width: 1, height: 1))
    _ = edited.drawing.apply(DrawingEdit.parse("EDIT:p6:recolor orange")!, pointsPerPixel: CGSize(width: 1, height: 1))
    let editAt = calm.end
    for k in edited.sketches.indices where edited.sketches[k].index == hyp {
        guard case let .moved(_, transform)? = changes.first, let sketch = edited.drawing.parts[hyp].item.sketch else { continue }
        edited.sketches[k].sketch = sketch
        edited.sketches[k].tweenFrom = transform.inverted()
        edited.sketches[k].tweenStart = editAt
        edited.sketches[k].color = .orange
    }
    // Erasing a label runs the pen backwards.
    var erased = calm
    for k in erased.sketches.indices where erased.sketches[k].index == 1 {
        erased.sketches[k].unwriteStart = calm.end
        erased.sketches[k].end = calm.end + erased.sketches[k].unwriteDuration
    }
    let sizes = [sketched(.text(at: g(1080, 300), text: "small words", size: .small), id: 1),
                 sketched(.text(at: g(1080, 360), text: "medium words", size: .medium), id: 2),
                 sketched(.text(at: g(1080, 440), text: "Large: a² + b² = c²", size: .large), id: 3)]
        .map { s -> ShownSketch in var s = s; s.noteFrame = noteFrame(s.sketch); return s }
    let crop = CGRect(x: 960, y: 140, width: 552, height: 460)
    let firstSentenceEnd = calm.sketches.filter { $0.index <= 2 }.map { $0.start + SketchTimeline.drawDuration($0.sketch) * $0.pace }.max()! + 0.05
    let boardCrop = busyOne.board.map { b in CGRect(x: b.minX - 80, y: screen.height - b.maxY - 60, width: b.width + 160, height: b.height + 120) }
    return [
        Shot(name: "w01-pythagoras", caption: "\"Explain Pythagoras' theorem while you draw it on my screen\": the beats form on calm space, shapes and handwritten TEXT",
             marks: [], sketches: calm.sketches, now: calm.end, crop: crop),
        Shot(name: "w02-pythagoras-first-sentence", caption: "The same, as the first sentence ends: only its parts (the two legs and the corner) are drawn",
             marks: [], sketches: calm.sketches, now: firstSentenceEnd, crop: crop),
        Shot(name: "w03-board", caption: "The same drawing asked for over the busy window: it goes on Benji's board (black card, faint grid) on calm space near the panel",
             marks: [], sketches: busyOne.sketches, now: busyOne.end, crop: boardCrop, board: busyOne.board),
        Shot(name: "w04-edit-hypotenuse", caption: "\"Make the hypotenuse longer\": [EDIT:p6:scale 1.3] [EDIT:p6:recolor orange], mid-glide; nothing else moves",
             marks: [], sketches: edited.sketches, now: editAt + ShownSketch.tween * 0.5, crop: crop),
        Shot(name: "w05-edit-settled", caption: "The edit at rest", marks: [], sketches: edited.sketches, now: editAt + 1, crop: crop),
        Shot(name: "w06-erase", caption: "[EDIT:p2:erase]: the pen runs backwards over leg b, halfway", marks: [],
             sketches: erased.sketches, now: calm.end + erased.sketches.first { $0.index == 1 }!.unwriteDuration * 0.5, crop: crop),
        Shot(name: "w07-text-sizes", caption: "TEXT in Kalam at small, medium and large", marks: [], sketches: sizes,
             now: 5, crop: CGRect(x: 1040, y: 250, width: 472, height: 230)),
    ]
}

@MainActor
func main() {
    let dir = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let drawing = CommandLine.arguments.dropFirst(2).first == "drawing"
    var tiles: [(Shot, CGImage)] = []
    if CommandLine.arguments.dropFirst(2).first == "whiteboard" {
        OverlayHandwriting.searchFolders = [URL(fileURLWithPath: "Resources/Fonts")]
        for shot in whiteboardShots() { tiles.append((shot, render(shot, to: dir, scale: 2))) }
        writePNG(image(ContactSheet(tiles: tiles, title: "Benji's whiteboard (chilly-whiteboard): beats-form answers parsed, owned, paced and edited as the app does, rendered offscreen in \(OverlayHandwriting.font(.large).fontName)."), scale: 1),
                 dir.appendingPathComponent("whiteboard-contact-sheet.png"))
        print("wrote \(tiles.count + 1) images to \(dir.path)")
        return
    }
    if CommandLine.arguments.dropFirst(2).first == "pictures" {
        for shot in pictureShots { tiles.append((shot, render(shot, to: dir, scale: 2))) }
        writePNG(image(ContactSheet(tiles: tiles, title: "Benji pictures (D-97): answers parsed, mapped and sequenced as the app does, rendered offscreen."), scale: 1),
                 dir.appendingPathComponent("pictures-contact-sheet.png"))
        print("wrote \(tiles.count + 1) images to \(dir.path)")
        return
    }
    if drawing {
        for shot in drawingShots { tiles.append((shot, render(shot, to: dir, scale: 3))) }
        writePNG(image(ContactSheet(tiles: tiles, title: "Benji drawing: offscreen renders over a synthetic screen (ImageRenderer)."), scale: 1.5),
                 dir.appendingPathComponent("drawing-contact-sheet.png"))
        print("wrote \(tiles.count + 1) images to \(dir.path)")
        return
    }
    for shot in shots { tiles.append((shot, render(shot, to: dir, scale: 3))) }

    // The whole screen once, with step 1 at rest and the panel open.
    _ = render(Shot(name: "00-full-screen", caption: "", marks: [shown(syncRing)], now: 3), to: dir, scale: 1)

    // A contact sheet of every crop with its caption.
    writePNG(image(ContactSheet(tiles: tiles), scale: 1.5), dir.appendingPathComponent("contact-sheet.png"))
    print("wrote \(tiles.count + 2) images to \(dir.path)")
}

struct ContactSheet: View {
    let tiles: [(Shot, CGImage)]
    var title = "Benji pointer overlay: offscreen renders over a synthetic screen (ImageRenderer). The HUD material is a stand-in: the picture underneath, blurred as in the design preview."
    let columns = Array(repeating: GridItem(.fixed(440), spacing: 20, alignment: .top), count: 4)
    let sheetWidth: CGFloat = 1868

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(verbatim: title)
                .font(.system(size: 15, weight: .semibold))
            LazyVGrid(columns: columns, spacing: 24) {
                ForEach(tiles.indices, id: \.self) { i in tile(tiles[i].0, tiles[i].1) }
            }
        }
        .padding(24)
        .frame(width: sheetWidth)
        .background(Color.white)
        .environment(\.colorScheme, .light)
    }

    func tile(_ shot: Shot, _ cg: CGImage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(decorative: cg, scale: 3).resizable().aspectRatio(contentMode: .fit)
                .frame(width: 440).border(Color.gray.opacity(0.3))
            Text(verbatim: shot.name).font(.system(size: 12, weight: .semibold, design: .monospaced))
            Text(verbatim: shot.caption).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

MainActor.assumeIsolated { main() }
