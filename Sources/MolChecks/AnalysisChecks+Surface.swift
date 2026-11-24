import Foundation
import simd
import MolCore
import MolIO
import MolAnalysis

// Lead D: marching cubes, grids, cube-file surfaces.
func analysisGrid(origin: Vec3, axes: [Vec3], counts: [Int], _ f: (Vec3) -> Double) -> VolumeGrid {
    let spec = GridSpec(origin: origin, axes: axes, counts: counts)
    var v = [Float](repeating: 0, count: spec.pointCount)
    var n = 0
    for i in 0..<counts[0] { for j in 0..<counts[1] { for k in 0..<counts[2] { v[n] = Float(f(spec.point(i, j, k))); n += 1 } } }
    return spec.volumeGrid(values: v)
}

func meshNormalsOutward(_ m: IsoSurfaceMesh, center: Vec3) -> Double {
    // Fraction of vertex normals pointing away from `center`.
    var good = 0
    for (p, n) in zip(m.vertices, m.normals) where simd_dot(SIMD3<Double>(p) - center, SIMD3<Double>(n)) > 0 { good += 1 }
    return Double(good) / Double(max(1, m.vertices.count))
}

extension Checks {
    static let analysisSurface: [Check] = [
        Check("analysis.surface.tableConsistency") {
            // Every crossed edge appears in the triangulation and only crossed edges are used.
            for cfg in 0..<256 {
                let used = Set(MarchingCubes.triangleTable[cfg])
                var crossed = Set<Int>()
                for e in 0..<12 where MarchingCubes.edgeTable[cfg] & (1 << e) != 0 { crossed.insert(e) }
                try expect(used == crossed, "case \(cfg)")
                try expect(MarchingCubes.triangleTable[cfg].count % 3 == 0)
            }
            try expect(MarchingCubes.triangleTable[0].isEmpty && MarchingCubes.triangleTable[255].isEmpty)
        },
        Check("analysis.surface.sphere") {
            let R = 2.0, h = 0.1
            let g = analysisGrid(origin: Vec3(repeating: -3), axes: [Vec3(h, 0, 0), Vec3(0, h, 0), Vec3(0, 0, h)],
                                 counts: [61, 61, 61]) { exp(-simd_length_squared($0) / 2) }
            let m = MarchingCubes.extract(grid: g, isovalue: exp(-R * R / 2))
            let area = MarchingCubes.surfaceArea(m), vol = MarchingCubes.enclosedVolume(m)
            let areaErr: Double = 100 * (area / (4 * Double.pi * R * R) - 1)
            let volErr: Double = 100 * (vol / (4.0 / 3 * Double.pi * R * R * R) - 1)
            print("    sphere R=2 h=0.1: \(m.vertices.count) verts, \(m.triangleCount) tris, area err \(String(format: "%.3f", areaErr))%, volume err \(String(format: "%.3f", volErr))%")
            try expect(abs(area / (4 * .pi * R * R) - 1) < 0.01, "area \(area)")
            try expect(abs(vol / (4.0 / 3 * .pi * R * R * R) - 1) < 0.01, "volume \(vol)")
            try expect(MarchingCubes.isClosedManifold(m), "not closed/consistent")
            try expect(meshNormalsOutward(m, center: .zero) > 0.999)
            try expect(m.sign == .positive && m.normals.count == m.vertices.count)
            // Welded: Euler characteristic of a sphere = 2.
            var edges = Set<UInt64>()
            var t = 0
            while t < m.indices.count {
                for (a, b) in [(m.indices[t], m.indices[t + 1]), (m.indices[t + 1], m.indices[t + 2]), (m.indices[t + 2], m.indices[t])] {
                    edges.insert(UInt64(min(a, b)) << 32 | UInt64(max(a, b)))
                }
                t += 3
            }
            try expect(m.vertices.count - edges.count + m.triangleCount == 2, "Euler characteristic")
            for n in m.normals { try expect(abs(simd_length(n) - 1) < 1e-4) }
        },
        Check("analysis.surface.skewedGrid") {
            let R = 1.8
            let axes = [Vec3(0.1, 0, 0), Vec3(0.05, 0.0866, 0), Vec3(0.03, 0.03, 0.09)]
            // Choose counts so the parallelepiped covers the sphere.
            let g = analysisGrid(origin: Vec3(-5.5, -3.2, -2.7), axes: axes, counts: [90, 70, 60]) { exp(-simd_length_squared($0) / 2) }
            let m = MarchingCubes.extract(grid: g, isovalue: exp(-R * R / 2))
            let area = MarchingCubes.surfaceArea(m), vol = MarchingCubes.enclosedVolume(m)
            try expect(abs(area / (4 * .pi * R * R) - 1) < 0.02, "area \(area)")
            try expect(abs(vol / (4.0 / 3 * .pi * R * R * R) - 1) < 0.02, "volume \(vol)")
            try expect(MarchingCubes.isClosedManifold(m))
            try expect(meshNormalsOutward(m, center: .zero) > 0.999)
            // Left-handed axis order still gives outward winding.
            let lh = analysisGrid(origin: Vec3(repeating: -2.5), axes: [Vec3(0, 0.1, 0), Vec3(0.1, 0, 0), Vec3(0, 0, 0.1)], counts: [51, 51, 51]) {
                exp(-simd_length_squared($0) / 2) }
            let m2 = MarchingCubes.extract(grid: lh, isovalue: exp(-R * R / 2))
            try expect(MarchingCubes.enclosedVolume(m2) > 0 && MarchingCubes.isClosedManifold(m2))
        },
        Check("analysis.surface.lobes") {
            // p-like function: + lobe at +x, − lobe at −x.
            let h = 0.12
            let g = analysisGrid(origin: Vec3(repeating: -4), axes: [Vec3(h, 0, 0), Vec3(0, h, 0), Vec3(0, 0, h)], counts: [67, 67, 67]) {
                $0.x * exp(-simd_length_squared($0) / 2) }
            let lobes = MarchingCubes.orbitalLobes(grid: g, isovalue: 0.1)
            try expect(lobes.count == 2 && lobes[0].sign == .positive && lobes[1].sign == .negative)
            try expect(lobes[1].isovalue == -0.1)
            for (lobe, cx) in zip(lobes, [1.0, -1.0]) {
                try expect(!lobe.isEmpty && MarchingCubes.isClosedManifold(lobe))
                try expect(MarchingCubes.enclosedVolume(lobe) > 0, "winding")
                let mean = lobe.vertices.reduce(SIMD3<Float>(0, 0, 0), +) / Float(lobe.vertices.count)
                try expect(Double(mean.x) * cx > 0.5)
                try expect(meshNormalsOutward(lobe, center: Vec3(Double(mean.x), 0, 0)) > 0.99)
            }
            // Mirror symmetry: equal areas.
            try expect(abs(MarchingCubes.surfaceArea(lobes[0]) - MarchingCubes.surfaceArea(lobes[1])) < 1e-3)
        },
        Check("analysis.surface.randomFieldsClosed") {
            // Random fields (all 256 cases incl. ambiguous faces occur) with a low border are always watertight.
            var rng = SystemRandomNumberGenerator()
            var seen = Set<Int>()
            for _ in 0..<30 {
                let n = 10
                var v = [Float](repeating: -1, count: n * n * n)
                for i in 1..<(n - 1) { for j in 1..<(n - 1) { for k in 1..<(n - 1) { v[(i * n + j) * n + k] = Float.random(in: -1...1, using: &rng) } } }
                let g = VolumeGrid(origin: .zero, axes: [Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1)], counts: [n, n, n], values: v)
                for i in 0..<(n - 1) { for j in 0..<(n - 1) { for k in 0..<(n - 1) {
                    var c = 0
                    for b in 0..<8 where v[((i + (b & 1)) * n + j + ((b >> 1) & 1)) * n + k + ((b >> 2) & 1)] > 0 { c |= 1 << b }
                    seen.insert(c)
                } } }
                let m = MarchingCubes.extract(grid: g, isovalue: 0)
                try expect(MarchingCubes.isClosedManifold(m), "open mesh on random field")
                try expect(MarchingCubes.enclosedVolume(m) > 0)
                let neg = MarchingCubes.extract(grid: g, isovalue: -0.0)  // -0.0 is not < 0 → positive
                try expect(neg.sign == .positive)
            }
            try expect(seen.count > 200, "covered \(seen.count) cases")
        },
        Check("analysis.surface.trilinearSample") {
            let axes = [Vec3(0.3, 0, 0), Vec3(0.1, 0.25, 0), Vec3(0, 0.05, 0.2)]
            let f: (Vec3) -> Double = { 2 * $0.x - 3 * $0.y + 0.5 * $0.z + 1 }
            let g = analysisGrid(origin: Vec3(-1, -1, -1), axes: axes, counts: [8, 9, 10], f)
            for p in [Vec3(0, 0, 0), Vec3(0.3, -0.2, 0.1), Vec3(0.5, 0.4, -0.3)] {
                try expectClose(g.sample(atAngstrom: p), f(p), tol: 1e-5)
            }
            let spec = GridSpec.automatic(around: [Vec3(0, 0, 0), Vec3(1, 2, 3)], padding: 3, spacing: 0.25)
            try expect(spec.point(0, 0, 0).x <= -3 + 1e-9 && spec.point(spec.counts[0] - 1, 0, 0).x >= 4 - 1e-9)
            let capped = GridSpec.automatic(around: [Vec3(0, 0, 0)], padding: 10, spacing: 0.05, maxPoints: 100_000)
            try expect(capped.pointCount <= 100_000)
        },
        Check("analysis.surface.cubeFiles") {
            let cube = try CubeFile.read(url: testDataURL("io/cube_water_homo.cube"))
            let lobes = CubeSurfaces.lobes(cube, isovalue: 0.05)
            try expect(lobes.count == 2)
            // Round trip: computed density + p field → cube text → parse → identical surface.
            let g = analysisGrid(origin: Vec3(repeating: -3), axes: [Vec3(0.15, 0, 0), Vec3(0, 0.15, 0), Vec3(0, 0, 0.15)], counts: [41, 41, 41]) {
                exp(-simd_length_squared($0)) }
            let prop = analysisGrid(origin: Vec3(repeating: -3.2), axes: [Vec3(0.2, 0, 0), Vec3(0.05, 0.2, 0), Vec3(0, 0, 0.2)], counts: [34, 34, 34]) { $0.z }
            var mol = Molecule(); mol.atoms = [Atom(id: 0, atomicNumber: 1, position: .zero)]
            let text = CubeFile(title: "t", comment: "c", molecule: mol, grids: [g]).write(unitsAngstrom: false)
            let back = try CubeFile.parse(text)
            let direct = MarchingCubes.extract(grid: g, isovalue: 0.1)
            let viaCube = CubeSurfaces.surface(back, isovalue: 0.1)
            try expect(direct.triangleCount == viaCube.triangleCount)
            try expect(abs(MarchingCubes.surfaceArea(direct) - MarchingCubes.surfaceArea(viaCube)) < 1e-3)
            let mapped = CubeSurfaces.mapped(surface: g, isovalue: 0.1, property: prop)
            try expect(mapped.vertexScalars?.count == mapped.vertices.count && mapped.vertexColors?.count == mapped.vertices.count)
            for (p, s) in zip(mapped.vertices, mapped.vertexScalars!) { try expect(abs(Double(s) - Double(p.z)) < 1e-3) }
        },
    ]
}
