import Foundation
import MolCore
import MolIO
import MolAnalysis

// Minimal local parser for the ORCA reference output (HF/STO-3G water opt+freq).
private struct OrcaThermoRef {
    var molecule = Molecule()
    var freqs: [Double] = []
    var energy = 0.0
    var values: [String: Double] = [:]

    init(text: String) {
        let lines = text.components(separatedBy: "\n")
        if let s = lines.lastIndex(where: { $0.hasPrefix("CARTESIAN COORDINATES (ANGSTROEM)") }) {
            var i = s + 2
            var atoms: [Atom] = []
            while i < lines.count {
                let p = lines[i].split(separator: " ").map(String.init)
                guard p.count == 4, let x = Double(p[1]), let y = Double(p[2]), let z = Double(p[3]),
                      let el = Elements.element(symbol: p[0]) else { break }
                atoms.append(Atom(id: atoms.count, atomicNumber: el.atomicNumber, position: Vec3(x, y, z)))
                i += 1
            }
            molecule = Molecule(atoms: atoms)
        }
        if let s = lines.lastIndex(where: { $0.hasPrefix("VIBRATIONAL FREQUENCIES") }) {
            var i = s + 1
            while i < lines.count, !lines[i].hasPrefix("NORMAL MODES") {
                let l = lines[i].trimmingCharacters(in: .whitespaces)
                if l.contains(":"), l.hasSuffix("cm**-1"), let v = Double(l.split(separator: " ")[1]) { freqs.append(v) }
                i += 1
            }
        }
        if let l = lines.last(where: { $0.hasPrefix("FINAL SINGLE POINT ENERGY") }) {
            energy = Double(l.split(separator: " ").last!)!
        }
        guard let t = lines.lastIndex(where: { $0.hasPrefix("THERMOCHEMISTRY AT") }) else { return }
        for l in lines[t...] {
            // "Label ... value Eh" or "Label   value Eh"
            let parts = l.components(separatedBy: " Eh")
            guard parts.count > 1 else { continue }
            let head = parts[0].replacingOccurrences(of: "...", with: " ")
            let toks = head.split(separator: " ").map(String.init)
            guard let v = Double(toks.last ?? ""), toks.count > 1 else { continue }
            let key = toks.dropLast().joined(separator: " ")
            if values[key] == nil { values[key] = v }
        }
    }
}

extension Checks {
    static let analysisThermoChecks: [Check] = [
        Check("analysis.thermo.argonTextbook") {
            let ar = Molecule(atoms: [Atom(id: 0, atomicNumber: 18, position: .zero)])
            let r = Thermochemistry.compute(ThermoInput(molecule: ar, frequencies: [], electronicEnergy: -526.0, multiplicity: 1))
            let T = 298.15, R = 8.314462618
            // Sackur–Tetrode: Ar, 298.15 K, 1 atm -> 154.74 J/mol/K; at 1 bar 154.85 (tabulated 154.84)
            try expectClose(r.sTrans * 4.184, 154.737, tol: 0.02)
            let bar = Thermochemistry.compute(ThermoInput(molecule: ar, frequencies: [], electronicEnergy: 0, multiplicity: 1),
                                              pressure: 1.0e5 / 101325.0)
            try expectClose(bar.sTrans * 4.184, 154.84, tol: 0.02)
            try expect(r.sRot == 0 && r.sVib == 0 && r.sElec == 0 && r.rotationalConstantsGHz.isEmpty)
            let hartreeMol = 4.3597447222071e-18 * 6.02214076e23
            try expectClose(r.thermalEnergyCorrection, 1.5 * R * T / hartreeMol, tol: 1e-12)
            try expectClose(r.enthalpyCorrection - r.thermalEnergyCorrection, R * T / hartreeMol, tol: 1e-12)
            try expectClose(r.cvTotal * 4.184, 1.5 * R, tol: 1e-9)
            try expectClose(r.zeroPointEnergy, 0, tol: 1e-15)
            try expectClose(r.sumH, -526.0 + r.enthalpyCorrection, tol: 1e-12)
            try expectClose(r.gibbsCorrection, r.enthalpyCorrection - r.tsTerm, tol: 1e-12)
            // electronic entropy for a doublet
            let dbl = Thermochemistry.compute(ThermoInput(molecule: ar, frequencies: [], electronicEnergy: 0, multiplicity: 2))
            try expectClose(dbl.sElec * 4.184, R * log(2.0), tol: 1e-9)
        },
        Check("analysis.thermo.symmetryAndLinear") {
            try expect(Thermochemistry.rotationalSymmetryNumber(pointGroup: "C2v") == 2)
            try expect(Thermochemistry.rotationalSymmetryNumber(pointGroup: "D3h") == 6)
            try expect(Thermochemistry.rotationalSymmetryNumber(pointGroup: "D*h") == 2)
            try expect(Thermochemistry.rotationalSymmetryNumber(pointGroup: "C*v") == 1)
            try expect(Thermochemistry.rotationalSymmetryNumber(pointGroup: "Td") == 12)
            try expect(Thermochemistry.rotationalSymmetryNumber(pointGroup: "Oh") == 24)
            try expect(Thermochemistry.rotationalSymmetryNumber(pointGroup: "Ih") == 60)
            try expect(Thermochemistry.rotationalSymmetryNumber(pointGroup: "D2d") == 4)
            try expect(Thermochemistry.rotationalSymmetryNumber(pointGroup: "S4") == 2)
            try expect(Thermochemistry.rotationalSymmetryNumber(pointGroup: "C3v") == 3)
            // CO2: linear, sigma 2, B = 11.7 GHz (r = 1.16 Å)
            let co2 = Molecule(atoms: [Atom(id: 0, atomicNumber: 6, position: .zero),
                                       Atom(id: 1, atomicNumber: 8, position: Vec3(0, 0, 1.16)),
                                       Atom(id: 2, atomicNumber: 8, position: Vec3(0, 0, -1.16))])
            let r = Thermochemistry.compute(ThermoInput(molecule: co2, frequencies: [667, 667, 1388, 2349], electronicEnergy: 0, multiplicity: 1))
            try expect(r.isLinear && r.symmetryNumber == 2 && r.rotationalConstantsGHz.count == 1)
            try expectClose(r.rotationalConstantsGHz[0], 11.7, tol: 0.2)
            try expectClose(r.cvRot * 4.184, 8.314462618, tol: 1e-9)
            // literature S°(CO2, 1 bar, 298.15 K) = 213.8 J/mol/K; total includes ~0.5 from vibrations
            let bar = Thermochemistry.compute(ThermoInput(molecule: co2, frequencies: [667, 667, 1388, 2349], electronicEnergy: 0, multiplicity: 1), pressure: 1.0e5 / 101325.0)
            try expectClose(bar.entropy * 4.184, 213.8, tol: 0.5)
            // HCl: sigma 1
            let hcl = Molecule(atoms: [Atom(id: 0, atomicNumber: 1, position: .zero), Atom(id: 1, atomicNumber: 17, position: Vec3(0, 0, 1.2746))])
            let h = Thermochemistry.compute(ThermoInput(molecule: hcl, frequencies: [2991], electronicEnergy: 0, multiplicity: 1))
            try expect(h.isLinear && h.symmetryNumber == 1)
            try expectClose(h.rotationalConstantsGHz[0], 317.5, tol: 1)
        },
        Check("analysis.thermo.vibrationsAndQRRHO") {
            let ar = Molecule(atoms: [Atom(id: 0, atomicNumber: 18, position: .zero), Atom(id: 1, atomicNumber: 18, position: Vec3(0, 0, 3.8))])
            // single harmonic mode, plain RRHO: closed form
            let nu = 500.0
            let r = Thermochemistry.compute(ThermoInput(molecule: ar, frequencies: [nu, -150, 0], electronicEnergy: 0, multiplicity: 1))
            try expect(r.frequenciesUsed == 1)
            let theta = 6.62607015e-34 * 2.99792458e10 * nu / 1.380649e-23
            let x = theta / 298.15
            let sv = 8.314462618 * (x / (exp(x) - 1) - log(1 - exp(-x)))
            try expectClose(r.sVib * 4.184, sv, tol: 1e-9)
            try expectClose(r.zeroPointEnergy, 0.5 * nu / 219474.6313632, tol: 1e-9)
            // frequency scaling lowers ZPE proportionally
            let sc = Thermochemistry.compute(ThermoInput(molecule: ar, frequencies: [nu], electronicEnergy: 0, multiplicity: 1), frequencyScale: 0.9)
            try expectClose(sc.zeroPointEnergy, 0.9 * r.zeroPointEnergy, tol: 1e-12)
            // quasi-RRHO: high frequency unchanged, low frequency has less entropy than the divergent HO value yet is finite & lower
            let hi = Thermochemistry.compute(ThermoInput(molecule: ar, frequencies: [3000], electronicEnergy: 0, multiplicity: 1), quasiRRHO: QuasiRRHO())
            let hiHO = Thermochemistry.compute(ThermoInput(molecule: ar, frequencies: [3000], electronicEnergy: 0, multiplicity: 1))
            try expectClose(hi.sVib, hiHO.sVib, tol: 1e-6)
            let lo = Thermochemistry.compute(ThermoInput(molecule: ar, frequencies: [10], electronicEnergy: 0, multiplicity: 1), quasiRRHO: QuasiRRHO())
            let loHO = Thermochemistry.compute(ThermoInput(molecule: ar, frequencies: [10], electronicEnergy: 0, multiplicity: 1))
            try expect(lo.sVib < loHO.sVib && lo.sVib > 0, "\(lo.sVib) \(loHO.sVib)")
        },
        Check("analysis.thermo.orcaWater") {
            let ref = OrcaThermoRef(text: try String(contentsOf: testDataURL("analysis/water_sto3g_optfreq.orca.out"), encoding: .utf8))
            try expect(ref.molecule.atoms.count == 3 && ref.freqs.count == 9, "parse: \(ref.molecule.atoms.count) atoms \(ref.freqs.count) freqs")
            let toEh = 1.0 / 1.0
            _ = toEh
            let inp = ThermoInput(molecule: ref.molecule, frequencies: ref.freqs, electronicEnergy: ref.energy, multiplicity: 1)
            let r = Thermochemistry.compute(inp, quasiRRHO: QuasiRRHO())
            let zpe = ref.values["Zero point energy"]!
            let thermal = ref.values["Total thermal correction"]!
            let hcorr = ref.values["Thermal Enthalpy correction"]!
            let ts = -ref.values["Total entropy correction"]!
            let gFinal = ref.values["Final Gibbs free energy"]!
            let hTot = ref.values["Total Enthalpy"]!
            print("  D water: ZPE d=\(r.zeroPointEnergy - zpe) thermal d=\(r.thermalEnergyCorrection - zpe - thermal) kT d=\(r.enthalpyCorrection - r.thermalEnergyCorrection - hcorr) TS d=\(r.tsTerm - ts) H d=\(r.sumH - hTot) G d=\(r.sumG - gFinal)")
            try expect(r.symmetryNumber == 2 && !r.isLinear)
            try expectClose(r.zeroPointEnergy, zpe, tol: 1e-5)
            try expectClose(r.thermalEnergyCorrection - r.zeroPointEnergy, thermal, tol: 1e-5)
            try expectClose(r.enthalpyCorrection - r.thermalEnergyCorrection, hcorr, tol: 1e-5)
            try expectClose(r.sumH, hTot, tol: 1e-5)
            try expectClose(r.tsTerm, ts, tol: 1e-5)
            try expectClose(r.sumG, gFinal, tol: 1e-5)
            // components: T*S_trans, T*S_rot
            let k = r.temperature * 4.184 / 6.02214076e23 / 4.3597447222071e-18
            try expectClose(r.sTrans * k, ref.values["Translational entropy"]!, tol: 1e-5)
            try expectClose(r.sRot * k, ref.values["Rotational entropy"]!, tol: 1e-5)
            // rotational constants vs ORCA (MHz → GHz)
            let orca = [698.271253989, 436.210174351, 268.486568257]
            for (a, b) in zip(r.rotationalConstantsGHz, orca) { try expect(abs(a - b) / b < 2e-3, "\(a) vs \(b)") }
            // explicit symmetry number override changes S_rot by R ln 2
            let c1 = Thermochemistry.compute(ThermoInput(molecule: ref.molecule, frequencies: ref.freqs, electronicEnergy: ref.energy, symmetryNumber: 1, multiplicity: 1))
            try expectClose((c1.sRot - r.sRot) * 4.184, 8.314462618 * log(2.0), tol: 1e-9)
            // 400 K: everything grows sensibly
            let hot = Thermochemistry.compute(inp, temperature: 400, quasiRRHO: QuasiRRHO())
            try expect(hot.sumH > r.sumH && hot.entropy > r.entropy && hot.sumG < r.sumG && hot.cvTotal > r.cvTotal)
            try expectClose(hot.zeroPointEnergy, r.zeroPointEnergy, tol: 1e-15)
            // classical limit check: Cv(trans+rot) = 3R at any T, vib small at 400 K
            try expect(hot.cvTrans + hot.cvRot > 0 && hot.cvVib < 0.1)
        },
    ]
}
