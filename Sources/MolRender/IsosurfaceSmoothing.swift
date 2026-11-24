import Foundation
import simd
import MolAnalysis

/// Pure mesh-conditioning helpers for isosurfaces: vertex welding, smooth normals and Taubin smoothing.
public enum IsosurfaceSmoothing {
    /// Merge vertices closer than `tolerance` (Å). Triangles that collapse are dropped; per-vertex scalars and
    /// colors follow the first vertex of each merged group. Normals are recomputed from the result.
    public static func weld(_ mesh: IsoSurfaceMesh, tolerance: Float = 1e-5) -> IsoSurfaceMesh {
        let n = mesh.vertices.count
        guard n > 1 else { return mesh }
        struct Cell: Hashable { var x: Int32, y: Int32, z: Int32 }
        let inv = 1 / max(tolerance, 1e-9)
        var cells: [Cell: [Int]] = [:]          // cell -> new vertex indices
        var newVerts: [SIMD3<Float>] = []
        var keep: [Int] = []                     // old index of each new vertex
        var remap = [UInt32](repeating: 0, count: n)
        newVerts.reserveCapacity(n)
        let tol2 = tolerance * tolerance
        for i in 0..<n {
            let p = mesh.vertices[i]
            guard p.x.isFinite && p.y.isFinite && p.z.isFinite else {
                remap[i] = UInt32(newVerts.count); newVerts.append(p); keep.append(i); continue
            }
            let c = Cell(x: Int32(clamping: Int((p.x * inv).rounded(.down))), y: Int32(clamping: Int((p.y * inv).rounded(.down))),
                         z: Int32(clamping: Int((p.z * inv).rounded(.down))))
            var found: Int? = nil
            search: for dx in Int32(-1)...1 { for dy in Int32(-1)...1 { for dz in Int32(-1)...1 {
                guard let list = cells[Cell(x: c.x &+ dx, y: c.y &+ dy, z: c.z &+ dz)] else { continue }
                for j in list where simd_length_squared(newVerts[j] - p) <= tol2 { found = j; break search }
            } } }
            if let f = found { remap[i] = UInt32(f) } else {
                let k = newVerts.count
                cells[c, default: []].append(k)
                remap[i] = UInt32(k); newVerts.append(p); keep.append(i)
            }
        }
        var out = mesh
        out.vertices = newVerts
        if let s = mesh.vertexScalars, s.count == n { out.vertexScalars = keep.map { s[$0] } }
        if let c = mesh.vertexColors, c.count == n { out.vertexColors = keep.map { c[$0] } }
        var idx: [UInt32] = []
        idx.reserveCapacity(mesh.indices.count)
        var t = 0
        while t + 2 < mesh.indices.count {
            let a = Int(mesh.indices[t]), b = Int(mesh.indices[t + 1]), c = Int(mesh.indices[t + 2])
            t += 3
            guard a < n, b < n, c < n else { continue }
            let ra = remap[a], rb = remap[b], rc = remap[c]
            if ra == rb || rb == rc || ra == rc { continue }
            idx.append(ra); idx.append(rb); idx.append(rc)
        }
        out.indices = idx
        out.normals = smoothNormals(vertices: out.vertices, indices: idx)
        return out
    }

    /// Unit vertex normals from the triangles, weighting each face by its corner angle (robust on uneven
    /// triangulations). Degenerate vertices get +Z.
    public static func smoothNormals(vertices: [SIMD3<Float>], indices: [UInt32]) -> [SIMD3<Float>] {
        var nrm = [SIMD3<Float>](repeating: .zero, count: vertices.count)
        let n = vertices.count
        var t = 0
        while t + 2 < indices.count {
            let ia = Int(indices[t]), ib = Int(indices[t + 1]), ic = Int(indices[t + 2])
            t += 3
            guard ia < n, ib < n, ic < n else { continue }
            let p = [vertices[ia], vertices[ib], vertices[ic]]
            let fn = simd_cross(p[1] - p[0], p[2] - p[0])
            let fl = simd_length(fn)
            guard fl > 1e-20 else { continue }
            let u = fn / fl
            let ids = [ia, ib, ic]
            for k in 0..<3 {
                let e1 = simd_normalize(p[(k + 1) % 3] - p[k]), e2 = simd_normalize(p[(k + 2) % 3] - p[k])
                let ang = acos(max(-1, min(1, simd_dot(e1, e2))))
                if ang.isFinite { nrm[ids[k]] += u * ang }
            }
        }
        return nrm.map { v in
            let l = simd_length(v)
            return l > 1e-12 ? v / l : SIMD3<Float>(0, 0, 1)
        }
    }

    /// Mesh with freshly computed smooth normals.
    public static func smoothNormals(_ mesh: IsoSurfaceMesh) -> IsoSurfaceMesh {
        var m = mesh
        m.normals = smoothNormals(vertices: mesh.vertices, indices: mesh.indices)
        return m
    }

    /// Taubin lambda/mu smoothing (lambda 0.5, mu -0.53): each iteration is a shrinking Laplacian step followed
    /// by an inflating one, so noise is removed without the lobe contracting. Vertex count and connectivity are
    /// unchanged; normals are recomputed. The mesh is welded first if it has duplicate vertices (otherwise the
    /// seams would tear), in which case the vertex count can drop.
    public static func taubin(_ mesh: IsoSurfaceMesh, iterations: Int) -> IsoSurfaceMesh {
        guard iterations > 0, mesh.vertices.count > 3, !mesh.indices.isEmpty else { return mesh }
        var m = mesh
        m.indices = validTriangles(mesh)
        if hasDuplicates(m) { m = weld(m) }
        let n = m.vertices.count
        // CSR adjacency from unique edges.
        let edges = IsosurfaceGeometry.uniqueEdges(m.indices)
        var deg = [Int](repeating: 0, count: n + 1)
        var e = 0
        while e + 1 < edges.count { deg[Int(edges[e]) + 1] += 1; deg[Int(edges[e + 1]) + 1] += 1; e += 2 }
        for i in 0..<n { deg[i + 1] += deg[i] }
        var fill = deg
        var adj = [UInt32](repeating: 0, count: deg[n])
        e = 0
        while e + 1 < edges.count {
            let a = Int(edges[e]), b = Int(edges[e + 1])
            adj[fill[a]] = UInt32(b); fill[a] += 1
            adj[fill[b]] = UInt32(a); fill[b] += 1
            e += 2
        }
        var cur = m.vertices
        var next = cur
        func step(_ f: Float) {
            for i in 0..<n {
                let s = deg[i], t = deg[i + 1]
                guard t > s else { next[i] = cur[i]; continue }
                var avg = SIMD3<Float>.zero
                for k in s..<t { avg += cur[Int(adj[k])] }
                avg /= Float(t - s)
                next[i] = cur[i] + f * (avg - cur[i])
            }
            swap(&cur, &next)
        }
        for _ in 0..<iterations { step(0.5); step(-0.53) }
        m.vertices = cur
        m.normals = smoothNormals(vertices: cur, indices: m.indices)
        return m
    }

    static func validTriangles(_ mesh: IsoSurfaceMesh) -> [UInt32] { IsosurfaceGeometry.validIndices(mesh) }

    /// True if two vertices coincide within 1e-5 (cheap hash test).
    static func hasDuplicates(_ mesh: IsoSurfaceMesh) -> Bool {
        var seen = Set<SIMD3<Int32>>()
        seen.reserveCapacity(mesh.vertices.count)
        for p in mesh.vertices {
            let q = SIMD3<Int32>(Int32(clamping: Int((p.x * 1e5).rounded())), Int32(clamping: Int((p.y * 1e5).rounded())),
                                 Int32(clamping: Int((p.z * 1e5).rounded())))
            if !seen.insert(q).inserted { return true }
        }
        return false
    }

    /// Signed enclosed volume (Å^3) of a closed, consistently wound mesh.
    public static func signedVolume(_ mesh: IsoSurfaceMesh) -> Double {
        var v = 0.0
        var t = 0
        while t + 2 < mesh.indices.count {
            let a = SIMD3<Double>(mesh.vertices[Int(mesh.indices[t])]), b = SIMD3<Double>(mesh.vertices[Int(mesh.indices[t + 1])])
            let c = SIMD3<Double>(mesh.vertices[Int(mesh.indices[t + 2])])
            v += simd_dot(a, simd_cross(b, c)) / 6
            t += 3
        }
        return v
    }
}
