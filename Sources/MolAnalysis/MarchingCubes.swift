import Foundation
import simd
import MolCore

// Marching cubes (Lorensen & Cline 1987) over a `VolumeGrid` with arbitrary (non-orthogonal) step vectors.
//
// The 256-case triangulation table is generated once at load time from a face-consistent rule instead of
// being typed in by hand: for every cube face the contour segments are determined from the face's four
// corner signs only (ambiguous faces separate the "inside" corners), so two cells sharing a face always
// agree and the resulting mesh is watertight. Segments are oriented so that, seen from outside the cube,
// the inside region lies to the right; chaining them gives closed loops that are fan-triangulated with a
// counter-clockwise winding as seen from the low-value (outside) side.
//
// Vertices are welded through a per-grid-edge index, positions are linearly interpolated along cell edges
// and normals come from the interpolated central-difference gradient (mapped through the inverse-transpose
// of the axis matrix, so they are correct for skewed grids).

public enum MarchingCubes {

    // MARK: Table

    /// Corner c has offset (c & 1, (c >> 1) & 1, (c >> 2) & 1) along (axis0, axis1, axis2).
    static let cornerOffsets: [(Int, Int, Int)] = (0..<8).map { ($0 & 1, ($0 >> 1) & 1, ($0 >> 2) & 1) }

    /// 12 cube edges as corner pairs (low corner first); `edgeAxis` is the axis the edge runs along.
    static let edges: [(Int, Int)] = {
        var out: [(Int, Int)] = []
        for axis in 0..<3 {
            let bit = 1 << axis
            for c in 0..<8 where c & bit == 0 { out.append((c, c | bit)) }
        }
        return out
    }()

    static func edgeIndex(_ a: Int, _ b: Int) -> Int {
        let lo = min(a, b), hi = max(a, b)
        return edges.firstIndex { $0.0 == lo && $0.1 == hi }!
    }

    /// Six faces, each listed with its four corners counter-clockwise as seen from outside the cube.
    static let faces: [[Int]] = {
        func pos(_ c: Int) -> SIMD3<Double> {
            let o = cornerOffsets[c]; return SIMD3(Double(o.0), Double(o.1), Double(o.2))
        }
        var out: [[Int]] = []
        for axis in 0..<3 {
            for side in 0..<2 {
                let corners = (0..<8).filter { ($0 >> axis) & 1 == side }
                var n = SIMD3<Double>(0, 0, 0); n[axis] = side == 0 ? -1 : 1
                let center = corners.map(pos).reduce(SIMD3<Double>(0, 0, 0), +) / 4
                // Sort corners by angle around the outward normal (CCW seen from outside = CCW about +n).
                let u: SIMD3<Double> = axis == 0 ? SIMD3(0, 1, 0) : SIMD3(1, 0, 0)
                let v = simd_cross(n, u)
                let sorted = corners.sorted { a, b in
                    let da = pos(a) - center, db = pos(b) - center
                    return atan2(simd_dot(da, v), simd_dot(da, u)) < atan2(simd_dot(db, v), simd_dot(db, u))
                }
                out.append(sorted)
            }
        }
        return out
    }()

    /// `triangleTable[case]` lists cube-edge indices, 3 per triangle. Case bit c set = corner c inside.
    public static let triangleTable: [[Int]] = (0..<256).map(triangulate)
    /// `edgeTable[case]` bit e set = edge e is crossed (classic 12-bit edge mask).
    public static let edgeTable: [Int] = (0..<256).map { cfg in
        var m = 0
        for (e, p) in edges.enumerated() where ((cfg >> p.0) & 1) != ((cfg >> p.1) & 1) { m |= 1 << e }
        return m
    }

    private static func triangulate(_ cfg: Int) -> [Int] {
        func inside(_ c: Int) -> Bool { (cfg >> c) & 1 == 1 }
        var next = [Int](repeating: -1, count: 12)
        for f in faces {
            // Walk the face boundary CCW; record crossings: A = outside→inside, B = inside→outside.
            var crossings: [(edge: Int, entering: Bool)] = []
            for i in 0..<4 {
                let a = f[i], b = f[(i + 1) % 4]
                if inside(a) != inside(b) { crossings.append((edgeIndex(a, b), inside(b))) }
            }
            guard !crossings.isEmpty else { continue }
            // Rotate so the list starts with an entering crossing, then pair A_k → B_k (inside separated).
            let start = crossings.firstIndex { $0.entering }!
            let rot = Array(crossings[start...] + crossings[..<start])
            var k = 0
            while k + 1 < rot.count { next[rot[k].edge] = rot[k + 1].edge; k += 2 }
        }
        var visited = [Bool](repeating: false, count: 12)
        var tris: [Int] = []
        for e0 in 0..<12 where next[e0] >= 0 && !visited[e0] {
            var loop: [Int] = []
            var e = e0
            while !visited[e] { visited[e] = true; loop.append(e); e = next[e] }
            guard loop.count >= 3 else { continue }
            tris += triangulateLoop(loop) ?? fan(loop)
        }
        return tris
    }

    /// Cube edges lying on each face (for diagonal validity).
    static let faceEdgeSets: [Set<Int>] = faces.map { f in Set((0..<4).map { edgeIndex(f[$0], f[($0 + 1) % 4]) }) }

    private static func fan(_ loop: [Int]) -> [Int] {
        var t: [Int] = []
        for i in 1..<(loop.count - 1) { t += [loop[0], loop[i], loop[i + 1]] }
        return t
    }

    /// Triangulates a loop without diagonals that lie on a cube face: such a diagonal could be generated
    /// by the neighbouring cell too and would make the shared edge non-manifold.
    private static func triangulateLoop(_ loop: [Int]) -> [Int]? {
        let n = loop.count
        func adjacent(_ a: Int, _ b: Int) -> Bool { (a + 1) % n == b || (b + 1) % n == a }
        func ok(_ a: Int, _ b: Int) -> Bool {
            if adjacent(a, b) { return true }
            let ea = loop[a], eb = loop[b]
            return !faceEdgeSets.contains { $0.contains(ea) && $0.contains(eb) }
        }
        // Polygon given by loop positions i...j (i < j), with edge (i, j) closing it.
        func solve(_ i: Int, _ j: Int) -> [Int]? {
            if j - i < 2 { return [] }
            for k in (i + 1)..<j where ok(i, k) && ok(k, j) {
                if let l = solve(i, k), let r = solve(k, j) { return l + [loop[i], loop[k], loop[j]] + r }
            }
            return nil
        }
        return solve(0, n - 1)
    }

    // MARK: Extraction

    /// Extract the isosurface `value == isovalue`. For `isovalue >= 0` the enclosed region is `value > isovalue`
    /// (sign `.positive`); for `isovalue < 0` it is `value < isovalue` (sign `.negative`, e.g. a negative orbital lobe).
    /// Normals point toward decreasing |value| (out of the lobe); triangles are CCW seen from that side.
    public static func extract(grid: VolumeGrid, isovalue: Double) -> IsoSurfaceMesh {
        let negative = isovalue < 0
        return extract(grid: grid, isovalue: isovalue, flip: negative)
    }

    /// Positive and negative lobes `[+|iso|, -|iso|]`. Both entries are always present (possibly empty).
    public static func orbitalLobes(grid: VolumeGrid, isovalue: Double) -> [IsoSurfaceMesh] {
        let iso = abs(isovalue)
        return [extract(grid: grid, isovalue: iso, flip: false), extract(grid: grid, isovalue: -iso, flip: true)]
    }

    private static func extract(grid: VolumeGrid, isovalue: Double, flip: Bool) -> IsoSurfaceMesh {
        var mesh = IsoSurfaceMesh(sign: flip ? .negative : .positive, isovalue: isovalue)
        guard grid.counts.count == 3, grid.axes.count == 3 else { return mesh }
        let nx = grid.counts[0], ny = grid.counts[1], nz = grid.counts[2]
        guard nx >= 2, ny >= 2, nz >= 2, grid.values.count >= nx * ny * nz else { return mesh }

        // Work on s = sign * (value - iso) so "inside" is always s > 0.
        let sgn: Float = flip ? -1 : 1
        let iso = Float(isovalue)
        let values = grid.values
        @inline(__always) func s(_ i: Int, _ j: Int, _ k: Int) -> Float { sgn * (values[(i * ny + j) * nz + k] - iso) }

        let a0 = grid.axes[0], a1 = grid.axes[1], a2 = grid.axes[2], org = grid.origin
        let M = simd_double3x3(columns: (a0, a1, a2))
        let det = M.determinant
        let invT = det != 0 ? M.inverse.transpose : matrix_identity_double3x3
        let reverse = det < 0

        // Gradient of s in index space (central differences, one-sided at the boundary).
        @inline(__always) func gIndex(_ i: Int, _ j: Int, _ k: Int) -> SIMD3<Double> {
            func d(_ lo: Float, _ hi: Float, _ h: Int) -> Double { Double(hi - lo) / Double(h) }
            let gx = i == 0 ? d(s(0, j, k), s(1, j, k), 1) : i == nx - 1 ? d(s(i - 1, j, k), s(i, j, k), 1) : d(s(i - 1, j, k), s(i + 1, j, k), 2)
            let gy = j == 0 ? d(s(i, 0, k), s(i, 1, k), 1) : j == ny - 1 ? d(s(i, j - 1, k), s(i, j, k), 1) : d(s(i, j - 1, k), s(i, j + 1, k), 2)
            let gz = k == 0 ? d(s(i, j, 0), s(i, j, 1), 1) : k == nz - 1 ? d(s(i, j, k - 1), s(i, j, k), 1) : d(s(i, j, k - 1), s(i, j, k + 1), 2)
            return SIMD3(gx, gy, gz)
        }

        // Edge → vertex index (welding). Edge id = 3 * pointIndex + axis.
        var edgeVertex = [Int32](repeating: -1, count: 3 * nx * ny * nz)
        var verts: [SIMD3<Float>] = [], norms: [SIMD3<Float>] = []
        var indices: [UInt32] = []

        func vertex(_ i: Int, _ j: Int, _ k: Int, axis: Int) -> UInt32 {
            let id = 3 * ((i * ny + j) * nz + k) + axis
            if edgeVertex[id] >= 0 { return UInt32(edgeVertex[id]) }
            let (di, dj, dk) = axis == 0 ? (1, 0, 0) : axis == 1 ? (0, 1, 0) : (0, 0, 1)
            let v0 = s(i, j, k), v1 = s(i + di, j + dj, k + dk)
            let denom = v0 - v1
            var t = denom != 0 ? Double(v0 / denom) : 0.5
            t = min(max(t, 0), 1)
            let fi = Double(i) + t * Double(di), fj = Double(j) + t * Double(dj), fk = Double(k) + t * Double(dk)
            let p = org + fi * a0 + fj * a1 + fk * a2
            let g = (1 - t) * gIndex(i, j, k) + t * gIndex(i + di, j + dj, k + dk)
            var n = -(invT * g)            // toward decreasing s = out of the lobe
            let len = simd_length(n)
            if len > 0 { n /= len } else { n = SIMD3(0, 0, 1) }
            let idx = Int32(verts.count)
            verts.append(SIMD3<Float>(Float(p.x), Float(p.y), Float(p.z)))
            norms.append(SIMD3<Float>(Float(n.x), Float(n.y), Float(n.z)))
            edgeVertex[id] = idx
            return UInt32(idx)
        }

        // Edge e of the local cube → (corner offset, axis) of the global edge.
        let edgeGlobal: [(Int, Int, Int, Int)] = edges.map { (a, b) in
            let o = cornerOffsets[a]
            let axis = (a ^ b) == 1 ? 0 : (a ^ b) == 2 ? 1 : 2
            return (o.0, o.1, o.2, axis)
        }

        var corner = [Float](repeating: 0, count: 8)
        var local = [UInt32](repeating: 0, count: 12)
        for i in 0..<(nx - 1) {
            for j in 0..<(ny - 1) {
                for k in 0..<(nz - 1) {
                    var cfg = 0
                    for c in 0..<8 {
                        let o = cornerOffsets[c]
                        corner[c] = s(i + o.0, j + o.1, k + o.2)
                        if corner[c] > 0 { cfg |= 1 << c }
                    }
                    if cfg == 0 || cfg == 255 { continue }
                    let em = edgeTable[cfg]
                    for e in 0..<12 where em & (1 << e) != 0 {
                        let g = edgeGlobal[e]
                        local[e] = vertex(i + g.0, j + g.1, k + g.2, axis: g.3)
                    }
                    let tri = triangleTable[cfg]
                    var t = 0
                    while t < tri.count {
                        let p0 = local[tri[t]], p1 = local[tri[t + 1]], p2 = local[tri[t + 2]]
                        t += 3
                        if p0 == p1 || p1 == p2 || p0 == p2 { continue }
                        if reverse { indices += [p0, p2, p1] } else { indices += [p0, p1, p2] }
                    }
                }
            }
        }
        mesh.vertices = verts
        mesh.normals = norms
        mesh.indices = indices
        return mesh
    }

    // MARK: Diagnostics

    public static func surfaceArea(_ m: IsoSurfaceMesh) -> Double {
        var a = 0.0
        forEachTriangle(m) { p0, p1, p2 in a += 0.5 * simd_length(simd_cross(p1 - p0, p2 - p0)) }
        return a
    }

    /// Signed enclosed volume (positive for a closed mesh with outward CCW winding).
    public static func enclosedVolume(_ m: IsoSurfaceMesh) -> Double {
        var v = 0.0
        forEachTriangle(m) { p0, p1, p2 in v += simd_dot(p0, simd_cross(p1, p2)) / 6 }
        return v
    }

    /// True when every edge is shared by exactly two triangles that traverse it in opposite directions.
    public static func isClosedManifold(_ m: IsoSurfaceMesh) -> Bool {
        var directed = [UInt64: Int]()
        directed.reserveCapacity(m.indices.count)
        var t = 0
        while t + 2 < m.indices.count {
            let a = m.indices[t], b = m.indices[t + 1], c = m.indices[t + 2]
            for (u, v) in [(a, b), (b, c), (c, a)] {
                directed[UInt64(u) << 32 | UInt64(v), default: 0] += 1
            }
            t += 3
        }
        for (key, n) in directed {
            guard n == 1 else { return false }
            let u = key >> 32, v = key & 0xffff_ffff
            if directed[v << 32 | u] != 1 { return false }
        }
        return !m.indices.isEmpty
    }

    static func forEachTriangle(_ m: IsoSurfaceMesh, _ body: (SIMD3<Double>, SIMD3<Double>, SIMD3<Double>) -> Void) {
        var t = 0
        while t + 2 < m.indices.count {
            let p0 = SIMD3<Double>(m.vertices[Int(m.indices[t])])
            let p1 = SIMD3<Double>(m.vertices[Int(m.indices[t + 1])])
            let p2 = SIMD3<Double>(m.vertices[Int(m.indices[t + 2])])
            body(p0, p1, p2)
            t += 3
        }
    }
}
