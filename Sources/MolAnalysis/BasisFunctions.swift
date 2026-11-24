import Foundation
import MolCore
import MolIO

// Gaussian basis-function machinery shared by the grid evaluator and the ESP integrals.
//
// Every contracted function is written as   χ_μ(r) = Σ_k W_μk · m_k(r − A) · Σ_p d_p exp(−α_p |r − A|²)
// where m_k are the Cartesian monomials x^i y^j z^k of degree l (in `BasisSet.cartesianOrder(l)` order),
// d_p = c_p · R(α_p) · (contraction renormalization) with R(α) = (2α/π)^{3/4} (4α)^{l/2}, and W is
//   • Cartesian: diag(1 / sqrt((2i−1)!!(2j−1)!!(2k−1)!!))   — each Cartesian component normalized (fchk convention)
//   • pure:      the real regular solid harmonic S_lm (Helgaker normalization, S_lm = √(4π/(2l+1)) r^l Y_lm)
//                divided by √((2l−1)!!), in the order m = 0, +1, −1, +2, −2, …
// With this, every primitive (and, after renormalization, every contracted function) has unit norm.

public enum SolidHarmonics {
    public typealias Key = Int  // packed (i, j, k): i * 10_000 + j * 100 + k

    @inline(__always) static func key(_ i: Int, _ j: Int, _ k: Int) -> Key { i * 10_000 + j * 100 + k }

    /// Real regular solid harmonics S_lm as monomial polynomials, for m = −l…l (index m + l).
    public static func polynomials(_ l: Int) -> [[Key: Double]] { table[l] }

    static let table: [[[Key: Double]]] = {
        var all: [[[Key: Double]]] = [[[key(0, 0, 0): 1]]]
        func mul(_ p: [Key: Double], _ di: Int, _ dj: Int, _ dk: Int, _ f: Double) -> [Key: Double] {
            var o: [Key: Double] = [:]
            for (k, v) in p { o[k + key(di, dj, dk), default: 0] += v * f }
            return o
        }
        func add(_ a: [Key: Double], _ b: [Key: Double]) -> [Key: Double] {
            var o = a; for (k, v) in b { o[k, default: 0] += v }; return o
        }
        func r2(_ p: [Key: Double], _ f: Double) -> [Key: Double] {
            add(add(mul(p, 2, 0, 0, f), mul(p, 0, 2, 0, f)), mul(p, 0, 0, 2, f))
        }
        for l in 0..<6 {
            let cur = all[l]
            let prev: [[Key: Double]]? = l > 0 ? all[l - 1] : nil
            var next = [[Key: Double]](repeating: [:], count: 2 * l + 3)
            let fl = Double(l)
            let f = ((l == 0 ? 2.0 : 1.0) * (2 * fl + 1) / (2 * fl + 2)).squareRoot()
            let sll = cur[2 * l], slm = cur[0]
            next[2 * l + 2] = l == 0 ? mul(sll, 1, 0, 0, f) : add(mul(sll, 1, 0, 0, f), mul(slm, 0, 1, 0, -f))
            next[0] = l == 0 ? mul(sll, 0, 1, 0, f) : add(mul(sll, 0, 1, 0, f), mul(slm, 1, 0, 0, f))
            for m in -l...l {
                let fm = Double(m)
                var t = mul(cur[m + l], 0, 0, 1, 2 * fl + 1)
                if let prev, abs(m) <= l - 1 {
                    t = add(t, r2(prev[m + l - 1], -((fl + fm) * (fl - fm)).squareRoot()))
                }
                let d = ((fl + fm + 1) * (fl - fm + 1)).squareRoot()
                next[m + l + 1] = t.mapValues { $0 / d }
            }
            all.append(next.map { $0.filter { abs($0.value) > 1e-14 } })
        }
        return all
    }()
}

@inline(__always) func doubleFactorial(_ n: Int) -> Double {
    var r = 1.0, k = n
    while k > 1 { r *= Double(k); k -= 2 }
    return r
}

/// A shell prepared for fast evaluation (Bohr units).
struct PreparedShell: Sendable {
    var center: Vec3
    var l: Int
    var exponents: [Double]
    /// Radial coefficients d_p for the l-part (includes R(α) and contraction renormalization).
    var radial: [Double]
    /// SP shells: s-part radial coefficients (the shell then yields 1 s + 3 p functions).
    var sRadial: [Double]?
    /// Monomials (i, j, k) of degree l.
    var monomials: [(Int, Int, Int)]
    /// Row-major [functions][monomials] for the l-part.
    var transform: [Double]
    var lFunctionCount: Int
    var functionCount: Int { lFunctionCount + (sRadial == nil ? 0 : 1) }
    /// Squared radius (Bohr²) beyond which every function of the shell is below ~1e-10.
    var cutoff2: Double
}

enum BasisPreparation {
    static func radialNorm(_ a: Double, _ l: Int) -> Double { pow(2 * a / .pi, 0.75) * pow(4 * a, Double(l) / 2) }

    /// Overlap of two normalized primitives with the same l on the same center.
    static func primitiveOverlap(_ a: Double, _ b: Double, _ l: Int) -> Double {
        pow(2 * (a * b).squareRoot() / (a + b), Double(l) + 1.5)
    }

    static func renormalized(_ c: [Double], _ e: [Double], _ l: Int) -> [Double] {
        var s = 0.0
        for i in c.indices { for j in c.indices { s += c[i] * c[j] * primitiveOverlap(e[i], e[j], l) } }
        guard s > 0 else { return c }
        let f = 1 / s.squareRoot()
        return c.map { $0 * f }
    }

    static func transform(l: Int, pure: Bool) -> (mono: [(Int, Int, Int)], w: [Double], count: Int) {
        let mono = BasisSet.cartesianOrder(l)
        let nm = mono.count
        if !pure || l < 2 {
            var w = [Double](repeating: 0, count: nm * nm)
            for (k, p) in mono.enumerated() {
                w[k * nm + k] = 1 / (doubleFactorial(2 * p.0 - 1) * doubleFactorial(2 * p.1 - 1) * doubleFactorial(2 * p.2 - 1)).squareRoot()
            }
            return (mono, w, nm)
        }
        let polys = SolidHarmonics.polynomials(l)
        let order = BasisSet.pureOrder(l)
        let scale = 1 / doubleFactorial(2 * l - 1).squareRoot()
        var w = [Double](repeating: 0, count: order.count * nm)
        for (f, m) in order.enumerated() {
            for (k, p) in mono.enumerated() {
                w[f * nm + k] = (polys[m + l][SolidHarmonics.key(p.0, p.1, p.2)] ?? 0) * scale
            }
        }
        return (mono, w, order.count)
    }

    static func prepare(_ s: AnalysisShell) -> PreparedShell {
        let l = s.l
        let pure = s.pure && l >= 2
        let t = transform(l: l, pure: pure)
        let lc = s.isSP ? (s.spCoefficients ?? s.coefficients) : s.coefficients
        let lr = zip(renormalized(lc, s.exponents, l), s.exponents).map { $0 * radialNorm($1, l) }
        var sr: [Double]? = nil
        if s.isSP {
            sr = zip(renormalized(s.coefficients, s.exponents, 0), s.exponents).map { $0 * radialNorm($1, 0) }
        }
        // Screening radius: max_p |d_p| e^{-α r²} (r^l ≲ 1 + r²) < 1e-10.
        var r2 = 0.0
        for (p, a) in s.exponents.enumerated() {
            let d = max(abs(lr[p]), abs(sr?[p] ?? 0))
            guard d > 0 else { continue }
            let est = (log(d) + 23.0 + Double(l) * 1.5) / a
            r2 = max(r2, est)
        }
        return PreparedShell(center: s.center, l: l, exponents: s.exponents, radial: lr, sRadial: sr,
                             monomials: t.mono, transform: t.w, lFunctionCount: t.count, cutoff2: max(r2, 1))
    }
}
