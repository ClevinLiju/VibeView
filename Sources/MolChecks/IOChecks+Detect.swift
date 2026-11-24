import Foundation
import MolCore
import MolIO
import simd

// Content sniffing for program outputs with generic extensions (.out/.log/.txt/none), and the
// one-call loader on top of it (Lead A, round 2).

fileprivate func detText(_ name: String) throws -> String { try String(contentsOf: testDataURL("io/" + name), encoding: .utf8) }

extension Checks {
    static let ioDetect: [Check] = [
        Check("io.detect.program_outputs_by_content") {
            let cases: [(String, MoleculeFileFormat)] = [
                ("orca/water_optfreq.out", .orcaOutput), ("orca/h2co_tddft.out", .orcaOutput), ("orca/oh_uhf.out", .orcaOutput),
                ("orca/water_optfreq.hess", .orcaHessian), ("orca/water_optfreq.inp", .orcaInput),
                ("orca/water_optfreq.molden.input", .molden),
                ("qchem/water_optfreq.out", .qchemOutput), ("qchem/h2co_tddft.out", .qchemOutput), ("qchem/water_optfreq.in", .qchemInput),
                ("xtb/xtb_water.out", .xtbOutput), ("gaussian/water_optfreq_td.log", .gaussianOutput),
            ]
            for (name, f) in cases {
                let t = try detText(name)
                try expect(MoleculeFileFormat.detect(contents: t) == f, "\(name): \(String(describing: MoleculeFileFormat.detect(contents: t)))")
                // a generic extension must not override the content
                for ext in ["out", "log", "txt", ""] {
                    try expect(MoleculeFileFormat.detect(contents: t, fileName: ext.isEmpty ? "job" : "job." + ext) == f, "\(name) as .\(ext)")
                }
            }
        },
        Check("io.detect.by_url_with_generic_extension") {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("molscope-det-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let cases: [(String, String, MoleculeFileFormat, QCProgram)] = [
                ("orca/water_optfreq.out", "a.log", .orcaOutput, .orca),
                ("qchem/water_optfreq.out", "b.out", .qchemOutput, .qchem),
                ("xtb/xtb_water.out", "c.txt", .xtbOutput, .xtb),
                ("gaussian/water_optfreq_td.log", "d.out", .gaussianOutput, .gaussian),
                ("orca/water_optfreq.out", "noext", .orcaOutput, .orca),
            ]
            for (src, name, f, prog) in cases {
                let u = dir.appendingPathComponent(name)
                try detText(src).write(to: u, atomically: true, encoding: .utf8)
                try expect(MoleculeFileFormat.detect(url: u) == f, "\(src) as \(name): \(String(describing: MoleculeFileFormat.detect(url: u)))")
                let l = try MolecularFileLoader.load(url: u)
                try expect(l.format == f && l.program == prog, "\(name) loader \(l.format) \(String(describing: l.program))")
                if f != .xtbOutput { try expect(!l.molecule.atoms.isEmpty && l.result != nil, "\(name) has geometry + result") }
            }
        },
        Check("io.detect.loader_program_outputs") {
            let o = try MolecularFileLoader.load(text: try detText("orca/water_optfreq.out"))
            try expect(o.format == .orcaOutput && o.molecules.count > 1 && o.result?.normalModes.count == 3, "orca")
            let q = try MolecularFileLoader.load(text: try detText("qchem/water_optfreq.out"))
            try expect(q.format == .qchemOutput && q.result?.extras?.finalEnergy != nil, "qchem")
            let m = try MolecularFileLoader.load(text: try detText("orca/h2co_tddft.molden.input"))
            try expect(m.format == .molden && m.wavefunction != nil && m.molecule.atoms.count == 4, "molden wavefunction")
            let x = try MolecularFileLoader.load(text: try detText("xtb/xtb_water.out"))
            try expect(x.format == .xtbOutput && x.result?.extras?.finalEnergy != nil, "xtb")
        },
        Check("io.detect.prose_mentioning_programs_is_not_output") {
            try expect(MoleculeFileFormat.detect(contents: "notes: compare ORCA and Q-Chem and xtb results\n") == nil, "prose")
        },
        Check("io.job.plan_per_program") {
            let w = Molecule(atoms: [Atom(id: 0, atomicNumber: 8, position: Vec3(0, 0, 0.1173)),
                                     Atom(id: 1, atomicNumber: 1, position: Vec3(0, 0.7572, -0.4692)),
                                     Atom(id: 2, atomicNumber: 1, position: Vec3(0, -0.7572, -0.4692))])
            var s = CalcSpec(program: .orca, task: .optimizeAndFrequencies, method: "B3LYP", basis: "def2-SVP", molecule: w)
            s.nprocs = 4
            var p = try CalcJobPlanner.plan(s, baseName: "water")
            try expect(p.inputFileName == "water.inp" && p.arguments == ["water.inp"] && p.captureStdout && p.outputFileName == "water.out", "orca plan")
            try expect(p.inputText.contains("%pal nprocs 4 end") && p.companionFileNames.contains("water.hess"), "orca resources")
            s.checkpointName = "keep"
            p = try CalcJobPlanner.plan(s, baseName: "water")
            try expect(p.baseName == "keep" && p.companionFileNames.contains("keep.hess") && p.inputText.contains("%base \"keep\""), "orca %base")
            s.checkpointName = nil
            s.program = .qchem
            p = try CalcJobPlanner.plan(s, baseName: "water")
            try expect(p.arguments == ["-nt", "4", "water.in", "water.out"] && !p.captureStdout && p.inputText.contains("$rem"), "qchem plan \(p.arguments)")
            s.program = .gaussian
            p = try CalcJobPlanner.plan(s, baseName: "water")
            try expect(p.inputFileName == "water.gjf" && p.outputFileName == "water.log" && p.inputText.contains("%chk=water.chk"), "gaussian plan")
            s.program = .xtb; s.method = "GFN2-xTB"; s.basis = ""; s.frozenAtoms = [0]
            p = try CalcJobPlanner.plan(s, baseName: "water")
            try expect(p.arguments.first == "water.xyz" && p.arguments.contains("--ohess") && p.arguments.contains("xcontrol.inp"), "xtb args \(p.arguments)")
            try expect(p.files.map(\.name) == ["water.xyz", "xcontrol.inp"] && p.environment["OMP_NUM_THREADS"] == "4,1", "xtb files/env")
            // invalid specs and unsafe names are refused
            s.excitedStates = ExcitedStatesSpec(roots: 3)
            try expect((try? CalcJobPlanner.plan(s)) == nil, "xtb has no excited states")
            s.excitedStates = nil
            for bad in ["", "../x", "a b", ".hidden", "x/y"] { try expect((try? CalcJobPlanner.plan(s, baseName: bad)) == nil, "base name '\(bad)'") }
        },
        Check("io.job.collect_orca_and_xtb") {
            let fm = FileManager.default
            let dir = fm.temporaryDirectory.appendingPathComponent("molscope-job-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: dir) }
            let w = try MolecularFileLoader.load(text: try detText("orca/water_optfreq.out")).molecule
            // ORCA: log + hess + molden
            let s = CalcSpec(program: .orca, task: .optimizeAndFrequencies, method: "HF", basis: "STO-3G", molecule: w)
            let p = try CalcJobPlanner.plan(s, baseName: "w")
            let od = dir.appendingPathComponent("orca")
            try p.write(to: od)
            try expect(fm.fileExists(atPath: od.appendingPathComponent("w.inp").path), "input written")
            try expect((try? CalcJobResults.collect(p, directory: od)) == nil, "missing log throws")
            try detText("orca/water_optfreq.out").write(to: od.appendingPathComponent("w.out"), atomically: true, encoding: .utf8)
            try detText("orca/water_optfreq.molden.input").write(to: od.appendingPathComponent("w.molden.input"), atomically: true, encoding: .utf8)
            let o = try CalcJobResults.collect(p, directory: od)
            try expect(o.program == .orca && o.result?.normalModes.count == 3 && o.wavefunction != nil && o.molecules.count > 1, "orca collect")
            // xtb: stdout + xtbopt.xyz/log + g98.out
            var xs = CalcSpec(program: .xtb, task: .optimizeAndFrequencies, method: "GFN2-xTB", molecule: w)
            xs.nprocs = 1
            let xp = try CalcJobPlanner.plan(xs, baseName: "w")
            let xd = dir.appendingPathComponent("xtb")
            try xp.write(to: xd)
            for (src, dst) in [("xtb/xtb_water.out", "w.out"), ("xtb/xtbopt.xyz", "xtbopt.xyz"), ("xtb/xtbopt.log", "xtbopt.log"), ("xtb/g98.out", "g98.out")] {
                try detText(src).write(to: xd.appendingPathComponent(dst), atomically: true, encoding: .utf8)
            }
            let x = try CalcJobResults.collect(xp, directory: xd)
            let r = x.result
            try expect(x.program == .xtb && r?.normalModes.count == 3 && (r?.steps.count ?? 0) >= 1, "xtb collect")
            try expect(r?.steps.count == r?.energies.count && x.molecule.atoms.count == 3, "xtb frames/energies")
            let opt = try XYZFormat.parse(try detText("xtb/xtbopt.xyz")).last!
            try expectClose(simd_distance(x.molecule.atoms[1].position, opt.atoms[1].position), 0, tol: 1e-9)
        },
    ]
}
