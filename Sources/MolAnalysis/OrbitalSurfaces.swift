import Foundation
import Accelerate
import simd
import MolCore
import MolIO

// Orbital surfaces with quality presets, adaptive grid boxes, a single-MO fast evaluator, analytic gradients and a cached service.

// MARK: - Quality

public enum OrbitalGridQuality: String, Codable, CaseIterable, Sendable, Hashable {
    case draft, normal, high, ultra

    /// Grid spacing in Å.
    public var spacing: Double {
        switch self { case .draft: return 0.25; case .normal: return 0.15; case .high: return 0.10; case .ultra: return 0.07 }
    }
    /// Upper bound on grid points (spacing is coarsened beyond this).
    public var maxPoints: Int {
        switch self { case .draft: return 500_000; case .normal: return 2_000_000; case .high: return 6_000_000; case .ultra: return 16_000_000 }
    }
}

// MARK: - Adaptive grid

extension GridSpec {
    /// Radius (Bohr) beyond which |c·N·r^l·exp(−a r²)| < `threshold` for every primitive of the shell (solved numerically).
    static func shellExtent(_ sh: PreparedShell, threshold: Double) -> Double {
        var best = 0.0
        let l = Double(sh.l)
        for (p, a) in sh.exponents.enumerated() {
            let amp = max(abs(sh.radial[p]), abs(sh.sRadial?[p] ?? 0))
            guard amp > 0, a > 0 else { continue }
            func f(_ r: Double) -> Double { amp * pow(r, l) * exp(-a * r * r) }
            let rPeak = (l / (2 * a)).squareRoot()
            if f(rPeak) < threshold { continue }
            var hi = rPeak + 1
            while f(hi) > threshold && hi < 1e4 { hi *= 2 }
            var lo = rPeak
            for _ in 0..<60 { let mid = 0.5 * (lo + hi); if f(mid) > threshold { lo = mid } else { hi = mid } }
            best = max(best, hi)
        }
        return best
    }

    /// Cubic-spaced grid whose box is the union of `atom ± extent` boxes. Each atom's extent comes from its basis functions'
    /// decay (`threshold`), clamped to [2, 8] Å. The spacing is coarsened if the point count would exceed `quality.maxPoints`.
    public static func adaptive(_ wf: Wavefunction, quality: OrbitalGridQuality, threshold: Double = 1e-4) -> GridSpec {
        let basis = AnalysisBasis(wf.basis)
        var radius = [Int: Double]()
        for s in basis.shells {
            let r = shellExtent(BasisPreparation.prepare(s), threshold: threshold) * PhysConst.bohrToAngstrom
            radius[s.atomIndex] = max(radius[s.atomIndex] ?? 0, r)
        }
        let pos = WavefunctionSurfaces.atomPositions(wf)
        var lo = Vec3(repeating: .infinity), hi = Vec3(repeating: -.infinity)
        for (i, p) in pos.enumerated() {
            let r = min(max(radius[i] ?? 0, 2.0), 8.0)
            lo = simd_min(lo, p - Vec3(repeating: r)); hi = simd_max(hi, p + Vec3(repeating: r))
        }
        if pos.isEmpty { lo = Vec3(repeating: -4); hi = Vec3(repeating: 4) }
        return make(lo: lo, hi: hi, spacing: quality.spacing, maxPoints: quality.maxPoints)
    }

    static func make(lo: Vec3, hi: Vec3, spacing: Double, maxPoints: Int) -> GridSpec {
        let ext = hi - lo
        var h = spacing
        func counts(_ h: Double) -> [Int] { (0..<3).map { max(2, Int((ext[$0] / h).rounded(.up)) + 1) } }
        var c = counts(h)
        while c.reduce(1, *) > maxPoints { h *= 1.03; c = counts(h) }
        let span = Vec3(Double(c[0] - 1), Double(c[1] - 1), Double(c[2] - 1)) * h
        let origin = (lo + hi) / 2 - span / 2
        return GridSpec(origin: origin, axes: [Vec3(h, 0, 0), Vec3(0, h, 0), Vec3(0, 0, h)], counts: c)
    }
}

// MARK: - Single-MO fast evaluation and gradients

extension OrbitalEvaluator {
    /// Per-shell data for a single orbital: the orbital's coefficients are folded into effective monomial coefficients so a
    /// shell contributes  R(r)·P(x,y,z)  (plus an s part for SP shells) without forming individual basis functions.
    struct OrbitalShell {
        var center: Vec3
        var cutoff2: Double
        var exps: [Double], radial: [Double]
        var sRadial: [Double]?
        var sCoef: Double
        var mi: [Int], mj: [Int], mk: [Int]
        var ceff: [Double]
        var l: Int
    }

    func orbitalShells(_ c: [Double]) -> [OrbitalShell] {
        precondition(c.count == functionCount, "coefficient count \(c.count) != basis functions \(functionCount)")
        var out: [OrbitalShell] = []
        for (si, sh) in shells.enumerated() {
            let base = offsets[si]
            let lOff = sh.sRadial == nil ? 0 : 1
            let nm = sh.monomials.count
            var ceff = [Double](repeating: 0, count: nm)
            for f in 0..<sh.lFunctionCount {
                let cf = c[base + lOff + f]
                if cf == 0 { continue }
                for k in 0..<nm { ceff[k] += cf * sh.transform[f * nm + k] }
            }
            let sc = sh.sRadial == nil ? 0 : c[base]
            if sc == 0 && !ceff.contains(where: { $0 != 0 }) { continue }
            out.append(OrbitalShell(center: sh.center, cutoff2: sh.cutoff2, exps: sh.exponents, radial: sh.radial, sRadial: sh.sRadial,
                                    sCoef: sc, mi: sh.monomials.map { $0.0 }, mj: sh.monomials.map { $0.1 }, mk: sh.monomials.map { $0.2 },
                                    ceff: ceff, l: sh.l))
        }
        return out
    }

    /// Fast single-orbital grid evaluation (no BLAS): per grid line, each shell is clipped to the sub-segment inside its
    /// cutoff sphere, contributions are accumulated with vectorized exp. Parallel over x-slabs. `nil` if cancelled.
    public func evaluateOrbitalFast(_ coefficients: [Double], on grid: GridSpec, isCancelled: (@Sendable () -> Bool)? = nil) -> VolumeGrid? {
        let nx = grid.counts[0], ny = grid.counts[1], nz = grid.counts[2]
        var values = [Float](repeating: 0, count: nx * ny * nz)
        let b2a = PhysConst.angstromToBohr
        let o = grid.origin * b2a, a0 = grid.axes[0] * b2a, a1 = grid.axes[1] * b2a, a2 = grid.axes[2] * b2a
        let osh = orbitalShells(coefficients)
        let cancelled = ManagedAtomicFlag()
        let A = simd_dot(a2, a2)
        values.withUnsafeMutableBufferPointer { vbuf in
            let vptr = vbuf.baseAddress!
            DispatchQueue.concurrentPerform(iterations: nx) { i in
                if cancelled.value { return }
                if let isCancelled, isCancelled() { cancelled.set(); return }
                let n = nz
                let line = UnsafeMutablePointer<Double>.allocate(capacity: n)
                let r2 = UnsafeMutablePointer<Double>.allocate(capacity: n)
                let tmp = UnsafeMutablePointer<Double>.allocate(capacity: n)
                let rad = UnsafeMutablePointer<Double>.allocate(capacity: n)
                let srad = UnsafeMutablePointer<Double>.allocate(capacity: n)
                let dxs = UnsafeMutablePointer<Double>.allocate(capacity: 3 * n)
                defer { line.deallocate(); r2.deallocate(); tmp.deallocate(); rad.deallocate(); srad.deallocate(); dxs.deallocate() }
                var pw = [Double](repeating: 1, count: 24)
                for j in 0..<ny {
                    let start = o + Double(i) * a0 + Double(j) * a1
                    line.update(repeating: 0, count: n)
                    for sh in osh {
                        let d = start - sh.center
                        let B = simd_dot(d, a2), C = simd_dot(d, d) - sh.cutoff2
                        let disc = B * B - A * C
                        if disc < 0 { continue }
                        let sq = disc.squareRoot()
                        let k0 = max(0, Int(((-B - sq) / A).rounded(.up))), k1 = min(n - 1, Int(((-B + sq) / A).rounded(.down)))
                        if k0 > k1 { continue }
                        let m = k1 - k0 + 1
                        for t in 0..<m {
                            let q = d + Double(k0 + t) * a2
                            dxs[t] = q.x; dxs[m + t] = q.y; dxs[2 * m + t] = q.z
                            r2[t] = q.x * q.x + q.y * q.y + q.z * q.z
                        }
                        rad.update(repeating: 0, count: m)
                        let hasS = sh.sRadial != nil && sh.sCoef != 0
                        if hasS { srad.update(repeating: 0, count: m) }
                        var cnt = Int32(m)
                        for p in 0..<sh.exps.count {
                            var na = -sh.exps[p]
                            vDSP_vsmulD(r2, 1, &na, tmp, 1, vDSP_Length(m))
                            vvexp(tmp, tmp, &cnt)
                            var c = sh.radial[p]
                            vDSP_vsmaD(tmp, 1, &c, rad, 1, rad, 1, vDSP_Length(m))
                            if hasS { var cs = sh.sRadial![p]; vDSP_vsmaD(tmp, 1, &cs, srad, 1, srad, 1, vDSP_Length(m)) }
                        }
                        let nm = sh.ceff.count, L = sh.l
                        for t in 0..<m {
                            var v = 0.0
                            if hasS { v += sh.sCoef * srad[t] }
                            let x = dxs[t], y = dxs[m + t], z = dxs[2 * m + t]
                            var poly = 0.0
                            if L == 0 { poly = sh.ceff[0] }
                            else if L == 1 { poly = sh.ceff[0] * x + sh.ceff[1] * y + sh.ceff[2] * z; if !(sh.mi[0] == 1 && sh.mj[1] == 1 && sh.mk[2] == 1) { poly = polyGeneral(sh, x, y, z, &pw, nm) } }
                            else { poly = polyGeneral(sh, x, y, z, &pw, nm) }
                            v += rad[t] * poly
                            line[k0 + t] += v
                        }
                    }
                    let rowBase = vptr + (i * ny + j) * nz
                    for k in 0..<n { rowBase[k] = Float(line[k]) }
                }
            }
        }
        if cancelled.value { return nil }
        return grid.volumeGrid(values: values)
    }

    @inline(__always) private func polyGeneral(_ sh: OrbitalShell, _ x: Double, _ y: Double, _ z: Double, _ pw: inout [Double], _ nm: Int) -> Double {
        pw[0] = 1; pw[8] = 1; pw[16] = 1
        for e in 1...max(sh.l, 1) { pw[e] = pw[e - 1] * x; pw[8 + e] = pw[7 + e] * y; pw[16 + e] = pw[15 + e] * z }
        var s = 0.0
        for k in 0..<nm { s += sh.ceff[k] * pw[sh.mi[k]] * pw[8 + sh.mj[k]] * pw[16 + sh.mk[k]] }
        return s
    }

    /// Orbital values and analytic Cartesian gradients (per Bohr) at points in Bohr.
    public func valuesAndGradients(coefficients: [Double], atBohr points: [Vec3]) -> (values: [Double], gradients: [Vec3]) {
        let osh = orbitalShells(coefficients)
        let n = points.count
        var vals = [Double](repeating: 0, count: n), grads = [Vec3](repeating: .zero, count: n)
        let chunk = 2048
        let chunks = (n + chunk - 1) / chunk
        vals.withUnsafeMutableBufferPointer { vb in grads.withUnsafeMutableBufferPointer { gb in
            let vp = vb.baseAddress!, gp = gb.baseAddress!
            DispatchQueue.concurrentPerform(iterations: chunks) { ch in
                var pw = [Double](repeating: 1, count: 24)
                for pi in (ch * chunk)..<min(n, (ch + 1) * chunk) {
                    var v = 0.0, g = Vec3.zero
                    for sh in osh {
                        let d = points[pi] - sh.center
                        let r2 = simd_dot(d, d)
                        if r2 >= sh.cutoff2 { continue }
                        var R = 0.0, dR = 0.0, S = 0.0, dS = 0.0
                        for p in 0..<sh.exps.count {
                            let e = exp(-sh.exps[p] * r2)
                            R += sh.radial[p] * e; dR += -2 * sh.exps[p] * sh.radial[p] * e
                            if let sr = sh.sRadial { S += sr[p] * e; dS += -2 * sh.exps[p] * sr[p] * e }
                        }
                        if sh.sRadial != nil && sh.sCoef != 0 { v += sh.sCoef * S; g += sh.sCoef * dS * d }
                        pw[0] = 1; pw[8] = 1; pw[16] = 1
                        if sh.l > 0 { for e in 1...sh.l { pw[e] = pw[e - 1] * d.x; pw[8 + e] = pw[7 + e] * d.y; pw[16 + e] = pw[15 + e] * d.z } }
                        var P = 0.0, gP = Vec3.zero
                        for k in 0..<sh.ceff.count {
                            let c = sh.ceff[k]
                            if c == 0 { continue }
                            let i = sh.mi[k], j = sh.mj[k], kk = sh.mk[k]
                            let xi = pw[i], yj = pw[8 + j], zk = pw[16 + kk]
                            P += c * xi * yj * zk
                            if i > 0 { gP.x += c * Double(i) * pw[i - 1] * yj * zk }
                            if j > 0 { gP.y += c * Double(j) * xi * pw[8 + j - 1] * zk }
                            if kk > 0 { gP.z += c * Double(kk) * xi * yj * pw[16 + kk - 1] }
                        }
                        v += R * P
                        g += R * gP + (P * dR) * d
                    }
                    vp[pi] = v; gp[pi] = g
                }
            }
        } }
        return (vals, grads)
    }
}

// MARK: - Service

public struct OrbitalSurfaceRequest: Hashable, Sendable {
    public var orbital: Int
    public var spin: WavefunctionSurfaces.Spin
    public var isovalue: Double
    public var quality: OrbitalGridQuality
    public var smoothing: Int
    public var maxTriangles: Int?
    public init(orbital: Int, spin: WavefunctionSurfaces.Spin = .alpha, isovalue: Double = 0.02, quality: OrbitalGridQuality = .normal,
                smoothing: Int = 0, maxTriangles: Int? = 400_000) {
        self.orbital = orbital; self.spin = spin; self.isovalue = isovalue; self.quality = quality
        self.smoothing = smoothing; self.maxTriangles = maxTriangles
    }
}

public struct OrbitalSurfaceResult: Sendable {
    public var meshes: [IsoSurfaceMesh]       // [+lobe, −lobe]
    public var isOccupied: Bool
    public var isHOMO: Bool
    public var isLUMO: Bool
    public var energy: Double                 // Hartree
    public var occupation: Double
    public var grid: GridSpec
    /// Seconds: "grid" (evaluation; ~0 when cached), "mesh" (marching cubes), "post" (decimation/smoothing).
    public var timings: [String: Double]
}

public enum OrbitalSurfaceError: Error, CustomStringConvertible {
    case orbitalOutOfRange(Int, Int)
    public var description: String {
        switch self { case .orbitalOutOfRange(let i, let n): return "orbital \(i) out of range (0..<\(n))" }
    }
}

public actor OrbitalSurfaceService {
    struct Key: Hashable { var orbital: Int; var spin: WavefunctionSurfaces.Spin; var quality: OrbitalGridQuality }

    public let wavefunction: Wavefunction
    let evaluator: OrbitalEvaluator
    let cacheLimit: Int
    private var cache: [Key: VolumeGrid] = [:]
    private var order: [Key] = []

    public init(wavefunction: Wavefunction, cacheLimit: Int = 8) {
        self.wavefunction = wavefunction
        self.evaluator = OrbitalEvaluator(wavefunction: wavefunction)
        self.cacheLimit = max(1, cacheLimit)
    }

    public func clearCache() { cache.removeAll(); order.removeAll() }

    private func orbitalSet(_ spin: WavefunctionSurfaces.Spin) -> MOCoefficients { spin == .beta ? (wavefunction.beta ?? wavefunction.alpha) : wavefunction.alpha }

    public func grid(orbital: Int, spin: WavefunctionSurfaces.Spin, quality: OrbitalGridQuality) async throws -> VolumeGrid {
        try await gridTimed(orbital: orbital, spin: spin, quality: quality).0
    }

    func gridTimed(orbital: Int, spin: WavefunctionSurfaces.Spin, quality: OrbitalGridQuality) async throws -> (VolumeGrid, Double) {
        let set = orbitalSet(spin)
        guard orbital >= 0, orbital < set.orbitalCount else { throw OrbitalSurfaceError.orbitalOutOfRange(orbital, set.orbitalCount) }
        let key = Key(orbital: orbital, spin: spin, quality: quality)
        if let g = cache[key] {
            order.removeAll { $0 == key }; order.append(key)
            return (g, 0)
        }
        let t0 = DispatchTime.now()
        let spec = GridSpec.adaptive(wavefunction, quality: quality)
        let coeffs = Array(set.orbital(orbital))
        let ev = evaluator
        let result = await runCancellableWork { isCancelled in ev.evaluateOrbitalFast(coeffs, on: spec, isCancelled: isCancelled) }
        guard let g = result, !Task.isCancelled else { throw CancellationError() }
        cache[key] = g; order.append(key)
        while order.count > cacheLimit { cache[order.removeFirst()] = nil }
        return (g, Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e9)
    }

    public func surfaces(_ request: OrbitalSurfaceRequest) async throws -> OrbitalSurfaceResult {
        let wf = wavefunction
        let set = orbitalSet(request.spin)
        let (grid, tGrid) = try await gridTimed(orbital: request.orbital, spin: request.spin, quality: request.quality)
        let ev = evaluator
        let coeffs = Array(set.orbital(request.orbital))
        let req = request
        let work = await runCancellableWork { _ -> ([IsoSurfaceMesh], Double, Double)? in
            let t0 = DispatchTime.now()
            var meshes = MarchingCubes.orbitalLobes(grid: grid, isovalue: req.isovalue)
            let t1 = DispatchTime.now()
            for i in meshes.indices {
                if let mt = req.maxTriangles, meshes[i].triangleCount > mt { meshes[i] = MeshProcessing.decimate(meshes[i], targetTriangles: mt) }
                if req.smoothing > 0 { meshes[i] = MeshProcessing.taubinSmooth(meshes[i], iterations: req.smoothing) }
            }
            let t2 = DispatchTime.now()
            _ = ev
            _ = coeffs
            return (meshes, Double(t1.uptimeNanoseconds - t0.uptimeNanoseconds) / 1e9, Double(t2.uptimeNanoseconds - t1.uptimeNanoseconds) / 1e9)
        }
        guard let (meshes, tMesh, tPost) = work else { throw CancellationError() }
        try Task.checkCancellation()
        let occ = request.spin == .beta ? wf.betaElectrons : wf.alpha.occupiedCount
        let perOrbital = (wf.beta != nil || wf.alphaElectrons != wf.betaElectrons) ? 1.0 : 2.0
        let occupied = request.orbital < occ
        return OrbitalSurfaceResult(
            meshes: meshes, isOccupied: occupied, isHOMO: request.orbital == occ - 1, isLUMO: request.orbital == occ,
            energy: request.orbital < set.energies.count ? set.energies[request.orbital] : 0,
            occupation: occupied ? perOrbital : 0, grid: GridSpec(grid),
            timings: ["grid": tGrid, "mesh": tMesh, "post": tPost])
    }
}
