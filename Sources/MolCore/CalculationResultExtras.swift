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

/// How a calculation was set up (level of theory, environment, resources), as reported by the program.
/// Every field is optional: parsers fill what the output states and leave the rest nil.
public struct CalculationInfo: Sendable, Codable, Equatable {
    /// Display name of the method, e.g. "B3LYP", "HF", "DLPNO-CCSD(T)", "r²SCAN-3c".
    public var method: String?
    /// "DFT", "HF", "MP2", "Coupled cluster", "Semiempirical", "Composite".
    public var methodFamily: String?
    public var exchangeFunctional: String?
    public var correlationFunctional: String?
    /// Fraction of exact (HF) exchange for hybrid functionals, 0...1.
    public var exactExchange: Double?
    /// "RHF"/"UHF"/"ROHF" (or "RKS"/"UKS" for DFT).
    public var reference: String?
    public var basisSet: String?
    public var auxiliaryBasis: String?
    /// e.g. "D3BJ", "D4".
    public var dispersion: String?
    /// e.g. "CPCM", "SMD".
    public var solvationModel: String?
    public var solvent: String?
    public var dielectric: Double?
    /// e.g. ["RIJCOSX"], ["RI-J"].
    public var approximations: [String] = []
    /// Job steps in order, e.g. ["Optimization", "Frequencies", "TD-DFT (3 roots)"].
    public var jobTypes: [String] = []
    /// Raw keyword line(s) as written by the user (ORCA "!" lines, Gaussian route).
    public var keywords: [String] = []
    public var charge: Int?
    public var multiplicity: Int?
    public var electrons: Int?
    public var basisFunctions: Int?
    public var integrationGrid: String?
    public var cores: Int?
    public var memoryPerCoreMB: Int?
    /// Wall time of the whole run, seconds.
    public var wallTimeSeconds: Double?
    public init() {}

    /// Compact "method/basis" label, e.g. "B3LYP-D3BJ/def2-SVP".
    public var levelOfTheory: String? {
        guard var m = method else { return basisSet }
        if let d = dispersion, !m.uppercased().contains(d.uppercased()), !m.hasSuffix("-3c") { m += "-\(d)" }
        if let b = basisSet, !m.hasSuffix("-3c") { m += "/\(b)" }
        return m
    }

    /// Solvation label, e.g. "SMD (water)", or "Gas phase" when none was used.
    public var solvationLabel: String {
        guard let model = solvationModel else { return "Gas phase" }
        if let s = solvent { return "\(model) (\(s))" }
        if let e = dielectric { return "\(model) (ε = \(String(format: "%.2f", e)))" }
        return model
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
    /// Calculation setup (method, basis, solvation, resources) when the parser recognizes it.
    public var info: CalculationInfo?
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
