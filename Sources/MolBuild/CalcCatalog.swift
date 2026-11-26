import Foundation
import MolCore

// Method / basis-set catalog for Calculation Setup: one table with each program's keyword spelling, the kind of
// method, the dispersion corrections that have parameters for it, and whether ORCA needs a correlation (/C)
// auxiliary basis. CalcSetup writes `method` / `basis` verbatim into the input, so the program-specific spelling
// lives here. A program missing from `keywords` means "not offered for that program".
//
// | kind           | basis shown | dispersion                      |
// |----------------|-------------|---------------------------------|
// | hf, dft, dh    | yes         | the method's list ∩ the program |
// | wavefunction   | yes         | none                            |
// | composite      | no          | built in                        |
// | semiEmpirical  | no          | none                            |
// | xtb            | no          | built in                        |

public enum MethodKind: String, Sendable, Codable, CaseIterable {
    case hf, dft, doubleHybrid, composite, semiEmpirical, wavefunction, xtb
    public var title: String {
        switch self {
        case .hf: "Hartree–Fock"; case .dft: "DFT"; case .doubleHybrid: "Double hybrid"; case .composite: "Composite"
        case .semiEmpirical: "Semi-empirical"; case .wavefunction: "Wavefunction"; case .xtb: "xtb"
        }
    }
    /// The method brings its own basis set (or none).
    public var isBasisFree: Bool { self == .composite || self == .semiEmpirical || self == .xtb }
}

/// Empirical dispersion corrections the setup sheet offers.
public enum CalcDispersion: String, Sendable, Codable, CaseIterable, Identifiable {
    case d3bj, d3zero, d4
    public var id: String { rawValue }
    public var title: String { switch self { case .d3bj: "D3(BJ)"; case .d3zero: "D3(0)"; case .d4: "D4" } }
    /// Programs with a keyword for it (Gaussian has no D4).
    public var programs: [QCProgram] { self == .d4 ? [.orca, .qchem] : [.gaussian, .orca, .qchem] }
    public func keyword(for p: QCProgram) -> String? {
        guard programs.contains(p) else { return nil }
        switch p {
        case .gaussian: return self == .d3bj ? "EmpiricalDispersion=GD3BJ" : "EmpiricalDispersion=GD3"
        case .orca: return self == .d3bj ? "D3BJ" : (self == .d3zero ? "D3ZERO" : "D4")
        case .qchem: return "DFT_D " + (self == .d3bj ? "D3_BJ" : (self == .d3zero ? "D3_ZERO" : "D4"))
        case .xtb: return nil
        }
    }
}

/// Which dispersion corrections a method takes.
public enum DispersionSupport: Sendable, Equatable {
    /// Any of these may be added (an empty list: none has parameters).
    case choose([CalcDispersion])
    /// Part of the method (ωB97X-D, B97-3c, xtb…): nothing to add.
    case builtin

    public static let all: DispersionSupport = .choose(CalcDispersion.allCases)
    public static let none: DispersionSupport = .choose([])
}

/// ORCA resolution-of-identity / auxiliary-basis choice ("!" line keywords).
public enum OrcaAuxiliary: String, Sendable, Codable, CaseIterable, Identifiable {
    case automatic, rijcosx, rij, rijk, autoAux, noRI
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .automatic: "Automatic"; case .rijcosx: "RIJCOSX def2/J"; case .rij: "RI-J def2/J"; case .rijk: "RIJK def2/JK"
        case .autoAux: "AutoAux"; case .noRI: "No RI (NoRI)"
        }
    }
    public var keywords: [String] {
        switch self {
        case .automatic: []; case .rijcosx: ["RIJCOSX", "def2/J"]; case .rij: ["RI", "def2/J"]; case .rijk: ["RIJK", "def2/JK"]
        case .autoAux: ["AutoAux"]; case .noRI: ["NoRI"]
        }
    }
}

public struct CatalogMethod: Sendable, Identifiable {
    public let id: String
    public let label: String
    public let group: String
    public let kind: MethodKind
    public let dispersion: DispersionSupport
    /// ORCA needs a /C correlation auxiliary basis (RI-MP2, DLPNO, double hybrids).
    public let needsCorrelationAux: Bool
    public let keywords: [QCProgram: String]
    /// Per-program dispersion when it differs from `dispersion` (Q-Chem's DSD-PBEP86-D3 has it built in).
    public let dispersionOverride: [QCProgram: DispersionSupport]

    public func keyword(for p: QCProgram) -> String? { keywords[p] }
    public func dispersion(for p: QCProgram) -> DispersionSupport { dispersionOverride[p] ?? dispersion }
    /// The dispersion corrections the user may pick for this method in program `p`.
    public func dispersionChoices(for p: QCProgram) -> [CalcDispersion] {
        guard !kind.isBasisFree else { return [] }
        if case .choose(let l) = dispersion(for: p) { return l.filter { $0.programs.contains(p) } }
        return []
    }
}

public struct CatalogBasis: Sendable, Identifiable {
    public let id: String
    public let label: String
    public let group: String
    /// Heaviest element the basis is defined for (all-electron or with its standard ECP).
    public let maxZ: Int
    /// "def2" (Q-Chem needs `ECP def2-ECP` past Kr) or "lanl2dz".
    public let ecp: String?
    public let keywords: [QCProgram: String]
    /// ORCA correlation auxiliary basis matching this one.
    public let orcaCorrelationAux: String?
    public func keyword(for p: QCProgram) -> String? { keywords[p] }
}

public enum CalcCatalog {
    private static func kw(_ g: String?, _ o: String?, _ q: String?) -> [QCProgram: String] {
        var d: [QCProgram: String] = [:]
        if let g { d[.gaussian] = g }
        if let o { d[.orca] = o }
        if let q { d[.qchem] = q }
        return d
    }
    private static func m(_ id: String, _ label: String? = nil, _ group: String, _ kind: MethodKind, _ disp: DispersionSupport,
                          ri: Bool = false, _ k: [QCProgram: String], override: [QCProgram: DispersionSupport] = [:]) -> CatalogMethod {
        CatalogMethod(id: id, label: label ?? id, group: group, kind: kind, dispersion: disp, needsCorrelationAux: ri,
                      keywords: k, dispersionOverride: override)
    }

    public static let methods: [CatalogMethod] = {
        let gga = "GGA / meta-GGA", hyb = "Hybrid", rsh = "Range-separated hybrid", dh = "Double hybrid"
        let comp = "Composite (own basis)", semi = "Semi-empirical", wft = "Wavefunction"
        return [
            m("HF", nil, "Hartree–Fock", .hf, .all, kw("HF", "HF", "HF")),
            m("PBE", nil, gga, .dft, .all, kw("PBEPBE", "PBE", "PBE")),
            m("BP86", nil, gga, .dft, .all, kw("BP86", "BP86", "BP86")),
            m("BLYP", nil, gga, .dft, .all, kw("BLYP", "BLYP", "BLYP")),
            m("revPBE", nil, gga, .dft, .all, kw(nil, "revPBE", "revPBE")),
            m("B97-D3", nil, gga, .dft, .builtin, kw("B97D3", "B97-D3", "B97-D3(0)")),
            m("TPSS", nil, gga, .dft, .all, kw("TPSSTPSS", "TPSS", "TPSS")),
            m("M06-L", nil, gga, .dft, .choose([.d3zero]), kw("M06L", "M06L", "M06-L")),
            m("r2SCAN", nil, gga, .dft, .all, kw(nil, "r2SCAN", "r2SCAN")),
            m("B97M-V", nil, gga, .dft, .builtin, kw(nil, "B97M-V", "B97M-V")),
            m("B3LYP", nil, hyb, .dft, .all, kw("B3LYP", "B3LYP", "B3LYP")),
            m("PBE0", nil, hyb, .dft, .all, kw("PBE1PBE", "PBE0", "PBE0")),
            m("B3PW91", nil, hyb, .dft, .choose([.d3bj, .d3zero]), kw("B3PW91", "B3PW91", "B3PW91")),
            m("APFD", nil, hyb, .dft, .builtin, kw("APFD", nil, nil)),
            m("r2SCAN0", nil, hyb, .dft, .choose([.d4]), kw(nil, "r2SCAN0", "r2SCAN0")),
            m("PW6B95", nil, hyb, .dft, .all, kw(nil, "PW6B95", "PW6B95")),
            m("TPSSh", nil, hyb, .dft, .all, kw("TPSSh", "TPSSh", "TPSSh")),
            m("M06", nil, hyb, .dft, .choose([.d3zero]), kw("M06", "M06", "M06")),
            m("M06-2X", nil, hyb, .dft, .choose([.d3zero]), kw("M062X", "M062X", "M06-2X")),
            m("MN15", nil, hyb, .dft, .none, kw("MN15", "MN15", "MN15")),
            m("CAM-B3LYP", nil, rsh, .dft, .all, kw("CAM-B3LYP", "CAM-B3LYP", "CAM-B3LYP")),
            m("LC-wPBE", "LC-ωPBE", rsh, .dft, .all, kw("LC-wHPBE", "LC-PBE", "LRC-wPBE")),
            m("wB97X", "ωB97X", rsh, .dft, .none, kw("wB97X", "wB97X", "wB97X")),
            m("wB97X-D", "ωB97X-D", rsh, .dft, .builtin, kw("wB97XD", "wB97X-D3", "wB97X-D")),
            m("wB97X-D3BJ", "ωB97X-D3(BJ)", rsh, .dft, .builtin, kw(nil, "wB97X-D3BJ", nil)),
            m("wB97X-V", "ωB97X-V", rsh, .dft, .builtin, kw(nil, "wB97X-V", "wB97X-V")),
            m("wB97M-V", "ωB97M-V", rsh, .dft, .builtin, kw(nil, "wB97M-V", "wB97M-V")),
            m("B2PLYP", nil, dh, .doubleHybrid, .all, ri: true, kw("B2PLYP", "B2PLYP", "B2PLYP")),
            m("mPW2PLYP", nil, dh, .doubleHybrid, .choose([.d3bj]), ri: true, kw("mPW2PLYP", "mPW2PLYP", nil)),
            m("revDSD-PBEP86-D4", nil, dh, .doubleHybrid, .builtin, ri: true, kw(nil, "revDSD-PBEP86-D4", nil)),
            m("DSD-PBEP86", nil, dh, .doubleHybrid, .choose([.d3bj]), ri: true, kw("DSDPBEP86", "DSD-PBEP86", "DSD-PBEP86-D3"),
              override: [.qchem: .builtin]),
            m("r2SCAN-3c", nil, comp, .composite, .builtin, kw(nil, "r2SCAN-3c", nil)),
            m("B97-3c", nil, comp, .composite, .builtin, kw(nil, "B97-3c", nil)),
            m("PBEh-3c", nil, comp, .composite, .builtin, kw(nil, "PBEh-3c", nil)),
            m("HF-3c", nil, comp, .composite, .builtin, kw(nil, "HF-3c", nil)),
            m("CBS-QB3", nil, comp, .composite, .builtin, kw("CBS-QB3", nil, nil)),
            m("G4", nil, comp, .composite, .builtin, kw("G4", nil, nil)),
            m("PM7", nil, semi, .semiEmpirical, .none, kw("PM7", nil, nil)),
            m("PM6", nil, semi, .semiEmpirical, .none, kw("PM6", nil, nil)),
            m("PM3", nil, semi, .semiEmpirical, .none, kw("PM3", "PM3", nil)),
            m("AM1", nil, semi, .semiEmpirical, .none, kw("AM1", "AM1", nil)),
            m("MP2", nil, wft, .wavefunction, .none, kw("MP2", "MP2", "MP2")),
            m("RI-MP2", nil, wft, .wavefunction, .none, ri: true, kw(nil, "RI-MP2", nil)),
            m("SCS-MP2", "SCS-RI-MP2", wft, .wavefunction, .none, ri: true, kw(nil, "RI-SCS-MP2", nil)),
            m("MP4", "MP4(SDTQ)", wft, .wavefunction, .none, kw("MP4", nil, nil)),
            m("CCSD", nil, wft, .wavefunction, .none, kw("CCSD", "CCSD", "CCSD")),
            m("CCSD(T)", nil, wft, .wavefunction, .none, kw("CCSD(T)", "CCSD(T)", "CCSD(T)")),
            m("DLPNO-CCSD(T)", nil, wft, .wavefunction, .none, ri: true, kw(nil, "DLPNO-CCSD(T)", nil)),
            m("DLPNO-CCSD(T1)", nil, wft, .wavefunction, .none, ri: true, kw(nil, "DLPNO-CCSD(T1)", nil)),
            m("GFN2-xTB", nil, "xtb", .xtb, .builtin, [.xtb: "GFN2-xTB"]),
            m("GFN1-xTB", nil, "xtb", .xtb, .builtin, [.xtb: "GFN1-xTB"]),
            m("GFN-FF", nil, "xtb", .xtb, .builtin, [.xtb: "GFN-FF"]),
        ]
    }()

    public static let bases: [CatalogBasis] = {
        func b(_ id: String, _ group: String, maxZ: Int, ecp: String? = nil, _ k: [QCProgram: String], aux: String? = nil, label: String? = nil) -> CatalogBasis {
            CatalogBasis(id: id, label: label ?? id, group: group, maxZ: maxZ, ecp: ecp, keywords: k, orcaCorrelationAux: aux)
        }
        func pople(_ id: String, _ qchem: String? = nil, maxZ: Int = 36) -> CatalogBasis { b(id, "Pople", maxZ: maxZ, kw(id, id, qchem ?? id)) }
        func def2(_ id: String, gaussian: String?, qchem: Bool = true, aux: String) -> CatalogBasis {
            b(id, "Karlsruhe def2", maxZ: 86, ecp: "def2", kw(gaussian, id, qchem ? id : nil), aux: aux)
        }
        func cc(_ id: String) -> CatalogBasis { b(id, "Dunning", maxZ: 36, kw(id, id, id), aux: id + "/C") }
        func pc(_ id: String) -> CatalogBasis { b(id, "Jensen", maxZ: 36, kw(nil, id, id)) }
        return [
            b("STO-3G", "Minimal", maxZ: 54, kw("STO-3G", "STO-3G", "STO-3G")),
            pople("3-21G", maxZ: 54), pople("6-31G"), pople("6-31G(d)", "6-31G*"), pople("6-31G(d,p)", "6-31G**"),
            pople("6-31+G(d)", "6-31+G*"), pople("6-31+G(d,p)", "6-31+G**"), pople("6-31++G(d,p)", "6-31++G**"), pople("6-31G(2df,p)"),
            pople("6-311G(d,p)", "6-311G**"), pople("6-311+G(d,p)", "6-311+G**"), pople("6-311+G(2d,p)"),
            pople("6-311++G(d,p)", "6-311++G**"), pople("6-311++G(2d,2p)"), pople("6-311++G(3df,3pd)"),
            def2("def2-SVP", gaussian: "Def2SVP", aux: "def2-SVP/C"),
            def2("def2-SV(P)", gaussian: nil, aux: "def2-SVP/C"),
            def2("def2-SVPD", gaussian: nil, aux: "def2-SVPD/C"),
            def2("def2-TZVP", gaussian: "Def2TZVP", aux: "def2-TZVP/C"),
            def2("def2-TZVP(-f)", gaussian: nil, qchem: false, aux: "def2-TZVP/C"),
            def2("def2-TZVPP", gaussian: "Def2TZVPP", aux: "def2-TZVPP/C"),
            def2("def2-TZVPD", gaussian: nil, aux: "def2-TZVPD/C"),
            def2("def2-QZVP", gaussian: "Def2QZVP", aux: "def2-QZVPP/C"),
            def2("def2-QZVPP", gaussian: "Def2QZVPP", aux: "def2-QZVPP/C"),
            def2("ma-def2-SVP", gaussian: nil, qchem: false, aux: "def2-SVP/C"),
            def2("ma-def2-TZVP", gaussian: nil, qchem: false, aux: "def2-TZVP/C"),
            cc("cc-pVDZ"), cc("cc-pVTZ"), cc("cc-pVQZ"), cc("cc-pV5Z"), cc("aug-cc-pVDZ"), cc("aug-cc-pVTZ"), cc("aug-cc-pVQZ"),
            b("jun-cc-pVTZ", "Dunning", maxZ: 18, kw("jun-cc-pVTZ", nil, nil)),
            pc("pcseg-1"), pc("aug-pcseg-1"), pc("pcseg-2"), pc("aug-pcseg-2"), pc("pcseg-3"),
            b("LANL2DZ", "Effective core potential", maxZ: 83, ecp: "lanl2dz", kw("LANL2DZ", "LANL2DZ", "LANL2DZ"), label: "LANL2DZ (ECP)"),
            b("SDD", "Effective core potential", maxZ: 86, kw("SDD", nil, nil), label: "SDD (Stuttgart/Dresden ECP)"),
        ]
    }()

    public static func methods(for p: QCProgram) -> [CatalogMethod] { methods.filter { $0.keywords[p] != nil } }
    public static func bases(for p: QCProgram) -> [CatalogBasis] { p == .xtb ? [] : bases.filter { $0.keywords[p] != nil } }

    private static func norm(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces).lowercased() }

    /// The entry a method keyword belongs to: the program's own spelling first, then the id, label or any
    /// program's keyword (saved settings may hold another program's spelling such as "M062X").
    public static func method(matching text: String, program: QCProgram? = nil) -> CatalogMethod? {
        let t = norm(text)
        guard !t.isEmpty else { return nil }
        if let p = program, let e = methods.first(where: { $0.keywords[p].map(norm) == t }) { return e }
        return methods.first { norm($0.id) == t || norm($0.label) == t }
            ?? methods.first { $0.keywords.values.contains { norm($0) == t } }
    }

    public static func basis(matching text: String, program: QCProgram? = nil) -> CatalogBasis? {
        let t = norm(text)
        guard !t.isEmpty else { return nil }
        if let p = program, let e = bases.first(where: { $0.keywords[p].map(norm) == t }) { return e }
        return bases.first { norm($0.id) == t || norm($0.label) == t } ?? bases.first { $0.keywords.values.contains { norm($0) == t } }
    }

    /// Kind of a method keyword; unknown keywords count as DFT (`basisOptional` still catches the classic names).
    public static func kind(of method: String, program: QCProgram) -> MethodKind {
        if program == .xtb { return .xtb }
        return self.method(matching: method, program: program)?.kind ?? .dft
    }
}

// MARK: - CalcSetup integration

extension CalcSetup {
    /// The catalog entry of the current method, if it is one.
    public var catalogMethod: CatalogMethod? { CalcCatalog.method(matching: method, program: program) }
    public var catalogBasis: CatalogBasis? { CalcCatalog.basis(matching: basis, program: program) }

    /// The method brings its own basis (composite, semi-empirical, xtb): the basis field is hidden and not written.
    public var methodIsBasisFree: Bool { program == .xtb || Self.basisOptional(method) }

    /// Dispersion choices for the current method and program (empty: none, or built in; see `dispersionIsBuiltin`).
    public var dispersionChoices: [CalcDispersion] {
        if program == .xtb { return [] }
        if let e = catalogMethod { return e.dispersionChoices(for: program) }
        return methodIsBasisFree ? [] : CalcDispersion.allCases.filter { $0.programs.contains(program) }   // custom keyword: anything
    }
    public var dispersionIsBuiltin: Bool {
        if program == .xtb { return true }
        if let e = catalogMethod { return e.dispersion(for: program) == .builtin || e.kind == .composite }
        return false
    }
    /// The dispersion actually written: the chosen one when valid for this method and program.
    public var effectiveDispersion: CalcDispersion? {
        guard let d = dispersion, dispersionChoices.contains(d) else { return nil }
        return d
    }

    /// ORCA "!" keywords for RI / auxiliary basis sets (empty for basis-free methods or other programs).
    public var orcaAuxiliaryKeywords: [String] {
        guard program == .orca, !methodIsBasisFree else { return [] }
        let aux = orcaAuxiliary ?? .automatic
        var k = aux.keywords
        let needsC = catalogMethod?.needsCorrelationAux
            ?? { let u = method.uppercased(); return u.hasPrefix("RI-") || u.hasPrefix("DLPNO") }()
        if needsC, aux != .autoAux, aux != .noRI { k.append(catalogBasis?.orcaCorrelationAux ?? "AutoAux") }
        return k
    }

    /// Q-Chem `$rem` lines for ECPs (def2 / LANL2DZ past krypton).
    public func qchemECPLines(molecule: Molecule) -> [String] {
        guard program == .qchem, let b = catalogBasis, let e = b.ecp, molecule.atoms.contains(where: { $0.atomicNumber > 36 }) else { return [] }
        return [e == "def2" ? "ECP def2-ECP" : "ECP fit-LANL2DZ"]
    }

    /// Non-blocking advice shown under the preview: method or basis not available for this program, basis not
    /// defined for the heaviest element.
    public func catalogAdvisories(molecule: Molecule) -> [String] {
        var out: [String] = []
        guard program != .xtb else { return out }
        if let e = CalcCatalog.method(matching: method), e.keywords[program] == nil {
            out.append("\(program.title) has no \(e.label) keyword; choose another method or type a custom one.")
        }
        if !methodIsBasisFree, let b = CalcCatalog.basis(matching: basis) {
            if b.keywords[program] == nil {
                out.append("\(program.title) has no built-in \(b.label); choose another basis or type a custom one.")
            }
            let zMax = molecule.atoms.map(\.atomicNumber).max() ?? 0
            if zMax > b.maxZ {
                out.append("\(b.label) is defined only up to Z = \(b.maxZ); this molecule has Z = \(zMax). Use def2-* or LANL2DZ for heavy atoms.")
            }
        }
        if let d = dispersion, effectiveDispersion == nil, !methodIsBasisFree {
            out.append("\(d.title) is not available for \(method) in \(program.title); no dispersion correction is written.")
        }
        return out
    }
}
