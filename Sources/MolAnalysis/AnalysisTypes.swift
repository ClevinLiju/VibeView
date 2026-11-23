import Foundation
import simd
import MolCore

// MolAnalysis shared types — owned by Lead 5 (Analysis). Signatures posted in docs/CONTRACTS.md.

// MARK: - Isosurface mesh (rendered by MolRender)

/// Triangle mesh extracted from a `VolumeGrid` by marching cubes.
/// Positions in Ångström (same frame as the grid / molecule). Normals are unit length and point
/// toward *decreasing* |value| (outward from the lobe), suitable for lighting directly.
/// Triangles are counter-clockwise when viewed from the outside (normal side).
public struct IsoSurfaceMesh: Sendable, Equatable {
    public enum Sign: Int, Sendable, Codable { case positive = 1, negative = -1 }

    public var vertices: [SIMD3<Float>]
    public var normals: [SIMD3<Float>]
    public var indices: [UInt32]              // 3 per triangle
    public var sign: Sign                     // which lobe (+iso or -iso) this mesh is
    public var isovalue: Double               // signed isovalue actually used
    /// Optional per-vertex scalar (e.g. ESP in Hartree/e) and per-vertex RGBA colors.
    public var vertexScalars: [Float]?
    public var vertexColors: [SIMD4<Float>]?

    public init(vertices: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = [], indices: [UInt32] = [],
                sign: Sign = .positive, isovalue: Double = 0,
                vertexScalars: [Float]? = nil, vertexColors: [SIMD4<Float>]? = nil) {
        self.vertices = vertices
        self.normals = normals
        self.indices = indices
        self.sign = sign
        self.isovalue = isovalue
        self.vertexScalars = vertexScalars
        self.vertexColors = vertexColors
    }

    public var triangleCount: Int { indices.count / 3 }
    public var isEmpty: Bool { indices.isEmpty }
}

// MARK: - Spectra (plotted by the app with Swift Charts)

public struct SpectrumPoint: Sendable, Equatable, Hashable, Codable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

/// One discrete transition drawn as a vertical stick.
public struct SpectrumStick: Sendable, Equatable, Codable {
    public var x: Double          // position in the spectrum's x unit
    public var height: Double     // in the spectrum's y unit (scaled the same as the curve)
    public var label: String?     // e.g. "mode 7 (A1)", "S3", "C2"
    public var sourceIndex: Int   // index into the source array (mode, state, atom)
    public init(x: Double, height: Double, label: String? = nil, sourceIndex: Int) {
        self.x = x; self.height = height; self.label = label; self.sourceIndex = sourceIndex
    }
}

public struct Spectrum: Sendable, Equatable, Codable {
    public var points: [SpectrumPoint]
    public var sticks: [SpectrumStick]
    public var xLabel: String     // e.g. "Wavenumber (cm⁻¹)"
    public var yLabel: String     // e.g. "ε (L mol⁻¹ cm⁻¹)"
    /// True when the conventional display has a reversed x axis (IR in cm⁻¹, NMR in ppm).
    public var xAxisReversed: Bool
    public init(points: [SpectrumPoint], sticks: [SpectrumStick], xLabel: String, yLabel: String, xAxisReversed: Bool = false) {
        self.points = points; self.sticks = sticks; self.xLabel = xLabel; self.yLabel = yLabel
        self.xAxisReversed = xAxisReversed
    }
}

public enum LineShape: String, Sendable, Codable, CaseIterable {
    case lorentzian, gaussian
}

// MARK: - Gaussian basis set (analysis-side model; adapter from MolIO.BasisSet lives in BasisAdapter.swift)

/// One contracted shell. Centers in **Bohr** (fchk convention).
public struct AnalysisShell: Sendable, Equatable {
    public var center: Vec3            // Bohr
    public var atomIndex: Int          // 0-based
    public var l: Int                  // 0=s 1=p 2=d 3=f 4=g (SP shells: l = 1 with spCoefficients set)
    public var pure: Bool              // spherical (5d/7f/9g) vs Cartesian (6d/10f/15g); ignored for s, p
    public var exponents: [Double]
    public var coefficients: [Double]  // contraction coeffs for normalized primitives (s part for SP)
    public var spCoefficients: [Double]? // p-part coefficients for SP ("L") shells

    public init(center: Vec3, atomIndex: Int, l: Int, pure: Bool, exponents: [Double], coefficients: [Double], spCoefficients: [Double]? = nil) {
        self.center = center; self.atomIndex = atomIndex; self.l = l; self.pure = pure
        self.exponents = exponents; self.coefficients = coefficients; self.spCoefficients = spCoefficients
    }

    public var isSP: Bool { spCoefficients != nil }

    /// Number of basis functions this shell contributes (SP = 4).
    public var functionCount: Int {
        if isSP { return 4 }
        if l <= 1 { return 2 * l + 1 }
        return pure ? 2 * l + 1 : (l + 1) * (l + 2) / 2
    }

    /// fchk "Shell types" code: 0 s, 1 p, -1 sp, 2 6d, -2 5d, 3 10f, -3 7f, ...
    public var fchkShellType: Int {
        if isSP { return -1 }
        if l <= 1 { return l }
        return pure ? -l : l
    }
}

public struct AnalysisBasis: Sendable, Equatable {
    public var shells: [AnalysisShell]
    public init(shells: [AnalysisShell]) { self.shells = shells }
    public var functionCount: Int { shells.reduce(0) { $0 + $1.functionCount } }
}

/// MO coefficients: `alpha[i]` is MO i (0-based) with `functionCount` AO coefficients.
public struct MOCoefficientSet: Sendable, Equatable {
    public var alpha: [[Double]]
    public var beta: [[Double]]?          // nil for restricted
    public var alphaOccupations: [Double] // per MO (2 for restricted doubly occupied, 1 for unrestricted)
    public var betaOccupations: [Double]?
    public var alphaEnergies: [Double]    // Hartree
    public var betaEnergies: [Double]?
    public init(alpha: [[Double]], beta: [[Double]]? = nil, alphaOccupations: [Double], betaOccupations: [Double]? = nil,
                alphaEnergies: [Double] = [], betaEnergies: [Double]? = nil) {
        self.alpha = alpha; self.beta = beta
        self.alphaOccupations = alphaOccupations; self.betaOccupations = betaOccupations
        self.alphaEnergies = alphaEnergies; self.betaEnergies = betaEnergies
    }
    public var isUnrestricted: Bool { beta != nil }
}

// MARK: - Constants & units

public enum PhysConst {
    public static let bohrToAngstrom = 0.529177210903
    public static let angstromToBohr = 1.0 / 0.529177210903
    public static let hartreeToEV = 27.211386245988
    public static let hartreeToKcalMol = 627.509474
    public static let hartreeToKJMol = 2625.499639
    public static let hartreeToWavenumber = 219474.6313632
    public static let evToNMFactor = 1239.84198            // λ(nm) = 1239.84198 / E(eV)
    public static let kB = 1.380649e-23                    // J/K
    public static let h = 6.62607015e-34                   // J s
    public static let c = 2.99792458e10                    // cm/s
    public static let NA = 6.02214076e23
    public static let R = 8.314462618                      // J/(mol K)
    public static let amu = 1.66053906660e-27              // kg
    public static let atm = 101325.0                       // Pa
    public static let calToJ = 4.184
}

public enum EnergyUnit: String, Sendable, Codable, CaseIterable {
    case hartree, kcalPerMol, kJPerMol, eV, wavenumber
    public var fromHartree: Double {
        switch self {
        case .hartree: return 1
        case .kcalPerMol: return PhysConst.hartreeToKcalMol
        case .kJPerMol: return PhysConst.hartreeToKJMol
        case .eV: return PhysConst.hartreeToEV
        case .wavenumber: return PhysConst.hartreeToWavenumber
        }
    }
    public var symbol: String {
        switch self {
        case .hartree: return "Eh"
        case .kcalPerMol: return "kcal/mol"
        case .kJPerMol: return "kJ/mol"
        case .eV: return "eV"
        case .wavenumber: return "cm⁻¹"
        }
    }
}
