import Foundation
import MolCore
import MolIO

// Adapters from MolIO's fchk model (Lead 2) to the analysis-side basis model.

extension AnalysisBasis {
    public init(_ b: BasisSet) {
        self.init(shells: b.shells.map {
            AnalysisShell(center: $0.center, atomIndex: $0.atomIndex, l: $0.angularMomentum,
                          pure: $0.isPure && $0.angularMomentum >= 2, exponents: $0.exponents,
                          coefficients: $0.coefficients, spCoefficients: $0.isSP ? ($0.spCoefficients ?? []) : nil)
        })
    }
}

extension MOCoefficientSet {
    /// Restricted closed shell → occupations 2/0. ROHF (no beta set, nβ ≠ nα) → the same orbitals are used
    /// for beta with nβ occupied. Unrestricted → separate alpha/beta sets with occupations 1/0.
    public init(_ wf: Wavefunction) {
        func rows(_ m: MOCoefficients) -> [[Double]] {
            (0..<m.orbitalCount).map { Array(m.orbital($0)) }
        }
        func occ(_ count: Int, _ n: Int, _ value: Double) -> [Double] {
            (0..<count).map { $0 < n ? value : 0 }
        }
        let a = rows(wf.alpha)
        let nA = wf.alphaElectrons, nB = wf.betaElectrons
        if let beta = wf.beta {
            self.init(alpha: a, beta: rows(beta),
                      alphaOccupations: occ(a.count, nA, 1), betaOccupations: occ(beta.orbitalCount, nB, 1),
                      alphaEnergies: wf.alpha.energies, betaEnergies: beta.energies)
        } else if nA != nB {
            self.init(alpha: a, beta: a,
                      alphaOccupations: occ(a.count, nA, 1), betaOccupations: occ(a.count, nB, 1),
                      alphaEnergies: wf.alpha.energies, betaEnergies: wf.alpha.energies)
        } else {
            self.init(alpha: a, alphaOccupations: occ(a.count, nA, 2), alphaEnergies: wf.alpha.energies)
        }
    }
}

public enum PackedMatrix {
    /// Expand an fchk lower-triangular packed symmetric matrix (row-wise: P11, P21, P22, P31, ...) to full n×n row-major.
    public static func unpackLowerTriangle(_ packed: [Double], n: Int) -> [Double]? {
        guard packed.count == n * (n + 1) / 2 else { return nil }
        var full = [Double](repeating: 0, count: n * n)
        var k = 0
        for i in 0..<n { for j in 0...i { full[i * n + j] = packed[k]; full[j * n + i] = packed[k]; k += 1 } }
        return full
    }
}
