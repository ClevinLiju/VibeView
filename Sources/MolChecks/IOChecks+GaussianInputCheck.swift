import Foundation
import MolSIMD
import MolCore
import MolIO
import MolCompute

// Structural checks of Gaussian input files (GaussianInputCheck) and the G09W adaptations: the reasons a job "has no
// atoms" (missing title, missing blank line, Geom=Connectivity without a section), the 32-bit %mem limit, the
// explicit output name on the command line, and exported .gjf without %mem.

fileprivate func gicWater() -> Molecule {
    var m = Molecule(atoms: [Atom(id: 0, atomicNumber: 8, position: Vec3(0, 0, 0.1173)),
                             Atom(id: 1, atomicNumber: 1, position: Vec3(0, 0.7572, -0.4692)),
                             Atom(id: 2, atomicNumber: 1, position: Vec3(0, -0.7572, -0.4692))])
    m.bonds = [Bond(0, 1), Bond(0, 2)]
    m.title = "water"
    return m
}

fileprivate let gicG09W = GaussianInstallProfile.detect(executableName: "g09.exe", is32Bit: true, linkYear: 2009)

fileprivate func errors(_ t: String, _ p: GaussianInstallProfile? = nil) -> [InputIssue] {
    GaussianInputCheck.check(t, profile: p).filter { $0.severity == .error }
}

fileprivate let gicBase = "%chk=job.chk\n%mem=1000MB\n%nprocshared=2\n#P HF/STO-3G\n\nwater\n\n0 1\nO 0.0 0.0 0.1173\nH 0.0 0.7572 -0.4692\nH 0.0 -0.7572 -0.4692\n\n"

extension Checks {
    static let ioGaussianInputCheck: [Check] = [
        Check("io.gaussian.inputcheck.generated") {
            // Every task and option the setup dialog can produce gives an input without structural errors.
            var specs: [CalcSpec] = []
            for task in CalcTask.allCases {
                var s = CalcSpec(program: .gaussian, task: task, method: "B3LYP", basis: "6-31G(d)", molecule: gicWater())
                if task == .scan { s.scan = ScanCoordinate(atoms: [0, 1], start: 0.9, end: 1.1, steps: 3) }
                specs.append(s)
            }
            var s = CalcSpec(program: .gaussian, task: .optimize, method: "HF", basis: "STO-3G", molecule: gicWater())
            s.frozenAtoms = [0]; specs.append(s)
            s = CalcSpec(program: .gaussian, task: .energy, method: "HF", basis: "STO-3G", molecule: gicWater())
            s.extraKeywords = ["Geom=Connectivity"]; specs.append(s)
            s.extraKeywords = []; s.excitedStates = ExcitedStatesSpec(roots: 3); s.solvation = Solvation(model: .smd, solvent: "water"); specs.append(s)
            s = CalcSpec(program: .gaussian, task: .energy, method: "B3LYP", basis: "6-31G(d)", molecule: gicWater(), title: "")
            s.molecule.title = ""; specs.append(s)
            s.title = "Gaussian optimize – café"; s.extraInput = "@basis.gbs"; specs.append(s)
            for var sp in specs {
                sp.memoryMB = min(sp.memoryMB, gicG09W.maxMemoryMB!)   // what calc.preview / calc.run do for G09W
                let text = GaussianJob(spec: sp).inputText
                let e = errors(text, gicG09W)
                try expect(e.isEmpty, "\(sp.task) \(sp.extraKeywords): \(e.map(\.message))\n\(text)")
                try expect(text.hasSuffix("\n\n"), "\(sp.task): no blank line at the end")
                let jobs = try GaussianInputReader.parse(text)
                try expect(jobs.first?.molecule.atoms.count == 3, "\(sp.task): reread atoms")
            }
            // Geom=Connectivity: a valid 1-based section, one line per atom.
            var c = CalcSpec(program: .gaussian, task: .energy, method: "HF", basis: "STO-3G", molecule: gicWater())
            c.extraKeywords = ["Geom=Connectivity"]
            let ct = GaussianJob(spec: c).inputText
            try expect(ct.contains("\n\n1 2 1.0 3 1.0\n2\n3\n\n"), ct)
            try expect(GaussianInputCheck.check(ct).isEmpty, "\(GaussianInputCheck.check(ct))")
            // Without the keyword there is no connectivity section.
            let plain = GaussianJob(spec: CalcSpec(program: .gaussian, method: "HF", basis: "STO-3G", molecule: gicWater())).inputText
            try expect(!plain.contains("1 2 1.0"), plain)
        },
        Check("io.gaussian.inputcheck.fixtures") {
            // Real-world inputs (Z-matrix + variables, ONIOM, ModRedundant, connectivity, Link1, Gen/PCM) are accepted.
            for n in ["input_water_optfreq.gjf", "input_zmat_variables.gjf", "input_oniom.com", "input_modredundant.gjf",
                      "input_connectivity.gjf", "input_link1.gjf", "input_gen_pcm.gjf", "input_dexp.gjf"] {
                let t = try String(contentsOf: testDataURL("io/" + n), encoding: .utf8)
                // Several parser fixtures have charge/multiplicity combinations Gaussian would reject (ONIOM: 15 electrons
                // as a singlet, Link1: OH- doublet, Gen/PCM: cation doublet with 42 electrons); only structure is checked here.
                let e = errors(t).filter { !$0.message.contains("are impossible with") }
                try expect(e.isEmpty, "\(n): \(e.map { "\($0.line ?? 0): \($0.message)" })")
            }
            // ... but the electron count is checked: water as a doublet is impossible.
            try expect(errors(gicBase.replacingOccurrences(of: "\n0 1\n", with: "\n0 2\n")).contains { $0.message.contains("impossible with 10 electrons") })
        },
        Check("io.gaussian.inputcheck.noatoms") {
            try expect(GaussianInputCheck.check(gicBase).isEmpty, "\(GaussianInputCheck.check(gicBase))")
            // CRLF and a UTF-8 BOM are fine for G09W.
            try expect(errors(gicBase.replacingOccurrences(of: "\n", with: "\r\n")).isEmpty, "CRLF")
            try expect(errors("\u{FEFF}" + gicBase).isEmpty, "BOM")
            // The user's case: the title line deleted -> "0 1" becomes the title, Gaussian finds no atoms.
            let noTitle = gicBase.replacingOccurrences(of: "\n\nwater\n\n", with: "\n\n")
            var e = errors(noTitle)
            try expect(e.count == 1 && e[0].message.contains("title section is missing") && e[0].line == 6 && e[0].fixable, "\(e)")
            var r = GaussianInputCheck.repair(noTitle)
            try expect(r.fixes.count == 1 && errors(r.text).isEmpty && r.text.contains("Title Card Required\n\n0 1\n"), r.text)
            try expect(try GaussianInputReader.parse(r.text).first?.molecule.atoms.count == 3)
            // No blank line at the end ("End of file in ZSymb").
            for cut in ["\n", ""] {
                let t = String(gicBase.dropLast(2)) + cut
                e = errors(t)
                try expect(e.count == 1 && e[0].message.contains("blank line"), "cut '\(cut)': \(e)")
                r = GaussianInputCheck.repair(t)
                try expect(r.text == gicBase && r.fixes.count == 1, "repair: \(r.fixes) \(r.text.debugDescription)")
            }
            // Empty title (two blank lines) is accepted by G09W.
            try expect(errors(gicBase.replacingOccurrences(of: "\nwater\n", with: "\n")).isEmpty)
            // No atoms at all.
            e = errors("#P HF/STO-3G\n\nt\n\n0 1\n\n")
            try expect(e.contains { $0.message.contains("no atoms") }, "\(e)")
            // Charge/multiplicity problems.
            e = errors(gicBase.replacingOccurrences(of: "\n0 1\n", with: "\n0 2\n"))
            try expect(e.contains { $0.message.contains("impossible") }, "\(e)")
            e = errors(gicBase.replacingOccurrences(of: "\n0 1\n", with: "\nO 0.0 0.0 0.0\n"))
            try expect(!e.isEmpty, "charge line")
            e = errors(gicBase.replacingOccurrences(of: "O 0.0 0.0 0.1173", with: "Qq 0.0 0.0 0.1173"))
            try expect(e.contains { $0.message.contains("'Qq'") }, "\(e)")
            // Route not followed by a blank line.
            e = errors(gicBase.replacingOccurrences(of: "#P HF/STO-3G\n\n", with: "#P HF/STO-3G\n"))
            try expect(!e.isEmpty, "route without blank")
            try expect(!errors("").isEmpty && !errors("water\n\n0 1\n").isEmpty, "empty / no route")
        },
        Check("io.gaussian.inputcheck.connectivity") {
            let kw = gicBase.replacingOccurrences(of: "#P HF/STO-3G", with: "#P HF/STO-3G Geom=Connectivity")
            // Keyword without a section: "End of file reading connectivity".
            var e = errors(kw)
            try expect(e.count == 1 && e[0].message.contains("connectivity section is missing"), "\(e)")
            // Valid section.
            try expect(errors(kw + "1 2 1.0 3 1.0\n2\n3\n\n").isEmpty)
            // Out of range / malformed.
            e = errors(kw + "1 2 1.0 4 1.0\n2\n3\n\n")
            try expect(e.contains { $0.message.contains("'4'") }, "\(e)")
            e = errors(kw + "1 2\n2\n3\n\n")
            try expect(e.contains { $0.message.contains("pairs") }, "\(e)")
            // Section without the keyword: ignored by Gaussian (warning), but read as ModRedundant input with Opt=ModRedundant.
            let w = GaussianInputCheck.check(gicBase + "1 2 1.0 3 1.0\n2\n3\n\n")
            try expect(w.count == 1 && w[0].severity == .warning && w[0].message.contains("no Geom=Connectivity"), "\(w)")
            let mr = gicBase.replacingOccurrences(of: "#P HF/STO-3G", with: "#P HF/STO-3G Opt(ModRedundant)") + "1 2 1.0 3 1.0\n2\n3\n\n"
            try expect(errors(mr).count == 1, "\(errors(mr))")
            // Opt=ModRedundant with nothing after the molecule runs in G09W.
            try expect(errors(gicBase.replacingOccurrences(of: "#P HF/STO-3G", with: "#P HF/STO-3G Opt(ModRedundant)")).isEmpty)
        },
        Check("io.gaussian.inputcheck.g09w") {
            // 32-bit G09W: %mem of 1700 MB or more stops it right after Link 1.
            try expect(gicG09W.maxMemoryMB == 1500 && !gicG09W.hasDef2AndGD3 && gicG09W.name == "Gaussian 09 (32-bit)", "\(gicG09W)")
            let g16 = GaussianInstallProfile.detect(executableName: "g16", is32Bit: false, linkYear: 2019)
            try expect(g16.maxMemoryMB == nil && g16.hasDef2AndGD3)
            try expect(GaussianInstallProfile.detect(executableName: "g09.exe", is32Bit: false, linkYear: 2016).hasDef2AndGD3, "G09 E.01")
            let big = gicBase.replacingOccurrences(of: "%mem=1000MB", with: "%mem=4GB")
            try expect(errors(big).isEmpty, "no limit without a profile")
            let e = errors(big, gicG09W)
            try expect(e.count == 1 && e[0].line == 2 && e[0].fixable, "\(e)")
            let r = GaussianInputCheck.repair(big, profile: gicG09W)
            try expect(r.text == gicBase.replacingOccurrences(of: "%mem=1000MB", with: "%mem=1500MB"), r.text)
            let w = GaussianInputCheck.check(gicBase.replacingOccurrences(of: "HF/STO-3G", with: "B3LYP/def2-SVP EmpiricalDispersion=GD3BJ"), profile: gicG09W)
            try expect(w.count == 2 && w.allSatisfy { $0.severity == .error }, "\(w)")   // G09 A.02: QPErr in Link 1
            try expect(GaussianInputCheck.check(gicBase.replacingOccurrences(of: "HF/STO-3G", with: "B3LYP/def2-SVP EmpiricalDispersion=GD3BJ")).isEmpty)
            // The default setup (B3LYP/def2-SVP, GD3BJ, 4000 MB) adapted to G09W A.02: SVP, no dispersion, 1500 MB.
            var d = CalcSpec(program: .gaussian, task: .optimizeAndFrequencies, method: "B3LYP", basis: "def2-SVP", molecule: gicWater())
            d.dispersion = .d3bj; d.memoryMB = 4000
            let notes = gicG09W.adapt(&d)
            try expect(notes.count == 3 && d.basis == "SVP" && d.dispersion == nil && d.memoryMB == 1500, "\(notes) \(d.basis)")
            try expect(errors(GaussianJob(spec: d).inputText, gicG09W).isEmpty, GaussianJob(spec: d).inputText)
            var t = d; t.basis = "def2-TZVPP"
            try expect(gicG09W.adapt(&t).first?.contains("syntax error") == true && t.basis == "def2-TZVPP")
            var n = CalcSpec(program: .gaussian, method: "B3LYP", basis: "def2-SVP", molecule: gicWater()); n.dispersion = .d3bj
            try expect(g16.adapt(&n).isEmpty && n.basis == "def2-SVP" && n.dispersion == .d3bj, "G16 keeps the spec")
            for (v, mb) in [("4000MB", 4000.0), ("4GB", 4096.0), ("500MW", 4000.0), ("262144000", 2000.0), ("1gb", 1024.0)] {
                try expectClose(GaussianInputCheck.memoryMB(v) ?? -1, mb, tol: 1e-6)
            }
            try expect(GaussianInputCheck.memoryMB("lots") == nil)
        },
        Check("io.gaussian.inputcheck.plan") {
            // The output file is named on the command line (G09W can't open an unquoted output path with spaces).
            let plan = try CalcJobPlanner.plan(CalcSpec(program: .gaussian, method: "HF", basis: "STO-3G", molecule: gicWater()), baseName: "job")
            try expect(plan.arguments == ["job.gjf", "job.log"], "\(plan.arguments)")
            try expect(CalcJobResults.outputFileCandidates(plan).first == "job.log")
            // Exported .gjf: no %mem / %nprocshared, valid structure.
            let ex = try MolecularFileLoader.write(gicWater(), format: .gaussianInput)
            try expect(!ex.contains("%mem") && !ex.contains("%nproc"), ex)
            try expect(GaussianInputCheck.check(ex, profile: gicG09W).isEmpty, "\(GaussianInputCheck.check(ex, profile: gicG09W))")
        },
        Check("io.gaussian.inputcheck.failure") {
            let qp = """
             #P HF/STO-3G EmpiricalDispersion=GD3BJ
             QPErr --- A syntax error was detected in the input line.
             q EmpiricalDispersion=GD3BJ
                                  '
             Last state="GCL"
             Error termination via Lnk1e in C:\\G09W\\l1.exe at Thu Nov 26 09:47:09 2026.
            """
            try expect(GaussianInputCheck.failureReason(output: qp)?.contains("'EmpiricalDispersion=GD3BJ'") == true,
                       GaussianInputCheck.failureReason(output: qp) ?? "nil")
            let zs = " Symbolic Z-matrix:\n Charge =  0 Multiplicity = 1\n End of file in ZSymb.\n Error termination via Lnk1e in C:\\G09W\\l101.exe at Thu Nov 26 2026.\n"
            try expect(GaussianInputCheck.failureReason(output: zs) == "Charge =  0 Multiplicity = 1 End of file in ZSymb. (l101.exe)",
                       GaussianInputCheck.failureReason(output: zs) ?? "nil")
            let head = " Entering Gaussian System, Link 0=C:\\G09W\\g09.exe\n Input=job.gjf\n Output=job.out\n Initial command:\n C:\\G09W\\l1.exe .\\gxx.inp job.out /scrdir=.\\\n"
            try expect(GaussianInputCheck.failureReason(output: head)?.contains("before Link 1") == true)
            let l1 = " Gaussian 09:  IA32W-G09RevA.02 11-Jun-2009\n %mem=2000MB\n 99/5=1,9=1/99;\n Leave Link    1 at Thu Nov 26 09:44:56 2026, MaxMem=  262144000 cpu:       0.0\n"
            try expect(GaussianInputCheck.failureReason(output: l1)?.contains("%mem") == true)
            try expect(GaussianInputCheck.failureReason(output: " Normal termination of Gaussian 09 at Thu Nov 26.\n") == nil)
        },
        Check("compute.executableinfo") {
            func pe(machine: UInt16, stamp: UInt32) -> Data {
                var b = [UInt8](repeating: 0, count: 256)
                b[0] = 0x4D; b[1] = 0x5A; b[0x3C] = 0x80
                b[0x80] = 0x50; b[0x81] = 0x45
                b[0x84] = UInt8(machine & 0xFF); b[0x85] = UInt8(machine >> 8)
                for k in 0..<4 { b[0x88 + k] = UInt8((stamp >> (8 * UInt32(k))) & 0xFF) }
                return Data(b)
            }
            let x86 = ExecutableInfo.parse(pe(machine: 0x14C, stamp: 1_244_800_000))   // June 2009
            try expect(x86?.is32Bit == true && x86?.linkYear == 2009, "\(String(describing: x86))")
            let x64 = ExecutableInfo.parse(pe(machine: 0x8664, stamp: 0))
            try expect(x64?.architecture == .x64 && x64?.linkDate == nil)
            try expect(ExecutableInfo.parse(Data("#!/bin/sh\necho hi\n".utf8)) == nil)
            #if os(Windows)
            if FileManager.default.fileExists(atPath: "C:\\G09W\\g09.exe") {
                let g = ExecutableInfo.read(URL(fileURLWithPath: "C:\\G09W\\g09.exe"))
                print("    C:\\G09W\\g09.exe: \(String(describing: g))")
                try expect(g?.is32Bit == true)
            }
            #endif
        },
    ]
}
