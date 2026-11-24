import SceneKit
import simd
import MolCore

public enum HighlightLayerBuilder {
    /// Translucent halos for selected atoms, the hovered atom and the hovered bond. One geometry per distinct
    /// radius and one material per color are shared by all nodes, so 1000+ selected atoms stay cheap.
    public static func build(molecule: Molecule, options: RenderOptions, selection: Set<Int>, hovered: PickTarget) -> SCNNode {
        let layer = SCNNode(); layer.name = NodeName.highlight
        let selMat = material(options.selectionColor)
        let hovMat = material(options.hoverColor)
        var spheres: [Int: SCNSphere] = [:]
        let seg = selection.count > 400 ? 8 : 16

        func halo(_ i: Int, _ mat: SCNMaterial, extra: Double) -> SCNNode? {
            guard i >= 0, i < molecule.atoms.count else { return nil }
            let a = molecule.atoms[i]
            guard RenderMetrics.isAtomVisible(a, options: options) else { return nil }
            let r = RenderMetrics.atomRadius(atomicNumber: a.atomicNumber, options: options) * 1.25 + 0.1 + extra
            let key = Int((r * 1000).rounded()) &* 4 &+ (mat === hovMat ? 1 : 0)
            let g: SCNSphere
            if let s = spheres[key] { g = s } else {
                g = SCNSphere(radius: CGFloat(r)); g.segmentCount = seg; g.firstMaterial = mat
                spheres[key] = g
            }
            let n = SCNNode(geometry: g)
            n.simdPosition = SIMD3<Float>(Float(a.position.x), Float(a.position.y), Float(a.position.z))
            n.renderingOrder = extra > 0 ? 12 : 10
            n.name = "highlight.atom:\(i)"
            return n
        }
        for i in selection.sorted() { if let n = halo(i, selMat, extra: 0) { layer.addChildNode(n) } }

        switch hovered {
        case .atom(let i):
            if let n = halo(i, hovMat, extra: 0.04) { n.name = "highlight.hover"; layer.addChildNode(n) }
        case .bond(let k):
            guard k >= 0, k < molecule.bonds.count else { break }
            let b = molecule.bonds[k]
            guard RenderMetrics.isBondVisible(b, in: molecule, options: options) else { break }
            let p = molecule.atoms[b.a].position, q = molecule.atoms[b.b].position
            let len = simd_length(q - p)
            guard len > 1e-9 else { break }
            let r = max(RenderMetrics.bondRadius(options: options), 0.06) * 1.6 + 0.04
            let g = SCNCylinder(radius: CGFloat(r), height: CGFloat(len)); g.radialSegmentCount = 16; g.firstMaterial = hovMat
            let n = SCNNode(geometry: g)
            let m = (p + q) / 2
            n.simdPosition = SIMD3<Float>(Float(m.x), Float(m.y), Float(m.z))
            n.simdOrientation = RenderMath.orientationFromY(to: q - p)
            n.renderingOrder = 12; n.name = "highlight.hover"
            layer.addChildNode(n)
        case .none: break
        }
        return layer
    }

    /// Fresnel rim: transparent in the middle, bright at the silhouette, so the halo reads as an outline/glow.
    static let rimShader = """
    float3 n = normalize(_surface.normal);
    float3 v = normalize(_surface.view);
    float rim = pow(clamp(1.0 - abs(dot(n, v)), 0.0, 1.0), 2.2);
    float k = clamp(0.12 + 1.5 * rim, 0.0, 1.0);
    _output.color *= k;
    """

    static func material(_ c: RGBA) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = c.nsColor
        m.transparency = 1
        m.isDoubleSided = false
        m.readsFromDepthBuffer = true
        m.writesToDepthBuffer = false
        m.blendMode = .alpha
        m.shaderModifiers = [.fragment: rimShader]
        return m
    }
}
