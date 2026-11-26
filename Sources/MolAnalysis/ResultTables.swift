import Foundation
import MolCore
import MolIO

/// File ▸ Export ▸ Table: calculation results as CSV (RFC 4180 quoting, one header row, "\n" line ends).
public enum ResultTables {
    public enum Table: String, Sendable, CaseIterable {
        case frequencies, orbitals, states, energies, charges
        public var title: String {
            switch self {
            case .frequencies: "Frequencies (IR / Raman)"
            case .orbitals: "Orbital energies"
            case .states: "Excited states"
            case .energies: "Energies per frame / step"
            case .charges: "Atomic charges"
            }
        }
    }

    static let kcal = 627.509474

    /// Tables with data in `result`.
    public static func available(_ r: CalculationResult?) -> [Table] {
        guard let r else { return [] }
        var out: [Table] = []
        if !r.normalModes.isEmpty { out.append(.frequencies) }
        if !r.orbitals.isEmpty { out.append(.orbitals) }
        if !r.excitedStates.isEmpty { out.append(.states) }
        if !r.energies.isEmpty { out.append(.energies) }
        if !r.mullikenCharges.isEmpty || !(r.extras?.charges.isEmpty ?? true) { out.append(.charges) }
        return out
    }

    public static func cell(_ v: String) -> String {
        v.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) ? "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : v
    }
    public static func rows(_ rows: [[String]]) -> String { rows.map { $0.map(cell).joined(separator: ",") }.joined(separator: "\n") + "\n" }
    static func num(_ v: Double?, _ d: Int = 6) -> String { v.map { String(format: "%.\(d)f", $0) } ?? "" }

    public enum TableError: Error, CustomStringConvertible {
        case empty(Table)
        public var description: String {
            switch self { case .empty(let t): "this document has no \(t.title.lowercased())" }
        }
    }

    /// The CSV text of `table`. `molecule` labels the charge rows with element symbols.
    public static func csv(_ table: Table, result r: CalculationResult, molecule: Molecule? = nil) throws -> String {
        switch table {
        case .frequencies:
            guard !r.normalModes.isEmpty else { throw TableError.empty(table) }
            var out = [["mode", "frequency (cm-1)", "IR intensity (km/mol)", "Raman activity (A^4/amu)", "symmetry",
                        "reduced mass (amu)", "force constant (mDyne/A)"]]
            for (i, m) in r.normalModes.enumerated() {
                out.append([String(i + 1), num(m.frequency, 4), num(m.irIntensity, 4), num(m.ramanActivity, 4), m.symmetry ?? "",
                            num(m.reducedMass, 4), num(m.forceConstant, 4)])
            }
            return rows(out)
        case .orbitals:
            guard !r.orbitals.isEmpty else { throw TableError.empty(table) }
            let d = OrbitalLevelDiagram(orbitals: r.orbitals)
            var label: [String: String] = [:]
            for c in d.columns { for l in c.levels { for i in l.orbitalIndices { label["\(c.spin.rawValue)|\(i + 1)"] = l.label } } }
            var out = [["spin", "orbital", "energy (Eh)", "energy (eV)", "occupation", "label"]]
            for o in r.orbitals.sorted(by: { ($0.spin.rawValue, $0.index) < ($1.spin.rawValue, $1.index) }) {
                let occ = o.occupied ? (o.spin == .restricted ? "2" : "1") : "0"
                out.append([o.spin.rawValue, String(o.index), num(o.energy, 6), num(o.energy * PhysConst.hartreeToEV, 4), occ,
                            label["\(o.spin.rawValue)|\(o.index)"] ?? ""])
            }
            return rows(out)
        case .states:
            guard !r.excitedStates.isEmpty else { throw TableError.empty(table) }
            var out = [["state", "energy (eV)", "wavelength (nm)", "oscillator strength", "multiplicity", "symmetry"]]
            for (i, s) in r.excitedStates.enumerated() {
                out.append([String(i + 1), num(s.energyEV, 4), num(s.wavelengthNM, 2), num(s.oscillatorStrength, 6),
                            s.multiplicity.map(String.init) ?? "", s.symmetry ?? ""])
            }
            return rows(out)
        case .energies:
            guard let e0 = r.energies.first else { throw TableError.empty(table) }
            var out = [["step", "energy (Eh)", "relative (kcal/mol)"]]
            for (i, e) in r.energies.enumerated() { out.append([String(i + 1), num(e, 10), num((e - e0) * kcal, 4)]) }
            return rows(out)
        case .charges:
            var schemes: [(String, [Double])] = []
            if !r.mullikenCharges.isEmpty { schemes.append(("Mulliken", r.mullikenCharges)) }
            for (k, v) in (r.extras?.charges ?? [:]).sorted(by: { $0.key < $1.key }) where !schemes.contains(where: { $0.0 == k }) {
                schemes.append((k, v))
            }
            guard !schemes.isEmpty else { throw TableError.empty(table) }
            let n = schemes.map(\.1.count).max() ?? 0
            var out = [["atom", "element"] + schemes.map(\.0)]
            for i in 0..<n {
                let sym = molecule.flatMap { i < $0.atoms.count ? Elements.symbol($0.atoms[i].atomicNumber) : nil } ?? ""
                out.append([String(i + 1), sym] + schemes.map { i < $0.1.count ? num($0.1[i], 6) : "" })
            }
            return rows(out)
        }
    }
}
