import Foundation
import MolSIMD
import MolCore

/// Post-processing for `IsoSurfaceMesh`: welding, Taubin smoothing, vertex-clustering decimation and normals.
/// Algorithms: spatial-hash welding, Taubin (1995) λ|μ smoothing with the umbrella operator, Rossignac–Borrel
/// vertex clustering, area-weighted vertex normals. Positions in Å.
public enum MeshProcessing {

    // MARK: Weld

    /// Merges vertices closer than `tolerance` (Å; vertices are snapped to a hash grid of that size and merged when
    /// they land in the same cell). Normals of merged vertices are summed and renormalized, scalars/colors are
    /// taken from the first vertex of each cluster. Degenerate triangles are dropped.
    public static func weld(_ mesh: IsoSurfaceMesh, tolerance: Double = 1e-5) -> IsoSurfaceMesh {
        let n = mesh.vertices.count
        guard n > 0 else { return mesh }
        let inv = 1.0 / max(tolerance, 1e-12)
        var map = [UInt32](repeating: 0, count: n)
        var table = [SIMD3<Int64>: UInt32](minimumCapacity: n)
        var first: [Int] = []
        for i in 0..<n {
            let v = mesh.vertices[i]
            let key = SIMD3<Int64>(Int64((Double(v.x) * inv).rounded()), Int64((Double(v.y) * inv).rounded()), Int64((Double(v.z) * inv).rounded()))
            if let j = table[key] { map[i] = j } else {
                let j = UInt32(first.count)
                table[key] = j; first.append(i); map[i] = j
            }
        }
        var out = IsoSurfaceMesh(sign: mesh.sign, isovalue: mesh.isovalue)
        out.vertices = first.map { mesh.vertices[$0] }
        if let s = mesh.vertexScalars { out.vertexScalars = first.map { s[$0] } }
        if let c = mesh.vertexColors { out.vertexColors = first.map { c[$0] } }
        if mesh.normals.count == n {
            var acc = [SIMD3<Float>](repeating: .zero, count: first.count)
            for i in 0..<n { acc[Int(map[i])] += mesh.normals[i] }
            out.normals = acc.map { simd_length($0) > 0 ? simd_normalize($0) : SIMD3<Float>(0, 0, 1) }
        }
        out.indices.reserveCapacity(mesh.indices.count)
        var t = 0
        while t + 2 < mesh.indices.count {
            let a = map[Int(mesh.indices[t])], b = map[Int(mesh.indices[t + 1])], c = map[Int(mesh.indices[t + 2])]
            t += 3
            if a == b || b == c || a == c { continue }
            out.indices.append(contentsOf: [a, b, c])
        }
        return out
    }

    // MARK: Normals

    /// Area-weighted vertex normals. If the mesh already has normals, each new normal is flipped to agree with the old
    /// one; otherwise the triangle winding (CCW seen from outside, see `IsoSurfaceMesh`) defines "outward".
    public static func recomputeNormals(_ mesh: IsoSurfaceMesh) -> IsoSurfaceMesh {
        var out = mesh
        let n = mesh.vertices.count
        var acc = [SIMD3<Float>](repeating: .zero, count: n)
        var t = 0
        while t + 2 < mesh.indices.count {
            let a = Int(mesh.indices[t]), b = Int(mesh.indices[t + 1]), c = Int(mesh.indices[t + 2])
            t += 3
            let fn = simd_cross(mesh.vertices[b] - mesh.vertices[a], mesh.vertices[c] - mesh.vertices[a])  // |fn| = 2·area
            acc[a] += fn; acc[b] += fn; acc[c] += fn
        }
        let hadNormals = mesh.normals.count == n
        for i in 0..<n {
            var v = acc[i]
            let len = simd_length(v)
            if len > 0 { v /= len } else { v = hadNormals ? mesh.normals[i] : SIMD3<Float>(0, 0, 1) }
            if hadNormals, simd_dot(v, mesh.normals[i]) < 0, simd_length(mesh.normals[i]) > 0 { v = -v }
            acc[i] = v
        }
        out.normals = acc
        return out
    }

    // MARK: Taubin smoothing

    /// Taubin λ|μ smoothing (umbrella operator). The mesh is welded first so shared positions move together. Boundary
    /// vertices (edges used by one triangle, e.g. where the surface leaves the grid) stay fixed. Sign and isovalue are kept;
    /// normals are recomputed afterwards.
    public static func taubinSmooth(_ mesh: IsoSurfaceMesh, iterations: Int, lambda: Double = 0.5, mu: Double = -0.53) -> IsoSurfaceMesh {
        guard iterations > 0, !mesh.isEmpty else { return mesh }
        var m = weld(mesh, tolerance: 1e-5)
        let (rowStart, nbrs, fixed) = adjacency(m)
        var p = m.vertices.map { SIMD3<Double>($0) }
        var q = p
        let n = p.count
        func step(_ factor: Double) {
            for i in 0..<n {
                if fixed[i] { q[i] = p[i]; continue }
                let s = rowStart[i], e = rowStart[i + 1]
                if e == s { q[i] = p[i]; continue }
                var avg = SIMD3<Double>.zero
                for k in s..<e { avg += p[Int(nbrs[k])] }
                avg /= Double(e - s)
                q[i] = p[i] + factor * (avg - p[i])
            }
            swap(&p, &q)
        }
        for _ in 0..<iterations { step(lambda); step(mu) }
        m.vertices = p.map { SIMD3<Float>($0) }
        return recomputeNormals(m)
    }

    /// CSR adjacency of unique edges, plus a flag for vertices on an open boundary.
    static func adjacency(_ m: IsoSurfaceMesh) -> (rowStart: [Int], nbrs: [UInt32], fixed: [Bool]) {
        let n = m.vertices.count
        var keys: [UInt64] = []
        keys.reserveCapacity(m.indices.count)
        var t = 0
        while t + 2 < m.indices.count {
            let a = m.indices[t], b = m.indices[t + 1], c = m.indices[t + 2]
            t += 3
            for (u, v) in [(a, b), (b, c), (c, a)] { keys.append(UInt64(min(u, v)) << 32 | UInt64(max(u, v))) }
        }
        keys.sort()
        var fixed = [Bool](repeating: false, count: n)
        var uniq: [UInt64] = []
        var i = 0
        while i < keys.count {
            var j = i
            while j < keys.count && keys[j] == keys[i] { j += 1 }
            uniq.append(keys[i])
            if j - i == 1 { fixed[Int(keys[i] >> 32)] = true; fixed[Int(keys[i] & 0xffff_ffff)] = true }
            i = j
        }
        var deg = [Int](repeating: 0, count: n + 1)
        for k in uniq { deg[Int(k >> 32) + 1] += 1; deg[Int(k & 0xffff_ffff) + 1] += 1 }
        for v in 0..<n { deg[v + 1] += deg[v] }
        var fill = deg
        var nbrs = [UInt32](repeating: 0, count: deg[n])
        for k in uniq {
            let a = Int(k >> 32), b = Int(k & 0xffff_ffff)
            nbrs[fill[a]] = UInt32(b); fill[a] += 1
            nbrs[fill[b]] = UInt32(a); fill[b] += 1
        }
        return (deg, nbrs, fixed)
    }

    /// Mean magnitude (Å) of the umbrella Laplacian over interior vertices: a simple roughness measure.
    public static func roughness(_ mesh: IsoSurfaceMesh) -> Double {
        let (rs, nb, fixed) = adjacency(mesh)
        var sum = 0.0, cnt = 0
        for i in 0..<mesh.vertices.count where !fixed[i] && rs[i + 1] > rs[i] {
            var avg = SIMD3<Double>.zero
            for k in rs[i]..<rs[i + 1] { avg += SIMD3<Double>(mesh.vertices[Int(nb[k])]) }
            avg /= Double(rs[i + 1] - rs[i])
            sum += simd_length(avg - SIMD3<Double>(mesh.vertices[i])); cnt += 1
        }
        return cnt > 0 ? sum / Double(cnt) : 0
    }

    // MARK: Decimation

    /// Vertex-clustering decimation to at most `targetTriangles` triangles. Vertices are clustered on a uniform grid whose
    /// cell size is tuned iteratively; each cluster becomes one vertex at the mean position. Degenerate and duplicate
    /// triangles are dropped; surviving triangles keep their winding. Returns the mesh unchanged if already small enough.
    public static func decimate(_ mesh: IsoSurfaceMesh, targetTriangles: Int) -> IsoSurfaceMesh {
        let target = max(targetTriangles, 4)
        guard mesh.triangleCount > target, !mesh.vertices.isEmpty else { return mesh }
        var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
        for v in mesh.vertices { lo = simd_min(lo, v); hi = simd_max(hi, v) }
        let area = MarchingCubes.surfaceArea(mesh)
        var h = max(Float((2.0 * area / Double(target)).squareRoot()), 1e-4)
        var best: IsoSurfaceMesh?
        for _ in 0..<30 {
            let r = cluster(mesh, cell: h, lo: lo, hi: hi)
            let t = r.triangleCount
            if t <= target {
                if best == nil || t > best!.triangleCount { best = r }
                if Double(t) >= 0.75 * Double(target) { break }
                h *= Float(max(0.7, min(1.0, (Double(t) / Double(target)).squareRoot() * 1.05)))
                if best != nil && h < 1e-4 { break }
            } else {
                h *= Float(max(1.05, min(2.0, (Double(t) / Double(target)).squareRoot() * 1.02)))
            }
        }
        if let best { return best }
        return cluster(mesh, cell: h * 4, lo: lo, hi: hi)
    }

    private static func cluster(_ mesh: IsoSurfaceMesh, cell h: Float, lo: SIMD3<Float>, hi: SIMD3<Float>) -> IsoSurfaceMesh {
        let n = mesh.vertices.count
        let dims = SIMD3<Int>(Int((hi.x - lo.x) / h) + 2, Int((hi.y - lo.y) / h) + 2, Int((hi.z - lo.z) / h) + 2)
        var cellIndex = [Int: UInt32](minimumCapacity: n / 4)
        var map = [UInt32](repeating: 0, count: n)
        var sumP: [SIMD3<Double>] = [], sumN: [SIMD3<Float>] = [], cnt: [Float] = []
        var sumS: [Float] = [], first: [Int] = []
        let hasN = mesh.normals.count == n, hasS = mesh.vertexScalars?.count == n, hasC = mesh.vertexColors?.count == n
        var sumC: [SIMD4<Float>] = []
        for i in 0..<n {
            let v = mesh.vertices[i]
            let c = SIMD3<Int>(Int((v.x - lo.x) / h), Int((v.y - lo.y) / h), Int((v.z - lo.z) / h))
            let key = (c.x * dims.y + c.y) * dims.z + c.z
            var id: UInt32
            if let e = cellIndex[key] { id = e } else {
                id = UInt32(sumP.count); cellIndex[key] = id
                sumP.append(.zero); sumN.append(.zero); cnt.append(0); sumS.append(0); sumC.append(.zero); first.append(i)
            }
            map[i] = id
            let k = Int(id)
            sumP[k] += SIMD3<Double>(v); cnt[k] += 1
            if hasN { sumN[k] += mesh.normals[i] }
            if hasS { sumS[k] += mesh.vertexScalars![i] }
            if hasC { sumC[k] += mesh.vertexColors![i] }
        }
        var out = IsoSurfaceMesh(sign: mesh.sign, isovalue: mesh.isovalue)
        out.vertices = (0..<sumP.count).map { SIMD3<Float>(sumP[$0] / Double(cnt[$0])) }
        if hasN { out.normals = sumN.map { simd_length($0) > 0 ? simd_normalize($0) : SIMD3<Float>(0, 0, 1) } }
        if hasS { out.vertexScalars = (0..<sumS.count).map { sumS[$0] / cnt[$0] } }
        if hasC { out.vertexColors = (0..<sumC.count).map { sumC[$0] / cnt[$0] } }
        var seen = Set<SIMD3<UInt32>>()
        var t = 0
        while t + 2 < mesh.indices.count {
            let a = map[Int(mesh.indices[t])], b = map[Int(mesh.indices[t + 1])], c = map[Int(mesh.indices[t + 2])]
            t += 3
            if a == b || b == c || a == c { continue }
            // Canonical rotation (keeps winding) for duplicate detection.
            let key: SIMD3<UInt32> = (a <= b && a <= c) ? SIMD3(a, b, c) : (b <= a && b <= c) ? SIMD3(b, c, a) : SIMD3(c, a, b)
            if !seen.insert(key).inserted { continue }
            out.indices.append(contentsOf: [a, b, c])
        }
        if !hasN { out = recomputeNormals(out) }
        return out
    }

    // MARK: Analytic normals

    /// Normals from the analytic orbital gradient: n = −sign(ψ)·∇ψ/|∇ψ| (toward decreasing |ψ|). `mesh.sign` is used where ψ ≈ 0.
    public static func analyticNormals(_ mesh: IsoSurfaceMesh, evaluator: OrbitalEvaluator, coefficients: [Double]) -> IsoSurfaceMesh {
        var out = mesh
        let n = mesh.vertices.count
        guard n > 0 else { return out }
        let b = PhysConst.angstromToBohr
        let pts = mesh.vertices.map { Vec3(Double($0.x), Double($0.y), Double($0.z)) * b }
        let (vals, grads) = evaluator.valuesAndGradients(coefficients: coefficients, atBohr: pts)
        let fallback: Double = mesh.sign == .negative ? -1 : 1
        out.normals = (0..<n).map { i in
            let s = vals[i] > 0 ? 1.0 : (vals[i] < 0 ? -1.0 : fallback)
            let g = -s * grads[i]
            let len = simd_length(g)
            return len > 0 ? SIMD3<Float>(g / len) : (mesh.normals.count == n ? mesh.normals[i] : SIMD3<Float>(0, 0, 1))
        }
        return out
    }
}
