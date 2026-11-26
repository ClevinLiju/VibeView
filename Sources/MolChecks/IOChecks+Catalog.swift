import Foundation
import MolCore
import MolIO

// Extended method/basis catalog in the MolIO writers (Gaussian, ORCA, Q-Chem) and Gaussian output naming on Windows.

fileprivate func ctWater(charge: Int = 0, multiplicity: Int = 1) -> Molecule {
    var m = Molecule(atoms: [Atom(id: 0, atomicNumber: 8, position: Vec3(0, 0, 0.1173)),
                             Atom(id: 1, atomicNumber: 1, position: Vec3(0, 0.7572, -0.4692)),
                             Atom(id: 2, atomicNumber: 1, position: Vec3(0, -0.7572, -0.4692))], title: "water")
    m.charge = charge; m.multiplicity = multiplicity
    return m
}

fileprivate func ctInput(_ p: QCProgram, _ method: String, _ basis: String, disp: DispersionCorrection? = nil,
                         unrestricted: Bool? = nil, radical: Bool = false, extra: [String] = []) throws -> String {
    var s = CalcSpec(program: p, task: .optimize, method: method, basis: basis,
                     molecule: radical ? ctWater(charge: 1, multiplicity: 2) : ctWater())
    s.dispersion = disp
    s.unrestricted = unrestricted
    s.extraKeywords = extra
    return try CalcInputWriter.write(s)
}

extension Checks {
    static let ioCatalog: [Check] = [
        Check("io.calcspec.basisFreeMethods") {
            for m in ["PM7", "pm6", "AM1", "PM3", "ZINDO", "HF-3c", "PBEh-3c", "r2SCAN-3c", "B97-3c", "wB97X-3c", "CBS-QB3", "G4", "G4MP2",
                      "W1BD", "GFN2-xTB", "GFN-FF"] {
                try expect(CalcSpec.isBasisFree(m), m)
            }
            for m in ["B3LYP", "MP2", "CCSD(T)", "DLPNO-CCSD(T)", "wB97X-D3", "PBE0", "G4X-fake", "CBS"] { try expect(!CalcSpec.isBasisFree(m), m) }
            try expect(CalcSpec.isComposite("CBS-QB3") && CalcSpec.isComposite("wB97X-3c") && !CalcSpec.isComposite("PM7"))
        },
        Check("io.calcspec.gaussianCatalog") {
            var t = try ctInput(.gaussian, "PBE1PBE", "Def2TZVP", disp: .d3bj)
            try expect(t.contains("PBE1PBE/Def2TZVP") && t.contains("EmpiricalDispersion=GD3BJ"), t)
            t = try ctInput(.gaussian, "M062X", "6-311++G(d,p)", disp: .d3zero)
            try expect(t.contains("M062X/6-311++G(d,p)") && t.contains("EmpiricalDispersion=GD3") && !t.contains("GD3BJ"), t)
            t = try ctInput(.gaussian, "B3LYP", "Def2SVP", disp: .d4)
            try expect(!t.contains("Empirical"), "D4 isn't a Gaussian keyword")
            t = try ctInput(.gaussian, "PM7", "6-31G(d)")
            try expect(t.contains("PM7") && !t.contains("PM7/"), "semiempirical drops the basis")
            t = try ctInput(.gaussian, "CBS-QB3", "", unrestricted: true, radical: true)
            try expect(t.contains(" CBS-QB3") && !t.contains("UCBS"), "composite keeps its name")
            t = try ctInput(.gaussian, "B3LYP", "Def2SVP", unrestricted: true, radical: true)
            try expect(t.contains("UB3LYP/Def2SVP"), t)
            t = try ctInput(.gaussian, "ROB3LYP", "Def2SVP", unrestricted: true, radical: true)
            try expect(t.contains("ROB3LYP/") && !t.contains("UROB3LYP"), t)
        },
        Check("io.calcspec.orcaCatalog") {
            var t = try ctInput(.orca, "r2SCAN-3c", "def2-SVP")
            try expect(t.contains("! r2SCAN-3c") && !t.contains("def2-SVP"), "composite drops the basis: \(t)")
            t = try ctInput(.orca, "wB97X-3c", "")
            try expect(t.contains("! wB97X-3c"), t)
            t = try ctInput(.orca, "PBE0", "def2-TZVPP", disp: .d4)
            try expect(t.contains("PBE0 def2-TZVPP D4"), t)
            t = try ctInput(.orca, "RI-MP2", "def2-TZVP", unrestricted: true, radical: true, extra: ["def2-TZVP/C"])
            try expect(t.contains("UHF") && !t.contains("UKS") && t.contains("def2-TZVP/C"), "open-shell RI-MP2 on UHF: \(t)")
            t = try ctInput(.orca, "DLPNO-CCSD(T)", "cc-pVTZ", unrestricted: true, radical: true)
            try expect(t.contains("UHF") && !t.contains("UKS"), t)
            t = try ctInput(.orca, "wB97X-D3BJ", "def2-TZVP", unrestricted: true, radical: true)
            try expect(t.contains("UKS"), t)
            t = try ctInput(.orca, "HF-3c", "", unrestricted: true, radical: true)
            try expect(!t.contains("UKS"), "composites pick the reference themselves")
        },
        Check("io.calcspec.qchemCatalog") {
            var t = try ctInput(.qchem, "wB97M-V", "def2-TZVP")
            try expect(t.contains("wb97m-v") && t.contains("def2-TZVP") && !t.contains("DFT_D"), t)
            t = try ctInput(.qchem, "B3LYP", "6-311++G**", disp: .d4)
            try expect(t.contains("D4"), t)
            t = try ctInput(.qchem, "PBE0", "def2-SVP", disp: .d3bj, extra: ["ECP def2-ECP"])
            try expect(t.contains("D3_BJ") && t.contains("ECP def2-ECP"), t)
            t = try ctInput(.qchem, "CCSD(T)", "aug-cc-pVDZ")
            try expect(t.contains("ccsd(t)") && t.contains("aug-cc-pVDZ"), t)
        },
        Check("io.job.gaussianOutputLogOrOut") {
            let fm = FileManager.default
            let dir = fm.temporaryDirectory.appendingPathComponent("molscope-g09w-\(UUID().uuidString)")
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: dir) }
            let s = CalcSpec(program: .gaussian, task: .energy, method: "HF", basis: "STO-3G", molecule: ctWater())
            let p = try CalcJobPlanner.plan(s, baseName: "job")
            try expect(CalcJobResults.outputFileCandidates(p) == ["job.log", "job.out"], "\(CalcJobResults.outputFileCandidates(p))")
            try expect(CalcJobResults.resolvedOutputFileName(p, directory: dir) == nil)
            do { _ = try CalcJobResults.collect(p, directory: dir); throw CheckFailure(description: "expected a throw") } catch is MolIOError {}
            // G09W writes job.out
            let log = try readText(testDataURL("io/gaussian/water_optfreq_td.log"))
            try log.write(to: dir.appendingPathComponent("job.out"), atomically: true, encoding: .utf8)
            try expect(CalcJobResults.resolvedOutputFileName(p, directory: dir) == "job.out")
            let f = try CalcJobResults.collect(p, directory: dir)
            try expect(f.molecule.atoms.count == 3 && f.result?.normalTermination == true, "collected job.out")
            // Both present: the newer one wins.
            try "stale".write(to: dir.appendingPathComponent("job.log"), atomically: true, encoding: .utf8)
            try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: dir.appendingPathComponent("job.log").path)
            try expect(CalcJobResults.resolvedOutputFileName(p, directory: dir) == "job.out")
            // Other programs keep their single name.
            let o = try CalcJobPlanner.plan(CalcSpec(program: .orca, task: .energy, method: "HF", basis: "STO-3G", molecule: ctWater()), baseName: "job")
            try expect(CalcJobResults.outputFileCandidates(o) == ["job.out"])
        },
    ]
}
