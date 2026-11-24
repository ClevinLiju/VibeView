import AppKit
import SceneKit
import simd
import MolCore
import MolRender

/// Renders VibeView's app icon with the app's own renderer: two water molecules side by side, each bent like a
/// "V", together reading as a "W", on a rounded-square macOS tile.
/// `VibeView --render-icon <dir.iconset>` writes every iconset size and exits (used by scripts/make-app.sh).
@MainActor
enum IconRenderer {
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--render-icon"), i + 1 < args.count else { return false }
        let out = URL(fileURLWithPath: args[i + 1])
        do {
            try render(to: out)
            print("wrote \(out.path)")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("icon render failed: \(error)\n".utf8))
            exit(1)
        }
    }

    /// Two waters with real geometry (0.96 Å, 104.5°): O at the bottom of each V, hydrogens up. Each molecule is
    /// turned about its own vertical axis by `turn` so its V looks narrower from the front (outer H toward the
    /// viewer, inner H away); the inner hydrogens meet in the middle of the W.
    static let turn = 58.0 * Double.pi / 180
    static func molecule() -> Molecule {
        var m = Molecule()
        let half = 104.5 / 2 * Double.pi / 180, r = 0.96
        let dx = r * sin(half), dy = r * cos(half)
        let px = dx * cos(turn), pz = dx * sin(turn)        // projected half-width and depth of each V
        let gap = 0.06
        for side in [-1.0, 1.0] {
            let cx = side * (px + gap)
            let o = m.atoms.count
            m.atoms.append(Atom(id: o, atomicNumber: 8, position: Vec3(cx, 0, 0)))
            m.atoms.append(Atom(id: o + 1, atomicNumber: 1, position: Vec3(cx + side * px, dy, pz)))    // outer, toward viewer
            m.atoms.append(Atom(id: o + 2, atomicNumber: 1, position: Vec3(cx - side * px, dy, -pz)))   // inner, behind
            m.bonds.append(Bond(o, o + 1)); m.bonds.append(Bond(o, o + 2))
        }
        return m
    }

    static func moleculeImage(pixels: Int, bold: Bool) throws -> CGImage {
        var o = RenderOptions()
        o.style = .ballAndStick
        o.material = .glossy
        o.ambientOcclusion = true
        o.shadows = false
        o.depthCueing = false
        o.atomScale = bold ? 0.24 : 0.2
        o.bondRadius = bold ? 0.2 : 0.16
        o.showBondOrders = false
        o.transparentBackground = true
        let r = MoleculeRenderer(molecule: Molecule(), options: o)
        r.view.frame = NSRect(x: 0, y: 0, width: 512, height: 512)
        r.camera.projection = .orthographic
        r.camera.setStandardView(.front, animated: false)
        // Express the molecule in the camera's own axes so the view is exactly frontal (no elevation).
        let right = simd_normalize(r.camera.rightVector), up = simd_normalize(r.camera.upVector)
        let toViewer = -simd_normalize(r.camera.lookDirection)
        var m = molecule()
        let c0 = m.centroid
        for i in m.atoms.indices {
            let p = m.atoms[i].position - c0
            m.atoms[i].position = right * p.x + up * p.y + toViewer * p.z
        }
        r.setMolecule(m, fitCamera: false)
        r.camera.fit(center: .zero, radius: bold ? 1.12 : 1.22, animated: false)
        var e = ImageExportOptions()
        e.widthPoints = Double(pixels); e.heightPoints = Double(pixels); e.dpi = 72
        e.transparentBackground = true
        e.supersampling = 2
        return try r.renderImage(e)
    }

    static func tile(size px: Int, molecule img: CGImage, small: Bool) -> Data {
        let s = CGFloat(px)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        let inset = s * (small ? 0.04 : 0.098)
        let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
        let radius = rect.width * 0.225
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        if !small {
            let sh = NSShadow(); sh.shadowColor = NSColor(white: 0, alpha: 0.35)
            sh.shadowBlurRadius = s * 0.025; sh.shadowOffset = NSSize(width: 0, height: -s * 0.01)
            NSGraphicsContext.saveGraphicsState(); sh.set(); NSColor.black.setFill(); path.fill(); NSGraphicsContext.restoreGraphicsState()
        }
        NSGradient(colors: [NSColor(srgbRed: 0.07, green: 0.12, blue: 0.30, alpha: 1),
                            NSColor(srgbRed: 0.10, green: 0.33, blue: 0.62, alpha: 1),
                            NSColor(srgbRed: 0.18, green: 0.62, blue: 0.78, alpha: 1)])!.draw(in: path, angle: 90)
        // Soft glow behind the molecules.
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        let glowR = rect.width * 0.55
        NSGradient(colors: [NSColor(white: 1, alpha: 0.22), NSColor(white: 1, alpha: 0)])!
            .draw(fromCenter: NSPoint(x: rect.midX, y: rect.midY + rect.height * 0.04), radius: 0,
                  toCenter: NSPoint(x: rect.midX, y: rect.midY + rect.height * 0.04), radius: glowR, options: [])
        // The rendered W fills most of the tile width.
        let w = rect.width * (small ? 1.04 : 0.92)
        let mRect = NSRect(x: rect.midX - w / 2, y: rect.midY - w / 2 + rect.height * 0.02, width: w, height: w)
        if small { drawVectorW(in: rect) } else { NSImage(cgImage: img, size: mRect.size).draw(in: mRect) }
        NSGraphicsContext.restoreGraphicsState()
        // Thin highlight rim.
        NSColor(white: 1, alpha: 0.18).setStroke(); path.lineWidth = max(1, s * 0.004); path.stroke()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    /// Small sizes: the same W drawn as flat shapes (projected coordinates of `molecule()`), which stays legible
    /// at 16–64 px where shaded spheres turn into blobs.
    static func drawVectorW(in rect: NSRect) {
        let m = molecule()
        let pts = m.atoms.map { CGPoint(x: $0.position.x, y: $0.position.y) }
        let minX = pts.map(\.x).min()!, maxX = pts.map(\.x).max()!, minY = pts.map(\.y).min()!, maxY = pts.map(\.y).max()!
        let scale = rect.width * 0.62 / (maxX - minX)
        let cx = rect.midX, cy = rect.midY - rect.height * 0.02
        func P(_ p: CGPoint) -> CGPoint { CGPoint(x: cx + (p.x - (minX + maxX) / 2) * scale, y: cy + (p.y - (minY + maxY) / 2) * scale * 1.35) }
        let lw = rect.width * 0.11
        let path = NSBezierPath()
        // H–O–H–O–H outline: outer H (1), O (0), inner H (2) | inner H (5), O (3), outer H (4)
        let order = [1, 0, 2, 5, 3, 4]
        path.move(to: P(pts[order[0]]))
        for k in order.dropFirst() { path.line(to: P(pts[k])) }
        path.lineWidth = lw; path.lineJoinStyle = .round; path.lineCapStyle = .round
        NSColor(white: 0.96, alpha: 1).setStroke(); path.stroke()
        func dot(_ i: Int, _ r: CGFloat, _ c: NSColor) {
            let p = P(pts[i]); c.setFill()
            NSBezierPath(ovalIn: NSRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)).fill()
        }
        for i in [0, 3] { dot(i, lw * 1.05, NSColor(srgbRed: 0.93, green: 0.16, blue: 0.16, alpha: 1)) }
    }

    static func render(to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let big = try moleculeImage(pixels: 1024, bold: false)
        let bold = try moleculeImage(pixels: 256, bold: true)
        for base in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let px = base * scale
                let small = px <= 64
                let data = tile(size: px, molecule: small ? bold : big, small: small)
                let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
                try data.write(to: dir.appendingPathComponent(name))
            }
        }
    }
}
