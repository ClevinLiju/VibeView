import Foundation
import MolCore
import MolIO

// Lead A, round 3: companion-file autoload on real ORCA fixtures.

private func tempDir(_ tag: String) throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("vv-comp-\(tag)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

extension Checks {
    static let ioCompanions: [Check] = [
        Check("io.companions.baseName") {
            try expect(CompanionFiles.baseName(of: "job.out") == "job")
            try expect(CompanionFiles.baseName(of: "job.molden.input") == "job")
            try expect(CompanionFiles.baseName(of: "job_trj.xyz") == "job")
            try expect(CompanionFiles.baseName(of: "my.job.hess") == "my.job")
            try expect(CompanionFiles.baseName(of: "a.b.c.fchk") == "a.b.c")
            try expect(CompanionFiles.baseName(of: "noext") == "noext")
            try expect(CompanionFiles.baseName(of: "x.weird") == "x")
        },
        Check("io.companions.waterOptFreq") {
            let u = testDataURL("io/orca/water_optfreq.out")
            let plain = try MolecularFileLoader.load(url: u)
            let (f, comps) = try MolecularFileLoader.loadWithCompanions(url: u)
            let used = Set(comps.filter(\.used).map(\.fileName))
            try expect(used.contains("water_optfreq.molden.input"), "molden used: \(comps.map { "\($0.fileName) \($0.used) \($0.note)" })")
            try expect(f.wavefunction != nil && plain.wavefunction == nil, "wavefunction from molden")
            try expect(f.companions == comps)
            // primary wins: the log already has modes, so the .hess is not used and modes equal the log's
            try expect(!(plain.result?.normalModes.isEmpty ?? true))
            try expect(f.result?.normalModes == plain.result?.normalModes, "modes from primary")
            try expect(comps.contains { $0.fileName == "water_optfreq.hess" && !$0.used })
            // frames: the log has its optimization steps; trajectory only fills when missing
            try expect(f.molecules.count == plain.molecules.count)
            try expect(!comps.contains { $0.fileName.hasSuffix(".inp") }, "input is not a companion")
            try expect(comps.contains { $0.fileName == "water_optfreq.engrad" }, "engrad considered")
            // unrelated stems are not picked up
            try expect(!comps.contains { $0.fileName.hasPrefix("water_scan") || $0.fileName.hasPrefix("h2co") })
        },
        Check("io.companions.h2coHess") {
            // copy only the .out + .hess, strip the frequency block from the log so the .hess fills the gap
            let d = try tempDir("h2co"); defer { try? FileManager.default.removeItem(at: d) }
            let src = testDataURL("io/orca")
            try FileManager.default.copyItem(at: src.appendingPathComponent("h2co_optfreq.hess"), to: d.appendingPathComponent("h2co_optfreq.hess"))
            let full = try String(contentsOf: src.appendingPathComponent("h2co_optfreq.out"), encoding: .utf8)
            let cut = full.components(separatedBy: "VIBRATIONAL FREQUENCIES").first ?? full
            try cut.write(to: d.appendingPathComponent("h2co_optfreq.out"), atomically: true, encoding: .utf8)
            let plain = try MolecularFileLoader.load(url: d.appendingPathComponent("h2co_optfreq.out"))
            try expect(plain.result?.normalModes.isEmpty ?? true, "cut log has no modes")
            let (f, comps) = try MolecularFileLoader.loadWithCompanions(url: d.appendingPathComponent("h2co_optfreq.out"))
            try expect(comps.count == 1 && comps[0].used && comps[0].role == .hessian, "\(comps)")
            try expect(f.result?.normalModes.count == 6, "H2CO: 6 modes from .hess, got \(f.result?.normalModes.count ?? -1)")
            try expect(f.result?.normalModes.allSatisfy { $0.displacements.count == 4 } ?? false)
        },
        Check("io.companions.trajectoryGradientFill") {
            // the .hess as primary: geometry only; companions fill wavefunction, trajectory, gradient, log data
            let d = try tempDir("water"); defer { try? FileManager.default.removeItem(at: d) }
            let src = testDataURL("io/orca")
            for n in ["water_optfreq.hess", "water_optfreq_trj.xyz", "water_optfreq.engrad", "water_optfreq.molden.input", "water_optfreq.out"] {
                try FileManager.default.copyItem(at: src.appendingPathComponent(n), to: d.appendingPathComponent(n))
            }
            let (f, comps) = try MolecularFileLoader.loadWithCompanions(url: d.appendingPathComponent("water_optfreq.hess"))
            let used = Set(comps.filter(\.used).map(\.fileName))
            try expect(used.isSuperset(of: ["water_optfreq_trj.xyz", "water_optfreq.engrad", "water_optfreq.molden.input", "water_optfreq.out"]),
                       "used: \(comps.map { "\($0.fileName) \($0.used) \($0.note)" })")
            try expect(f.molecules.count > 1, "frames from _trj.xyz")
            try expect(f.result?.extras?.gradients.first?.count == 3, "gradient from .engrad")
            try expect(f.wavefunction != nil)
            try expect(!(f.result?.orbitals.isEmpty ?? true), "orbital energies")
            try expect(f.result?.extras?.info != nil, "setup info from the log")
            try expect(!(f.result?.normalModes.isEmpty ?? true), "modes from primary .hess")
            if let e = f.result?.energies, e.count == f.molecules.count { try expect(e.allSatisfy { $0 < -70 }, "trj energies") }
        },
        Check("io.companions.binaryAndCube") {
            let d = try tempDir("bin"); defer { try? FileManager.default.removeItem(at: d) }
            let src = testDataURL("io")
            let log = try String(contentsOf: src.appendingPathComponent("gaussian/water_optfreq_td.log"), encoding: .utf8)
            try log.write(to: d.appendingPathComponent("job.log"), atomically: true, encoding: .utf8)
            try Data([0, 1, 2, 3]).write(to: d.appendingPathComponent("job.chk"))
            try FileManager.default.copyItem(at: src.appendingPathComponent("cube_water_homo.cube"), to: d.appendingPathComponent("job_homo.cube"))
            try "junk".write(to: d.appendingPathComponent("jobless.cube"), atomically: true, encoding: .utf8)
            let (f, comps) = try MolecularFileLoader.loadWithCompanions(url: d.appendingPathComponent("job.log"))
            let chk = comps.first { $0.fileName == "job.chk" }
            try expect(chk != nil && chk!.used == false && chk!.role == .binary && chk!.note.contains("formchk"), "\(comps)")
            try expect(!comps.contains { $0.fileName == "jobless.cube" }, "different stem ignored")
            if let cube = comps.first(where: { $0.fileName == "job_homo.cube" }) {
                // water cube vs water log: atom counts agree, so it is merged
                try expect(cube.used == (cube.note.contains("grid")), cube.note)
                if cube.used { try expect(!f.volumes.isEmpty) }
            } else { try expect(false, "cube considered") }
        },
        Check("io.companions.collectUsesMerge") {
            let d = try tempDir("plan"); defer { try? FileManager.default.removeItem(at: d) }
            let src = testDataURL("io/orca")
            for (from, to) in [("water_optfreq.out", "job.out"), ("water_optfreq.molden.input", "job.molden.input"), ("water_optfreq_trj.xyz", "job_trj.xyz")] {
                try FileManager.default.copyItem(at: src.appendingPathComponent(from), to: d.appendingPathComponent(to))
            }
            let m = try Molecule(smiles: "O")
            let plan = try CalcJobPlanner.plan(CalcSpec(program: .orca, method: "B3LYP", basis: "def2-SVP", molecule: m), baseName: "job")
            let r = try CalcJobResults.collect(plan, directory: d)
            try expect(r.wavefunction != nil)
            try expect(r.companions.contains { $0.fileName == "job.molden.input" && $0.used })
        },
    ]
}
