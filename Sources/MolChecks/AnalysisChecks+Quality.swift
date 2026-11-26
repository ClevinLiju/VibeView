import Foundation
import MolSIMD
import MolCore
import MolIO
import MolAnalysis

// Lead D round 3 (worker 2): orbital quality — adaptive grids, mesh processing, analytic gradients, surface service.

private func qualityWavefunction() throws -> Wavefunction {
    guard let wf = try MoldenFile.read(url: testDataURL("io/orca/h2co_tddft.molden.input")).wavefunction else {
        throw CheckFailure(description: "no wavefunction in h2co_tddft.molden.input")
    }
    return wf
}

private func secondsSince(_ t0: DispatchTime) -> Double { Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e9 }

/// Sphere of radius `r` Å at the origin via marching cubes on f = r − |x| (inside positive).
private func sphereMesh(radius: Double = 3.0, spacing: Double = 0.25) -> IsoSurfaceMesh {
    let n = Int((2 * (radius + 1)) / spacing) + 1
    let o = -(radius + 1)
    var vals = [Float](repeating: 0, count: n * n * n)
    for i in 0..<n { for j in 0..<n { for k in 0..<n {
        let p = Vec3(o + Double(i) * spacing, o + Double(j) * spacing, o + Double(k) * spacing)
        vals[(i * n + j) * n + k] = Float(radius - simd_length(p))
    } } }
    let g = VolumeGrid(origin: Vec3(repeating: o), axes: [Vec3(spacing, 0, 0), Vec3(0, spacing, 0), Vec3(0, 0, spacing)], counts: [n, n, n], values: vals)
    return MarchingCubes.extract(grid: g, isovalue: 0.001)
}

extension Checks {
    static let analysisQuality: [Check] = [
        Check("analysis.quality.adaptiveBounds") {
            let wf = try qualityWavefunction()
            let g = GridSpec.adaptive(wf, quality: .normal)
            let hi = g.origin + Double(g.counts[0] - 1) * g.axes[0] + Double(g.counts[1] - 1) * g.axes[1] + Double(g.counts[2] - 1) * g.axes[2]
            for p in WavefunctionSurfaces.atomPositions(wf) {
                for d in 0..<3 { try expect(p[d] - g.origin[d] >= 2.0 - 1e-9 && hi[d] - p[d] >= 2.0 - 1e-9, "atom within 2 A of grid edge on axis \(d)") }
            }
            let fixed = GridSpec.automatic(around: WavefunctionSurfaces.atomPositions(wf), padding: 4.0, spacing: 0.15, maxPoints: 2_000_000)
            let ext = hi - g.origin
            let fhi = fixed.origin + Double(fixed.counts[0] - 1) * fixed.axes[0] + Double(fixed.counts[1] - 1) * fixed.axes[1] + Double(fixed.counts[2] - 1) * fixed.axes[2]
            let fext = fhi - fixed.origin
            print(String(format: "    adaptive box %.1f x %.1f x %.1f A (%d pts) vs fixed 4 A padding %.1f x %.1f x %.1f A (%d pts)",
                         ext.x, ext.y, ext.z, g.pointCount, fext.x, fext.y, fext.z, fixed.pointCount))
            // The orbital value at the box edge must be negligible.
            let ev = OrbitalEvaluator(wavefunction: wf)
            let mo = Array(wf.alpha.orbital(wf.homoIndex!))
            let vg = ev.evaluateOrbitalFast(mo, on: g)!
            var edgeMax: Float = 0
            let nx = g.counts[0], ny = g.counts[1], nz = g.counts[2]
            for i in 0..<nx { for j in 0..<ny { for k in [0, nz - 1] { edgeMax = max(edgeMax, abs(vg.values[(i * ny + j) * nz + k])) } } }
            for i in [0, nx - 1] { for j in 0..<ny { for k in 0..<nz { edgeMax = max(edgeMax, abs(vg.values[(i * ny + j) * nz + k])) } } }
            try expect(edgeMax < 1e-3, "HOMO at box edge \(edgeMax)")
        },
        Check("analysis.quality.fastMatchesReference") {
            let wf = try qualityWavefunction()
            let ev = OrbitalEvaluator(wavefunction: wf)
            let g = GridSpec.adaptive(wf, quality: .draft)
            for mo in [0, 3, wf.homoIndex!, wf.homoIndex! + 2] {
                let c = Array(wf.alpha.orbital(mo))
                let a = ev.evaluate(.orbital(c), on: g)!, b = ev.evaluateOrbitalFast(c, on: g)!
                var worst: Float = 0
                for (x, y) in zip(a.values, b.values) { worst = max(worst, abs(x - y)) }
                try expect(worst < 1e-5, "MO \(mo): fast vs reference max diff \(worst)")
            }
        },
        Check("analysis.quality.weld") {
            var m = sphereMesh()
            let n0 = m.vertices.count
            // Unweld: one vertex per triangle corner.
            var u = IsoSurfaceMesh(sign: m.sign, isovalue: m.isovalue)
            for idx in m.indices { u.vertices.append(m.vertices[Int(idx)]); u.normals.append(m.normals[Int(idx)]); u.indices.append(UInt32(u.vertices.count - 1)) }
            try expect(u.vertices.count > n0)
            let w = MeshProcessing.weld(u, tolerance: 1e-4)
            try expect(w.vertices.count == n0, "welded \(w.vertices.count) != \(n0)")
            try expect(w.triangleCount == m.triangleCount && MarchingCubes.isClosedManifold(w), "closed after weld")
            m = w
        },
        Check("analysis.quality.taubin") {
            let m = sphereMesh(radius: 3.0, spacing: 0.25)
            let v0 = MarchingCubes.enclosedVolume(m)
            let s = MeshProcessing.taubinSmooth(m, iterations: 10)
            let v1 = MarchingCubes.enclosedVolume(s)
            try expect(abs(v1 - v0) / v0 < 0.05, "volume change \((v1 - v0) / v0)")
            try expect(s.sign == m.sign && s.isovalue == m.isovalue && s.normals.count == s.vertices.count)
            // Jittered copy: roughness must drop and volume stay.
            var j = m
            var seed: UInt64 = 12345
            func rnd() -> Float { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Float(seed >> 40) / Float(1 << 24) - 0.5 }
            for i in j.vertices.indices { j.vertices[i] += SIMD3<Float>(rnd(), rnd(), rnd()) * 0.08 }
            let r0 = MeshProcessing.roughness(j)
            let sj = MeshProcessing.taubinSmooth(j, iterations: 10)
            let r1 = MeshProcessing.roughness(sj)
            let vj = MarchingCubes.enclosedVolume(sj)
            print(String(format: "    taubin: volume change %.2f%%, roughness %.4f -> %.4f (jittered)", 100 * (v1 - v0) / v0, r0, r1))
            try expect(r1 < 0.5 * r0, "roughness \(r0) -> \(r1)")
            try expect(abs(vj - v0) / v0 < 0.05, "jittered smoothed volume \(vj) vs \(v0)")
        },
        Check("analysis.quality.decimate") {
            let m = sphereMesh(radius: 3.0, spacing: 0.1)
            let v0 = MarchingCubes.enclosedVolume(m)
            let target = m.triangleCount / 8
            let d = MeshProcessing.decimate(m, targetTriangles: target)
            let v1 = MarchingCubes.enclosedVolume(d)
            print("    decimate: \(m.triangleCount) -> \(d.triangleCount) triangles (target \(target)), closed=\(MarchingCubes.isClosedManifold(d)), volume change \(String(format: "%.2f", 100 * (v1 - v0) / v0))%")
            try expect(d.triangleCount <= target && d.triangleCount > target / 4, "triangle count \(d.triangleCount)")
            try expect(abs(v1 - v0) / v0 < 0.1, "volume change")
            try expect(d.normals.count == d.vertices.count)
            let rn = MeshProcessing.recomputeNormals(d)
            var agree = 0
            for i in rn.normals.indices where simd_dot(rn.normals[i], d.normals[i]) > 0 { agree += 1 }
            try expect(agree == rn.normals.count, "recomputed normals disagree with outward normals")
        },
        Check("analysis.quality.analyticGradient") {
            let wf = try qualityWavefunction()
            let ev = OrbitalEvaluator(wavefunction: wf)
            var pts: [Vec3] = []
            var seed: UInt64 = 99
            func rnd() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 11) / Double(1 << 53) }
            let nuc = wf.nuclearPositions
            for _ in 0..<60 { let a = nuc[Int(rnd() * Double(nuc.count)) % nuc.count]; pts.append(a + Vec3(rnd() - 0.5, rnd() - 0.5, rnd() - 0.5) * 4) }
            for mo in [0, 4, wf.homoIndex!, wf.homoIndex! + 1] {
                let c = Array(wf.alpha.orbital(mo))
                let (vals, gr) = ev.valuesAndGradients(coefficients: c, atBohr: pts)
                let ref = ev.values(coefficients: c, atBohr: pts)
                var worstV = 0.0, worstG = 0.0
                let h = 1e-4
                for (i, p) in pts.enumerated() {
                    worstV = max(worstV, abs(vals[i] - ref[i]))
                    var fd = Vec3.zero
                    for d in 0..<3 {
                        var e = Vec3.zero; e[d] = h
                        let vv = ev.values(coefficients: c, atBohr: [p + e, p - e])
                        fd[d] = (vv[0] - vv[1]) / (2 * h)
                    }
                    worstG = max(worstG, simd_length(fd - gr[i]) / max(simd_length(fd), 1e-3))
                }
                try expect(worstV < 1e-10, "MO \(mo) value mismatch \(worstV)")
                try expect(worstG < 1e-4, "MO \(mo) gradient rel err \(worstG)")
            }
            // analyticNormals: unit length, outward (agree with marching-cubes normals).
            let homo = Array(wf.alpha.orbital(wf.homoIndex!))
            let g = GridSpec.adaptive(wf, quality: .draft)
            let grid = ev.evaluateOrbitalFast(homo, on: g)!
            let lobes = MarchingCubes.orbitalLobes(grid: grid, isovalue: 0.03)
            for lobe in lobes where !lobe.isEmpty {
                let a = MeshProcessing.analyticNormals(lobe, evaluator: ev, coefficients: homo)
                var agree = 0
                for i in a.normals.indices {
                    try expect(abs(simd_length(a.normals[i]) - 1) < 1e-4)
                    if simd_dot(a.normals[i], lobe.normals[i]) > 0.9 { agree += 1 }
                }
                try expect(Double(agree) > 0.95 * Double(a.normals.count), "analytic vs grid normals agree for \(agree)/\(a.normals.count)")
            }
        },
        Check("analysis.quality.serviceCache") {
            let wf = try qualityWavefunction()
            let svc = OrbitalSurfaceService(wavefunction: wf, cacheLimit: 2)
            let req = OrbitalSurfaceRequest(orbital: wf.homoIndex!, quality: .normal)
            let r1 = try runAsync { try await svc.surfaces(req) }
            let r2 = try runAsync { try await svc.surfaces(req) }
            print(String(format: "    service: first grid %.3f s, second grid %.4f s (mesh %.3f s)", r1.timings["grid"]!, r2.timings["grid"]!, r1.timings["mesh"]!))
            try expect(r1.timings["grid"]! > 0 && r2.timings["grid"]! < r1.timings["grid"]! * 0.2 + 1e-3, "cache not faster")
            try expect(r1.meshes == r2.meshes && !r1.meshes[0].isEmpty && !r1.meshes[1].isEmpty, "same non-empty lobes")
            // LRU: after two other qualities the first is evicted (limit 2).
            _ = try runAsync { try await svc.grid(orbital: 0, spin: .alpha, quality: .draft) }
            _ = try runAsync { try await svc.grid(orbital: 1, spin: .alpha, quality: .draft) }
            let r3 = try runAsync { try await svc.surfaces(req) }
            try expect(r3.timings["grid"]! > 0, "evicted entry should be recomputed")
            // Decimation / smoothing options.
            let r4 = try runAsync { try await svc.surfaces(OrbitalSurfaceRequest(orbital: wf.homoIndex!, quality: .normal, smoothing: 5, maxTriangles: 2000)) }
            try expect(r4.meshes.allSatisfy { $0.triangleCount <= 2000 })
            // Bad index.
            var threw = false
            do { _ = try runAsync { try await svc.surfaces(OrbitalSurfaceRequest(orbital: 9999)) } } catch { threw = true }
            try expect(threw, "out-of-range orbital should throw")
        },
        Check("analysis.quality.homoLumoFlags") {
            let wf = try qualityWavefunction()
            let svc = OrbitalSurfaceService(wavefunction: wf)
            let occ = wf.alphaElectrons
            for (mo, occupied, homo, lumo) in [(occ - 2, true, false, false), (occ - 1, true, true, false), (occ, false, false, true), (occ + 1, false, false, false)] {
                let r = try runAsync { try await svc.surfaces(OrbitalSurfaceRequest(orbital: mo, quality: .draft)) }
                try expect(r.isOccupied == occupied && r.isHOMO == homo && r.isLUMO == lumo, "flags for MO \(mo)")
                try expectClose(r.energy, wf.alpha.energies[mo], tol: 1e-12)
                try expectClose(r.occupation, occupied ? 2 : 0)
            }
        },
        Check("analysis.quality.timingH2CO") {
            let wf = try qualityWavefunction()
            let svc = OrbitalSurfaceService(wavefunction: wf, cacheLimit: 1)
            print("    quality  points      eval(s)  mesh(s)  post(s)  triangles")
            for q in OrbitalGridQuality.allCases {
                let t0 = DispatchTime.now()
                let r = try runAsync { try await svc.surfaces(OrbitalSurfaceRequest(orbital: wf.homoIndex!, quality: q, maxTriangles: nil)) }
                let total = secondsSince(t0)
                let tri = r.meshes.reduce(0) { $0 + $1.triangleCount }
                print(String(format: "    %-7@  %9d  %7.3f  %7.3f  %7.3f  %9d", q.rawValue as NSString, r.grid.pointCount, r.timings["grid"]!, r.timings["mesh"]!, r.timings["post"]!, tri))
                try expect(total < 60, "\(q) took \(total) s")
                try expect(tri > 0)
            }
        },
    ]
}

private func runAsync<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
    try computeRunAsync(timeout: 120, body)
}
