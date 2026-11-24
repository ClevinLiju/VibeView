// Generates VibeView's original app icon: a vivid gradient tile, a bent three-atom molecule
// inside a lens ring, with vibration arcs beside the hydrogens.
// Usage: swift scripts/make-icon.swift <output.iconset>
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "VibeView.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func col(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: r, green: g, blue: b, alpha: a)
}

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let small = px <= 64
    let inset = s * 0.07
    let tile = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = NSBezierPath(roundedRect: tile, xRadius: s * 0.205, yRadius: s * 0.205)

    // soft drop shadow under the tile
    if !small {
        NSGraphicsContext.saveGraphicsState()
        let sh = NSShadow()
        sh.shadowColor = NSColor(white: 0, alpha: 0.35)
        sh.shadowBlurRadius = s * 0.025
        sh.shadowOffset = NSSize(width: 0, height: -s * 0.012)
        sh.set()
        col(0.2, 0.1, 0.5).setFill(); path.fill()
        NSGraphicsContext.restoreGraphicsState()
    }
    // vivid gradient: indigo -> violet -> hot coral
    NSGradient(colors: [col(0.16, 0.12, 0.62), col(0.47, 0.20, 0.82), col(0.98, 0.36, 0.46)],
               atLocations: [0, 0.55, 1], colorSpace: .deviceRGB)!.draw(in: path, angle: 55)
    // top sheen
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    NSGradient(starting: NSColor(white: 1, alpha: 0.22), ending: NSColor(white: 1, alpha: 0))!
        .draw(in: NSRect(x: tile.minX, y: tile.midY, width: tile.width, height: tile.height / 2), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    let center = NSPoint(x: s / 2, y: s / 2)
    // lens ring
    let rr = s * 0.37
    let ring = NSBezierPath(ovalIn: NSRect(x: center.x - rr, y: center.y - rr, width: 2 * rr, height: 2 * rr))
    ring.lineWidth = s * (small ? 0.045 : 0.032)
    NSColor(white: 1, alpha: small ? 0.55 : 0.5).setStroke(); ring.stroke()
    if !small {
        // lens glint
        let g = NSBezierPath()
        g.appendArc(withCenter: center, radius: rr, startAngle: 120, endAngle: 160)
        g.lineWidth = s * 0.032; g.lineCapStyle = .round
        NSColor(white: 1, alpha: 0.95).setStroke(); g.stroke()
    }

    // bent molecule (O at bottom, two H up)
    let o = NSPoint(x: s * 0.50, y: s * 0.365)
    let h1 = NSPoint(x: s * 0.355, y: s * 0.575), h2 = NSPoint(x: s * 0.645, y: s * 0.575)
    for p in [h1, h2] {
        let b = NSBezierPath(); b.move(to: o); b.line(to: p)
        b.lineWidth = s * (small ? 0.075 : 0.055); b.lineCapStyle = .round
        NSColor(white: 0.97, alpha: 1).setStroke(); b.stroke()
    }
    // vibration arcs beside each hydrogen (stretching motion)
    if !small {
        for (p, dir) in [(h1, CGFloat(-1)), (h2, CGFloat(1))] {
            let toward = atan2(p.y - o.y, p.x - o.x)
            let base = toward * 180 / .pi
            for (i, r) in [s * 0.108, s * 0.14].enumerated() {
                let a = NSBezierPath()
                a.appendArc(withCenter: p, radius: r, startAngle: base - 32, endAngle: base + 32)
                a.lineWidth = s * 0.02; a.lineCapStyle = .round
                NSColor(white: 1, alpha: i == 0 ? 0.9 : 0.55).setStroke(); a.stroke()
            }
            _ = dir
        }
    }
    func atom(_ p: NSPoint, _ r: CGFloat, _ c: NSColor) {
        let rect = NSRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)
        let g = NSGradient(colors: [c.blended(withFraction: 0.65, of: .white)!, c, c.blended(withFraction: 0.4, of: .black)!])!
        g.draw(in: NSBezierPath(ovalIn: rect), relativeCenterPosition: NSPoint(x: -0.35, y: 0.4))
    }
    let hr = s * (small ? 0.105 : 0.078)
    atom(h1, hr, col(0.98, 0.98, 1.0)); atom(h2, hr, col(0.98, 0.98, 1.0))
    atom(o, s * (small ? 0.15 : 0.118), col(1.0, 0.78, 0.18))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base)@2x.png"))
}
print("wrote \(out)")
