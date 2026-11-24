import Foundation
import simd
import Accelerate
import MolCore

// UFF-style force field + optimizer (Worker A, Lead 4). Parameters from Rappe et al., JACS 114, 10024 (1992).

public struct MinimizeResult: Sendable {
    public var molecule: Molecule
    public var initialEnergy: Double
    public var energy: Double
    public var steps: Int
    public var converged: Bool
    public var rmsGradient: Double
}

struct UFFParam {
    var r1: Double, theta0: Double, x1: Double, D1: Double, Z1: Double
}

enum UFFTables {
    static let params: [String: UFFParam] = [
        "H_": UFFParam(r1: 0.354, theta0: 180, x1: 2.886, D1: 0.044, Z1: 0.712),
        "C_3": UFFParam(r1: 0.757, theta0: 109.47, x1: 3.851, D1: 0.105, Z1: 1.912),
        "C_2": UFFParam(r1: 0.732, theta0: 120, x1: 3.851, D1: 0.105, Z1: 1.912),
        "C_R": UFFParam(r1: 0.729, theta0: 120, x1: 3.851, D1: 0.105, Z1: 1.912),
        "C_1": UFFParam(r1: 0.706, theta0: 180, x1: 3.851, D1: 0.105, Z1: 1.912),
        "N_3": UFFParam(r1: 0.700, theta0: 106.7, x1: 3.660, D1: 0.069, Z1: 2.544),
        "N_2": UFFParam(r1: 0.685, theta0: 111.2, x1: 3.660, D1: 0.069, Z1: 2.544),
        "N_R": UFFParam(r1: 0.699, theta0: 120, x1: 3.660, D1: 0.069, Z1: 2.544),
        "N_1": UFFParam(r1: 0.656, theta0: 180, x1: 3.660, D1: 0.069, Z1: 2.544),
        "O_3": UFFParam(r1: 0.658, theta0: 104.51, x1: 3.500, D1: 0.060, Z1: 2.300),
        "O_R": UFFParam(r1: 0.680, theta0: 110, x1: 3.500, D1: 0.060, Z1: 2.300),
        "O_2": UFFParam(r1: 0.634, theta0: 120, x1: 3.500, D1: 0.060, Z1: 2.300),
        "O_1": UFFParam(r1: 0.639, theta0: 180, x1: 3.500, D1: 0.060, Z1: 2.300),
        "F_": UFFParam(r1: 0.668, theta0: 180, x1: 3.364, D1: 0.050, Z1: 1.735),
        "P_3": UFFParam(r1: 1.101, theta0: 93.8, x1: 4.147, D1: 0.305, Z1: 2.863),
        "S_3": UFFParam(r1: 1.064, theta0: 92.1, x1: 4.035, D1: 0.274, Z1: 2.703),
        "S_3+6": UFFParam(r1: 1.027, theta0: 109.47, x1: 4.035, D1: 0.274, Z1: 2.703),
        "S_2": UFFParam(r1: 0.854, theta0: 120, x1: 4.035, D1: 0.274, Z1: 2.703),
        "Cl": UFFParam(r1: 0.994, theta0: 180, x1: 3.947, D1: 0.227, Z1: 2.348),
        "Br": UFFParam(r1: 1.141, theta0: 180, x1: 4.189, D1: 0.251, Z1: 2.519),
        "I_": UFFParam(r1: 1.333, theta0: 180, x1: 4.500, D1: 0.339, Z1: 2.650),
    ]
    static let chi: [Int: Double] = [1: 4.528, 6: 5.343, 7: 6.899, 8: 8.741, 9: 10.874, 15: 5.463, 16: 6.928, 17: 8.564, 35: 7.790, 53: 6.822]
    static let vSp3: [Int: Double] = [6: 2.119, 7: 0.450, 8: 0.018, 14: 1.225, 15: 2.4, 16: 0.484]
}

struct UFFAtomType {
    var p: UFFParam
    var hyb: Int       // 0 terminal(H/halogen), 1, 2, 3
    var z: Int
    var chi: Double
}

final class UFFSystem {
    struct BondT { var i: Int, j: Int, r0: Double, k: Double }
    struct AngleT { var i: Int, j: Int, k: Int, form: Int, K: Double, c0: Double, c1: Double, c2: Double }
    struct TorsT { var i: Int, j: Int, k: Int, l: Int, V: Double, n: Double, cosn0: Double }
    struct InvT { var c: Int, a: Int, b: Int, d: Int, K: Double }
    struct PairT { var i: Int, j: Int, x2: Double, D: Double }

    var bonds: [BondT] = [], angles: [AngleT] = [], tors: [TorsT] = [], invs: [InvT] = [], pairs: [PairT] = []
    let n: Int

    static func atomType(_ m: Molecule, _ i: Int, nbrs: [Int], bondsOf: [Bond]) -> UFFAtomType {
        let z = m.atoms[i].atomicNumber
        let ch = UFFTables.chi[z] ?? 5.0
        let triple = bondsOf.contains { $0.order == .triple }
        let doubles = bondsOf.filter { $0.order == .double }.count
        let arom = bondsOf.contains { $0.order == .aromatic }
        func P(_ k: String) -> UFFParam { UFFTables.params[k]! }
        func conj() -> Bool { nbrs.contains { j in m.bonds.contains { ($0.a == j || $0.b == j) && $0.order != .single } } }
        switch z {
        case 1: return UFFAtomType(p: P("H_"), hyb: 0, z: z, chi: ch)
        case 6:
            if triple || doubles >= 2 { return UFFAtomType(p: P("C_1"), hyb: 1, z: z, chi: ch) }
            if arom { return UFFAtomType(p: P("C_R"), hyb: 2, z: z, chi: ch) }
            if doubles == 1 { return UFFAtomType(p: P("C_2"), hyb: 2, z: z, chi: ch) }
            return UFFAtomType(p: P("C_3"), hyb: 3, z: z, chi: ch)
        case 7:
            if triple { return UFFAtomType(p: P("N_1"), hyb: 1, z: z, chi: ch) }
            if arom { return UFFAtomType(p: P("N_R"), hyb: 2, z: z, chi: ch) }
            if doubles >= 1 { return UFFAtomType(p: P("N_2"), hyb: 2, z: z, chi: ch) }
            if conj() { return UFFAtomType(p: P("N_R"), hyb: 2, z: z, chi: ch) }
            return UFFAtomType(p: P("N_3"), hyb: 3, z: z, chi: ch)
        case 8:
            if arom { return UFFAtomType(p: P("O_R"), hyb: 2, z: z, chi: ch) }
            if doubles >= 1 || triple { return UFFAtomType(p: P("O_2"), hyb: 2, z: z, chi: ch) }
            if conj() && nbrs.count >= 1 { return UFFAtomType(p: P("O_R"), hyb: 2, z: z, chi: ch) }
            return UFFAtomType(p: P("O_3"), hyb: 3, z: z, chi: ch)
        case 9: return UFFAtomType(p: P("F_"), hyb: 0, z: z, chi: ch)
        case 15: return UFFAtomType(p: P("P_3"), hyb: 3, z: z, chi: ch)
        case 16:
            if nbrs.count >= 3 || doubles >= 2 { return UFFAtomType(p: P("S_3+6"), hyb: 3, z: z, chi: ch) }
            if arom || doubles == 1 { return UFFAtomType(p: P("S_2"), hyb: 2, z: z, chi: ch) }
            return UFFAtomType(p: P("S_3"), hyb: 3, z: z, chi: ch)
        case 17: return UFFAtomType(p: P("Cl"), hyb: 0, z: z, chi: ch)
        case 35: return UFFAtomType(p: P("Br"), hyb: 0, z: z, chi: ch)
        case 53: return UFFAtomType(p: P("I_"), hyb: 0, z: z, chi: ch)
        default:
            let r = BuildElements.covalentRadius(z)
            return UFFAtomType(p: UFFParam(r1: r > 0 ? r : 1.0, theta0: 109.47, x1: 4.0, D1: 0.1, Z1: 1.5), hyb: 3, z: z, chi: ch)
        }
    }

    init(_ m: Molecule) {
        n = m.atoms.count
        var nbrs = [[Int]](repeating: [], count: n)
        var bondsOf = [[Bond]](repeating: [], count: n)
        for b in m.bonds where b.a < n && b.b < n && b.a != b.b {
            nbrs[b.a].append(b.b); nbrs[b.b].append(b.a)
            bondsOf[b.a].append(b); bondsOf[b.b].append(b)
        }
        let types = (0..<n).map { UFFSystem.atomType(m, $0, nbrs: nbrs[$0], bondsOf: bondsOf[$0]) }
        var r0 = [Int: Double]()
        func key(_ a: Int, _ b: Int) -> Int { min(a, b) * n + max(a, b) }
        for b in m.bonds where b.a < n && b.b < n && b.a != b.b {
            let ti = types[b.a], tj = types[b.b]
            let ri = ti.p.r1, rj = tj.p.r1
            let bo = b.order.rawValue
            let rBO = -0.1332 * (ri + rj) * log(bo)
            let si = ti.chi.squareRoot(), sj = tj.chi.squareRoot()
            let rEN = ri * rj * (si - sj) * (si - sj) / (ti.chi * ri + tj.chi * rj)
            let r = ri + rj + rBO - rEN
            r0[key(b.a, b.b)] = r
            bonds.append(BondT(i: b.a, j: b.b, r0: r, k: 664.12 * ti.p.Z1 * tj.p.Z1 / (r * r * r)))
        }
        // angles
        for j in 0..<n {
            let t = types[j]
            let nb = nbrs[j]
            guard nb.count >= 2 else { continue }
            for a in 0..<nb.count {
                for c in (a + 1)..<nb.count {
                    let i = nb[a], k = nb[c]
                    let rij = r0[key(i, j)]!, rjk = r0[key(j, k)]!
                    let th0 = t.p.theta0 * .pi / 180
                    let cs = cos(th0)
                    let rik2 = rij * rij + rjk * rjk - 2 * rij * rjk * cs
                    let rik = rik2.squareRoot()
                    let ZZ = types[i].p.Z1 * types[k].p.Z1
                    var K = 664.12 * ZZ / pow(rik, 5) * (3 * rij * rjk * (1 - cs * cs) - rik2 * cs)
                    if !(K.isFinite) || K < 0 { K = 50 }
                    var a = AngleT(i: i, j: j, k: k, form: 2, K: K, c0: 0, c1: 0, c2: 0)
                    if t.p.theta0 > 179 { a.form = 0 }
                    else if abs(t.p.theta0 - 120) < 0.5 { a.form = 1 }
                    else {
                        let s2 = sin(th0) * sin(th0)
                        let C2 = 1 / (4 * s2), C1 = -4 * C2 * cs, C0 = C2 * (2 * cs * cs + 1)
                        a.c0 = C0; a.c1 = C1; a.c2 = C2
                    }
                    angles.append(a)
                }
            }
        }
        // torsions
        for b in m.bonds where b.a < n && b.b < n && b.a != b.b {
            let j = b.a, k = b.b
            let tj = types[j], tk = types[k]
            guard nbrs[j].count > 1, nbrs[k].count > 1, tj.hyb >= 2 || tj.hyb == 3, tj.hyb != 1, tk.hyb != 1, tj.hyb != 0, tk.hyb != 0 else { continue }
            var V = 0.0, nn = 3.0, cosn0 = -1.0
            if tj.hyb == 3 && tk.hyb == 3 {
                let group6 = Set([8, 16])
                if group6.contains(tj.z) && group6.contains(tk.z) {
                    let vj = tj.z == 8 ? 2.0 : 6.8, vk = tk.z == 8 ? 2.0 : 6.8
                    V = (vj * vk).squareRoot(); nn = 2; cosn0 = -1
                } else {
                    V = ((UFFTables.vSp3[tj.z] ?? 1.0) * (UFFTables.vSp3[tk.z] ?? 1.0)).squareRoot(); nn = 3; cosn0 = -1
                }
            } else if tj.hyb == 2 && tk.hyb == 2 {
                let uj = tj.z > 10 ? 1.25 : 2.0, uk = tk.z > 10 ? 1.25 : 2.0
                V = 5 * (uj * uk).squareRoot() * (1 + 4.18 * log(b.order.rawValue)); nn = 2; cosn0 = 1
            } else {
                V = 1.0; nn = 6; cosn0 = 1
            }
            guard V > 0 else { continue }
            let cnt = Double((nbrs[j].count - 1) * (nbrs[k].count - 1))
            for i in nbrs[j] where i != k {
                for l in nbrs[k] where l != j && l != i {
                    tors.append(TorsT(i: i, j: j, k: k, l: l, V: V / cnt, n: nn, cosn0: cosn0))
                }
            }
        }
        // inversions (planar sp2 centres with three neighbours)
        for c in 0..<n where nbrs[c].count == 3 && types[c].hyb == 2 && [6, 7, 8].contains(types[c].z) && types[c].z != 8 {
            let nb = nbrs[c]
            var K = 6.0
            if types[c].z == 6 && nb.contains(where: { types[$0].z == 8 && types[$0].hyb == 2 }) { K = 50 }
            for perm in [(0, 1, 2), (1, 2, 0), (2, 0, 1)] {
                invs.append(InvT(c: c, a: nb[perm.0], b: nb[perm.1], d: nb[perm.2], K: K / 3))
            }
        }
        // vdW pairs, exclude 1-2 and 1-3
        var excl = Set<Int>()
        for b in m.bonds where b.a < n && b.b < n { excl.insert(key(b.a, b.b)) }
        for j in 0..<n { let nb = nbrs[j]; for a in 0..<nb.count { for c in (a + 1)..<nb.count { excl.insert(key(nb[a], nb[c])) } } }
        for i in 0..<n {
            for j in (i + 1)..<max(n, i + 1) where !excl.contains(key(i, j)) {
                let x = (types[i].p.x1 * types[j].p.x1).squareRoot()
                let D = (types[i].p.D1 * types[j].p.D1).squareRoot()
                pairs.append(PairT(i: i, j: j, x2: x * x, D: D))
            }
        }
    }

    // MARK: energy + gradient

    func evaluate(_ x: [Double], _ g: inout [Double]) -> Double {
        var e = 0.0
        for i in 0..<g.count { g[i] = 0 }
        @inline(__always) func P(_ i: Int) -> Vec3 { Vec3(x[3 * i], x[3 * i + 1], x[3 * i + 2]) }
        @inline(__always) func addG(_ i: Int, _ v: Vec3) { g[3 * i] += v.x; g[3 * i + 1] += v.y; g[3 * i + 2] += v.z }

        for b in bonds {
            let d = P(b.i) - P(b.j)
            let r = max(simd_length(d), 1e-9)
            let dr = r - b.r0
            e += 0.5 * b.k * dr * dr
            let f = d * (b.k * dr / r)
            addG(b.i, f); addG(b.j, -f)
        }
        for a in angles {
            let u = P(a.i) - P(a.j), v = P(a.k) - P(a.j)
            let lu = max(simd_length(u), 1e-9), lv = max(simd_length(v), 1e-9)
            let uh = u / lu, vh = v / lv
            let c = max(-1, min(1, simd_dot(uh, vh)))
            let s = max(sqrt(1 - c * c), 1e-8)
            var E = 0.0, dE = 0.0 // dE/dtheta
            switch a.form {
            case 0: E = a.K * (1 + c); dE = -a.K * s
            case 1:
                let th = acos(c)
                E = a.K / 9 * (1 - cos(3 * th)); dE = a.K / 3 * sin(3 * th)
            default:
                let th = acos(c)
                E = a.K * (a.c0 + a.c1 * c + a.c2 * cos(2 * th))
                dE = a.K * (-a.c1 * s - 2 * a.c2 * sin(2 * th))
            }
            e += E
            // dtheta/du = -(vh - c uh)/(lu s)
            let dtu = -(vh - c * uh) / (lu * s)
            let dtv = -(uh - c * vh) / (lv * s)
            addG(a.i, dE * dtu); addG(a.k, dE * dtv); addG(a.j, -dE * (dtu + dtv))
        }
        for t in tors {
            let F = P(t.i) - P(t.j), G = P(t.j) - P(t.k), H = P(t.l) - P(t.k)
            let A = simd_cross(F, G), B = simd_cross(H, G)
            let A2 = max(simd_length_squared(A), 1e-12), B2 = max(simd_length_squared(B), 1e-12)
            let lg = max(simd_length(G), 1e-9)
            let cosphi = max(-1, min(1, simd_dot(A, B) / (A2 * B2).squareRoot()))
            let sinphi = simd_dot(simd_cross(B, A), G) / ((A2 * B2).squareRoot() * lg)   // Blondel–Karplus sign, consistent with the derivatives below
            let phi = atan2(sinphi, cosphi)
            e += 0.5 * t.V * (1 - t.cosn0 * cos(t.n * phi))
            let dE = 0.5 * t.V * t.cosn0 * t.n * sin(t.n * phi)
            let dpi = -lg / A2 * A
            let dpl = lg / B2 * B
            let fg = simd_dot(F, G) / (A2 * lg), hg = simd_dot(H, G) / (B2 * lg)
            let dpj = lg / A2 * A + fg * A - hg * B
            let dpk = -lg / B2 * B - fg * A + hg * B
            addG(t.i, dE * dpi); addG(t.j, dE * dpj); addG(t.k, dE * dpk); addG(t.l, dE * dpl)
        }
        for p in pairs {
            let d = P(p.i) - P(p.j)
            let r2 = max(simd_length_squared(d), 0.05)
            let s2 = p.x2 / r2
            let s6 = s2 * s2 * s2
            e += p.D * (s6 * s6 - 2 * s6)
            let coef = p.D * (-12 * s6 * s6 + 12 * s6) / r2
            let f = d * coef
            addG(p.i, f); addG(p.j, -f)
        }
        for v in invs {
            func en(_ pc: Vec3, _ pa: Vec3, _ pb: Vec3, _ pd: Vec3) -> Double {
                let nrm = simd_cross(pa - pc, pb - pc)
                let ln = simd_length(nrm)
                if ln < 1e-9 { return 0 }
                let w = pd - pc
                let lw = simd_length(w)
                if lw < 1e-9 { return 0 }
                let sinw = simd_dot(nrm / ln, w / lw)
                return v.K * (1 - sqrt(max(0, 1 - sinw * sinw)))
            }
            let idx = [v.c, v.a, v.b, v.d]
            var pts = idx.map { P($0) }
            e += en(pts[0], pts[1], pts[2], pts[3])
            let h = 1e-5
            for q in 0..<4 {
                var grad = Vec3.zero
                for ax in 0..<3 {
                    let orig = pts[q][ax]
                    pts[q][ax] = orig + h; let ep = en(pts[0], pts[1], pts[2], pts[3])
                    pts[q][ax] = orig - h; let em = en(pts[0], pts[1], pts[2], pts[3])
                    pts[q][ax] = orig
                    grad[ax] = (ep - em) / (2 * h)
                }
                addG(idx[q], grad)
            }
        }
        return e
    }
}

public enum Cleanup {
    public static func energy(_ m: Molecule) -> Double {
        guard m.atoms.count > 1 else { return 0 }
        let sys = UFFSystem(m)
        var x = [Double](); x.reserveCapacity(3 * m.atoms.count)
        for a in m.atoms { x += [a.position.x, a.position.y, a.position.z] }
        var g = [Double](repeating: 0, count: x.count)
        return sys.evaluate(x, &g)
    }

    public static func minimize(_ m: Molecule, frozen: Set<Int> = [], maxSteps: Int = 500, gradientTolerance: Double = 1e-2,
                                progress: ((Int, Double) -> Void)? = nil) -> MinimizeResult {
        let n = m.atoms.count
        guard n > 1 else {
            return MinimizeResult(molecule: m, initialEnergy: 0, energy: 0, steps: 0, converged: true, rmsGradient: 0)
        }
        let sys = UFFSystem(m)
        let dim = 3 * n
        var x = [Double](); x.reserveCapacity(dim)
        for a in m.atoms { x += [a.position.x, a.position.y, a.position.z] }
        var mask = [Double](repeating: 1, count: dim)
        for f in frozen where f >= 0 && f < n { for k in 0..<3 { mask[3 * f + k] = 0 } }
        let nFree = max(1, (0..<n).filter { !frozen.contains($0) }.count)

        var g = [Double](repeating: 0, count: dim)
        func eval(_ xx: [Double], _ gg: inout [Double]) -> Double {
            let e = sys.evaluate(xx, &gg)
            vDSP.multiply(gg, mask, result: &gg)
            return e
        }
        func rms(_ gg: [Double]) -> Double { (vDSP.sumOfSquares(gg) / Double(3 * nFree)).squareRoot() }
        func maxAbs(_ v: [Double]) -> Double { vDSP.maximumMagnitude(v) }

        var e = eval(x, &g)
        let e0 = e
        var step = 0
        var converged = rms(g) < gradientTolerance
        let maxDisp = 0.25
        var sList = [[Double]](), yList = [[Double]]()
        let mem = 8
        var xNew = x, gNew = g

        while step < maxSteps && !converged {
            step += 1
            // direction
            var d: [Double]
            if sList.isEmpty || step <= 5 && false {
                d = vDSP.multiply(-1, g)
                let mg = maxAbs(g)
                if mg > 0 { d = vDSP.multiply(min(1.0, 0.05 / mg), d) }   // cautious first move
            } else {
                var q = g
                var alphas = [Double](repeating: 0, count: sList.count)
                for i in stride(from: sList.count - 1, through: 0, by: -1) {
                    let rho = 1 / vDSP.dot(yList[i], sList[i])
                    alphas[i] = rho * vDSP.dot(sList[i], q)
                    q = vDSP.add(q, vDSP.multiply(-alphas[i], yList[i]))
                }
                let last = sList.count - 1
                let gamma = vDSP.dot(sList[last], yList[last]) / vDSP.dot(yList[last], yList[last])
                q = vDSP.multiply(gamma, q)
                for i in 0..<sList.count {
                    let rho = 1 / vDSP.dot(yList[i], sList[i])
                    let beta = rho * vDSP.dot(yList[i], q)
                    q = vDSP.add(q, vDSP.multiply(alphas[i] - beta, sList[i]))
                }
                d = vDSP.multiply(-1, q)
                if vDSP.dot(d, g) >= 0 { d = vDSP.multiply(-1, g); sList = []; yList = [] }
            }
            // limit step length
            let md = maxAbs(d)
            var t = md > maxDisp ? maxDisp / md : 1.0
            let slope = vDSP.dot(g, d)
            var accepted = false
            for _ in 0..<30 {
                xNew = vDSP.add(x, vDSP.multiply(t, d))
                let en = eval(xNew, &gNew)
                if en.isFinite && en <= e + 1e-4 * t * slope { 
                    let s = vDSP.subtract(xNew, x), y = vDSP.subtract(gNew, g)
                    if vDSP.dot(s, y) > 1e-12 {
                        sList.append(s); yList.append(y)
                        if sList.count > mem { sList.removeFirst(); yList.removeFirst() }
                    }
                    x = xNew; g = gNew; e = en; accepted = true; break
                }
                t *= 0.5
            }
            if !accepted {
                if sList.isEmpty { break }
                sList = []; yList = []
                _ = eval(x, &g)
                continue
            }
            progress?(step, e)
            if rms(g) < gradientTolerance { converged = true }
        }
        var out = m
        for i in 0..<n { out.atoms[i].position = Vec3(x[3 * i], x[3 * i + 1], x[3 * i + 2]) }
        return MinimizeResult(molecule: out, initialEnergy: e0, energy: e, steps: step, converged: converged, rmsGradient: rms(g))
    }
}
