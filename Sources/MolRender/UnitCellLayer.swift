import SceneKit
import AppKit
import simd
import MolCore

/// Periodic box edges plus colored a/b/c axis stubs. Owned by Lead 3.
public enum UnitCellLayerBuilder {
    public static let axisColors = [RGBA(0.85, 0.15, 0.15), RGBA(0.15, 0.7, 0.2), RGBA(0.15, 0.3, 0.9)]

    public static func build(cell: UnitCell, options: RenderOptions) -> SCNNode {
        let n = SCNNode(); n.name = NodeName.cell
        let corners = cell.corners
        // All 12 edges in one line geometry.
        let verts = corners.map { SCNVector3($0) }
        var idx: [Int32] = []
        for (i, j) in UnitCell.edges { idx += [Int32(i), Int32(j)] }
        let src = SCNGeometrySource(vertices: verts)
        let el = SCNGeometryElement(indices: idx, primitiveType: .line)
        let g = SCNGeometry(sources: [src], elements: [el])
        let m = SCNMaterial(); m.lightingModel = .constant
        m.diffuse.contents = options.theme.foreground.withAlpha(0.8).nsColor
        g.materials = [m]
        let edges = SCNNode(geometry: g); edges.name = "cell.edges"
        n.addChildNode(edges)
        // Axis cylinders a, b, c from the origin (thin, colored, 1/3 of each vector).
        for (k, v) in [cell.a, cell.b, cell.c].enumerated() {
            let len = simd_length(v); guard len > 1e-6 else { continue }
            let axisLen = min(len, max(1.0, len / 3))
            let cyl = SCNCylinder(radius: 0.04, height: CGFloat(axisLen))
            let am = SCNMaterial(); am.lightingModel = .constant; am.diffuse.contents = axisColors[k].nsColor
            cyl.materials = [am]
            let an = SCNNode(geometry: cyl); an.name = "cell.axis.\(["a","b","c"][k])"
            let dir = v / len
            an.simdPosition = SIMD3<Float>(cell.origin + dir * axisLen / 2)
            an.simdOrientation = RenderMath.orientationFromY(to: dir)
            n.addChildNode(an)
        }
        return n
    }
}
