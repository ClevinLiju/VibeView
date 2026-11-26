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

    /// Bytes per packed vertex (three Floats, no SIMD padding: 12 instead of the 16 of `SIMD3<Float>`).
    static let packedStride = 3 * MemoryLayout<Float>.size

    /// Packed (12-byte stride) source; the merged meshes are large, so the padding of `SIMD3<Float>` is not kept.
    static func source(_ v: [SIMD3<Float>], _ semantic: SCNGeometrySource.Semantic) -> SCNGeometrySource {
        source(count: v.count, semantic) { out in for (i, p) in v.enumerated() { out[3 * i] = p.x; out[3 * i + 1] = p.y; out[3 * i + 2] = p.z } }
    }
    /// Packed source of `count` vectors written by `fill` (3 Floats per vector) straight into the source's storage.
    static func source(count: Int, _ semantic: SCNGeometrySource.Semantic,
                       fill: (UnsafeMutableBufferPointer<Float>) -> Void) -> SCNGeometrySource {
        var d = Data(count: count * packedStride)
        d.withUnsafeMutableBytes { raw in fill(raw.bindMemory(to: Float.self)) }
        return SCNGeometrySource(data: d, semantic: semantic, vectorCount: count, usesFloatComponents: true,
                                 componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: packedStride)
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
        assemble(name, sources: [source(verts, .vertex), source(normals, .normal)], groups: groups, materials: materials)
    }
    static func assemble(_ name: String, sources: [SCNGeometrySource], groups: Groups, materials: MaterialLibrary) -> SCNNode {
        let g = SCNGeometry(sources: sources, elements: groups.indices.map(element))
        g.materials = groups.order.map { materials.material(for: $0) }
        let n = SCNNode(geometry: g); n.name = name
        return n
    }

    /// Replace the vertex (and optionally normal) source, keeping elements and materials.
    static func replace(_ node: SCNNode, verts: [SIMD3<Float>], normals: [SIMD3<Float>]?) {
        replace(node, vertexSource: source(verts, .vertex), normalSource: normals.map { source($0, .normal) })
    }
    static func replace(_ node: SCNNode, vertexSource: SCNGeometrySource, normalSource: SCNGeometrySource?) {
        guard let old = node.geometry else { return }
        let nSrc = normalSource ?? old.sources(for: .normal).first
        let g = SCNGeometry(sources: [vertexSource] + (nSrc.map { [$0] } ?? []), elements: old.elements)
        g.materials = old.materials
        node.geometry = g
    }

    /// Node with one triangle element per colour for items (atoms / bond pieces) that each repeat the index template
    /// `tpl` offset by `item * stride` vertices. `colors[j]` is item j's colour; groups are in first-appearance order.
    /// Indices are written straight into each element's storage (exact size, no intermediate arrays).
    static func assembleTemplated(_ name: String, sources: [SCNGeometrySource], colors: [RGBA], tpl: [UInt32], stride: Int,
                                  materials: MaterialLibrary) -> SCNNode {
        var order: [RGBA] = [], slot: [RGBA: Int] = [:]
        var group = [Int](); group.reserveCapacity(colors.count)
        var perGroup = [Int]()
        for c in colors {
            let g: Int
            if let x = slot[c] { g = x } else { g = order.count; slot[c] = g; order.append(c); perGroup.append(0) }
            perGroup[g] += 1
            group.append(g)
        }
        // One exact-size buffer per colour, filled in a single pass and handed to Data without a copy.
        let bufs = perGroup.map { UnsafeMutablePointer<UInt32>.allocate(capacity: max(1, $0 * tpl.count)) }
        var cursor = [Int](repeating: 0, count: order.count)
        tpl.withUnsafeBufferPointer { t in
            for (j, g) in group.enumerated() {
                let base = UInt32(j * stride), out = bufs[g] + cursor[g]
                for k in 0..<t.count { out[k] = t[k] + base }
                cursor[g] += t.count
            }
        }
        let elements = bufs.indices.map { g in
            let count = perGroup[g] * tpl.count
            let d = Data(bytesNoCopy: bufs[g], count: count * MemoryLayout<UInt32>.size, deallocator: .custom { p, _ in
                p.assumingMemoryBound(to: UInt32.self).deallocate()
            })
            return SCNGeometryElement(data: d, primitiveType: .triangles, primitiveCount: count / 3, bytesPerIndex: 4)
        }
        let geo = SCNGeometry(sources: sources, elements: elements)
        geo.materials = order.map { materials.material(for: $0) }
        let n = SCNNode(geometry: geo); n.name = name
        return n
    }

    static func vertexCount(_ node: SCNNode) -> Int { node.geometry?.sources(for: .vertex).first?.vectorCount ?? -1 }

    // MARK: Atoms

    static func atomSegments(_ o: RenderOptions, _ count: Int) -> (lon: Int, lat: Int) {
        let lon = SceneQuality.mergedSphereSegments(quality: o.geometryQuality, atomCount: count)
        return (lon, max(4, lon * 2 / 3))
    }

    /// Packed vertex source for the atoms of `slice`: the template sphere scaled and moved onto each atom.
    private static func atomVertexSource(_ slice: ArraySlice<Int>, molecule: Molecule, options: RenderOptions, tpl: SphereTemplate) -> SCNGeometrySource {
        let V = tpl.positions.count
        return source(count: slice.count * V, .vertex) { out in
            tpl.positions.withUnsafeBufferPointer { t in
                var o = 0
                for i in slice {
                    let a = molecule.atoms[i]
                    let c = SIMD3<Float>(a.position), r = Float(AtomLayerBuilder.radius(of: a, options: options))
                    for v in 0..<V {
                        let p = c + t[v] * r
                        out[o] = p.x; out[o + 1] = p.y; out[o + 2] = p.z
                        o += 3
                    }
                }
            }
        }
    }

    static func buildAtoms(_ layer: SCNNode, idx: [Int], molecule: Molecule, options: RenderOptions, colors: [RGBA], materials: MaterialLibrary) {
        let (lon, lat) = atomSegments(options, idx.count)
        let tpl = unitSphere(lon: lon, lat: lat)
        let V = tpl.positions.count
        // Unit-sphere normals are the template positions, the same for every atom.
        let tplNormals = tpl.positions.flatMap { [$0.x, $0.y, $0.z] }
        var n = 0, start = 0
        while start < idx.count {
            let end = min(idx.count, start + atomChunk)
            let slice = idx[start..<end]
            let normals = source(count: slice.count * V, .normal) { out in
                tplNormals.withUnsafeBufferPointer { t in
                    for j in 0..<slice.count { UnsafeMutableBufferPointer(rebasing: out[(j * t.count)..<((j + 1) * t.count)]).initialize(from: t) }
                }
            }
            let colorOf = slice.map { i in i < colors.count ? colors[i] : ElementPalette.color(molecule.atoms[i].atomicNumber) }
            let verts = atomVertexSource(slice, molecule: molecule, options: options, tpl: tpl)
            layer.addChildNode(assembleTemplated(atomPrefix + "\(n)", sources: [verts, normals], colors: colorOf, tpl: tpl.indices,
                                                 stride: V, materials: materials))
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
            replace(node, vertexSource: atomVertexSource(idx[start..<end], molecule: molecule, options: options, tpl: tpl), normalSource: nil)
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

    /// Packed vertex and normal sources of the open cylinders of `segs`.
    private static func bondSources(_ segs: ArraySlice<BondSegment>, radial: Int) -> (SCNGeometrySource, SCNGeometrySource) {
        let ring = ring(radial)
        let V = 2 * radial
        var normalData = Data(count: segs.count * V * packedStride)
        let verts = source(count: segs.count * V, .vertex) { vo in normalData.withUnsafeMutableBytes { raw in
            let no = raw.bindMemory(to: Float.self)
            var o = 0
            @inline(__always) func put(_ buf: UnsafeMutableBufferPointer<Float>, _ at: Int, _ p: SIMD3<Float>) {
                buf[3 * at] = p.x; buf[3 * at + 1] = p.y; buf[3 * at + 2] = p.z
            }
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
                    put(vo, o + k, a + dir * r); put(vo, o + radial + k, b + dir * r)
                    put(no, o + k, dir); put(no, o + radial + k, dir)
                }
                o += V
            }
        } }
        let normals = SCNGeometrySource(data: normalData, semantic: .normal, vectorCount: segs.count * V, usesFloatComponents: true,
                                        componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: packedStride)
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
            let (verts, normals) = bondSources(slice, radial: radial)
            layer.addChildNode(assembleTemplated(bondPrefix + "\(n)", sources: [verts, normals], colors: slice.map(\.color), tpl: tpl,
                                                 stride: 2 * radial, materials: materials))
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
            let (v, nrm) = bondSources(segs[start..<end], radial: radial)
            replace(node, vertexSource: v, normalSource: nrm)
            start = end
        }
        return true
    }
}
