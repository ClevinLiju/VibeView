import Foundation
import Accelerate
import simd
import MolCore
import MolIO

// Becke (J. Chem. Phys. 88, 2547, 1988) multicenter numerical integration.
//
// Uniform cube grids cannot resolve core densities (def2 core exponents reach ~10^4 Bohr^-2), so integrals
// such as the electron count are done on atom-centred grids: Becke's radial map r = R (1+x)/(1-x) with
// Gauss–Chebyshev (2nd kind) nodes, a Gauss–Legendre(cos θ) × uniform-φ product angular grid, and Becke's
// fuzzy-cell partition (three-fold iterated polynomial, with the heteronuclear size adjustment).

public struct MolecularQuadrature: Sendable {
    /// Points in Bohr.
    public private(set) var points: [Vec3] = []
    /// Integration weights (Bohr³), Becke partition already applied.
    public private(set) var weights: [Double] = []
    /// Atom whose fuzzy cell each point belongs to (index into `nuclei`).
    public private(set) var owner: [Int] = []
    public let nuclei: [Vec3]

    /// - Parameters: nuclei in Bohr; atomic numbers set the radial scale (half the Bragg–Slater-like radius).
    public init(nuclei: [Vec3], atomicNumbers: [Int], radialPoints: Int = 100, thetaPoints: Int = 26) {
        self.nuclei = nuclei
        let nAtoms = nuclei.count
        guard nAtoms > 0 else { return }
        // Bragg–Slater-like radii (covalent radii); Becke's radial scale is half of it, except for H.
        let radii: [Double] = atomicNumbers.map { max(0.3, Elements.element($0).covalentRadius) * PhysConst.angstromToBohr }
        let scale: [Double] = zip(atomicNumbers, radii).map { $0 == 1 ? $1 : 0.5 * $1 }
        // Radial nodes (Gauss–Chebyshev 2nd kind mapped to [0, ∞)).
        let nr = radialPoints
        var rNodes: [(r: Double, w: Double)] = []
        for i in 1...nr {
            let th = Double(i) * .pi / Double(nr + 1)
            let x = cos(th)
            let wx = Double.pi / Double(nr + 1) * sin(th)
            rNodes.append((r: (1 + x) / (1 - x), w: wx * 2 / ((1 - x) * (1 - x))))   // scaled by R later
        }
        // Angular product grid.
        let (ct, wt) = Self.gaussLegendre(thetaPoints)
        let nphi = 2 * thetaPoints
        var ang: [(Vec3, Double)] = []
        for (c, w) in zip(ct, wt) {
            let s = (1 - c * c).squareRoot()
            for k in 0..<nphi {
                let ph = 2 * Double.pi * Double(k) / Double(nphi)
                ang.append((Vec3(s * cos(ph), s * sin(ph), c), w * 2 * .pi / Double(nphi)))
            }
        }
        // Inter-nuclear data for the partition.
        var invR = [Double](repeating: 0, count: nAtoms * nAtoms)
        var adj = [Double](repeating: 0, count: nAtoms * nAtoms)
        for a in 0..<nAtoms {
            for b in 0..<nAtoms where a != b {
                invR[a * nAtoms + b] = 1 / simd_length(nuclei[a] - nuclei[b])
                let chi = radii[a] / radii[b]
                let u = (chi - 1) / (chi + 1)
                adj[a * nAtoms + b] = min(0.5, max(-0.5, u / (u * u - 1)))
            }
        }
        func step(_ mu: Double) -> Double {
            var f = mu
            for _ in 0..<3 { f = 1.5 * f - 0.5 * f * f * f }
            return 0.5 * (1 - f)
        }
        var cell = [Double](repeating: 0, count: nAtoms)
        points.reserveCapacity(nAtoms * nr * ang.count)
        for a in 0..<nAtoms {
            let R = scale[a]
            for rn in rNodes {
                let r = rn.r * R, wr = rn.w * R * r * r
                for (dir, wa) in ang {
                    let p = nuclei[a] + r * dir
                    var w = wr * wa
                    if nAtoms > 1 {
                        var dist = [Double](repeating: 0, count: nAtoms)
                        for b in 0..<nAtoms { dist[b] = simd_length(p - nuclei[b]) }
                        var total = 0.0
                        for i in 0..<nAtoms {
                            var prod = 1.0
                            for j in 0..<nAtoms where j != i {
                                var mu = (dist[i] - dist[j]) * invR[i * nAtoms + j]
                                let aij = adj[i * nAtoms + j]
                                mu += aij * (1 - mu * mu)
                                prod *= step(mu)
                                if prod == 0 { break }
                            }
                            cell[i] = prod; total += prod
                        }
                        w *= total > 0 ? cell[a] / total : 0
                    }
                    if w == 0 { continue }
                    points.append(p); weights.append(w); owner.append(a)
                }
            }
        }
    }

    public init(wavefunction wf: Wavefunction, radialPoints: Int = 100, thetaPoints: Int = 26) {
        self.init(nuclei: wf.nuclearPositions, atomicNumbers: wf.atomicNumbers, radialPoints: radialPoints, thetaPoints: thetaPoints)
    }

    public var pointCount: Int { points.count }

    /// Σ w_i f_i.
    public func integrate(_ values: [Double]) -> Double {
        precondition(values.count == weights.count)
        var s = 0.0
        vDSP_dotprD(values, 1, weights, 1, &s, vDSP_Length(values.count))
        return s
    }

    /// Per-atom (fuzzy-cell) integrals.
    public func integratePerAtom(_ values: [Double]) -> [Double] {
        var out = [Double](repeating: 0, count: nuclei.count)
        for i in values.indices { out[owner[i]] += values[i] * weights[i] }
        return out
    }

    /// Gauss–Legendre nodes/weights on [-1, 1] (Newton on P_n).
    static func gaussLegendre(_ n: Int) -> ([Double], [Double]) {
        var x = [Double](repeating: 0, count: n), w = x
        for i in 0..<n {
            var z = cos(.pi * (Double(i) + 0.75) / (Double(n) + 0.5)), pp = 0.0
            for _ in 0..<100 {
                var p1 = 1.0, p2 = 0.0
                for j in 1...n { let p3 = p2; p2 = p1; p1 = ((2 * Double(j) - 1) * z * p2 - (Double(j) - 1) * p3) / Double(j) }
                pp = Double(n) * (z * p1 - p2) / (z * z - 1)
                let dz = p1 / pp
                z -= dz
                if abs(dz) < 1e-15 { break }
            }
            x[i] = z; w[i] = 2 / ((1 - z * z) * pp * pp)
        }
        return (x, w)
    }
}

extension OrbitalEvaluator {
    /// Evaluates `field` at arbitrary points (Bohr), in parallel chunks.
    public func evaluate(_ field: Field, atBohr points: [Vec3]) -> [Double] {
        let nbf = functionCount, total = points.count
        guard total > 0 else { return [] }
        var cmat: [Double] = [], weights: [Double] = [], ncol = 0
        var mode = 0   // 0 orbital, 1 orbital density, 2 density matrix
        switch field {
        case .orbital(let c):
            precondition(c.count == nbf); cmat = c; ncol = 1
        case .orbitalDensity(let orbs, let w):
            let keep = orbs.indices.filter { $0 < w.count && w[$0] != 0 }
            ncol = keep.count; mode = 1
            cmat = [Double](repeating: 0, count: nbf * ncol)
            for (col, i) in keep.enumerated() { for mu in 0..<nbf { cmat[mu * ncol + col] = orbs[i][mu] } }
            weights = keep.map { w[$0] }
        case .densityMatrix(let p):
            precondition(p.count == nbf * nbf); cmat = p; ncol = nbf; mode = 2
        }
        var out = [Double](repeating: 0, count: total)
        guard ncol > 0 else { return out }
        let chunk = 256
        let nChunks = (total + chunk - 1) / chunk
        out.withUnsafeMutableBufferPointer { ob in
            let optr = ob.baseAddress!
            DispatchQueue.concurrentPerform(iterations: nChunks) { c in
                let lo = c * chunk, n = min(chunk, total - lo)
                var xs = [Double](repeating: 0, count: n), ys = xs, zs = xs
                for k in 0..<n { let p = points[lo + k]; xs[k] = p.x; ys[k] = p.y; zs[k] = p.z }
                var b = [Double](repeating: 0, count: n * nbf)
                var scratch = [Double](repeating: 0, count: 7 * n)
                var prod = [Double](repeating: 0, count: n * ncol)
                b.withUnsafeMutableBufferPointer { bb in scratch.withUnsafeMutableBufferPointer { sb in
                    basisValues(xs, ys, zs, n: n, out: bb.baseAddress!, scratch: sb.baseAddress!)
                } }
                cblas_dgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans, Int32(n), Int32(ncol), Int32(nbf),
                            1, b, Int32(nbf), cmat, Int32(ncol), 0, &prod, Int32(ncol))
                for k in 0..<n {
                    var s = 0.0
                    switch mode {
                    case 0: s = prod[k]
                    case 1: for j in 0..<ncol { let v = prod[k * ncol + j]; s += weights[j] * v * v }
                    default: for mu in 0..<nbf { s += prod[k * nbf + mu] * b[k * nbf + mu] }
                    }
                    optr[lo + k] = s
                }
            }
        }
        return out
    }
}

extension WavefunctionSurfaces {
    /// ∫ρ dV for a density kind, on a Becke molecular grid (exact to ~1e-5 e for typical bases).
    public static func electronCount(_ wf: Wavefunction, kind: DensityKind = .total,
                                     quadrature: MolecularQuadrature? = nil, evaluator: OrbitalEvaluator? = nil) -> Double {
        let q = quadrature ?? MolecularQuadrature(wavefunction: wf)
        let (o, w) = weightedOrbitals(wf, kind)
        let rho = (evaluator ?? OrbitalEvaluator(wavefunction: wf)).evaluate(.orbitalDensity(orbitals: o, weights: w), atBohr: q.points)
        return q.integrate(rho)
    }

    /// Becke atomic charges Z_A − ∫_A ρ (fuzzy-cell partition of the total density). Spin populations with `kind: .spin`.
    public static func beckePopulations(_ wf: Wavefunction, kind: DensityKind = .total,
                                        quadrature: MolecularQuadrature? = nil) -> [Double] {
        let q = quadrature ?? MolecularQuadrature(wavefunction: wf)
        let (o, w) = weightedOrbitals(wf, kind)
        let rho = OrbitalEvaluator(wavefunction: wf).evaluate(.orbitalDensity(orbitals: o, weights: w), atBohr: q.points)
        return q.integratePerAtom(rho)
    }

    public static func beckeCharges(_ wf: Wavefunction, quadrature: MolecularQuadrature? = nil) -> [Double] {
        let pop = beckePopulations(wf, quadrature: quadrature)
        return zip(wf.atomicNumbers, pop).map { Double($0) - $1 }
    }
}
