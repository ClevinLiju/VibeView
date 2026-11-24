import simd
import Foundation
import MolCore
@testable import MolIO

// xtb checks (worker W1). xtb is not installed here: the fixtures in TestData/io/xtb/ are hand-written
// from the public xtb documentation (stdout summary, xtbopt.xyz/xtbopt.log, Turbomole-style `gradient`,
// `charges`, and the Gaussian-98-style g98.out), so these checks verify format handling, not xtb numerics.

fileprivate func xtbText(_ name: String) throws -> String { try readText(testDataURL("io/xtb/" + name)) }
fileprivate func xtbCRLF(_ s: String) -> String { s.replacingOccurrences(of: "\n", with: "\r\n") }
fileprivate func xtbMustThrow(_ label: String, _ body: () throws -> Void) throws {
    do { try body() } catch is MolIOError { return } catch {
        throw CheckFailure(description: "wrong error type for \(label): \(error)")
    }
    throw CheckFailure(description: "expected MolIOError: \(label)")
}
fileprivate func xtbWater() -> Molecule {
    Molecule(atoms: [Atom(id: 0, atomicNumber: 8, position: Vec3(0, 0, 0.0626)),
                     Atom(id: 1, atomicNumber: 1, position: Vec3(0, 0.7658, -0.5013)),
                     Atom(id: 2, atomicNumber: 1, position: Vec3(0, -0.7658, -0.5013))])
}
fileprivate func xtbSweep(_ name: String, _ parse: (String) throws -> Void) throws -> (threw: Int, parsed: Int) {
    let t = try xtbText(name)
    let lines = t.split(separator: "\n", omittingEmptySubsequences: false)
    var threw = 0, parsed = 0
    for k in 1..<max(1, lines.count - 1) {   // prefix(count - 1) would be the whole file
        do { try parse(lines.prefix(k).joined(separator: "\n") + "\n"); parsed += 1 } catch is MolIOError { threw += 1 }
    }
    for f in stride(from: 0.017, to: 1.0, by: 0.023) {
        do { try parse(String(t.prefix(Int(Double(t.count) * f)))); parsed += 1 } catch is MolIOError { threw += 1 }
    }
    return (threw, parsed)
}

extension Checks {
    static let ioXTB: [Check] = [
        Check("io.xtb.stdout.summary") {
            let o = try XTBOutput.parse(try xtbText("xtb_water.out"))
            try expect(o.programVersion == "6.7.1", "version")
            try expectClose(o.totalEnergy ?? 0, -5.070544440612, tol: 1e-12)
            try expectClose(o.gradientNorm ?? 0, 0.000123456789, tol: 1e-15)
            try expectClose(o.homoLumoGapEV ?? 0, 14.612345678901, tol: 1e-12)
            try expect(o.normalTermination && o.optimizationConverged == true, "termination / converged")
            try expect(o.charges.count == 3 && o.elements == [8, 1, 1], "charge table")
            try expectClose(o.charges[0], -0.58427, tol: 1e-9)
            try expectClose(o.charges.reduce(0, +), 0, tol: 1e-4)
            try expectClose(simd_length(o.dipoleDebye ?? .zero), 0.909, tol: 5e-3)
        },
        Check("io.xtb.stdout.thermo_and_result") {
            let o = try XTBOutput.parse(try xtbText("xtb_water.out"))
            let t = o.thermochemistry
            try expectClose(t?.zeroPointEnergy ?? 0, 0.02146, tol: 1e-12)
            try expectClose(t?.totalGibbs ?? 0, -5.069564440612, tol: 1e-12)
            try expectClose(t?.totalEnthalpy ?? 0, -5.0453, tol: 1e-12)
            try expectClose(t?.electronicEnergy ?? 0, -5.070544440612, tol: 1e-12)
            let geo = try XTBTrajectory.parse(try xtbText("xtbopt.xyz")).molecules[0]
            let r = o.result(geometry: geo)
            try expect(r.extras?.program == "xtb" && r.steps.count == 1 && r.energies == [-5.070544440612], "result \(r.energies)")
            try expectClose(r.extras?.homoLumoGapEV ?? 0, 14.612345678901, tol: 1e-12)
            try expect(r.extras?.charges["xtb"]?.count == 3 && r.normalTermination, "charges in extras")
        },
        Check("io.xtb.xyz_and_trajectory") {
            let one = try XTBTrajectory.parse(try xtbText("xtbopt.xyz"))
            try expect(one.molecules.count == 1 && one.molecules[0].atoms.count == 3, "xtbopt.xyz")
            try expectClose(one.energies[0], -5.070544440612, tol: 1e-12)
            try expectClose(one.gradientNorms[0] ?? 0, 0.000123456789, tol: 1e-15)
            let log = try XTBTrajectory.parse(try xtbText("xtbopt.log"))
            try expect(log.molecules.count == 3 && log.energies.count == 3, "3 frames")
            try expect(log.energies[0] > log.energies[1] && log.energies[1] > log.energies[2], "energy decreases along optimization")
            try expectClose(log.energies[2], one.energies[0], tol: 1e-12)
            try expect(log.molecules[2].atoms.map(\.position) == one.molecules[0].atoms.map(\.position), "last frame == xtbopt.xyz")
            try expect(log.result.steps.count == 3 && log.result.energies.count == 3, "result")
        },
        Check("io.xtb.gradient_file_d_exponents") {
            let g = try XTBGradientFile.parse(try xtbText("gradient"))
            try expect(g.cycles.count == 1, "one cycle")
            let c = g.cycles[0]
            try expectClose(c.energy, -5.07054444061, tol: 1e-12)
            try expectClose(c.gradientNorm, 0.000123, tol: 1e-12)
            try expect(c.molecule.atoms.map(\.atomicNumber) == [8, 1, 1], "elements from lowercase symbols")
            try expectClose(c.molecule.atoms[0].position.z, 0.1183 * bohrToAngstrom, tol: 1e-12)
            try expectClose(c.gradient[0].z, -5.1234567890123e-05, tol: 1e-18)
            try expectClose(c.gradient[0].x, -1.2345678901234e-19, tol: 1e-30)
            try expectClose(c.gradient[0].y, 1.0e-18, tol: 1e-30)
            try expectClose(c.gradient.reduce(Vec3.zero, +).z, 0, tol: 1e-9)
        },
        Check("io.xtb.charges_file") {
            let q = try XTBChargesFile.parse(try xtbText("charges"))
            try expect(q.count == 3, "count")
            try expectClose(q[0], -0.58427, tol: 1e-12)
            try expectClose(q.reduce(0, +), 0, tol: 1e-9)
            try xtbMustThrow("charges garbage") { _ = try XTBChargesFile.parse("0.1\nabc\n") }
            try xtbMustThrow("charges empty") { _ = try XTBChargesFile.parse("\n\n") }
        },
        Check("io.xtb.g98_frequencies") {
            let m = try XTBG98Frequencies.parse(try xtbText("g98.out"))
            try expect(m.count == 3, "3 modes")
            try expectClose(m[0].frequency, 1630.5, tol: 1e-9)
            try expectClose(m[2].frequency, 3745.7, tol: 1e-9)
            try expectClose(m[1].irIntensity, 5.4321, tol: 1e-9)
            try expectClose(m[0].reducedMass ?? 0, 1.0822, tol: 1e-9)
            try expectClose(m[2].forceConstant ?? 0, 8.9477, tol: 1e-9)
            try expect(m.allSatisfy { $0.displacements.count == 3 }, "3 atoms")
            try expectClose(m[0].displacements[0].z, 0.07, tol: 1e-12)
            try expectClose(m[1].displacements[1].y, 0.58, tol: 1e-12)
            try expectClose(m[2].displacements[2].y, -0.55, tol: 1e-12)
            try expectClose(m[0].displacements.reduce(Vec3.zero, +).y, 0, tol: 1e-9)
            _ = try XTBG98Frequencies.parse(try xtbText("g98.out"), atomCount: 3)
            try xtbMustThrow("atom count mismatch") { _ = try XTBG98Frequencies.parse(try xtbText("g98.out"), atomCount: 4) }
        },
        Check("io.xtb.g98_two_blocks") {
            // Two blocks of 3 modes (6 modes) built from the fixture's block.
            let t = try xtbText("g98.out")
            let lines = t.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let a = lines.firstIndex(where: { $0.contains("Frequencies --") }) else { throw CheckFailure(description: "layout") }
            let block = Array(lines[(a - 2)...(a + 7)])
            let doubled = (lines[..<(a - 2)] + block + block + lines[(a + 8)...]).joined(separator: "\n")
            let m = try XTBG98Frequencies.parse(doubled)
            try expect(m.count == 6, "6 modes, got \(m.count)")
            try expectClose(m[3].frequency, 1630.5, tol: 1e-9)
        },
        Check("io.xtb.crlf_equals_lf") {
            let o = try xtbText("xtb_water.out")
            try expect(try XTBOutput.parse(xtbCRLF(o)) == XTBOutput.parse(o), "stdout")
            let g = try xtbText("gradient")
            try expect(try XTBGradientFile.parse(xtbCRLF(g)) == XTBGradientFile.parse(g), "gradient")
            let l = try xtbText("xtbopt.log")
            try expect(try XTBTrajectory.parse(xtbCRLF(l)) == XTBTrajectory.parse(l), "log")
            let f = try xtbText("g98.out")
            try expect(try XTBG98Frequencies.parse(xtbCRLF(f)) == XTBG98Frequencies.parse(f), "g98")
            let c = try xtbText("charges")
            try expect(try XTBChargesFile.parse(xtbCRLF(c)) == XTBChargesFile.parse(c), "charges")
        },
        Check("io.xtb.truncation_sweeps") {
            // stdout: cut inside the charge table throws; a log cut between blocks parses with normalTermination false
            let r1 = try xtbSweep("xtb_water.out") { s in
                let o = try XTBOutput.parse(s)
                if !s.contains("normal termination of xtb\n") { try expect(!o.normalTermination, "cut stdout cannot be terminated") }
                try expect(o.charges.isEmpty || o.charges.count == 3, "charge table complete or absent")
            }
            try expect(r1.parsed > 0, "stdout partial logs parse")
            let t = try xtbText("xtb_water.out")
            let lines = t.split(separator: "\n", omittingEmptySubsequences: false)
            guard let q = lines.firstIndex(where: { $0.contains("covCN") }) else { throw CheckFailure(description: "layout") }
            try xtbMustThrow("cut inside charge table") { _ = try XTBOutput.parse(lines.prefix(q + 3).joined(separator: "\n") + "\n") }
            // gradient: every cut throws (missing $end)
            let r2 = try xtbSweep("gradient") { s in _ = try XTBGradientFile.parse(s) }
            try expect(r2.parsed == 0 && r2.threw > 0, "gradient cuts must all throw (parsed \(r2.parsed))")
            // trajectory: parsed cuts hold whole frames only
            let r3 = try xtbSweep("xtbopt.log") { s in
                let tr = try XTBTrajectory.parse(s)
                try expect(tr.molecules.allSatisfy { $0.atoms.count == 3 }, "whole frames only")
            }
            try expect(r3.threw > 0 && r3.parsed > 0, "trajectory outcomes")
            // g98: a cut inside a displacement block throws, never partial modes
            let r4 = try xtbSweep("g98.out") { s in
                let m = try XTBG98Frequencies.parse(s)
                try expect(m.count == 3 && m.allSatisfy { $0.displacements.count == 3 }, "complete modes only")
            }
            try expect(r4.threw > 0, "g98 cuts throw")
        },
        Check("io.xtb.malformed_inputs_throw") {
            try xtbMustThrow("empty stdout") { _ = try XTBOutput.parse("") }
            try xtbMustThrow("garbage stdout") { _ = try XTBOutput.parse("random text\nwithout meaning\n") }
            try xtbMustThrow("orca out as xtb") { _ = try XTBOutput.parse(try readText(testDataURL("io/orca/water_optfreq.out"))) }
            try xtbMustThrow("empty gradient") { _ = try XTBGradientFile.parse("") }
            try xtbMustThrow("gradient count mismatch") {
                _ = try XTBGradientFile.parse("$grad\n cycle = 1 SCF energy = -1.0 |dE/dxyz| = 0.1\n 0.0 0.0 0.0 h\n 0.0 0.0 1.0 h\n 0.1 0.0 0.0\n$end\n")
            }
            try xtbMustThrow("bad gradient number") {
                _ = try XTBGradientFile.parse("$grad\n cycle = 1 SCF energy = -1.0 |dE/dxyz| = 0.1\n 0.0 0.0 0.0 h\n 0.1 zz 0.0\n$end\n")
            }
            try xtbMustThrow("xyz without energy") { _ = try XTBTrajectory.parse("1\nhello\nH 0 0 0\n") }
            try xtbMustThrow("empty trajectory") { _ = try XTBTrajectory.parse("") }
            try xtbMustThrow("g98 empty") { _ = try XTBG98Frequencies.parse("") }
            try xtbMustThrow("g98 garbage") { _ = try XTBG98Frequencies.parse("nothing here\n") }
        },
        Check("io.xtb.arguments") {
            var s = CalcSpec(program: .xtb, task: .optimizeAndFrequencies, method: "GFN2-xTB", molecule: xtbWater())
            s.solvation = Solvation(model: .alpb, solvent: "water")
            s.nprocs = 4
            var a = XTBInput.arguments(for: s)
            try expect(a == ["input.xyz", "--gfn", "2", "--ohess", "--chrg", "0", "--uhf", "0", "--alpb", "water", "-P", "4"], "args \(a)")
            s.task = .optimize; s.method = "GFN1-xTB"; s.molecule.charge = -1; s.molecule.multiplicity = 2
            s.solvation = Solvation(model: .gbsa, solvent: "thf"); s.tightOptimization = true
            a = XTBInput.arguments(for: s)
            try expect(a == ["input.xyz", "--gfn", "1", "--opt", "tight", "--chrg", "-1", "--uhf", "1", "--gbsa", "thf", "-P", "4"], "args \(a)")
            s.task = .frequencies; s.method = "GFN-FF"; s.solvation = nil
            try expect(XTBInput.arguments(for: s).prefix(4) == ["input.xyz", "--gfnff", "--hess", "--chrg"], "gfnff/hess \(XTBInput.arguments(for: s))")
            s.task = .gradient
            try expect(XTBInput.arguments(for: s).contains("--grad"), "grad")
            try expect(XTBInput.xcontrol(for: s) == nil && !XTBInput.arguments(for: s).contains("--input"), "no xcontrol needed")
        },
        Check("io.xtb.xcontrol") {
            var s = CalcSpec(program: .xtb, task: .optimize, method: "GFN2-xTB", molecule: xtbWater())
            s.frozenAtoms = [0, 1, 2, 4, 6, 5]
            let x = XTBInput.xcontrol(for: s) ?? ""
            try expect(x == "$fix\n  atoms: 1-3,5-7\n$end\n", "fix:\n\(x)")
            try expect(XTBInput.arguments(for: s).suffix(2) == ["--input", "xcontrol.inp"], "input arg")
            s.frozenAtoms = []; s.task = .scan
            s.scan = ScanCoordinate(atoms: [0, 1], start: 0.9, end: 1.1, steps: 5)
            let sc = XTBInput.xcontrol(for: s) ?? ""
            try expect(sc.contains("$constrain") && sc.contains("distance: 1,2,auto") && sc.contains("$scan") && sc.contains("1: 0.9, 1.1, 5") && sc.hasSuffix("$end\n"), "scan:\n\(sc)")
            s.scan = ScanCoordinate(atoms: [0, 1, 2, 0], start: 0, end: 90, steps: 10)
            try expect((XTBInput.xcontrol(for: s) ?? "").contains("dihedral: 1,2,3,1,auto"), "dihedral")
            s.scan = ScanCoordinate(atoms: [0, 1, 2], start: 90, end: 120, steps: 4)
            try expect((XTBInput.xcontrol(for: s) ?? "").contains("angle: 1,2,3,auto"), "angle")
        },
    ]
}
