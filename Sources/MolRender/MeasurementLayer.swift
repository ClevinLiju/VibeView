import SceneKit
import AppKit
import simd
import MolCore

public enum MeasurementLayerBuilder {
    /// Overlay color for measurements (distinct from element/selection colors).
    public static let color = RGBA(0.95, 0.42, 0.05)

    public static func build(molecule: Molecule, options: RenderOptions) -> SCNNode {
        let layer = SCNNode(); layer.name = NodeName.measurements
        guard !options.measurements.isEmpty else { return layer }
        let mat = SCNMaterial()
        mat.lightingModel = .constant
        mat.diffuse.contents = color.nsColor
        mat.readsFromDepthBuffer = true
        mat.writesToDepthBuffer = false
        let unit = SCNCylinder(radius: 0.022, height: 1)
        unit.radialSegmentCount = 8
        unit.firstMaterial = mat
        var planes: [String: SCNPlane] = [:]
        let h = max(0.05, options.labelSize)

        func seg(_ p: Vec3, _ q: Vec3) -> SCNNode? {
            let len = simd_length(q - p)
            guard len > 1e-6 else { return nil }
            let n = SCNNode(geometry: unit)
            let m = (p + q) / 2
            n.simdPosition = SIMD3<Float>(Float(m.x), Float(m.y), Float(m.z))
            n.simdOrientation = RenderMath.orientationFromY(to: q - p)
            n.simdScale = SIMD3<Float>(1, Float(len), 1)
            n.renderingOrder = 50
            return n
        }
        func dashed(_ p: Vec3, _ q: Vec3, into parent: SCNNode) {
            let len = simd_length(q - p)
            guard len > 1e-6 else { return }
            let dash = 0.14, gap = 0.09
            let count = min(300, max(1, Int((len / (dash + gap)).rounded(.up))))
            let dir = (q - p) / len
            var s = 0.0
            for _ in 0..<count {
                let e = min(len, s + dash)
                if let n = seg(p + dir * s, p + dir * e) { parent.addChildNode(n) }
                s += dash + gap
                if s >= len { break }
            }
        }
        func label(_ text: String, at p: Vec3, into parent: SCNNode) {
            let n = LabelLayerBuilder.labelNode(text: text, color: color, height: h, anchorOffset: 0.05, planes: &planes)
            n.simdPosition = SIMD3<Float>(Float(p.x), Float(p.y), Float(p.z))
            parent.addChildNode(n)
        }

        for (mi, m) in options.measurements.enumerated() {
            guard let v = m.value(in: molecule) else { continue }
            let g = SCNNode(); g.name = "measurement:\(mi)"
            let P = m.atoms.map { molecule.atoms[$0].position }
            switch m {
            case .distance:
                dashed(P[0], P[1], into: g)
                label(String(format: "%.3f Å", v), at: (P[0] + P[1]) / 2, into: g)
            case .angle:
                dashed(P[1], P[0], into: g); dashed(P[1], P[2], into: g)
                let u = P[0] - P[1], w = P[2] - P[1]
                let lu = simd_length(u), lw = simd_length(w)
                var anchor = P[1]
                if lu > 1e-6, lw > 1e-6 {
                    let un = u / lu, wn = w / lw
                    let r = min(0.6, 0.5 * min(lu, lw))
                    let steps = 20
                    var prev = P[1] + un * r
                    let ang = acos(max(-1, min(1, simd_dot(un, wn))))
                    var axis = simd_cross(un, wn)
                    axis = simd_length(axis) > 1e-9 ? simd_normalize(axis) : RenderMath.perpendicular(to: un)
                    for k in 1...steps {
                        let d = VecMath.rotate(un, about: .zero, axis: axis, degrees: radToDeg(ang) * Double(k) / Double(steps))
                        let pt = P[1] + d * r
                        if let n = seg(prev, pt) { g.addChildNode(n) }
                        prev = pt
                    }
                    let bis = un + wn
                    let bl = simd_length(bis)
                    anchor = P[1] + (bl > 1e-9 ? bis / bl : RenderMath.perpendicular(to: un)) * (r * 1.25)
                }
                label(String(format: "%.1f°", v), at: anchor, into: g)
            case .dihedral:
                dashed(P[0], P[1], into: g); dashed(P[1], P[2], into: g); dashed(P[2], P[3], into: g)
                label(String(format: "%.1f°", v), at: (P[1] + P[2]) / 2, into: g)
            }
            layer.addChildNode(g)
        }
        return layer
    }
}

extension Measurement {
    /// Å for distance, degrees for angle/dihedral (dihedral signed, -180...180); nil if an index is out of range.
    public func value(in molecule: Molecule) -> Double? {
        let idx = atoms
        guard idx.allSatisfy({ $0 >= 0 && $0 < molecule.atoms.count }) else { return nil }
        let p = idx.map { molecule.atoms[$0].position }
        switch self {
        case .distance: return VecMath.distance(p[0], p[1])
        case .angle: return VecMath.angle(p[0], p[1], p[2])
        case .dihedral: return VecMath.dihedral(p[0], p[1], p[2], p[3])
        }
    }
}
