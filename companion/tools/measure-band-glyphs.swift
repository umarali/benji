import AppKit
// usage: measure <pointSize> <weight> symbol... ; reports visible bbox in points (rendered at 16x).
let args = CommandLine.arguments
let size = CGFloat(Double(args[1])!)
let weight: NSFont.Weight = .semibold
for name in args.dropFirst(2) {
    let parts = name.split(separator: "@"); let sym = String(parts[0]); let s = parts.count > 1 ? size * CGFloat(Double(parts[1])!) : size
    guard let base = NSImage(systemSymbolName: sym, accessibilityDescription: nil),
          let img = base.withSymbolConfiguration(.init(pointSize: s, weight: weight)) else { print("\(sym): missing"); continue }
    let k: CGFloat = 16
    let W = Int(60 * k), H = Int(60 * k)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext; ctx.scaleBy(x: k, y: k)
    img.isTemplate = false
    let r = NSRect(x: 30 - img.size.width/2, y: 30 - img.size.height/2, width: img.size.width, height: img.size.height)
    NSColor.white.set()
    img.draw(in: r)
    NSGraphicsContext.restoreGraphicsState()
    var minX = W, maxX = -1, minY = H, maxY = -1
    for y in 0..<H { for x in 0..<W {
        let c = rep.colorAt(x: x, y: y)!
        if c.alphaComponent > 0.35 { minX = min(minX,x); maxX = max(maxX,x); minY = min(minY,y); maxY = max(maxY,y) }
    }}
    // stroke: horizontal run of ink on the middle row, first run
    var run = 0; var first = 0
    let my = (minY+maxY)/2
    for x in minX...maxX { if rep.colorAt(x: x, y: my)!.alphaComponent > 0.5 { run += 1 } else if run > 0 { first = run; break } }
    print("   edge run at mid row: \(String(format: "%.2f", Double(first)/Double(k))) pt")
    print(String(format: "%-48@ w %.2f h %.2f", sym as NSString, Double(maxX-minX+1)/Double(k), Double(maxY-minY+1)/Double(k)))
}
