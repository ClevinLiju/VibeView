import Foundation
import MolCore
import MolIO
import MolBuild

// Method / basis catalog (MolBuild/CalcCatalog.swift): every entry generates valid input for each program it claims.

fileprivate func catWater() -> Molecule {
    var m = Molecule(atoms: [Atom(id: 0, atomicNumber: 8, position: Vec3(0, 0, 0.1173)),
                             Atom(id: 1, atomicNumber: 1, position: Vec3(0, 0.7572, -0.4692)),
                             Atom(id: 2, atomicNumber: 1, position: Vec3(0, -0.7572, -0.4692))], title: "water")
    m.addBond(0, 1, order: .single); m.addBond(0, 2, order: .single)
    return m
}

/// The program's level-of-theory text: Gaussian route, ORCA "!" line, Q-Chem $rem block.
fileprivate func catLevel(_ s: CalcSetup, _ text: String) -> String {
    let lines = text.components(separatedBy: "\n")
    switch s.program {
    case .gaussian: return lines.first { $0.hasPrefix("#") } ?? ""
    case .orca: return lines.first { $0.hasPrefix("!") } ?? ""
    default:
        guard let a = lines.firstIndex(of: "$rem") else { return "" }
        return lines[a...].prefix { $0 != "$end" }.joined(separator: "\n")
    }
}

/// Generates the input, checks it parses back (Gaussian / ORCA readers) and returns the level-of-theory text.
fileprivate func catGenerate(_ s: CalcSetup) throws -> String {
    let w = catWater()
    try expect(s.validate(molecule: w).isEmpty, "\(s.program) \(s.method)/\(s.basis): \(s.validate(molecule: w))")
    let text = s.inputText(molecule: w)
    switch s.program {
    case .gaussian:
        let f = try MolecularFileLoader.load(text: text, format: .gaussianInput, fileName: "job.gjf")
        try expect(f.molecule.atoms.count == 3, "gaussian parse \(s.method)")
    case .orca:
        let f = try MolecularFileLoader.load(text: text, format: .orcaInput, fileName: "job.inp")
        try expect(f.molecule.atoms.count == 3, "orca parse \(s.method)")
    case .qchem:
        try expect(text.contains("$molecule") && text.contains("$rem") && text.contains("METHOD \(s.method)"), text)
    case .xtb: break
    }
    return catLevel(s, text)
}

fileprivate func words(_ s: String) -> [String] { s.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "/" }).map(String.init) }

extension Checks {
    static let buildCatalog: [Check] = [
        Check("build.catalog.tableIsConsistent") {
            try expect(Set(CalcCatalog.methods.map(\.id)).count == CalcCatalog.methods.count, "method ids unique")
            try expect(Set(CalcCatalog.bases.map(\.id)).count == CalcCatalog.bases.count, "basis ids unique")
            for p in [MolBuild.QCProgram.gaussian, .orca, .qchem] {
                let ms = CalcSetup.methods(for: p), bs = CalcSetup.bases(for: p)
                try expect(ms.count >= 25 && bs.count >= 20, "\(p): \(ms.count) methods, \(bs.count) bases")
                try expect(Set(ms).count == ms.count && Set(bs).count == bs.count, "\(p) duplicates")
                try expect(ms.contains(CalcSetup.defaultMethod(for: p)) && bs.contains(CalcSetup.defaultBasis(for: p)), "\(p) defaults listed")
            }
            try expect(CalcSetup.methods(for: .xtb) == ["GFN2-xTB", "GFN1-xTB", "GFN-FF"] && CalcSetup.bases(for: .xtb).isEmpty)
            try expect(CalcCatalog.method(matching: "PBE1PBE")?.id == "PBE0" && CalcCatalog.method(matching: "m062x")?.id == "M06-2X")
            try expect(CalcCatalog.basis(matching: "Def2TZVP")?.id == "def2-TZVP" && CalcCatalog.basis(matching: "6-31G*")?.id == "6-31G(d)")
            for e in CalcCatalog.methods where e.kind.isBasisFree { try expect(e.dispersionChoices(for: .orca).isEmpty, "\(e.id) hides dispersion") }
        },
        Check("build.catalog.everyMethodWritesValidInput") {
            var n = 0
            for p in [MolBuild.QCProgram.gaussian, .orca, .qchem] {
                for e in CalcCatalog.methods(for: p) {
                    let k = e.keyword(for: p)!
                    for d in [nil] + e.dispersionChoices(for: p).map(Optional.some) {
                        var s = CalcSetup(molecule: catWater(), program: p)
                        s.jobType = .energy; s.method = k; s.dispersion = d
                        if e.kind.isBasisFree { s.basis = "" }
                        let level = try catGenerate(s)
                        try expect(words(level).contains(k), "\(p) \(k): \(level)")
                        let basis = CalcSetup.defaultBasis(for: p)
                        if e.kind.isBasisFree {
                            try expect(s.methodIsBasisFree && s.dispersionChoices.isEmpty, "\(p) \(k) is basis-free")
                            // Even with a stale basis left in the field nothing is written.
                            var t = s; t.basis = basis
                            try expect(!words(try catGenerate(t)).contains(basis), "\(p) \(k) drops the basis")
                        }
                        if let d {
                            try expect(level.contains(d.keyword(for: p)!), "\(p) \(k) \(d): \(level)")
                        } else {
                            try expect(!level.contains("EmpiricalDispersion") && !level.contains("DFT_D") && !level.contains(" D3BJ")
                                       && !level.contains(" D4"), "\(p) \(k) without dispersion: \(level)")
                        }
                        n += 1
                    }
                    // A correction the method has no parameters for is not written.
                    if let bad = CalcDispersion.allCases.first(where: { $0.programs.contains(p) && !e.dispersionChoices(for: p).contains($0) }) {
                        var s = CalcSetup(molecule: catWater(), program: p)
                        s.method = k; s.dispersion = bad
                        if e.kind.isBasisFree { s.basis = "" }
                        try expect(s.effectiveDispersion == nil, "\(p) \(k) refuses \(bad)")
                    }
                }
            }
            try expect(n > 150, "\(n) combinations")
        },
        Check("build.catalog.everyBasisWritesValidInput") {
            for p in [MolBuild.QCProgram.gaussian, .orca, .qchem] {
                for b in CalcCatalog.bases(for: p) {
                    var s = CalcSetup(molecule: catWater(), program: p)
                    s.jobType = .energy; s.basis = b.keyword(for: p)!
                    let level = try catGenerate(s)
                    try expect(level.contains(b.keyword(for: p)!), "\(p) \(b.id): \(level)")
                }
            }
        },
        Check("build.catalog.orcaAuxiliaryAndQChemECP") {
            var s = CalcSetup(molecule: catWater(), program: .orca)
            s.method = "RI-MP2"; s.basis = "def2-TZVP"
            try expect(catLevel(s, s.inputText(molecule: catWater())).contains("def2-TZVP/C"), "RI-MP2 gets the /C basis")
            s.method = "DLPNO-CCSD(T)"; s.basis = "6-31G(d)"
            try expect(catLevel(s, s.inputText(molecule: catWater())).contains("AutoAux"), "no /C for Pople: AutoAux")
            s.method = "B3LYP"; s.orcaAuxiliary = .rijcosx
            let l = catLevel(s, s.inputText(molecule: catWater()))
            try expect(l.contains("RIJCOSX def2/J") && !l.contains("/C"), l)
            s.method = "r2SCAN-3c"
            try expect(s.orcaAuxiliaryKeywords.isEmpty, "composites take no aux")
            var q = CalcSetup(molecule: catWater(), program: .qchem)
            q.basis = "def2-SVP"
            var heavy = catWater(); heavy.atoms[0].atomicNumber = 53
            try expect(q.qchemECPLines(molecule: heavy) == ["ECP def2-ECP"] && q.qchemECPLines(molecule: catWater()).isEmpty)
            q.basis = "cc-pVDZ"
            try expect(q.catalogAdvisories(molecule: heavy).contains { $0.contains("Z = 36") }, "\(q.catalogAdvisories(molecule: heavy))")
        },
        Check("build.catalog.programSwitchKeepsTheMethod") {
            var s = CalcSetup(molecule: catWater(), program: .orca)
            s.method = "PBE0"; s.basis = "def2-TZVP"; s.dispersion = .d4
            s.setProgram(.gaussian)
            try expect(s.method == "PBE1PBE" && s.basis == "Def2TZVP" && s.dispersion == nil, "\(s.method) \(s.basis) \(String(describing: s.dispersion))")
            s.setProgram(.qchem)
            try expect(s.method == "PBE0" && s.basis == "def2-TZVP", "\(s.method) \(s.basis)")
            s.method = "r2SCAN-3c"
            try expect(!s.catalogAdvisories(molecule: catWater()).isEmpty, "advisory for a method the program lacks")
        },
    ]
}
