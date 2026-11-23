import Foundation

// SHARED CONTRACT — produced by MolIO parsers, consumed by MolAnalysis / MolRender / app.

public struct NormalMode: Sendable, Codable, Equatable {
    public var frequency: Double          // cm^-1 (negative = imaginary)
    public var irIntensity: Double        // km/mol
    public var ramanActivity: Double?
    public var symmetry: String?
    public var displacements: [Vec3]      // one per atom, Cartesian

    public init(frequency: Double, irIntensity: Double, ramanActivity: Double? = nil, symmetry: String? = nil, displacements: [Vec3]) {
        self.frequency = frequency
        self.irIntensity = irIntensity
        self.ramanActivity = ramanActivity
        self.symmetry = symmetry
        self.displacements = displacements
    }
}

public struct OrbitalInfo: Sendable, Codable, Equatable {
    public var index: Int                 // 1-based, as Gaussian prints
    public var energy: Double             // Hartree
    public var occupied: Bool
    public var spin: Spin

    public enum Spin: String, Sendable, Codable { case alpha, beta, restricted }

    public init(index: Int, energy: Double, occupied: Bool, spin: Spin = .restricted) {
        self.index = index
        self.energy = energy
        self.occupied = occupied
        self.spin = spin
    }
}

public struct ExcitedState: Sendable, Codable, Equatable {
    public var energyEV: Double
    public var wavelengthNM: Double
    public var oscillatorStrength: Double

    public init(energyEV: Double, wavelengthNM: Double, oscillatorStrength: Double) {
        self.energyEV = energyEV
        self.wavelengthNM = wavelengthNM
        self.oscillatorStrength = oscillatorStrength
    }
}

/// Volumetric data on a regular grid (cube files, computed orbitals/densities).
public struct VolumeGrid: Sendable, Codable, Equatable {
    public var origin: Vec3               // Ångström
    public var axes: [Vec3]               // 3 step vectors, Ångström
    public var counts: [Int]              // nx, ny, nz
    public var values: [Float]            // x-slowest, z-fastest (cube-file order)

    public init(origin: Vec3, axes: [Vec3], counts: [Int], values: [Float]) {
        self.origin = origin
        self.axes = axes
        self.counts = counts
        self.values = values
    }
}

public struct CalculationResult: Sendable, Codable, Equatable {
    public var steps: [Molecule] = []     // geometry per opt/scan/IRC step; last = final
    public var energies: [Double] = []    // SCF energy per step, Hartree
    public var normalModes: [NormalMode] = []
    public var orbitals: [OrbitalInfo] = []
    public var excitedStates: [ExcitedState] = []
    public var mullikenCharges: [Double] = []
    public var dipole: Vec3? = nil        // Debye
    public var routeSection: String = ""
    public var normalTermination: Bool = false
    public var volumes: [String: VolumeGrid] = [:]

    public init() {}

    public var finalMolecule: Molecule? { steps.last }
}
