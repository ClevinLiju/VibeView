import SceneKit
import AppKit
import simd
import MolCore

public enum LabelLayerBuilder {
    /// Label string for one atom (`index` is 0-based; shown 1-based). nil = no label.
    public static func text(for atom: Atom, index: Int, mode: LabelMode) -> String? {
        switch mode {
        case .none: return nil
        case .element: return ElementPalette.symbol(atom.atomicNumber)
        case .index: return "\(index + 1)"
        case .elementIndex: return "\(ElementPalette.symbol(atom.atomicNumber))\(index + 1)"
        case .charge: return String(format: "%+.3f", atom.charge)
        case .custom:
            guard let l = atom.label, !l.isEmpty else { return nil }
            return l
        }
    }

    public static func build(molecule: Molecule, options: RenderOptions) -> SCNNode {
        let layer = SCNNode(); layer.name = NodeName.labels
        guard options.labelMode != .none else { return layer }
        var planes: [String: SCNPlane] = [:]
        let color = options.theme.foreground
        let h = max(0.05, options.labelSize)
        for (i, a) in molecule.atoms.enumerated() where RenderMetrics.isAtomVisible(a, options: options) {
            guard let s = text(for: a, index: i, mode: options.labelMode) else { continue }
            let r = RenderMetrics.atomRadius(atomicNumber: a.atomicNumber, options: options)
            let n = labelNode(text: s, color: color, height: h, anchorOffset: r * 0.72, planes: &planes)
            n.name = "label:\(i)"
            n.simdPosition = SIMD3<Float>(Float(a.position.x), Float(a.position.y), Float(a.position.z))
            layer.addChildNode(n)
        }
        return layer
    }

    /// Billboard node (camera-facing) holding a text plane offset up-right of its origin by `anchorOffset`.
    static func labelNode(text: String, color: RGBA, height h: Double, anchorOffset: Double,
                          planes: inout [String: SCNPlane]) -> SCNNode {
        let key = "\(text)|\(color.r),\(color.g),\(color.b),\(color.a)|\(h)"
        let plane: SCNPlane
        if let p = planes[key] { plane = p } else {
            let (img, aspect) = LabelImageCache.image(text: text, color: color)
            plane = SCNPlane(width: CGFloat(h * aspect), height: CGFloat(h))
            let m = SCNMaterial()
            m.lightingModel = .constant
            m.diffuse.contents = img
            m.isDoubleSided = true
            m.readsFromDepthBuffer = false
            m.writesToDepthBuffer = false
            plane.firstMaterial = m
            planes[key] = plane
        }
        let holder = SCNNode()
        let bb = SCNBillboardConstraint(); bb.freeAxes = .all
        holder.constraints = [bb]
        let child = SCNNode(geometry: plane)
        child.position = SCNVector3(anchorOffset + Double(plane.width) / 2, anchorOffset + h / 2, 0)
        child.renderingOrder = 100
        holder.addChildNode(child)
        return holder
    }
}

/// Renders text to a transparent image (cached per string + color).
final class LabelImageCache: @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: (NSImage, Double)] = [:]

    static func image(text: String, color: RGBA) -> (NSImage, Double) {
        let key = "\(text)|\(color.r),\(color.g),\(color.b),\(color.a)"
        lock.lock(); defer { lock.unlock() }
        if let c = cache[key] { return c }
        let font = NSFont.systemFont(ofSize: 64, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color.nsColor]
        let str = NSAttributedString(string: text, attributes: attrs)
        let sz = str.size()
        let pad: CGFloat = 8
        let w = Int(ceil(sz.width + 2 * pad)), hgt = Int(ceil(sz.height + 2 * pad))
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: w, height: hgt, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let gc = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gc
        // soft halo for legibility over any background
        let halo = NSShadow()
        halo.shadowColor = NSColor(white: color.r + color.g + color.b > 1.5 ? 0 : 1, alpha: 0.8)
        halo.shadowBlurRadius = 6; halo.shadowOffset = .zero
        halo.set()
        str.draw(at: NSPoint(x: pad, y: pad))
        NSGraphicsContext.restoreGraphicsState()
        let img = NSImage(cgImage: ctx.makeImage()!, size: NSSize(width: w, height: hgt))
        let out = (img, Double(w) / Double(hgt))
        cache[key] = out
        return out
    }
}
