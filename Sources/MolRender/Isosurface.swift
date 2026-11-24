import SceneKit
import AppKit
import MolCore
import MolAnalysis

public enum SurfaceDisplayMode: String, Sendable, Codable, CaseIterable { case solid, mesh, points }

public struct Isosurface: Sendable {
    public var id: String
    public var meshes: [IsoSurfaceMesh]
    public var positiveColor: RGBA = RGBA(0.15, 0.35, 0.95)
    public var negativeColor: RGBA = RGBA(0.95, 0.25, 0.15)
    public var opacity: Double = 0.75
    public var mode: SurfaceDisplayMode = .solid
    public var visible: Bool = true
    public init(id: String, meshes: [IsoSurfaceMesh]) { self.id = id; self.meshes = meshes }
    /// Convenience: one optional mesh per lobe (their `sign` is forced to match).
    public init(id: String, positive: IsoSurfaceMesh?, negative: IsoSurfaceMesh?) {
        var m: [IsoSurfaceMesh] = []
        if var p = positive { p.sign = .positive; m.append(p) }
        if var n = negative { n.sign = .negative; m.append(n) }
        self.init(id: id, meshes: m)
    }
}

public enum IsosurfaceGeometry {
    /// Deduplicated undirected triangle edges as a flat index list (2 per edge). Incomplete trailing triangle ignored.
    public static func uniqueEdges(_ indices: [UInt32]) -> [UInt32] {
        var seen = Set<UInt64>()
        var out: [UInt32] = []
        var t = 0
        while t + 2 < indices.count {
            let a = indices[t], b = indices[t + 1], c = indices[t + 2]
            for (u, v) in [(a, b), (b, c), (c, a)] where u != v {
                let lo = min(u, v), hi = max(u, v)
                if seen.insert(UInt64(lo) << 32 | UInt64(hi)).inserted { out.append(lo); out.append(hi) }
            }
            t += 3
        }
        return out
    }

    /// Triangle indices with out-of-range / incomplete triangles removed.
    static func validIndices(_ mesh: IsoSurfaceMesh) -> [UInt32] {
        let n = UInt32(clamping: mesh.vertices.count)
        var out: [UInt32] = []
        out.reserveCapacity(mesh.indices.count)
        var t = 0
        while t + 2 < mesh.indices.count {
            let a = mesh.indices[t], b = mesh.indices[t + 1], c = mesh.indices[t + 2]
            if a < n && b < n && c < n { out.append(a); out.append(b); out.append(c) }
            t += 3
        }
        return out
    }

    /// Area-weighted smooth normals computed from the triangles.
    static func computeNormals(vertices: [SIMD3<Float>], indices: [UInt32]) -> [SIMD3<Float>] {
        var nrm = [SIMD3<Float>](repeating: .zero, count: vertices.count)
        var t = 0
        while t + 2 < indices.count {
            let a = Int(indices[t]), b = Int(indices[t + 1]), c = Int(indices[t + 2])
            let n = simd_cross(vertices[b] - vertices[a], vertices[c] - vertices[a])
            nrm[a] += n; nrm[b] += n; nrm[c] += n
            t += 3
        }
        return nrm.map { v in
            let l = simd_length(v)
            return l > 1e-12 ? v / l : SIMD3<Float>(0, 0, 1)
        }
    }

    /// Geometry for one lobe; nil if the mesh has no drawable content.
    public static func geometry(for mesh: IsoSurfaceMesh, mode: SurfaceDisplayMode) -> SCNGeometry? {
        guard !mesh.vertices.isEmpty else { return nil }
        let verts = mesh.vertices
        for v in verts where !(v.x.isFinite && v.y.isFinite && v.z.isFinite) { return finiteFallback(mesh, mode: mode) }
        return build(mesh, vertices: verts, mode: mode)
    }

    private static func finiteFallback(_ mesh: IsoSurfaceMesh, mode: SurfaceDisplayMode) -> SCNGeometry? {
        var m = mesh
        m.vertices = mesh.vertices.map { SIMD3<Float>($0.x.isFinite ? $0.x : 0, $0.y.isFinite ? $0.y : 0, $0.z.isFinite ? $0.z : 0) }
        return build(m, vertices: m.vertices, mode: mode)
    }

    private static func build(_ mesh: IsoSurfaceMesh, vertices verts: [SIMD3<Float>], mode: SurfaceDisplayMode) -> SCNGeometry? {
        var sources: [SCNGeometrySource] = [SCNGeometrySource(vertices: verts.map { SCNVector3($0) })]
        var elements: [SCNGeometryElement] = []
        switch mode {
        case .solid, .mesh:
            let idx = validIndices(mesh)
            guard !idx.isEmpty else { return nil }
            if mode == .solid {
                var normals = mesh.normals
                if normals.count != verts.count || normals.contains(where: { !($0.x.isFinite && $0.y.isFinite && $0.z.isFinite) }) {
                    normals = computeNormals(vertices: verts, indices: idx)
                }
                sources.append(SCNGeometrySource(normals: normals.map { SCNVector3($0) }))
                elements.append(SCNGeometryElement(indices: idx, primitiveType: .triangles))
            } else {
                let e = uniqueEdges(idx)
                guard !e.isEmpty else { return nil }
                elements.append(SCNGeometryElement(indices: e, primitiveType: .line))
            }
        case .points:
            let n = verts.count
            let idx = (0..<n).map { UInt32($0) }
            let el = SCNGeometryElement(indices: idx, primitiveType: .point)
            el.pointSize = 3
            el.minimumPointScreenSpaceRadius = 1.5
            el.maximumPointScreenSpaceRadius = 4
            elements.append(el)
        }
        if let cols = mesh.vertexColors, cols.count == verts.count {
            let data = cols.withUnsafeBufferPointer { Data(buffer: $0) }
            sources.append(SCNGeometrySource(data: data, semantic: .color, vectorCount: cols.count,
                                             usesFloatComponents: true, componentsPerVector: 4,
                                             bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0,
                                             dataStride: MemoryLayout<SIMD4<Float>>.stride))
        }
        return SCNGeometry(sources: sources, elements: elements)
    }
}

public enum IsosurfaceNodeBuilder {
    /// Draw after atoms/bonds.
    static let renderingOrder = 100

    /// Fragment modifier: alpha rises from `opacity` (facing) toward ~1 at the silhouette.
    static func fresnelModifier(opacity: Double) -> String {
        let base = String(format: "%.4f", max(0.05, opacity))
        return """
        #pragma transparent
        #pragma body
        float3 V = normalize(-_surface.position);
        float f = pow(1.0 - abs(dot(normalize(_surface.normal), V)), 3.0);
        float k = mix(1.0, 1.0 / \(base), f * 0.85);
        _output.color = min(_output.color * k, float4(1.0));
        """
    }

    public static func build(_ s: Isosurface) -> SCNNode {
        let node = SCNNode(); node.name = "surface:\(s.id)"
        let opacity = max(0, min(1, s.opacity))
        for mesh in s.meshes where !mesh.isEmpty || (s.mode == .points && !mesh.vertices.isEmpty) {
            guard let g = IsosurfaceGeometry.geometry(for: mesh, mode: s.mode) else { continue }
            let color = mesh.sign == .positive ? s.positiveColor : s.negativeColor
            let hasVC = mesh.vertexColors?.count == mesh.vertices.count
            let m = SCNMaterial()
            m.diffuse.contents = hasVC ? NSColor.white : color.nsColor
            if s.mode == .solid {
                // Glossy PBR "glass-candy" look; a fresnel term raises opacity at grazing angles so
                // translucent lobes keep a crisp silhouette while showing the atoms inside.
                m.lightingModel = .physicallyBased
                m.roughness.contents = NSNumber(value: 0.3)
                m.metalness.contents = NSNumber(value: 0.0)
                m.clearCoat.contents = NSNumber(value: 0.6)
                m.clearCoatRoughness.contents = NSNumber(value: 0.08)
                if opacity < 1 {
                    m.shaderModifiers = [.fragment: IsosurfaceNodeBuilder.fresnelModifier(opacity: opacity)]
                }
            } else {
                m.lightingModel = .constant
            }
            m.isDoubleSided = true
            if opacity < 1 {
                m.transparency = CGFloat(opacity)
                m.transparencyMode = .dualLayer
                m.writesToDepthBuffer = false
                m.blendMode = .alpha
            }
            if s.mode == .mesh || s.mode == .points { m.emission.contents = hasVC ? NSColor.white : color.nsColor }
            g.materials = [m]
            let child = SCNNode(geometry: g)
            child.name = mesh.sign == .positive ? "lobe.positive" : "lobe.negative"
            child.renderingOrder = renderingOrder
            node.addChildNode(child)
        }
        return node
    }
}
