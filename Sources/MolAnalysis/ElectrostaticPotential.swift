import Foundation
import simd
import MolCore
import MolIO

/// Molecular electrostatic potential V(C) = Σ_A Z_A/|R_A − C| − Σ_μν P_μν ⟨χ_μ| 1/|r − C| |χ_ν⟩ (Hartree/e),
/// with the electronic part from exact nuclear-attraction integrals (McMurchie–Davidson Hermite expansion,
/// Boys function from a Taylor-interpolated table). Primitive-pair Hermite densities are contracted with the
/// density matrix once, so each evaluation point costs Σ_pairs O(L³).
public struct ElectrostaticPotential: Sendable {
    struct PairTerm: Sendable {
        var p: Double
        var P: Vec3
        var L: Int
        var D: [Double]   // Hermite density, index tuv packed by hermiteIndex
    }
    let pairs: [PairTerm]
    let nuclei: [(Double, Vec3)]

    /// Builds the evaluator from a total density matrix (full n×n, AO basis of `basis`).
    public init(basis: AnalysisBasis, densityMatrix P: [Double], nuclearCharges: [Double], nuclearPositions: [Vec3] /*Bohr*/) {
        nuclei = Array(zip(nuclearCharges, nuclearPositions))
        // Split shells into sub-shells (SP → s + p) with AO offsets.
        struct Sub { var center: Vec3; var l: Int; var exps: [Double]; var d: [Double]; var mono: [(Int, Int, Int)]; var w: [Double]; var nf: Int; var off: Int }
        var subs: [Sub] = []
        var off = 0
        for s in basis.shells {
            let ps = BasisPreparation.prepare(s)
            if let sr = ps.sRadial {
                subs.append(Sub(center: s.center, l: 0, exps: s.exponents, d: sr, mono: [(0, 0, 0)], w: [1], nf: 1, off: off))
                off += 1
            }
            subs.append(Sub(center: s.center, l: ps.l, exps: s.exponents, d: ps.radial, mono: ps.monomials, w: ps.transform, nf: ps.lFunctionCount, off: off))
            off += ps.lFunctionCount
        }
        let n = off
        var terms: [PairTerm] = []
        for a in subs.indices {
            for b in a..<subs.count {
                let A = subs[a], B = subs[b]
                // Q = W_Aᵀ P_AB W_B  (nmA × nmB)
                let nmA = A.mono.count, nmB = B.mono.count
                var Q = [Double](repeating: 0, count: nmA * nmB)
                var anyQ = false
                for mu in 0..<A.nf { for nu in 0..<B.nf {
                    let pv = P[(A.off + mu) * n + B.off + nu]
                    if pv == 0 { continue }
                    for k in 0..<nmA {
                        let wa = A.w[mu * nmA + k]; if wa == 0 { continue }
                        for k2 in 0..<nmB {
                            let wb = B.w[nu * nmB + k2]; if wb == 0 { continue }
                            Q[k * nmB + k2] += pv * wa * wb; anyQ = true
                        }
                    }
                } }
                guard anyQ else { continue }
                let factor = a == b ? 1.0 : 2.0
                let L = A.l + B.l
                let AB = A.center - B.center
                let ab2 = simd_length_squared(AB)
                for (i, ea) in A.exps.enumerated() {
                    for (j, eb) in B.exps.enumerated() {
                        let p = ea + eb
                        let mu = ea * eb / p
                        let pref = exp(-mu * ab2)
                        let coef = factor * A.d[i] * B.d[j] * 2 * Double.pi / p
                        if abs(coef * pref) < 1e-14 { continue }
                        let Pc = (ea * A.center + eb * B.center) / p
                        let Ex = hermiteETable(A.l, B.l, p, Pc.x - A.center.x, Pc.x - B.center.x, mu, AB.x)
                        let Ey = hermiteETable(A.l, B.l, p, Pc.y - A.center.y, Pc.y - B.center.y, mu, AB.y)
                        let Ez = hermiteETable(A.l, B.l, p, Pc.z - A.center.z, Pc.z - B.center.z, mu, AB.z)
                        let L1 = L + 1
                        var D = [Double](repeating: 0, count: L1 * L1 * L1)
                        for (k, ma) in A.mono.enumerated() {
                            for (k2, mb) in B.mono.enumerated() {
                                let q = Q[k * nmB + k2]; if q == 0 { continue }
                                let s = q * coef
                                for t in 0...(ma.0 + mb.0) {
                                    let ex = Ex[(ma.0 * (B.l + 1) + mb.0) * L1 + t]; if ex == 0 { continue }
                                    for u in 0...(ma.1 + mb.1) {
                                        let ey = Ey[(ma.1 * (B.l + 1) + mb.1) * L1 + u]; if ey == 0 { continue }
                                        for v in 0...(ma.2 + mb.2) {
                                            let ez = Ez[(ma.2 * (B.l + 1) + mb.2) * L1 + v]
                                            D[(t * L1 + u) * L1 + v] += s * ex * ey * ez
                                        }
                                    }
                                }
                            }
                        }
                        terms.append(PairTerm(p: p, P: Pc, L: L, D: D))
                    }
                }
            }
        }
        pairs = terms
    }

    /// From a wavefunction: total density from occupied MOs (alpha + beta).
    public init(wavefunction wf: Wavefunction) {
        let basis = AnalysisBasis(wf.basis)
        let P = WavefunctionSurfaces.densityMatrix(wf, spin: .total)
        self.init(basis: basis, densityMatrix: P, nuclearCharges: wf.atomicNumbers.map(Double.init), nuclearPositions: wf.nuclearPositions)
    }

    /// Hermite expansion coefficients E^{ij}_t for one Cartesian direction, flattened [i][j][t] with t ≤ la+lb.
    func hermiteE(_ la: Int, _ lb: Int, _ p: Double, _ xpa: Double, _ xpb: Double, _ mu: Double, _ xab: Double) -> [Double] {
        hermiteETable(la, lb, p, xpa, xpb, mu, xab)
    }

    /// Potential at points given in Bohr.
    public func evaluate(atBohr points: [Vec3]) -> [Double] {
        var out = [Double](repeating: 0, count: points.count)
        let me = self
        out.withUnsafeMutableBufferPointer { buf in
            let ptr = buf.baseAddress!
            let chunk = 64
            let nChunks = (points.count + chunk - 1) / chunk
            DispatchQueue.concurrentPerform(iterations: nChunks) { c in
                for idx in (c * chunk)..<min(points.count, (c + 1) * chunk) { ptr[idx] = me.potential(points[idx]) }
            }
        }
        return out
    }

    /// Potential at points given in Å (e.g. mesh vertices).
    public func evaluate(atAngstrom points: [SIMD3<Float>]) -> [Double] {
        evaluate(atBohr: points.map { SIMD3<Double>($0) * PhysConst.angstromToBohr })
    }

    func potential(_ C: Vec3) -> Double {
        var v = 0.0
        for (z, R) in nuclei { let d = simd_length(R - C); if d > 1e-8 { v += z / d } }
        var R = [Double](repeating: 0, count: 9 * 9 * 9 * 9)
        var el = 0.0
        for t in pairs {
            let PC = t.P - C
            let L = t.L, L1 = L + 1
            hermiteR(L, t.p, PC, &R)
            // R stored at n = 0 in the first L1³ block.
            var s = 0.0
            for a in 0...L { for b in 0...(L - a) { for c in 0...(L - a - b) {
                s += t.D[(a * L1 + b) * L1 + c] * R[(a * L1 + b) * L1 + c]
            } } }
            el += s
        }
        return v - el
    }
}

func hermiteETable(_ la: Int, _ lb: Int, _ p: Double, _ xpa: Double, _ xpb: Double, _ mu: Double, _ xab: Double) -> [Double] {
    let L1 = la + lb + 1
    let nb = lb + 1
    var E = [Double](repeating: 0, count: (la + 1) * nb * L1)
    @inline(__always) func idx(_ i: Int, _ j: Int, _ t: Int) -> Int { (i * nb + j) * L1 + t }
    // Hermite coefficients exclude the Gaussian overlap prefactor exp(-mu xab²) per direction; it is applied
    // here in E^{00}_0 so that the product over x, y, z gives the full exp(-mu |AB|²).
    E[idx(0, 0, 0)] = exp(-mu * xab * xab)
    let h = 1 / (2 * p)
    for i in 0...la {
        for j in 0...lb {
            if i == 0 && j == 0 { continue }
            for t in 0...(i + j) {
                var v = 0.0
                if j == 0 {
                    // from (i-1, 0)
                    let pi = i - 1
                    if t > 0 { v += h * E[idx(pi, 0, t - 1)] }
                    if t <= pi { v += xpa * E[idx(pi, 0, t)] }
                    if t + 1 <= pi { v += Double(t + 1) * E[idx(pi, 0, t + 1)] }
                } else {
                    let pj = j - 1
                    if t > 0 { v += h * E[idx(i, pj, t - 1)] }
                    if t <= i + pj { v += xpb * E[idx(i, pj, t)] }
                    if t + 1 <= i + pj { v += Double(t + 1) * E[idx(i, pj, t + 1)] }
                }
                E[idx(i, j, t)] = v
            }
        }
    }
    return E
}

/// Fills R[(t*L1+u)*L1+v] = R^0_{tuv}(p, PC) for t+u+v ≤ L. Scratch layout: n-major blocks of L1³.
func hermiteR(_ L: Int, _ p: Double, _ PC: Vec3, _ R: inout [Double]) {
    let L1 = L + 1, blk = L1 * L1 * L1
    let T = p * simd_length_squared(PC)
    var F = [Double](repeating: 0, count: L + 1)
    Boys.values(L, T, &F)
    var m2p = 1.0
    for n in 0...L { R[n * blk] = m2p * F[n]; m2p *= -2 * p }
    @inline(__always) func I(_ n: Int, _ t: Int, _ u: Int, _ v: Int) -> Int { n * blk + (t * L1 + u) * L1 + v }
    if L == 0 { return }
    for s in 1...L {
        for n in 0...(L - s) {
            for t in 0...s { for u in 0...(s - t) {
                let v = s - t - u
                var val = 0.0
                if t > 0 {
                    val = PC.x * R[I(n + 1, t - 1, u, v)]
                    if t > 1 { val += Double(t - 1) * R[I(n + 1, t - 2, u, v)] }
                } else if u > 0 {
                    val = PC.y * R[I(n + 1, t, u - 1, v)]
                    if u > 1 { val += Double(u - 1) * R[I(n + 1, t, u - 2, v)] }
                } else {
                    val = PC.z * R[I(n + 1, t, u, v - 1)]
                    if v > 1 { val += Double(v - 1) * R[I(n + 1, t, u, v - 2)] }
                }
                R[I(n, t, u, v)] = val
            } }
        }
    }
}

/// Boys function F_n(T) = ∫₀¹ t^{2n} e^{−T t²} dt via a tabulated 6-term Taylor expansion (T < 36),
/// the asymptotic form beyond, and downward recursion.
enum Boys {
    static let nMax = 24, step = 0.05, tMax = 36.0
    static let table: [[Double]] = {
        let nT = Int(tMax / step) + 2
        var tab = [[Double]](repeating: [], count: nT)
        for k in 0..<nT { tab[k] = series(nMax + 7, Double(k) * step) }
        return tab
    }()

    /// Accurate values F_0…F_n at T by series for F_n then downward recursion.
    static func series(_ n: Int, _ T: Double) -> [Double] {
        var out = [Double](repeating: 0, count: n + 1)
        // F_n(T) = e^{-T} Σ_k (2T)^k / ((2n+1)(2n+3)…(2n+2k+1))
        var term = 1.0 / Double(2 * n + 1), sum = term, k = 0
        while term > 1e-17 * sum && k < 500 {
            k += 1
            term *= 2 * T / Double(2 * n + 2 * k + 1)
            sum += term
        }
        let eT = exp(-T)
        out[n] = eT * sum
        if n > 0 { for m in stride(from: n - 1, through: 0, by: -1) { out[m] = (2 * T * out[m + 1] + eT) / Double(2 * m + 1) } }
        return out
    }

    static func values(_ n: Int, _ T: Double, _ F: inout [Double]) {
        if T >= tMax {
            // Asymptotic: F_m = (2m−1)!! / 2^{m+1} · sqrt(π / T^{2m+1})
            F[0] = 0.5 * (Double.pi / T).squareRoot()
            if n > 0 { for m in 1...n { F[m] = F[m - 1] * Double(2 * m - 1) / (2 * T) } }
            return
        }
        let k = Int((T / step).rounded())
        let dT = Double(k) * step - T   // Taylor: F_n(T) = Σ_j F_{n+j}(T0) (T0−T)^j / j!
        let row = table[k]
        var fact = 1.0, pw = 1.0
        var fn = 0.0
        for j in 0..<7 { fn += row[n + j] * pw / fact; pw *= dT; fact *= Double(j + 1) }
        F[n] = fn
        if n > 0 {
            let eT = exp(-T)
            for m in stride(from: n - 1, through: 0, by: -1) { F[m] = (2 * T * F[m + 1] + eT) / Double(2 * m + 1) }
        }
    }
}

/// Red (negative) – white – blue (positive) color map for ESP-mapped surfaces.
public enum ESPColorMap {
    public static func color(_ v: Double, range: ClosedRange<Double>) -> SIMD4<Float> {
        let m = max(abs(range.lowerBound), abs(range.upperBound), 1e-12)
        let t = Float(max(-1, min(1, v / m)))
        if t < 0 { return SIMD4(1, 1 + t, 1 + t, 1) }   // red for negative
        return SIMD4(1 - t, 1 - t, 1, 1)                 // blue for positive
    }

    /// Fills `vertexColors` from `vertexScalars`. A nil range uses a symmetric range around the data.
    public static func colorize(_ mesh: inout IsoSurfaceMesh, range: ClosedRange<Double>? = nil) {
        guard let s = mesh.vertexScalars, !s.isEmpty else { return }
        let r: ClosedRange<Double>
        if let range { r = range } else {
            let sorted = s.map(Double.init).sorted()
            // Robust range: 2nd–98th percentile.
            let lo = sorted[Int(Double(sorted.count - 1) * 0.02)], hi = sorted[Int(Double(sorted.count - 1) * 0.98)]
            let m = max(abs(lo), abs(hi))
            r = -m...m
        }
        mesh.vertexColors = s.map { color(Double($0), range: r) }
    }
}
