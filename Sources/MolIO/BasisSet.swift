import Foundation
import MolCore

// SHARED CONTRACT (Lead 2 → Lead 5). Produced by the .fchk reader, consumed by MolAnalysis to
// evaluate orbitals / densities on grids. Signature is mirrored in docs/CONTRACTS.md.
//
// Units: atomic units throughout (centers in Bohr, exponents in Bohr^-2).
// Conventions follow the public formatted-checkpoint description:
//  * `coefficients` are contraction coefficients that multiply NORMALIZED primitive Gaussians.
//    The evaluator must apply the primitive normalization N(alpha, l) itself.
//  * Basis-function order inside a shell is given by `BasisSet.cartesianOrder(l)` (Cartesian)
//    or `BasisSet.pureOrder(l)` (spherical harmonics: m = 0, +1, -1, +2, -2, ...).
//  * An SP ("L") shell expands to 4 functions: s, then px, py, pz. The s part uses
//    `coefficients`, the p part uses `spCoefficients`.

public struct BasisSet: Sendable, Codable, Equatable {
    public struct Shell: Sendable, Codable, Equatable {
        /// 0-based index of the atom this shell sits on.
        public var atomIndex: Int
        /// Shell center in Bohr (normally equal to the atom position).
        public var center: Vec3
        /// Angular momentum l (0=s, 1=p, 2=d, ...). For an SP shell this is 1.
        public var angularMomentum: Int
        /// True for a combined SP ("L") shell (fchk shell type -1).
        public var isSP: Bool
        /// True for spherical-harmonic (5D/7F...) functions, false for Cartesian (6D/10F...).
        public var isPure: Bool
        /// Primitive exponents, Bohr^-2.
        public var exponents: [Double]
        /// Contraction coefficients (s part for SP shells).
        public var coefficients: [Double]
        /// P-part coefficients for SP shells; nil otherwise.
        public var spCoefficients: [Double]?

        public init(atomIndex: Int, center: Vec3, angularMomentum: Int, isSP: Bool = false, isPure: Bool,
                    exponents: [Double], coefficients: [Double], spCoefficients: [Double]? = nil) {
            self.atomIndex = atomIndex; self.center = center; self.angularMomentum = angularMomentum
            self.isSP = isSP; self.isPure = isPure; self.exponents = exponents
            self.coefficients = coefficients; self.spCoefficients = spCoefficients
        }

        /// fchk "Shell types" code: 0 s, 1 p, -1 sp, 2 cart d, -2 pure d, 3 cart f, -3 pure f, ...
        public var fchkShellType: Int {
            if isSP { return -1 }
            if angularMomentum < 2 { return angularMomentum }
            return isPure ? -angularMomentum : angularMomentum
        }

        /// Number of contracted basis functions this shell contributes.
        public var functionCount: Int {
            if isSP { return 4 }
            let l = angularMomentum
            return isPure ? 2 * l + 1 : (l + 1) * (l + 2) / 2
        }
    }

    public var shells: [Shell]

    public init(shells: [Shell]) { self.shells = shells }

    /// Total number of contracted basis functions.
    public var functionCount: Int { shells.reduce(0) { $0 + $1.functionCount } }

    /// Index of the first basis function of each shell.
    public var shellOffsets: [Int] {
        var out: [Int] = []; out.reserveCapacity(shells.count)
        var n = 0
        for s in shells { out.append(n); n += s.functionCount }
        return out
    }

    /// Cartesian powers (i, j, k) of x^i y^j z^k in the fchk order for angular momentum l.
    /// d: XX YY ZZ XY XZ YZ; f: XXX YYY ZZZ XYY XXY XXZ XZZ YZZ YYZ XYZ;
    /// g and higher: ZZZZ, YZZZ, YYZZ, ... (descending x, then descending y — see code).
    public static func cartesianOrder(_ l: Int) -> [(Int, Int, Int)] {
        switch l {
        case 0: return [(0, 0, 0)]
        case 1: return [(1, 0, 0), (0, 1, 0), (0, 0, 1)]
        case 2: return [(2, 0, 0), (0, 2, 0), (0, 0, 2), (1, 1, 0), (1, 0, 1), (0, 1, 1)]
        case 3: return [(3, 0, 0), (0, 3, 0), (0, 0, 3), (1, 2, 0), (2, 1, 0), (2, 0, 1),
                        (1, 0, 2), (0, 1, 2), (0, 2, 1), (1, 1, 1)]
        default:
            // For l >= 4 the fchk order is: x power ascending (outer), y power descending... encoded
            // as ZZZZ, YZZZ, YYZZ, YYYZ, YYYY, XZZZ, XYZZ, XYYZ, XYYY, XXZZ, ... XXXX.
            var out: [(Int, Int, Int)] = []
            for i in 0...l {
                for j in stride(from: 0, through: l - i, by: 1) {
                    out.append((i, j, l - i - j))
                }
            }
            return out
        }
    }

    /// Order of real solid harmonics for a pure shell: [0, +1, -1, +2, -2, ...].
    public static func pureOrder(_ l: Int) -> [Int] {
        var out = [0]
        if l > 0 { for m in 1...l { out.append(m); out.append(-m) } }
        return out
    }
}

/// One set (alpha or beta) of molecular-orbital coefficients.
public struct MOCoefficients: Sendable, Codable, Equatable {
    /// Orbital energies, Hartree, ascending as stored in the file.
    public var energies: [Double]
    /// Row-major [orbitalCount][basisCount]: coefficients[mo * basisCount + mu].
    public var coefficients: [Double]
    public var basisCount: Int
    /// Number of occupied orbitals in this set (electrons of this spin; for restricted, nAlpha).
    public var occupiedCount: Int

    public init(energies: [Double], coefficients: [Double], basisCount: Int, occupiedCount: Int) {
        self.energies = energies; self.coefficients = coefficients
        self.basisCount = basisCount; self.occupiedCount = occupiedCount
    }

    public var orbitalCount: Int { basisCount == 0 ? 0 : coefficients.count / basisCount }

    /// Coefficients of orbital `mo` (0-based).
    public func orbital(_ mo: Int) -> ArraySlice<Double> {
        coefficients[(mo * basisCount)..<((mo + 1) * basisCount)]
    }
}

/// Everything needed to evaluate orbitals / densities on a grid.
public struct Wavefunction: Sendable, Codable, Equatable {
    public var basis: BasisSet
    public var alpha: MOCoefficients
    /// nil for restricted (closed-shell or ROHF stored as one set) wavefunctions.
    public var beta: MOCoefficients?
    /// Lower-triangular packed total SCF density ((n*(n+1))/2), if present.
    public var totalDensity: [Double]?
    /// Lower-triangular packed spin density, if present.
    public var spinDensity: [Double]?
    /// Atomic numbers and positions (Bohr) of the nuclei.
    public var atomicNumbers: [Int]
    public var nuclearPositions: [Vec3]
    /// Beta electron count as stored in the file (needed for ROHF, where `beta` is nil).
    public var betaElectronCount: Int?

    public init(basis: BasisSet, alpha: MOCoefficients, beta: MOCoefficients? = nil,
                totalDensity: [Double]? = nil, spinDensity: [Double]? = nil,
                atomicNumbers: [Int], nuclearPositions: [Vec3], betaElectronCount: Int? = nil) {
        self.betaElectronCount = betaElectronCount
        self.basis = basis; self.alpha = alpha; self.beta = beta
        self.totalDensity = totalDensity; self.spinDensity = spinDensity
        self.atomicNumbers = atomicNumbers; self.nuclearPositions = nuclearPositions
    }

    public var isUnrestricted: Bool { beta != nil }
    /// 0-based HOMO index of the alpha set (nil if no electrons).
    public var homoIndex: Int? { alpha.occupiedCount > 0 ? alpha.occupiedCount - 1 : nil }
}

// Flat fchk-style views requested by Lead 5 (same layout as the formatted-checkpoint arrays).
extension BasisSet {
    /// fchk "Shell types": 0 s, 1 p, -1 sp, ±2 d, ±3 f, ±4 g (negative = pure).
    public var shellTypes: [Int] { shells.map(\.fchkShellType) }
    public var primitivesPerShell: [Int] { shells.map { $0.exponents.count } }
    /// 1-based shell-to-atom map (fchk convention).
    public var shellToAtomMap: [Int] { shells.map { $0.atomIndex + 1 } }
    public var primitiveExponents: [Double] { shells.flatMap(\.exponents) }
    public var contractionCoefficients: [Double] { shells.flatMap(\.coefficients) }
    /// "P(S=P) Contraction coefficients": zeros for non-SP shells, as in fchk.
    public var spContractionCoefficients: [Double] {
        shells.flatMap { $0.spCoefficients ?? Array(repeating: 0, count: $0.exponents.count) }
    }
    /// Shell coordinates in Bohr.
    public var shellCoordinates: [Vec3] { shells.map(\.center) }
}

extension Wavefunction {
    public var alphaElectrons: Int { alpha.occupiedCount }
    public var betaElectrons: Int { betaElectronCount ?? beta?.occupiedCount ?? alpha.occupiedCount }
}
