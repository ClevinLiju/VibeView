import Foundation
import MolCore
import MolIO
import MolSIMD

/// Evaluates basis functions, molecular orbitals and densities on points or grids.
/// Basis functions are computed in batches along grid lines (vectorized `vvexp`), orbitals are formed
/// with BLAS (`cblas_dgemm`; a blocked, zero-skipping Swift kernel where Accelerate is unavailable, see
/// `PortableLA`), and grid slabs run concurrently via `DispatchQueue.concurrentPerform`.
public struct OrbitalEvaluator: Sendable {
    public let basis: AnalysisBasis
    let shells: [PreparedShell]
    let offsets: [Int]
    public let functionCount: Int

    public init(basis: AnalysisBasis) {
        self.basis = basis
        self.shells = basis.shells.map(BasisPreparation.prepare)
        var off: [Int] = [], n = 0
        for s in shells { off.append(n); n += s.functionCount }
        self.offsets = off
        self.functionCount = n
    }

    public init(basis: BasisSet) { self.init(basis: AnalysisBasis(basis)) }
    public init(wavefunction: Wavefunction) { self.init(basis: wavefunction.basis) }

    // MARK: Point evaluation

    /// Basis-function values at `n` points (Bohr), written point-major into `out[n * functionCount]`.
    func basisValues(_ px: UnsafePointer<Double>, _ py: UnsafePointer<Double>, _ pz: UnsafePointer<Double>, n: Int,
                     out: UnsafeMutablePointer<Double>, scratch: UnsafeMutablePointer<Double>) {
        let nbf = functionCount
        out.update(repeating: 0, count: n * nbf)
        let r2 = scratch, tmp = scratch + n, rad = scratch + 2 * n, srad = scratch + 3 * n
        let dx = scratch + 4 * n, dy = scratch + 5 * n, dz = scratch + 6 * n
        let pw = UnsafeMutablePointer<Double>.allocate(capacity: 24)
        defer { pw.deallocate() }
        for (si, sh) in shells.enumerated() {
            var anyNear = false
            for p in 0..<n {
                let x = px[p] - sh.center.x, y = py[p] - sh.center.y, z = pz[p] - sh.center.z
                dx[p] = x; dy[p] = y; dz[p] = z
                let d = x * x + y * y + z * z
                r2[p] = d
                if d < sh.cutoff2 { anyNear = true }
            }
            guard anyNear else { continue }
            rad.update(repeating: 0, count: n)
            if sh.sRadial != nil { srad.update(repeating: 0, count: n) }
            for (pi, a) in sh.exponents.enumerated() {
                if let s = sh.sRadial {
                    PortableLA.accumulateGaussian(r2: r2, alpha: a, count: n, tmp: tmp, c: sh.radial[pi], rad: rad,
                                                  cs: s[pi], srad: srad)
                } else {
                    PortableLA.accumulateGaussian(r2: r2, alpha: a, count: n, tmp: tmp, c: sh.radial[pi], rad: rad)
                }
            }
            let base = offsets[si]
            let lOff = sh.sRadial == nil ? 0 : 1
            let nm = sh.monomials.count
            let nf = sh.lFunctionCount
            for p in 0..<n where r2[p] < sh.cutoff2 {
                let row = out + p * nbf + base
                if sh.sRadial != nil { row[0] = srad[p] }
                let r = rad[p]
                switch sh.l {
                case 0: row[lOff] = sh.transform[0] * r
                case 1:
                    row[lOff] = dx[p] * r; row[lOff + 1] = dy[p] * r; row[lOff + 2] = dz[p] * r
                default:
                    let L = sh.l
                    pw[0] = 1; pw[8] = 1; pw[16] = 1
                    for e in 1...L { pw[e] = pw[e - 1] * dx[p]; pw[8 + e] = pw[7 + e] * dy[p]; pw[16 + e] = pw[15 + e] * dz[p] }
                    for f in 0..<nf { row[lOff + f] = 0 }
                    sh.transform.withUnsafeBufferPointer { w in
                        for (k, m) in sh.monomials.enumerated() {
                            let v = pw[m.0] * pw[8 + m.1] * pw[16 + m.2] * r
                            if v == 0 { continue }
                            for f in 0..<nf {
                                let c = w[f * nm + k]
                                if c != 0 { row[lOff + f] += c * v }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Basis-function values at points (Bohr): `[point][function]`.
    public func basisValues(atBohr points: [Vec3]) -> [[Double]] {
        let n = points.count, nbf = functionCount
        guard n > 0 else { return [] }
        var out = [Double](repeating: 0, count: n * nbf)
        var scratch = [Double](repeating: 0, count: 7 * n)
        let xs = points.map(\.x), ys = points.map(\.y), zs = points.map(\.z)
        out.withUnsafeMutableBufferPointer { o in scratch.withUnsafeMutableBufferPointer { s in
            basisValues(xs, ys, zs, n: n, out: o.baseAddress!, scratch: s.baseAddress!)
        } }
        return (0..<n).map { Array(out[($0 * nbf)..<(($0 + 1) * nbf)]) }
    }

    /// Value of the orbital with AO `coefficients` at points (Bohr).
    public func values(coefficients: [Double], atBohr points: [Vec3]) -> [Double] {
        basisValues(atBohr: points).map { row in zip(row, coefficients).reduce(0) { $0 + $1.0 * $1.1 } }
    }

    // MARK: Grid evaluation

    /// Kind of field to evaluate on a grid.
    public enum Field: Sendable {
        /// Σ_μ c_μ χ_μ.
        case orbital([Double])
        /// Σ_i w_i |ψ_i|² over orbitals given as rows (each `functionCount` long) with weights (occupations;
        /// negative weights give spin densities).
        case orbitalDensity(orbitals: [[Double]], weights: [Double])
        /// Σ_μν P_μν χ_μ χ_ν with a full symmetric n×n matrix (row-major).
        case densityMatrix([Double])
    }

    /// Evaluates `field` on `grid` (Å). Returns `nil` if `isCancelled` became true.
    public func evaluate(_ field: Field, on grid: GridSpec, isCancelled: (@Sendable () -> Bool)? = nil) -> VolumeGrid? {
        let nx = grid.counts[0], ny = grid.counts[1], nz = grid.counts[2]
        let nbf = functionCount
        var values = [Float](repeating: 0, count: nx * ny * nz)
        let b2a = PhysConst.angstromToBohr
        let o = grid.origin * b2a, a0 = grid.axes[0] * b2a, a1 = grid.axes[1] * b2a, a2 = grid.axes[2] * b2a

        // Coefficient matrix C (nbf × ncol) and weights.
        var cmat: [Double] = [], weights: [Double] = [], ncol = 0
        var pmat: [Double] = []
        switch field {
        case .orbital(let c):
            precondition(c.count == nbf, "coefficient count \(c.count) != basis functions \(nbf)")
            cmat = c; ncol = 1; weights = [1]
        case .orbitalDensity(let orbs, let w):
            let keep = orbs.indices.filter { $0 < w.count && w[$0] != 0 }
            ncol = keep.count
            cmat = [Double](repeating: 0, count: nbf * ncol)
            for (col, i) in keep.enumerated() { for mu in 0..<nbf { cmat[mu * ncol + col] = orbs[i][mu] } }
            weights = keep.map { w[$0] }
        case .densityMatrix(let p):
            precondition(p.count == nbf * nbf)
            pmat = p; ncol = nbf
        }
        let isOrbital: Bool = { if case .orbital = field { return true }; return false }()
        let isPmat = !pmat.isEmpty
        guard ncol > 0 else { return grid.volumeGrid(values: values) }

        let cancelled = ManagedAtomicFlag()
        values.withUnsafeMutableBufferPointer { vbuf in
            let vptr = vbuf.baseAddress!
            DispatchQueue.concurrentPerform(iterations: nx) { i in
                if cancelled.value { return }
                if let isCancelled, isCancelled() { cancelled.set(); return }
                let n = nz
                var xs = [Double](repeating: 0, count: n), ys = xs, zs = xs
                var bvals = [Double](repeating: 0, count: n * nbf)
                var scratch = [Double](repeating: 0, count: 7 * n)
                var prod = [Double](repeating: 0, count: n * ncol)
                for j in 0..<ny {
                    let start = o + Double(i) * a0 + Double(j) * a1
                    for k in 0..<n { let p = start + Double(k) * a2; xs[k] = p.x; ys[k] = p.y; zs[k] = p.z }
                    bvals.withUnsafeMutableBufferPointer { bb in scratch.withUnsafeMutableBufferPointer { sb in
                        basisValues(xs, ys, zs, n: n, out: bb.baseAddress!, scratch: sb.baseAddress!)
                    } }
                    let rowBase = vptr + (i * ny + j) * nz
                    let mat = isPmat ? pmat : cmat
                    // prod (n × ncol) = B (n × nbf) · M (nbf × ncol)
                    PortableLA.gemm(m: n, n: ncol, k: nbf, bvals, mat, &prod)
                    if isOrbital {
                        for k in 0..<n { rowBase[k] = Float(prod[k]) }
                    } else if isPmat {
                        for k in 0..<n {
                            var s = 0.0
                            for mu in 0..<nbf { s += prod[k * nbf + mu] * bvals[k * nbf + mu] }
                            rowBase[k] = Float(s)
                        }
                    } else {
                        for k in 0..<n {
                            var s = 0.0
                            for c in 0..<ncol { let v = prod[k * ncol + c]; s += weights[c] * v * v }
                            rowBase[k] = Float(s)
                        }
                    }
                }
            }
        }
        if cancelled.value { return nil }
        return grid.volumeGrid(values: values)
    }

    /// Async wrapper that honours Swift task cancellation.
    ///
    /// `grid` is an autoclosure so that no SIMD vector is an argument of this async function: on Windows x64,
    /// Swift 6.4.3 lowers an async function's inline `SIMD3<Double>` parameter (here `GridSpec.origin`)
    /// differently in caller and callee, and the callee dereferences garbage at entry. Callers still write
    /// `evaluateAsync(field, on: grid)`.
    public func evaluateAsync(_ field: Field, on grid: @autoclosure () -> GridSpec) async throws -> VolumeGrid {
        let grid = grid()
        let me = self
        // `Task.isCancelled` is always false on the concurrentPerform worker threads (no current task), so
        // cancellation is carried by a shared flag set from the cancellation handler.
        let flag = EvaluatorCancelFlag()
        // `grid` (GridSpec) holds a SIMD3<Double>, so it goes in through `AsyncCapture` (Windows codegen bug).
        let input = AsyncCapture((me, field, grid))
        let task = Task.detached(priority: .userInitiated) { () -> VolumeGrid? in
            let (me, field, grid) = input.value
            return me.evaluate(field, on: grid, isCancelled: { flag.isSet })
        }
        let result = await withTaskCancellationHandler { await task.value } onCancel: { flag.set(); task.cancel() }
        guard let result else { throw CancellationError() }
        return result
    }

    public func moGrid(coefficients: [Double], grid: GridSpec) -> VolumeGrid {
        evaluate(.orbital(coefficients), on: grid)!
    }

    public func densityGrid(densityMatrix: [Double], grid: GridSpec) -> VolumeGrid {
        evaluate(.densityMatrix(densityMatrix), on: grid)!
    }
}

/// Tiny lock-protected flag (Sendable) for cooperative cancellation across worker threads.
final class ManagedAtomicFlag: @unchecked Sendable {
    private var flag = false
    private let lock = NSLock()
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func set() { lock.lock(); flag = true; lock.unlock() }
}

final class EvaluatorCancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
