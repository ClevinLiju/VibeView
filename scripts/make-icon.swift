// Generates MolScope's original app icon (a stylised three-atom molecule on a gradient tile).
// Usage: swift scripts/make-icon.swift <output.iconset>
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "MolScope.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let inset = s * 0.09
    let tile = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = NSBezierPath(roundedRect: tile, xRadius: s * 0.19, yRadius: s * 0.19)
    NSGradient(starting: NSColor(calibratedRed: 0.10, green: 0.16, blue: 0.32, alpha: 1),
               ending: NSColor(calibratedRed: 0.05, green: 0.45, blue: 0.55, alpha: 1))!.draw(in: path, angle: -60)
    // orbit ring
    let ring = NSBezierPath(ovalIn: tile.insetBy(dx: s * 0.12, dy: s * 0.24))
    var t = AffineTransform(translationByX: s / 2, byY: s / 2); t.rotate(byDegrees: 30); t.translate(x: -s / 2, y: -s / 2)
    ring.transform(using: t)
    ring.lineWidth = s * 0.018
    NSColor(white: 1, alpha: 0.35).setStroke(); ring.stroke()
    // bonds + atoms
    let c = NSPoint(x: s * 0.50, y: s * 0.47)
    let a1 = NSPoint(x: s * 0.28, y: s * 0.64), a2 = NSPoint(x: s * 0.74, y: s * 0.66), a3 = NSPoint(x: s * 0.52, y: s * 0.24)
    for p in [a1, a2, a3] {
        let b = NSBezierPath(); b.move(to: c); b.line(to: p); b.lineWidth = s * 0.05; b.lineCapStyle = .round
        NSColor(white: 0.92, alpha: 1).setStroke(); b.stroke()
    }
    func atom(_ p: NSPoint, _ r: CGFloat, _ col: NSColor) {
        let rect = NSRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)
        let g = NSGradient(colors: [col.blended(withFraction: 0.6, of: .white)!, col, col.blended(withFraction: 0.45, of: .black)!])!
        g.draw(in: NSBezierPath(ovalIn: rect), relativeCenterPosition: NSPoint(x: -0.35, y: 0.4))
    }
    atom(a1, s * 0.085, NSColor(calibratedRed: 0.95, green: 0.95, blue: 0.97, alpha: 1))
    atom(a2, s * 0.085, NSColor(calibratedRed: 0.95, green: 0.95, blue: 0.97, alpha: 1))
    atom(a3, s * 0.095, NSColor(calibratedRed: 0.25, green: 0.55, blue: 0.98, alpha: 1))
    atom(c, s * 0.135, NSColor(calibratedRed: 0.93, green: 0.25, blue: 0.22, alpha: 1))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base)@2x.png"))
}
print("wrote \(out)")
