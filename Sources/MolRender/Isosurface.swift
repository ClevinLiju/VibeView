import SceneKit
import AppKit
import MolCore
import MolAnalysis

/// How an isosurface is drawn.
/// - `solid`: shaded PBR lobes; honours `Isosurface.opacity` (default 1 = opaque).
/// - `transparent`: shaded lobes at `Isosurface.transparentOpacity` (default 0.55) with a fresnel edge boost;
///   back faces are drawn before front faces so overlapping lobes sort correctly.
/// - `wireframe`: unique mesh edges as lines in a constant-lit tone slightly darker than the lobe color.
/// - `mesh`: like `wireframe` but self-lit in the full lobe color (legacy look).
/// - `points`: one point per vertex.
public enum SurfaceDisplayMode: String, Sendable, Codable, CaseIterable { case solid, transparent, wireframe, mesh, points }

/// Sign colors for orbital-like lobes. Users may override either color.
public struct OrbitalColorScheme: Sendable, Hashable, Codable {
    public var positive: RGBA
    public var negative: RGBA
    public init(positive: RGBA, negative: RGBA) { self.positive = positive; self.negative = negative }
    /// Occupied orbitals: red positive phase, blue negative phase.
    public static let occupied = OrbitalColorScheme(positive: RGBA(0.89, 0.22, 0.20), negative: RGBA(0.17, 0.40, 0.90))
    /// Virtual orbitals: green positive phase, yellow negative phase.
    public static let virtual = OrbitalColorScheme(positive: RGBA(0.18, 0.70, 0.38), negative: RGBA(0.97, 0.79, 0.16))
    public static func forOccupation(occupied: Bool) -> OrbitalColorScheme { occupied ? .occupied : .virtual }
}

public struct Isosurface: Sendable {
    public var id: String
    public var meshes: [IsoSurfaceMesh]
    public var positiveColor: RGBA = RGBA(0.15, 0.35, 0.95)
    public var negativeColor: RGBA = RGBA(0.95, 0.25, 0.15)
    /// Opacity for `.solid` (1 = opaque).
    public var opacity: Double = 1
    /// Opacity for `.transparent`.
    public var transparentOpacity: Double = 0.55
    public var mode: SurfaceDisplayMode = .solid
    public var visible: Bool = true
    /// Taubin smoothing iterations applied to each lobe when the node is built (0 = off).
    public var smoothingIterations: Int = 4
    public init(id: String, meshes: [IsoSurfaceMesh]) { self.id = id; self.meshes = meshes }
    public init(id: String, meshes: [IsoSurfaceMesh], colors: OrbitalColorScheme) {
        self.init(id: id, meshes: meshes); apply(colors)
    }
    public mutating func apply(_ scheme: OrbitalColorScheme) { positiveColor = scheme.positive; negativeColor = scheme.negative }
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
    public static func geometry(for mesh: IsoSurfaceMesh, mode: SurfaceDisplayMode, smoothingIterations: Int = 0) -> SCNGeometry? {
        guard !mesh.vertices.isEmpty else { return nil }
        if smoothingIterations > 0, mode != .points, !mesh.vertices.contains(where: { !($0.x.isFinite && $0.y.isFinite && $0.z.isFinite) }) {
            let smoothed = IsosurfaceSmoothing.taubin(mesh, iterations: smoothingIterations)
            return geometry(for: smoothed, mode: mode, smoothingIterations: 0)
        }
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
        case .solid, .transparent, .wireframe, .mesh:
            let idx = validIndices(mesh)
            guard !idx.isEmpty else { return nil }
            if mode == .solid || mode == .transparent {
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
            el.pointSize = 2.5
            el.minimumPointScreenSpaceRadius = 1.2
            el.maximumPointScreenSpaceRadius = 3.5
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

    private static func solidMaterial(_ color: NSColor, opacity: Double, fresnel: Bool, hasVC: Bool) -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = color
        m.lightingModel = .physicallyBased
        m.roughness.contents = NSNumber(value: 0.35)
        m.metalness.contents = NSNumber(value: 0.0)
        m.clearCoat.contents = NSNumber(value: 0.15)
        m.clearCoatRoughness.contents = NSNumber(value: 0.2)
        if opacity < 1 {
            if fresnel { m.shaderModifiers = [.fragment: IsosurfaceNodeBuilder.fresnelModifier(opacity: opacity)] }
            m.transparency = CGFloat(opacity)
            m.transparencyMode = .dualLayer
            m.writesToDepthBuffer = false
            m.blendMode = .alpha
        }
        m.isDoubleSided = true
        return m
    }

    public static func build(_ s: Isosurface) -> SCNNode {
        let node = SCNNode(); node.name = "surface:\(s.id)"
        let isTransparent = s.mode == .transparent
        let opacity = max(0, min(1, isTransparent ? s.transparentOpacity : s.opacity))
        for mesh in s.meshes where !mesh.isEmpty || (s.mode == .points && !mesh.vertices.isEmpty) {
            guard let g = IsosurfaceGeometry.geometry(for: mesh, mode: s.mode, smoothingIterations: s.smoothingIterations) else { continue }
            let color = mesh.sign == .positive ? s.positiveColor : s.negativeColor
            let hasVC = mesh.vertexColors?.count == mesh.vertices.count
            let base: NSColor = hasVC ? .white : color.nsColor
            let child = SCNNode(geometry: g)
            child.name = mesh.sign == .positive ? "lobe.positive" : "lobe.negative"
            child.renderingOrder = renderingOrder
            switch s.mode {
            case .solid, .transparent:
                let m = solidMaterial(base, opacity: opacity, fresnel: true, hasVC: hasVC)
                g.materials = [m]
                if isTransparent && opacity < 1 {
                    // Two passes: back faces first, then front faces, so lobes inside one another and the
                    // positive/negative pair composite in a stable order.
                    m.isDoubleSided = false
                    m.cullMode = .back
                    m.transparencyMode = .aOne
                    m.shaderModifiers = [.fragment: IsosurfaceNodeBuilder.fresnelModifier(opacity: opacity)]
                    child.renderingOrder = renderingOrder + 1
                    if let bg = g.copy() as? SCNGeometry {
                        let bm = solidMaterial(base, opacity: opacity, fresnel: false, hasVC: hasVC)
                        bm.isDoubleSided = false
                        bm.transparencyMode = .aOne
                        bm.lightingModel = .lambert
                        bm.diffuse.contents = base
                        bm.cullMode = .front
                        bg.materials = [bm]
                        let back = SCNNode(geometry: bg)
                        back.name = "lobe.back"
                        back.renderingOrder = renderingOrder
                        child.addChildNode(back)
                    }
                }
            case .wireframe, .mesh, .points:
                let m = SCNMaterial()
                m.lightingModel = .constant
                var c = color
                if s.mode == .wireframe { c = RGBA(color.r * 0.75, color.g * 0.75, color.b * 0.75, color.a) }
                let col: NSColor = hasVC ? .white : c.nsColor
                m.diffuse.contents = col
                m.emission.contents = col
                m.isDoubleSided = true
                if opacity < 1 && s.mode != .wireframe {
                    m.transparency = CGFloat(opacity); m.transparencyMode = .dualLayer
                    m.writesToDepthBuffer = false; m.blendMode = .alpha
                }
                g.materials = [m]
            }
            node.addChildNode(child)
        }
        return node
    }
}
