import SceneKit
import simd
import MolCore

/// Builds the bond layer.
///
/// Ball-and-stick / tube: one SCNNode per `BondGeometry.renderSegments` piece, named "bond:<bondIndex>".
/// Every cylinder is a UNIT-height SCNCylinder (shared per (radius, color)); the node is placed at the
/// segment midpoint, rotated from +Y onto the segment direction, and scaled by the length along its local y.
/// Wireframe: a single `.line` SCNGeometry holding all bonds with per-vertex colors (one node, "bond:wire").
/// Children are in `renderSegments` order, which `updatePositions` relies on; if the number of pieces
/// changes (dashes depend on length) `updatePositions` returns false and the renderer rebuilds.
public enum BondLayerBuilder {
    static let wireNodeName = "bond:wire"

    private struct Key: Hashable { let r: Double; let c: RGBA }

    /// Returns a node named NodeName.bonds containing all visible bonds.
    public static func build(molecule: Molecule, options: RenderOptions, colors: [RGBA], materials: MaterialLibrary) -> SCNNode {
        let layer = SCNNode(); layer.name = NodeName.bonds
        let segs = BondGeometry.renderSegments(molecule: molecule, options: options, colors: colors)
        guard !segs.isEmpty else { return layer }
        if options.style == .wireframe {
            let node = SCNNode(geometry: wireGeometry(segs, materials: materials))
            node.name = wireNodeName
            layer.addChildNode(node)
            return layer
        }
        if MergedGeometry.isMergedBonds(molecule: molecule, options: options) {
            MergedGeometry.buildBonds(layer, segs: segs, options: options, materials: materials)
            return layer
        }
        let radial = SceneQuality.cylinderSegments(quality: options.geometryQuality, segmentCount: segs.count)
        var cache: [Key: SCNCylinder] = [:]
        var nodes: [SCNNode] = []
        nodes.reserveCapacity(segs.count)
        for s in segs {
            let key = Key(r: s.radius, c: s.color)
            let cyl: SCNCylinder
            if let c = cache[key] { cyl = c } else {
                cyl = SCNCylinder(radius: CGFloat(s.radius), height: 1)
                cyl.radialSegmentCount = radial
                cyl.heightSegmentCount = 1
                cyl.firstMaterial = materials.material(for: s.color)
                cache[key] = cyl
            }
            let node = SCNNode(geometry: cyl)
            node.name = NodeName.bond(s.bondIndex)
            place(node, s)
            nodes.append(node)
        }
        for n in nodes { layer.addChildNode(n) }
        return layer
    }

    /// Position/orientation/scale a unit cylinder node onto a segment.
    static func place(_ node: SCNNode, _ s: BondSegment) {
        let d = s.end - s.start
        node.simdPosition = SIMD3<Float>((s.start + s.end) / 2)
        node.simdOrientation = RenderMath.orientationFromY(to: d)
        node.simdScale = SIMD3<Float>(1, Float(simd_length(d)), 1)
    }

    static func wireGeometry(_ segs: [BondSegment], materials: MaterialLibrary) -> SCNGeometry {
        var verts = [SIMD3<Float>](); verts.reserveCapacity(segs.count * 2)
        var cols = [SIMD4<Float>](); cols.reserveCapacity(segs.count * 2)
        var idx = [UInt32](); idx.reserveCapacity(segs.count * 2)
        for s in segs {
            let c = SIMD4<Float>(Float(s.color.r), Float(s.color.g), Float(s.color.b), Float(s.color.a))
            idx.append(UInt32(verts.count)); verts.append(SIMD3<Float>(s.start)); cols.append(c)
            idx.append(UInt32(verts.count)); verts.append(SIMD3<Float>(s.end)); cols.append(c)
        }
        let vSrc = SCNGeometrySource(data: verts.withUnsafeBufferPointer { Data(buffer: $0) }, semantic: .vertex,
                                     vectorCount: verts.count, usesFloatComponents: true, componentsPerVector: 3,
                                     bytesPerComponent: 4, dataOffset: 0, dataStride: MemoryLayout<SIMD3<Float>>.stride)
        let cSrc = SCNGeometrySource(data: cols.withUnsafeBufferPointer { Data(buffer: $0) }, semantic: .color,
                                     vectorCount: cols.count, usesFloatComponents: true, componentsPerVector: 4,
                                     bytesPerComponent: 4, dataOffset: 0, dataStride: MemoryLayout<SIMD4<Float>>.stride)
        let el = SCNGeometryElement(data: idx.withUnsafeBufferPointer { Data(buffer: $0) }, primitiveType: .line,
                                    primitiveCount: segs.count, bytesPerIndex: 4)
        let g = SCNGeometry(sources: [vSrc, cSrc], elements: [el])
        g.firstMaterial = materials.lineMaterial()
        return g
    }

    public static func updatePositions(_ layer: SCNNode, molecule: Molecule, options: RenderOptions) -> Bool {
        guard layer.name == NodeName.bonds else { return false }
        // Colors only matter for the wire geometry rebuild; recompute them.
        let colors = RenderMetrics.atomColors(for: molecule, options: options)
        let segs = BondGeometry.renderSegments(molecule: molecule, options: options, colors: colors)
        let children = layer.childNodes
        if options.style == .wireframe {
            if segs.isEmpty { return children.isEmpty }
            guard children.count == 1, children[0].name == wireNodeName, let mat = children[0].geometry?.firstMaterial else { return false }
            let g = wireGeometry(segs, materials: MaterialLibrary())
            g.firstMaterial = mat
            children[0].geometry = g
            return true
        }
        if MergedGeometry.isMergedBonds(molecule: molecule, options: options) {
            return MergedGeometry.updateBonds(layer, segs: segs, options: options)
        }
        guard children.count == segs.count else { return false }
        for (node, s) in zip(children, segs) {
            guard node.name == NodeName.bond(s.bondIndex) else { return false }
            place(node, s)
        }
        return true
    }
}
