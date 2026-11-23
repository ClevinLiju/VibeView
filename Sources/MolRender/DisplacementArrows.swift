import SceneKit
import simd
import MolCore

public enum DisplacementArrowBuilder {
    public static let minimumLength = 0.05
    public struct Arrow: Sendable, Equatable { public var atom: Int; public var start: Vec3; public var end: Vec3 }

    /// Pure helper: arrows (atom start -> start + d*scale) with length >= minimumLength.
    public static func arrows(molecule: Molecule, mode: NormalMode, scale: Double) -> [Arrow] {
        var out: [Arrow] = []
        for i in 0..<min(molecule.atoms.count, mode.displacements.count) {
            let d = mode.displacements[i] * scale
            let l = simd_length(d)
            guard l.isFinite, l >= minimumLength else { continue }
            let p = molecule.atoms[i].position
            out.append(Arrow(atom: i, start: p, end: p + d))
        }
        return out
    }

    public static func build(molecule: Molecule, mode: NormalMode, scale: Double, color: RGBA) -> SCNNode {
        let n = SCNNode(); n.name = NodeName.vectors
        let mat = SCNMaterial()
        mat.diffuse.contents = color.nsColor
        mat.lightingModel = .blinn
        let shaft = SCNCylinder(radius: 0.04, height: 1); shaft.radialSegmentCount = 12; shaft.materials = [mat]
        let head = SCNCone(topRadius: 0, bottomRadius: 0.10, height: 1); head.radialSegmentCount = 16; head.materials = [mat]
        for a in arrows(molecule: molecule, mode: mode, scale: scale) {
            let d = a.end - a.start
            let len = simd_length(d)
            let headLen = min(0.3, len * 0.4)
            let shaftLen = len - headLen
            let arrow = SCNNode(); arrow.name = "arrow:\(a.atom)"
            arrow.simdPosition = SIMD3<Float>(a.start)
            arrow.simdOrientation = RenderMath.orientationFromY(to: d)
            let s = SCNNode(geometry: shaft)
            s.scale = SCNVector3(1, CGFloat(shaftLen), 1)
            s.position = SCNVector3(0, CGFloat(shaftLen / 2), 0)
            let h = SCNNode(geometry: head)
            h.scale = SCNVector3(1, CGFloat(headLen), 1)
            h.position = SCNVector3(0, CGFloat(shaftLen + headLen / 2), 0)
            arrow.addChildNode(s); arrow.addChildNode(h)
            n.addChildNode(arrow)
        }
        return n
    }
}
