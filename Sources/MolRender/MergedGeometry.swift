import SceneKit
import simd
import MolCore

/// Merged (instanced-by-copy) geometry for big structures: all atoms / bond segments of a chunk live in
/// one SCNGeometry (one SCNGeometryElement + material per distinct color). Chunk k of the layer holds
/// displayed atoms [k*chunk, (k+1)*chunk) (atoms) or render segments [k*chunk, ...) (bonds), in order, so
/// the per-chunk layout is deterministic and `update` can regenerate vertices in place.
enum MergedGeometry {
    static let atomChunk = 4096
    static let bondChunk = 8192
    static let atomPrefix = "atoms:merged:"
    static let bondPrefix = "bonds:merged:"

    struct SphereTemplate { let positions: [SIMD3<Float>]; let indices: [UInt32] }

    /// Unit UV sphere without a duplicated seam; positions double as normals.
    static func unitSphere(lon: Int, lat: Int) -> SphereTemplate {
        let lon = max(3, lon), lat = max(3, lat)
        var p: [SIMD3<Float>] = [SIMD3(0, 1, 0)]
        for i in 1..<lat {
            let th = Float.pi * Float(i) / Float(lat)
            for k in 0..<lon {
                let ph = 2 * Float.pi * Float(k) / Float(lon)
                p.append(SIMD3(sin(th) * cos(ph), cos(th), sin(th) * sin(ph)))
            }
        }
        p.append(SIMD3(0, -1, 0))
        let bottom = UInt32(p.count - 1)
        func r(_ row: Int, _ k: Int) -> UInt32 { UInt32(1 + (row - 1) * lon + (k % lon)) }
        var idx: [UInt32] = []
        for k in 0..<lon { idx += [0, r(1, k + 1), r(1, k)] }
        if lat > 2 {
            for row in 1..<(lat - 1) { for k in 0..<lon {
                let p0 = r(row, k), p1 = r(row, k + 1), p2 = r(row + 1, k), p3 = r(row + 1, k + 1)
                idx += [p0, p1, p2, p1, p3, p2]
            } }
        }
        for k in 0..<lon { idx += [bottom, r(lat - 1, k), r(lat - 1, k + 1)] }
        return SphereTemplate(positions: p, indices: idx)
    }

    static func source(_ v: [SIMD3<Float>], _ semantic: SCNGeometrySource.Semantic) -> SCNGeometrySource {
        SCNGeometrySource(data: v.withUnsafeBufferPointer { Data(buffer: $0) }, semantic: semantic,
                          vectorCount: v.count, usesFloatComponents: true, componentsPerVector: 3,
                          bytesPerComponent: 4, dataOffset: 0, dataStride: MemoryLayout<SIMD3<Float>>.stride)
    }
    static func element(_ idx: [UInt32]) -> SCNGeometryElement {
        SCNGeometryElement(data: idx.withUnsafeBufferPointer { Data(buffer: $0) }, primitiveType: .triangles,
                           primitiveCount: idx.count / 3, bytesPerIndex: 4)
    }

    /// Color groups in first-appearance order.
    struct Groups {
        var order: [RGBA] = []
        var slot: [RGBA: Int] = [:]
        var indices: [[UInt32]] = []
        mutating func index(for c: RGBA) -> Int {
            if let s = slot[c] { return s }
            slot[c] = order.count; order.append(c); indices.append([]); return order.count - 1
        }
    }

    static func assemble(_ name: String, verts: [SIMD3<Float>], normals: [SIMD3<Float>], groups: Groups, materials: MaterialLibrary) -> SCNNode {
        let g = SCNGeometry(sources: [source(verts, .vertex), source(normals, .normal)], elements: groups.indices.map(element))
        g.materials = groups.order.map { materials.material(for: $0) }
        let n = SCNNode(geometry: g); n.name = name
        return n
    }

    /// Replace the vertex (and optionally normal) source, keeping elements and materials.
    static func replace(_ node: SCNNode, verts: [SIMD3<Float>], normals: [SIMD3<Float>]?) {
        guard let old = node.geometry else { return }
        let nSrc = normals.map { source($0, .normal) } ?? old.sources(for: .normal).first
        let g = SCNGeometry(sources: [source(verts, .vertex)] + (nSrc.map { [$0] } ?? []), elements: old.elements)
        g.materials = old.materials
        node.geometry = g
    }

    static func vertexCount(_ node: SCNNode) -> Int { node.geometry?.sources(for: .vertex).first?.vectorCount ?? -1 }

    // MARK: Atoms

    static func atomSegments(_ o: RenderOptions, _ count: Int) -> (lon: Int, lat: Int) {
        let lon = SceneQuality.mergedSphereSegments(quality: o.geometryQuality, atomCount: count)
        return (lon, max(4, lon * 2 / 3))
    }

    private static func atomVerts(_ slice: ArraySlice<Int>, molecule: Molecule, options: RenderOptions, tpl: SphereTemplate) -> [SIMD3<Float>] {
        let V = tpl.positions.count
        var verts = [SIMD3<Float>](repeating: .zero, count: slice.count * V)
        verts.withUnsafeMutableBufferPointer { out in
            tpl.positions.withUnsafeBufferPointer { t in
                var o = 0
                for i in slice {
                    let a = molecule.atoms[i]
                    let c = SIMD3<Float>(a.position), r = Float(AtomLayerBuilder.radius(of: a, options: options))
                    for v in 0..<V { out[o + v] = c + t[v] * r }
                    o += V
                }
            }
        }
        return verts
    }

    static func buildAtoms(_ layer: SCNNode, idx: [Int], molecule: Molecule, options: RenderOptions, colors: [RGBA], materials: MaterialLibrary) {
        let (lon, lat) = atomSegments(options, idx.count)
        let tpl = unitSphere(lon: lon, lat: lat)
        let V = tpl.positions.count
        var n = 0, start = 0
        while start < idx.count {
            let end = min(idx.count, start + atomChunk)
            let slice = idx[start..<end]
            let verts = atomVerts(slice, molecule: molecule, options: options, tpl: tpl)
            var normals = [SIMD3<Float>](); normals.reserveCapacity(verts.count)
            var groups = Groups()
            for (j, i) in slice.enumerated() {
                normals.append(contentsOf: tpl.positions)
                let color = i < colors.count ? colors[i] : ElementPalette.color(molecule.atoms[i].atomicNumber)
                let g = groups.index(for: color)
                let base = UInt32(j * V)
                groups.indices[g].reserveCapacity(groups.indices[g].count + tpl.indices.count)
                for t in tpl.indices { groups.indices[g].append(t + base) }
            }
            layer.addChildNode(assemble(atomPrefix + "\(n)", verts: verts, normals: normals, groups: groups, materials: materials))
            n += 1; start = end
        }
    }

    static func updateAtoms(_ layer: SCNNode, idx: [Int], molecule: Molecule, options: RenderOptions) -> Bool {
        let children = layer.childNodes
        guard children.count == (idx.count + atomChunk - 1) / atomChunk else { return false }
        let (lon, lat) = atomSegments(options, idx.count)
        let tpl = unitSphere(lon: lon, lat: lat)
        var start = 0
        for (n, node) in children.enumerated() {
            let end = min(idx.count, start + atomChunk)
            guard node.name == atomPrefix + "\(n)", vertexCount(node) == (end - start) * tpl.positions.count else { return false }
            start = end
        }
        start = 0
        for node in children {
            let end = min(idx.count, start + atomChunk)
            replace(node, verts: atomVerts(idx[start..<end], molecule: molecule, options: options, tpl: tpl), normals: nil)
            start = end
        }
        return true
    }

    // MARK: Bonds

    static func isMergedBonds(molecule: Molecule, options: RenderOptions) -> Bool {
        options.style != .wireframe && molecule.atoms.count > AtomLayerBuilder.mergeThreshold
    }

    private static func ring(_ radial: Int) -> [SIMD2<Float>] {
        (0..<radial).map { k in let a = 2 * Float.pi * Float(k) / Float(radial); return SIMD2(cos(a), sin(a)) }
    }

    private static func bondVerts(_ segs: ArraySlice<BondSegment>, radial: Int) -> ([SIMD3<Float>], [SIMD3<Float>]) {
        let ring = ring(radial)
        let V = 2 * radial
        var verts = [SIMD3<Float>](repeating: .zero, count: segs.count * V)
        var normals = verts
        verts.withUnsafeMutableBufferPointer { vo in normals.withUnsafeMutableBufferPointer { no in
            var o = 0
            for s in segs {
                let a = SIMD3<Float>(s.start), b = SIMD3<Float>(s.end)
                let d = b - a
                let len = simd_length(d)
                var y = SIMD3<Float>(0, 1, 0)
                if len > 1e-9 { y = d / len }
                let helper: SIMD3<Float> = abs(y.y) < 0.9 ? SIMD3(0, 1, 0) : SIMD3(1, 0, 0)
                let u = simd_normalize(simd_cross(helper, y))
                let v = simd_cross(y, u)
                let r = Float(s.radius)
                for k in 0..<radial {
                    let dir = u * ring[k].x + v * ring[k].y
                    vo[o + k] = a + dir * r; vo[o + radial + k] = b + dir * r
                    no[o + k] = dir; no[o + radial + k] = dir
                }
                o += V
            }
        } }
        return (verts, normals)
    }

    private static func bondTemplate(_ radial: Int) -> [UInt32] {
        var idx: [UInt32] = []
        for k in 0..<radial {
            let b0 = UInt32(k), b1 = UInt32((k + 1) % radial), t0 = UInt32(radial + k), t1 = UInt32(radial + (k + 1) % radial)
            idx += [b0, b1, t0, b1, t1, t0]
        }
        return idx
    }

    static func buildBonds(_ layer: SCNNode, segs: [BondSegment], options: RenderOptions, materials: MaterialLibrary) {
        let radial = SceneQuality.mergedCylinderSegments(quality: options.geometryQuality, segmentCount: segs.count)
        let tpl = bondTemplate(radial)
        var n = 0, start = 0
        while start < segs.count {
            let end = min(segs.count, start + bondChunk)
            let slice = segs[start..<end]
            let (verts, normals) = bondVerts(slice, radial: radial)
            var groups = Groups()
            for (j, s) in slice.enumerated() {
                let g = groups.index(for: s.color)
                let base = UInt32(j * 2 * radial)
                for t in tpl { groups.indices[g].append(t + base) }
            }
            layer.addChildNode(assemble(bondPrefix + "\(n)", verts: verts, normals: normals, groups: groups, materials: materials))
            n += 1; start = end
        }
    }

    static func updateBonds(_ layer: SCNNode, segs: [BondSegment], options: RenderOptions) -> Bool {
        let children = layer.childNodes
        guard children.count == (segs.count + bondChunk - 1) / bondChunk else { return false }
        let radial = SceneQuality.mergedCylinderSegments(quality: options.geometryQuality, segmentCount: segs.count)
        var start = 0
        for (n, node) in children.enumerated() {
            let end = min(segs.count, start + bondChunk)
            guard node.name == bondPrefix + "\(n)", vertexCount(node) == (end - start) * 2 * radial else { return false }
            start = end
        }
        start = 0
        for node in children {
            let end = min(segs.count, start + bondChunk)
            let (v, nrm) = bondVerts(segs[start..<end], radial: radial)
            replace(node, verts: v, normals: nrm)
            start = end
        }
        return true
    }
}
