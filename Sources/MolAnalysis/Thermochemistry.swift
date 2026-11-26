import Foundation
import MolSIMD
import MolCore
import MolIO

// Ideal-gas / rigid-rotor / harmonic-oscillator thermochemistry (McQuarrie; same formalism as the
// public Ochterski white paper), with optional Grimme quasi-RRHO vibrational entropy.

/// Input for `Thermochemistry.compute`.
public struct ThermoInput: Sendable {
    public var molecule: Molecule
    /// Harmonic frequencies in cm⁻¹. Imaginary (negative) and zero values are skipped.
    public var frequencies: [Double]
    /// Electronic energy in Hartree.
    public var electronicEnergy: Double
    /// Rotational symmetry number; nil = detect from the point group.
    public var symmetryNumber: Int?
    public var multiplicity: Int
    /// nil = detect from inertia moments.
    public var isLinear: Bool?

    public init(molecule: Molecule, frequencies: [Double], electronicEnergy: Double,
                symmetryNumber: Int? = nil, multiplicity: Int? = nil, isLinear: Bool? = nil) {
        self.molecule = molecule; self.frequencies = frequencies; self.electronicEnergy = electronicEnergy
        self.symmetryNumber = symmetryNumber; self.multiplicity = multiplicity ?? molecule.multiplicity
        self.isLinear = isLinear
    }

    /// Final geometry, frequencies, last SCF energy and multiplicity of a Gaussian log.
    public init?(log: GaussianLog) {
        guard let mol = log.geometrySteps.last?.molecule, !mol.atoms.isEmpty,
              let e = log.scfEnergies.last?.energy else { return nil }
        self.init(molecule: mol, frequencies: log.vibrations.map { $0.frequency }, electronicEnergy: e,
                  symmetryNumber: nil, multiplicity: log.multiplicity)
    }
}

extension ThermoInput {
    /// Final geometry, vibrational frequencies (translations/rotations dropped) and the electronic energy of an ORCA output.
    public init?(orca out: OrcaOutput) {
        guard let mol = out.geometries.last, !mol.atoms.isEmpty, !out.allFrequencies.isEmpty else { return nil }
        let vib = Array(out.allFrequencies.dropFirst(out.firstVibrationIndex)).filter { abs($0) > 1e-3 }
        guard let e = out.thermochemistry?.electronicEnergy ?? out.finalEnergy else { return nil }
        self.init(molecule: mol, frequencies: vib, electronicEnergy: e, symmetryNumber: nil, multiplicity: out.multiplicity)
    }
}

/// Grimme (Chem. Eur. J. 2012, 18, 9955) quasi-rigid-rotor–harmonic-oscillator entropy interpolation.
public struct QuasiRRHO: Sendable, Equatable {
    /// ν0 in cm⁻¹
    public var cutoff: Double
    public var alpha: Double
    /// Average molecular moment of inertia B_av in kg m²
    public var averageMoment: Double
    public init(cutoff: Double = 100, alpha: Double = 4, averageMoment: Double = 1e-44) {
        self.cutoff = cutoff; self.alpha = alpha; self.averageMoment = averageMoment
    }
}

/// Thermochemistry results. Energies in Hartree, entropies / heat capacity in cal mol⁻¹ K⁻¹.
public struct ThermoResult: Sendable, Equatable {
    public var temperature: Double
    public var pressure: Double              // atm
    public var zeroPointEnergy: Double
    /// E_trans + E_rot + E_vib (E_vib includes the ZPE).
    public var thermalEnergyCorrection: Double
    /// Thermal energy correction + kT.
    public var enthalpyCorrection: Double
    /// Enthalpy correction − T·S.
    public var gibbsCorrection: Double
    public var electronicEnergy: Double
    public var sumZPE: Double                // E_el + ZPE
    public var sumE: Double                  // E_el + thermalEnergyCorrection
    public var sumH: Double
    public var sumG: Double
    public var sTrans: Double, sRot: Double, sVib: Double, sElec: Double
    public var entropy: Double
    public var cvTotal: Double
    public var cvTrans: Double, cvRot: Double, cvVib: Double
    /// Rotational constants in GHz (descending; empty for atoms, one value for linear molecules).
    public var rotationalConstantsGHz: [Double]
    public var symmetryNumber: Int
    public var isLinear: Bool
    public var frequenciesUsed: Int

    /// T·S in Hartree.
    public var tsTerm: Double { entropy * Thermochemistry.calPerMolKToHartreePerK * temperature }

    public enum Quantity: Sendable { case zeroPointEnergy, thermalEnergyCorrection, enthalpyCorrection, gibbsCorrection, sumZPE, sumE, sumH, sumG, tsTerm }
    /// Selected quantity (Hartree) converted to `unit`.
    public func energy(_ q: Quantity, unit: EnergyUnit) -> Double {
        let v: Double
        switch q {
        case .zeroPointEnergy: v = zeroPointEnergy
        case .thermalEnergyCorrection: v = thermalEnergyCorrection
        case .enthalpyCorrection: v = enthalpyCorrection
        case .gibbsCorrection: v = gibbsCorrection
        case .sumZPE: v = sumZPE
        case .sumE: v = sumE
        case .sumH: v = sumH
        case .sumG: v = sumG
        case .tsTerm: v = tsTerm
        }
        return v * unit.fromHartree
    }
}

public enum Thermochemistry {
    static let hartreeJ = 4.3597447222071e-18
    /// 1 cal/mol/K in Hartree/K
    public static let calPerMolKToHartreePerK = 4.184 / PhysConst.NA / hartreeJ

    /// Rotational symmetry number for a Schoenflies point-group name.
    public static func rotationalSymmetryNumber(pointGroup name: String) -> Int {
        let n = name.replacingOccurrences(of: "∞", with: "*")
        switch n {
        case "C1", "Ci", "Cs", "C*v", "Kh": return 1
        case "D*h": return 2
        case "T", "Td", "Th": return 12
        case "O", "Oh": return 24
        case "I", "Ih": return 60
        default: break
        }
        guard let first = n.first else { return 1 }
        let digits = Int(n.dropFirst().prefix { $0.isNumber }) ?? 1
        switch first {
        case "C": return max(1, digits)               // Cn, Cnv, Cnh
        case "D": return 2 * max(1, digits)           // Dn, Dnd, Dnh
        case "S": return max(1, digits / 2)           // S2n
        default: return 1
        }
    }

    public static func compute(_ input: ThermoInput, temperature T: Double = 298.15, pressure: Double = 1.0,
                               frequencyScale: Double = 1.0, quasiRRHO: QuasiRRHO? = nil) -> ThermoResult {
        let kB = PhysConst.kB, h = PhysConst.h, cLight = PhysConst.c   // c in cm/s
        let R = PhysConst.R                                           // J/mol/K
        let hartreeMol = hartreeJ * PhysConst.NA                      // J/mol per Hartree
        let atoms = input.molecule.atoms
        let masses = atoms.map { Elements.element($0.atomicNumber).mass }
        let totalMass = masses.reduce(0, +)                           // amu
        let kT = kB * T

        // Translation
        var sTrans = 0.0, eTrans = 0.0, cvTrans = 0.0
        if totalMass > 0 {
            let m = totalMass * PhysConst.amu
            let q = pow(2 * Double.pi * m * kT / (h * h), 1.5) * kT / (pressure * PhysConst.atm)
            sTrans = R * (log(q) + 2.5)
            eTrans = 1.5 * R * T
            cvTrans = 1.5 * R
        }

        // Rotation
        var sRot = 0.0, eRot = 0.0, cvRot = 0.0
        var linear = false
        var rotConstGHz: [Double] = []
        var sigma = max(1, input.symmetryNumber ?? 1)
        if atoms.count > 1 {
            let pa = Geometry.principalAxes(input.molecule.positions, masses: masses).moments  // amu·Å²
            let mom = [pa.x, pa.y, pa.z].sorted()
            let toKgM2 = PhysConst.amu * 1e-20
            linear = input.isLinear ?? (mom[0] < 1e-3 * max(mom[2], 1e-12) || mom[2] < 1e-8)
            if input.symmetryNumber == nil {
                sigma = rotationalSymmetryNumber(pointGroup: Symmetry.detect(input.molecule).schoenflies)
            }
            let hBar2 = h * h / (8 * Double.pi * Double.pi)
            if linear {
                let I = mom[2] * toKgM2
                let theta = hBar2 / (I * kB)
                sRot = R * (log(T / (Double(sigma) * theta)) + 1)
                eRot = R * T; cvRot = R
                rotConstGHz = [h / (8 * Double.pi * Double.pi * I) / 1e9]
            } else {
                let th = mom.map { hBar2 / ($0 * toKgM2 * kB) }
                let q = Double.pi.squareRoot() / Double(sigma) * pow(T, 1.5) / (th[0] * th[1] * th[2]).squareRoot()
                sRot = R * (log(q) + 1.5)
                eRot = 1.5 * R * T; cvRot = 1.5 * R
                rotConstGHz = mom.map { h / (8 * Double.pi * Double.pi * $0 * toKgM2) / 1e9 }
            }
        } else {
            sigma = 1
        }

        // Vibration
        var zpe = 0.0, eVibThermal = 0.0, sVib = 0.0, cvVib = 0.0
        var used = 0
        for f0 in input.frequencies where f0 > 0 {
            let nu = f0 * frequencyScale
            used += 1
            let theta = h * cLight * nu / kB
            let x = theta / T
            zpe += 0.5 * R * theta
            let ex = exp(-x)
            eVibThermal += R * theta * ex / (1 - ex)
            let sHO = R * (x * ex / (1 - ex) - log(1 - ex))
            cvVib += R * x * x * ex / ((1 - ex) * (1 - ex))
            if let q = quasiRRHO {
                let nuS = h * cLight * nu            // J: h·ν
                _ = nuS
                let freqHz = cLight * nu
                let mu = h / (8 * Double.pi * Double.pi * freqHz)
                let muP = mu * q.averageMoment / (mu + q.averageMoment)
                let sFree = R * (0.5 + log((8 * pow(Double.pi, 3) * muP * kT / (h * h)).squareRoot()))
                let w = 1 / (1 + pow(q.cutoff / nu, q.alpha))
                sVib += w * sHO + (1 - w) * sFree
            } else {
                sVib += sHO
            }
        }

        let sElec = R * log(Double(max(1, input.multiplicity)))
        let eThermal = (eTrans + eRot + eVibThermal + zpe) / hartreeMol
        let kTHartree = R * T / hartreeMol
        let hCorr = eThermal + (atoms.isEmpty ? 0 : kTHartree)
        let sTotal = sTrans + sRot + sVib + sElec                      // J/mol/K
        let gCorr = hCorr - T * sTotal / hartreeMol
        let toCal = 1 / 4.184
        let el = input.electronicEnergy
        return ThermoResult(
            temperature: T, pressure: pressure, zeroPointEnergy: zpe / hartreeMol,
            thermalEnergyCorrection: eThermal, enthalpyCorrection: hCorr, gibbsCorrection: gCorr,
            electronicEnergy: el, sumZPE: el + zpe / hartreeMol, sumE: el + eThermal, sumH: el + hCorr, sumG: el + gCorr,
            sTrans: sTrans * toCal, sRot: sRot * toCal, sVib: sVib * toCal, sElec: sElec * toCal,
            entropy: sTotal * toCal, cvTotal: (cvTrans + cvRot + cvVib) * toCal,
            cvTrans: cvTrans * toCal, cvRot: cvRot * toCal, cvVib: cvVib * toCal,
            rotationalConstantsGHz: rotConstGHz, symmetryNumber: sigma, isLinear: linear, frequenciesUsed: used)
    }
}
