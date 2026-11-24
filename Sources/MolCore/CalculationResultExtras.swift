import Foundation

// Additive, program-neutral extensions to the shared result model (Lead A, round 2).
// Everything new here is OPTIONAL storage on `CalculationResult` (see `extras`), so JSON written by
// round 1 still decodes and existing members are unchanged.

/// Thermochemistry summary as printed by a frequency job (all corrections in Hartree).
public struct ThermochemistrySummary: Sendable, Codable, Equatable {
    public var temperature: Double?            // K
    public var pressure: Double?               // atm
    public var electronicEnergy: Double?       // Hartree, the reference energy
    public var zeroPointEnergy: Double?        // ZPE correction, Hartree
    public var thermalEnergyCorrection: Double?
    public var enthalpyCorrection: Double?
    public var gibbsCorrection: Double?        // G - E(el)
    public var totalEnthalpy: Double?          // E(el) + H corr
    public var totalGibbs: Double?             // E(el) + G corr
    public var entropy: Double?                // T*S total, Hartree (when printed as T*S)
    public init(temperature: Double? = nil, pressure: Double? = nil, electronicEnergy: Double? = nil,
                zeroPointEnergy: Double? = nil, thermalEnergyCorrection: Double? = nil,
                enthalpyCorrection: Double? = nil, gibbsCorrection: Double? = nil,
                totalEnthalpy: Double? = nil, totalGibbs: Double? = nil, entropy: Double? = nil) {
        self.temperature = temperature; self.pressure = pressure; self.electronicEnergy = electronicEnergy
        self.zeroPointEnergy = zeroPointEnergy; self.thermalEnergyCorrection = thermalEnergyCorrection
        self.enthalpyCorrection = enthalpyCorrection; self.gibbsCorrection = gibbsCorrection
        self.totalEnthalpy = totalEnthalpy; self.totalGibbs = totalGibbs; self.entropy = entropy
    }
}

/// Program-neutral extra data a parser may attach to a `CalculationResult`.
public struct CalculationExtras: Sendable, Codable, Equatable {
    /// "gaussian", "orca", "qchem", "xtb", ... (lowercase).
    public var program: String?
    public var programVersion: String?
    /// Final single-point/total energy, Hartree (may differ from `energies.last`, e.g. with dispersion).
    public var finalEnergy: Double?
    /// Atomic charges by scheme name: "Mulliken", "Loewdin", "Hirshfeld", "NBO", "CM5", "APT", "ChelpG".
    public var charges: [String: [Double]] = [:]
    /// Atomic spin populations by scheme name (open shell).
    public var spinDensities: [String: [Double]] = [:]
    /// Cartesian gradient per geometry step, Hartree/Bohr, one vector per atom.
    public var gradients: [[Vec3]] = []
    public var thermochemistry: ThermochemistrySummary?
    /// HOMO-LUMO gap, eV, when the program prints it (xtb) or it can be derived.
    public var homoLumoGapEV: Double?
    /// True when the optimizer reported convergence.
    public var optimizationConverged: Bool?
    /// Free-form warnings/errors found in the output (e.g. "SCF not converged").
    public var messages: [String] = []
    public init() {}
}

extension CalculationResult {
    /// Program name from `extras` ("orca", "gaussian", ...).
    public var program: String? { extras?.program }
    /// Charges by scheme; falls back to `mullikenCharges` under "Mulliken".
    public var chargesByScheme: [String: [Double]] {
        var d = extras?.charges ?? [:]
        if d["Mulliken"] == nil, !mullikenCharges.isEmpty { d["Mulliken"] = mullikenCharges }
        return d
    }
    public var thermochemistry: ThermochemistrySummary? { extras?.thermochemistry }
    /// Mutating accessor that creates `extras` on first use.
    public var extrasOrEmpty: CalculationExtras {
        get { extras ?? CalculationExtras() }
        set { extras = newValue }
    }
}
