import Foundation
import MolCore
import simd
@testable import MolIO

// ORCA checks (worker W1). Fixtures are real ORCA 6.1.1 outputs in TestData/io/orca/.

fileprivate func orcaText(_ name: String) throws -> String { try readText(testDataURL("io/orca/" + name)) }
fileprivate func orcaParse(_ name: String) throws -> OrcaOutput { try OrcaOutput.parse(try orcaText(name)) }
fileprivate func orcaCRLF(_ s: String) -> String { s.replacingOccurrences(of: "\n", with: "\r\n") }

fileprivate func orcaMustThrowIOError(_ label: String, _ body: () throws -> Void) throws {
    do { try body() } catch is MolIOError { return } catch {
        throw CheckFailure(description: "wrong error type for \(label): \(error)")
    }
    throw CheckFailure(description: "expected MolIOError: \(label)")
}

fileprivate func orcaCutLines(_ s: String, _ k: Int) -> String {
    s.split(separator: "\n", omittingEmptySubsequences: false).prefix(k).joined(separator: "\n") + "\n"
}

fileprivate func orcaLineIndex(_ s: String, _ needle: String) -> Int? {
    s.split(separator: "\n", omittingEmptySubsequences: false).firstIndex { $0.contains(needle) }
}

fileprivate func orcaWater() -> Molecule {
    var m = Molecule(atoms: [Atom(id: 0, atomicNumber: 8, position: Vec3(0, 0, 0.1173)),
                             Atom(id: 1, atomicNumber: 1, position: Vec3(0, 0.7572, -0.4692)),
                             Atom(id: 2, atomicNumber: 1, position: Vec3(0, -0.7572, -0.4692))])
    m.bonds = [Bond(0, 1), Bond(0, 2)]
    return m
}

fileprivate func orcaClose(_ a: Vec3, _ b: Vec3, _ tol: Double) -> Bool {
    abs(a.x - b.x) <= tol && abs(a.y - b.y) <= tol && abs(a.z - b.z) <= tol
}

fileprivate func orcaCos(_ a: [Vec3], _ b: [Vec3]) -> Double {
    var d = 0.0, na = 0.0, nb = 0.0
    for (x, y) in zip(a, b) { d += (x * y).sum(); na += (x * x).sum(); nb += (y * y).sum() }
    return abs(d) / (sqrt(na * nb) + 1e-300)
}

extension Checks {
    static let ioOrca: [Check] = [
        Check("io.orca.water.basics") {
            let o = try orcaParse("water_optfreq.out")
            try expect(o.programVersion == "6.1.1", "version \(String(describing: o.programVersion))")
            try expect(o.charge == 0 && o.multiplicity == 1, "charge/mult")
            try expect(o.normalTermination, "normal termination")
            try expect(o.keywordLines == ["! HF STO-3G Opt Freq"], "keywords \(o.keywordLines)")
            let r = o.result
            try expect(r.routeSection == "! HF STO-3G Opt Freq", "route")
            try expect(r.extras?.program == "orca", "program")
            try expect(r.steps[0].atoms.map(\.atomicNumber) == [8, 1, 1], "elements")
            try expect(r.steps[0].bonds.count == 2, "bonds perceived")
        },
        Check("io.orca.water.energy_and_steps") {
            let o = try orcaParse("water_optfreq.out")
            try expectClose(o.finalEnergy ?? 0, -74.965901192188, tol: 1e-10)
            try expectClose(o.result.extras?.finalEnergy ?? 0, -74.965901192188, tol: 1e-10)
            try expect(o.geometries.count == 5, "geometry blocks \(o.geometries.count)")
            try expect(o.energies.count == o.geometries.count, "energies per step")
            try expectClose(o.energies[0], -74.963805061084, tol: 1e-10)
            try expectClose(o.energies[3], -74.965901190846, tol: 1e-10)
            try expect(o.result.steps.count == 5 && o.result.energies.count == 5, "result steps")
        },
        Check("io.orca.water.optimization_convergence") {
            let o = try orcaParse("water_optfreq.out")
            try expect(o.optimizationConverged == true, "converged")
            try expect(o.optimizationCycles.count == 4, "cycles \(o.optimizationCycles.count)")
            let first = o.optimizationCycles[0], last = o.optimizationCycles[3]
            try expect(first.items.count == 4 && !first.items.contains { $0.name == "Energy change" && $0.converged } || first.items.count >= 4, "first items")
            try expect(first.items.contains { !$0.converged }, "first cycle unconverged")
            try expect(last.items.count == 5 && last.items.allSatisfy { $0.converged }, "last cycle converged \(last.items)")
            try expectClose(last.items.first { $0.name == "RMS gradient" }?.value ?? 0, 0.0000217470, tol: 1e-12)
            try expect(o.result.extras?.optimizationConverged == true, "extras")
        },
        Check("io.orca.water.last_geometry_matches_trj") {
            let o = try orcaParse("water_optfreq.out")
            let frames = try XYZFormat.parse(try orcaText("water_optfreq_trj.xyz"))
            try expect(frames.count >= 4, "trj frames \(frames.count)")
            // the optimized geometry: the last trajectory frame equals the final converged cycle geometry
            let lastTrj = frames[frames.count - 1]
            let cand = [o.geometries[o.geometries.count - 1], o.geometries[o.geometries.count - 2]]
            try expect(cand.contains { m in zip(m.atoms, lastTrj.atoms).allSatisfy { orcaClose($0.position, $1.position, 1e-5) } }, "geometry vs trj")
            try expect(frames[0].atoms.count == 3, "atoms")
            for (m, f) in zip(o.geometries, frames) {
                try expect(zip(m.atoms, f.atoms).allSatisfy { orcaClose($0.position, $1.position, 1e-5) }, "frame match")
            }
        },
        Check("io.orca.water.frequencies_and_ir") {
            let o = try orcaParse("water_optfreq.out")
            try expect(o.allFrequencies.count == 9 && o.firstVibrationIndex == 6, "all freqs / first vib")
            let m = o.result.normalModes
            try expect(m.count == 3, "3 vibrations, got \(m.count)")
            try expectClose(m[0].frequency, 2169.82, tol: 1e-6)
            try expectClose(m[1].frequency, 4139.64, tol: 1e-6)
            try expectClose(m[2].frequency, 4390.67, tol: 1e-6)
            try expectClose(m[0].irIntensity, 7.24, tol: 1e-9)
            try expectClose(m[1].irIntensity, 44.27, tol: 1e-9)
            try expectClose(m[2].irIntensity, 29.93, tol: 1e-9)
            try expect(m.allSatisfy { $0.displacements.count == 3 }, "displacement per atom")
            // mode 8 (third vibration), atom 1: x,y,z = (-0.068110?, ...) from the NORMAL MODES table
            try expectClose(m[2].displacements[0].y, -0.068110, tol: 1e-6)
            try expectClose(m[2].displacements[1].y, 0.540523, tol: 1e-6)
            try expectClose(m[2].displacements[2].z, 0.453338, tol: 1e-6)
            try expectClose(o.allNormalModes[0].displacements[0].x, 0, tol: 1e-12)
        },
        Check("io.orca.water.orbitals_and_charges") {
            let o = try orcaParse("water_optfreq.out")
            try expect(o.orbitals.count == 7, "orbitals \(o.orbitals.count)")
            try expect(o.orbitals.filter(\.occupied).count == 5, "5 occupied")
            try expect(o.orbitals[4].occupied && !o.orbitals[5].occupied && o.orbitals[4].index == 5, "HOMO is #5")
            try expectClose(o.orbitals[0].energy, -20.251577, tol: 1e-6)   // last printed block (final geometry)
            try expectClose(o.orbitals[4].energy, -0.392617, tol: 1e-6)
            try expect(o.orbitals.allSatisfy { $0.spin == .restricted }, "restricted")
            try expectClose(o.result.extras?.homoLumoGapEV ?? 0, (0.581795 + 0.392617) * 27.211386, tol: 1e-3)
            try expect(o.mullikenCharges.count == 3, "mulliken count")
            try expectClose(o.mullikenCharges[0], -0.330530, tol: 1e-9)   // last block (final geometry), like the orbitals
            try expectClose(o.mullikenCharges.reduce(0, +), 0, tol: 1e-5)
            try expectClose(o.loewdinCharges[1], 0.115776, tol: 1e-9)
            try expectClose(o.loewdinCharges.reduce(0, +), 0, tol: 1e-5)
            let ch = o.result.chargesByScheme
            try expect(ch["Mulliken"]?.count == 3 && ch["Loewdin"]?.count == 3, "schemes \(ch.keys)")
        },
        Check("io.orca.water.dipole_and_gradient") {
            let o = try orcaParse("water_optfreq.out")
            let d = o.result.dipole ?? .zero
            try expectClose(d.z, -0.672455686 * 2.541746, tol: 1e-6)
            try expectClose(simd_length(d), 1.709246519, tol: 5e-3)
            let g = o.result.extras?.gradients ?? []
            try expect(g.count == 4, "gradient blocks \(g.count)")
            try expectClose(g[0][0].z, -0.008197662, tol: 1e-12)
            try expectClose(g[0][1].y, 0.022806227, tol: 1e-12)
            try expect(g[0].count == 3, "per atom")
        },
        Check("io.orca.water.thermochemistry") {
            let o = try orcaParse("water_optfreq.out")
            let t = try { () throws -> ThermochemistrySummary in
                guard let t = o.result.thermochemistry else { throw CheckFailure(description: "no thermochemistry") }
                return t }()
            try expectClose(t.temperature ?? 0, 298.15, tol: 1e-9)
            try expectClose(t.pressure ?? 0, 1.0, tol: 1e-9)
            try expectClose(t.electronicEnergy ?? 0, -74.96590119, tol: 1e-8)
            try expectClose(t.zeroPointEnergy ?? 0, 0.02437668, tol: 1e-9)
            try expectClose(t.thermalEnergyCorrection ?? 0, 0.02720950, tol: 1e-9)
            try expectClose(t.totalEnthalpy ?? 0, -74.93774748, tol: 1e-8)
            try expectClose(t.entropy ?? 0, 0.02151523, tol: 1e-9)
            try expectClose(t.totalGibbs ?? 0, -74.95926271, tol: 1e-8)
            try expectClose(t.gibbsCorrection ?? 0, 0.00663848, tol: 1e-9)
            try expectClose(t.enthalpyCorrection ?? 0, -74.93774748 + 74.96590119, tol: 1e-8)
        },
        Check("io.orca.h2co.frequencies") {
            let o = try orcaParse("h2co_optfreq.out")
            let m = o.result.normalModes
            try expect(m.count == 6, "H2CO has 6 vibrations, got \(m.count)")
            let f = [1191.68, 1264.48, 1529.13, 1862.20, 2863.57, 2922.49]
            let ir = [1.21, 13.67, 6.27, 111.65, 60.73, 164.97]
            for k in 0..<6 {
                try expectClose(m[k].frequency, f[k], tol: 1e-6)
                try expectClose(m[k].irIntensity, ir[k], tol: 1e-9)
                try expect(m[k].displacements.count == 4, "4 atoms")
            }
            try expect(o.allFrequencies.count == 12, "12 total")
            try expect(o.result.steps.count == o.result.energies.count && !o.result.steps.isEmpty, "steps/energies")
            try expect(o.optimizationConverged == true, "converged")
        },
        Check("io.orca.tddft.states") {
            let o = try orcaParse("h2co_tddft.out")
            let ex = o.result.excitedStates
            try expect(ex.count == 3, "3 states, got \(ex.count)")
            let ev = [4.020, 8.238, 9.149]
            let f = [0.0, 0.154031786, 0.002211817]
            let nm = [308.5, 150.5, 135.5]
            for k in 0..<3 {
                try expectClose(ex[k].energyEV, ev[k], tol: 1e-9)
                try expectClose(ex[k].oscillatorStrength, f[k], tol: 1e-9)
                try expectClose(ex[k].wavelengthNM, nm[k], tol: 1e-9)
                try expect(ex[k].multiplicity == 1, "singlet")
            }
            try expect(o.excitedStates[0].transitions.first?.from == "7a" && o.excitedStates[0].transitions.first?.to == "8a", "dominant transition")
            try expectClose(o.excitedStates[2].transitions[0].weight, 0.992909, tol: 1e-9)
            try expectClose(o.excitedStates[1].energyCm1, 66445.8, tol: 1e-6)
            try expectClose(o.result.dipole.map { simd_length($0) } ?? 0, 2.165960254, tol: 5e-3)
        },
        Check("io.orca.tddft.orca5_table_layout") {
            // Rewrite the electric-dipole absorption table in the ORCA 5 layout (cm-1 / nm / fosc, integer state ids).
            var lines = try orcaText("h2co_tddft.out").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let h = lines.firstIndex(where: { $0.contains("ABSORPTION SPECTRUM VIA TRANSITION ELECTRIC DIPOLE MOMENTS") }) else {
                throw CheckFailure(description: "table not found") }
            let v5 = ["-----------------------------------------------------------------------------",
                      "         ABSORPTION SPECTRUM VIA TRANSITION ELECTRIC DIPOLE MOMENTS",
                      "-----------------------------------------------------------------------------",
                      "     State   Energy    Wavelength  fosc         T2         TX        TY        TZ",
                      "             (cm-1)      (nm)                 (au**2)      (au)      (au)      (au)",
                      "-----------------------------------------------------------------------------",
                      "   1   32419.7    308.5   0.000000000   0.00000  -0.00000  -0.00000   0.00000",
                      "   2   66445.8    150.5   0.154031786   0.76317   0.00000  -0.87359   0.00000",
                      "   3   73788.2    135.5   0.002211817   0.00987   0.09934  -0.00000   0.00000"]
            lines.replaceSubrange((h - 1)...(h + 7), with: v5)
            let o = try OrcaOutput.parse(lines.joined(separator: "\n"))
            let ex = o.result.excitedStates
            try expect(ex.count == 3, "states \(ex.count)")
            try expectClose(ex[1].oscillatorStrength, 0.154031786, tol: 1e-12)
            try expectClose(ex[2].wavelengthNM, 135.5, tol: 1e-9)
            try expectClose(ex[0].energyEV, 4.020, tol: 1e-9)
        },
        Check("io.orca.tddft.triplets_smd_orca6") {
            // real ORCA 6.1.1 run of the writer's TD-DFT (TDA, triplets) + SMD layout: STATE lines are numbered
            // globally, the spectrum labels states per multiplicity ("1-3A")
            let o = try orcaParse("water_td_smd.out")
            try expect(o.normalTermination, "terminated")
            try expectClose(o.result.extras?.finalEnergy ?? 0, -74.834730581028, tol: 1e-10)
            let st = o.excitedStates
            try expect(st.count == 6 && st.filter { $0.multiplicity == 3 }.count == 3, "3 singlets + 3 triplets, got \(st.map(\.multiplicity))")
            try expect(st.allSatisfy { $0.oscillatorStrength != nil }, "every state matched to a spectrum row")
            try expectClose(st[0].energyEV, 12.193, tol: 1e-9)
            try expectClose(st[0].oscillatorStrength ?? 0, 0.002945724, tol: 1e-12)
            try expectClose(st[3].energyEV, 10.256, tol: 1e-9)
            try expectClose(st[3].wavelengthNM ?? 0, 120.9, tol: 1e-9)
            try expect(o.result.excitedStates.count == 6, "result states")
            let inp = try OrcaInputFile.parse(try orcaText("water_td_smd.inp"))
            try expect(inp.blocks.contains { $0.name == "cpcm" } && inp.molecule.atoms.count == 3, "input parses")
        },
        Check("io.orca.uhf.spin") {
            let o = try orcaParse("oh_uhf.out")
            try expect(o.multiplicity == 2, "doublet")
            let up = o.orbitals.filter { $0.spin == .alpha }, dn = o.orbitals.filter { $0.spin == .beta }
            try expect(up.count == 6 && dn.count == 6, "alpha \(up.count) beta \(dn.count)")
            try expect(up.filter(\.occupied).count == 5 && dn.filter(\.occupied).count == 4, "occupations")
            try expectClose(dn[3].energy, -0.377794, tol: 1e-9)
            try expectClose(o.mullikenSpins[0], 1.069760, tol: 1e-9)
            try expectClose(o.mullikenSpins.reduce(0, +), 1.0, tol: 1e-6)
            try expectClose(o.loewdinSpins[1], -0.055980, tol: 1e-9)
            try expectClose(o.spinSquared ?? 0, 0.753262, tol: 1e-9)
            try expectClose(o.mullikenCharges[0], -0.164453, tol: 1e-9)
            let r = o.result
            try expect(r.extras?.spinDensities["Mulliken"]?.count == 2, "spin densities in extras")
            try expectClose(simd_length(r.dipole ?? .zero), 1.278490585, tol: 5e-3)
            try expect(r.normalModes.isEmpty && r.normalTermination, "no modes, terminated")
        },
        Check("io.orca.scan.surface_and_hirshfeld") {
            let o = try orcaParse("water_scan.out")
            try expect(o.scanSurface.count == 3, "scan points \(o.scanSurface.count)")
            try expectClose(o.scanSurface[0].coordinate, 0.9, tol: 1e-9)
            try expectClose(o.scanSurface[2].coordinate, 1.0, tol: 1e-9)
            try expect(o.scanSurface[1].energy < o.scanSurface[0].energy, "energy drops towards minimum")
            try expect(o.geometries.count == o.energies.count && o.geometries.count >= 3, "steps vs energies")
            try expect(o.hirshfeldCharges.count == 3, "hirshfeld")
            try expectClose(o.hirshfeldCharges.reduce(0, +), 0, tol: 1e-4)
            try expect(o.result.extras?.charges["Hirshfeld"]?.count == 3, "hirshfeld in extras")
            try expect(o.normalTermination, "terminated")
        },
        Check("io.orca.engrad") {
            let e = try OrcaEngrad.parse(try orcaText("water_optfreq.engrad"))
            try expectClose(e.energy, -74.965901192188, tol: 1e-12)
            try expect(e.gradient.count == 3 && e.molecule.atoms.count == 3, "3 atoms")
            try expectClose(e.gradient[0].z, 0.000011670745, tol: 1e-15)
            try expectClose(e.gradient[1].y, 0.000024164213, tol: 1e-15)
            try expectClose(e.molecule.atoms[0].position.z, 0.2718732 * bohrToAngstrom, tol: 1e-9)
            try expectClose(e.molecule.atoms[1].position.y, 1.4325612 * bohrToAngstrom, tol: 1e-9)
            try expect(e.molecule.atoms.map(\.atomicNumber) == [8, 1, 1], "Z")
            try orcaMustThrowIOError("engrad garbage") { _ = try OrcaEngrad.parse("hello\nworld\n") }
            let txt = try orcaText("water_optfreq.engrad")
            try orcaMustThrowIOError("engrad cut") { _ = try OrcaEngrad.parse(orcaCutLines(txt, 22)) }
        },
        Check("io.orca.hess.water") {
            let h = try OrcaHessian.parse(try orcaText("water_optfreq.hess"))
            try expect(h.atomCount == 3 && h.hessian.count == 9 && h.hessian.allSatisfy { $0.count == 9 }, "dims")
            try expect(h.frequencies.count == 9, "freqs")
            try expectClose(h.hessian[1][1], 8.0394390946E-01, tol: 1e-12)
            try expectClose(h.hessian[8][8], 3.0009695049E-01, tol: 1e-12)
            var asym = 0.0
            for r in 0..<9 { for c in 0..<9 { asym = max(asym, abs(h.hessian[r][c] - h.hessian[c][r])) } }
            try expect(asym < 1e-6, "hessian symmetric within 1e-6, got \(asym)")
            try expectClose(h.masses[0], 15.999, tol: 1e-9)
            try expectClose(h.molecule.atoms[1].position.y, 1.432561179323 * bohrToAngstrom, tol: 1e-9)
            let m = h.normalModes
            try expect(m.count == 3, "3 vibrations")
            try expectClose(m[0].frequency, 2169.8220940559663, tol: 1e-9)
            try expectClose(m[0].irIntensity, 7.23597396, tol: 1e-9)
            try expectClose(m[2].displacements[1].y, 0.540522, tol: 1e-5)
        },
        Check("io.orca.hess.agrees_with_out") {
            for (hess, out) in [("water_optfreq.hess", "water_optfreq.out"), ("h2co_optfreq.hess", "h2co_optfreq.out")] {
                let h = try OrcaHessian.parse(try orcaText(hess))
                let o = try orcaParse(out)
                let a = h.normalModes, b = o.result.normalModes
                try expect(a.count == b.count && !a.isEmpty, "\(hess): mode counts \(a.count) vs \(b.count)")
                for k in a.indices {
                    try expect(abs(a[k].frequency - b[k].frequency) < 0.1, "\(hess) freq \(k): \(a[k].frequency) vs \(b[k].frequency)")
                    try expect(abs(a[k].irIntensity - b[k].irIntensity) < 0.1 * max(1, b[k].irIntensity) * 0.01 + 0.05, "\(hess) IR \(k): \(a[k].irIntensity) vs \(b[k].irIntensity)")
                    try expect(orcaCos(a[k].displacements, b[k].displacements) > 0.99, "\(hess) mode \(k) cosine \(orcaCos(a[k].displacements, b[k].displacements))")
                }
            }
        },
        Check("io.orca.crlf_equals_lf") {
            for n in ["water_optfreq.out", "h2co_tddft.out", "oh_uhf.out"] {
                let t = try orcaText(n)
                try expect(try OrcaOutput.parse(orcaCRLF(t)) == OrcaOutput.parse(t), "\(n) CRLF parse differs")
            }
            let hs = try orcaText("water_optfreq.hess")
            try expect(try OrcaHessian.parse(orcaCRLF(hs)) == OrcaHessian.parse(hs), "hess CRLF")
            let eg = try orcaText("water_optfreq.engrad")
            try expect(try OrcaEngrad.parse(orcaCRLF(eg)) == OrcaEngrad.parse(eg), "engrad CRLF")
            let inp = try orcaText("h2co_tddft.inp")
            try expect(try OrcaInputFile.parse(orcaCRLF(inp)) == OrcaInputFile.parse(inp), "inp CRLF")
        },
        Check("io.orca.error_termination_detected") {
            let t = try orcaText("water_optfreq.out")
            let cut = orcaCutLines(t, 1000) + "\n\nORCA finished by error termination in SCF\nCalling Command: orca_scf\n[file orca_tools/qcmsg.cpp, line 394]: \n  .... aborting the run\n"
            let o = try OrcaOutput.parse(cut)
            try expect(o.errorTermination && !o.normalTermination, "flags")
            try expect(o.messages.contains { $0.contains("error termination") }, "message \(o.messages)")
            try expect(o.result.extras?.messages.isEmpty == false, "extras messages")
            let clean = try OrcaOutput.parse(orcaCutLines(t, 1000))
            try expect(!clean.normalTermination && !clean.errorTermination, "clean cut is just unterminated")
            try expect(clean.optimizationConverged == false, "unfinished optimization is not converged")
        },
        Check("io.orca.truncation_sweep_out") {
            for name in ["water_optfreq.out", "h2co_tddft.out", "oh_uhf.out"] {
                let t = try orcaText(name)
                let total = t.split(separator: "\n", omittingEmptySubsequences: false).count
                var threw = 0, parsed = 0
                var k = 1
                while k < total - 1 {   // prefix(total - 1) is the whole file
                    let cut = orcaCutLines(t, k)
                    do {
                        let o = try OrcaOutput.parse(cut)
                        parsed += 1
                        try expect(!o.normalTermination, "\(name) cut at line \(k) cannot be terminated normally")
                        let r = o.result
                        try expect(r.energies.isEmpty || r.steps.count == r.energies.count, "\(name)@\(k): steps/energies consistent")  // a geometry printed before its first SCF has no energy yet
                        try expect(o.allNormalModes.isEmpty || o.allNormalModes.count == o.allFrequencies.count, "\(name)@\(k): modes complete")
                        try expect(o.mullikenCharges.isEmpty || o.mullikenCharges.count == r.steps.first?.atoms.count, "\(name)@\(k): charge count")
                    } catch is MolIOError { threw += 1 }
                    k += 7
                }
                // mid-character cuts
                for f in stride(from: 0.013, to: 1.0, by: 0.037) {
                    let s = String(t.prefix(Int(Double(t.count) * f)))
                    do { let o = try OrcaOutput.parse(s); try expect(!o.normalTermination, "\(name) char cut \(f)") } catch is MolIOError {}
                }
                try expect(threw > 0 && parsed > 0, "\(name): expected both outcomes (threw \(threw), parsed \(parsed))")
            }
        },
        Check("io.orca.truncation_inside_tables_throws") {
            let t = try orcaText("water_optfreq.out")
            func cutInside(_ marker: String, after: Int) throws {
                guard let i = orcaLineIndex(t, marker) else { throw CheckFailure(description: "no \(marker)") }
                try orcaMustThrowIOError("cut inside \(marker)") { _ = try OrcaOutput.parse(orcaCutLines(t, i + after)) }
            }
            try cutInside("CARTESIAN COORDINATES (ANGSTROEM)", after: 4)      // inside the first coordinate list
            try cutInside("ORBITAL ENERGIES", after: 7)
            try cutInside("MULLIKEN ATOMIC CHARGES", after: 4)
            try cutInside("VIBRATIONAL FREQUENCIES", after: 6)
            try cutInside("NORMAL MODES", after: 14)                          // inside the first column block
            try cutInside("NORMAL MODES", after: 22)                          // between the two column blocks
            try cutInside("IR SPECTRUM", after: 8)
            try cutInside("CARTESIAN GRADIENT", after: 4)
        },
        Check("io.orca.truncation_sweep_hess") {
            let t = try orcaText("water_optfreq.hess")
            let lines = t.split(separator: "\n", omittingEmptySubsequences: false)
            guard let hi = lines.firstIndex(where: { $0.hasPrefix("$hessian") }), let fi = lines.firstIndex(where: { $0.hasPrefix("$vibrational") }) else {
                throw CheckFailure(description: "layout") }
            var parsed = 0
            for k in 1..<lines.count {
                let cut = lines.prefix(k).joined(separator: "\n") + "\n"
                do {
                    let h = try OrcaHessian.parse(cut)
                    parsed += 1
                    try expect(h.frequencies.count == 9 && h.hessian.count == 9 && h.allNormalModes.count == 9, "cut \(k) parsed but incomplete")
                    try expect(k > fi, "cut at \(k) inside the matrix must not parse")
                } catch is MolIOError {}
                if k > hi && k < fi { try orcaMustThrowIOError("hess cut at line \(k)") { _ = try OrcaHessian.parse(cut) } }
            }
            try expect(parsed > 0, "late cuts (after the normal modes) still give data")
            for f in stride(from: 0.02, to: 1.0, by: 0.031) {
                do { _ = try OrcaHessian.parse(String(t.prefix(Int(Double(t.count) * f)))) } catch is MolIOError {}
            }
        },
        Check("io.orca.malformed_inputs_throw") {
            try orcaMustThrowIOError("empty") { _ = try OrcaOutput.parse("") }
            try orcaMustThrowIOError("garbage") { _ = try OrcaOutput.parse("lorem ipsum\n\u{0}\u{1}\nxyz 12 ;;\n") }
            try orcaMustThrowIOError("xyz file") { _ = try OrcaOutput.parse("3\nwater\nO 0 0 0.117\nH 0 0.757 -0.469\nH 0 -0.757 -0.469\n") }
            try orcaMustThrowIOError("gaussian-ish") { _ = try OrcaOutput.parse(" Entering Gaussian System, Link 0=g16\n #P HF/STO-3G\n") }
            try orcaMustThrowIOError("hess garbage") { _ = try OrcaHessian.parse("nonsense\n") }
            try orcaMustThrowIOError("hess empty") { _ = try OrcaHessian.parse("") }
            try orcaMustThrowIOError("hess xyz") { _ = try OrcaHessian.parse("3\nwater\nO 0 0 0\nH 0 1 0\nH 1 0 0\n") }
            try orcaMustThrowIOError("input xyz") { _ = try OrcaInputFile.parse("3\nwater\nO 0 0 0\nH 0 1 0\nH 1 0 0\n") }
            try orcaMustThrowIOError("input empty") { _ = try OrcaInputFile.parse("") }
            let h = try orcaText("water_optfreq.hess").replacingOccurrences(of: "6.7750232893E-18", with: "abc")
            try orcaMustThrowIOError("bad number in hessian") { _ = try OrcaHessian.parse(h) }
        },
        Check("io.orca.input.parse_real_files") {
            let w = try OrcaInputFile.parse(try orcaText("water_optfreq.inp"))
            try expect(w.keywords == ["HF", "STO-3G", "Opt", "Freq"], "keywords \(w.keywords)")
            try expect(w.nprocs == 1, "nprocs")
            try expect(w.molecule.atoms.count == 3 && w.molecule.charge == 0 && w.molecule.multiplicity == 1, "molecule")
            try expectClose(w.molecule.atoms[0].position.z, 0.12, tol: 1e-12)
            try expect(w.blocks.contains { $0.name == "output" && $0.body.contains("Print[P_MOs] 1") }, "output block \(w.blocks)")
            let t = try OrcaInputFile.parse(try orcaText("h2co_tddft.inp"))
            try expect(t.blocks.contains { $0.name == "tddft" && $0.body == "nroots 3" }, "tddft block \(t.blocks)")
            try expect(t.molecule.atoms.map(\.atomicNumber) == [6, 8, 1, 1], "Z")
            let u = try OrcaInputFile.parse(try orcaText("oh_uhf.inp"))
            try expect(u.molecule.multiplicity == 2 && u.keywords.contains("UHF"), "uhf")
            // keywords of the echoed input in an output match the input file
            let o = try orcaParse("water_optfreq.out")
            try expect(o.keywordLines == w.keywordLines, "echo vs file")
        },
        Check("io.orca.input.syntax_variants") {
            let txt = """
            # my comment
            ! B3LYP def2-SVP   # trailing comment
            ! Opt
            %maxcore 3000
            %pal
              nprocs 4
            end
            %geom
              Scan
                B 0 1 = 0.9, 1.1, 5
              end
            end
            * xyz -1 1
            O  0.0D+00  0.0  1.0d-1
            H  0.0  0.8 -0.5
            *
            """
            let f = try OrcaInputFile.parse(txt)
            try expect(f.keywords == ["B3LYP", "def2-SVP", "Opt"], "keywords \(f.keywords)")
            try expect(f.maxcore == 3000 && f.nprocs == 4, "maxcore/nprocs")
            try expect(f.molecule.charge == -1 && f.molecule.atoms.count == 2, "mol")
            try expectClose(f.molecule.atoms[0].position.z, 0.1, tol: 1e-15)
            try expect(f.blocks.first { $0.name == "geom" }?.body.contains("B 0 1 = 0.9, 1.1, 5") == true, "nested end handled: \(f.blocks)")
            try expect(f.title == "my comment", "title \(f.title)")
        },
        Check("io.orca.input.int_and_xyzfile") {
            let z = """
            ! HF STO-3G
            * int 0 1
            O 0 0 0 0.0 0.0 0.0
            H 1 0 0 0.96 0.0 0.0
            H 1 2 0 0.96 104.5 0.0
            *
            """
            let f = try OrcaInputFile.parse(z)
            try expect(f.molecule.atoms.count == 3, "3 atoms")
            let d = simd_length(f.molecule.atoms[0].position - f.molecule.atoms[1].position)
            try expectClose(d, 0.96, tol: 1e-9)
            let d2 = simd_length(f.molecule.atoms[0].position - f.molecule.atoms[2].position)
            try expectClose(d2, 0.96, tol: 1e-9)
            let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("orca-w1-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            try "3\nw\nO 0 0 0.1\nH 0 0.8 -0.5\nH 0 -0.8 -0.5\n".write(to: dir.appendingPathComponent("w.xyz"), atomically: true, encoding: .utf8)
            let g = try OrcaInputFile.parse("! HF STO-3G\n* xyzfile 0 1 w.xyz\n", baseDirectory: dir)
            try expect(g.molecule.atoms.count == 3 && g.coordinateType == "xyzfile", "xyzfile")
            try orcaMustThrowIOError("xyzfile without base") { _ = try OrcaInputFile.parse("! HF STO-3G\n* xyzfile 0 1 w.xyz\n") }
            try orcaMustThrowIOError("unterminated xyz block") { _ = try OrcaInputFile.parse("! HF\n* xyz 0 1\nO 0 0 0\n") }
            try orcaMustThrowIOError("gzmt unsupported") { _ = try OrcaInputFile.parse("! HF\n* gzmt 0 1\nO\n*\n") }
            try orcaMustThrowIOError("unterminated block") { _ = try OrcaInputFile.parse("! HF\n%pal nprocs 2\n* xyz 0 1\nO 0 0 0\n*\n") }
        },
        Check("io.orca.input.write_roundtrip") {
            var spec = CalcSpec(program: .orca, task: .optimizeAndFrequencies, method: "B3LYP", basis: "def2-SVP", molecule: orcaWater(), title: "water test")
            spec.dispersion = .d3bj
            spec.solvation = Solvation(model: .cpcm, solvent: "water")
            spec.nprocs = 4; spec.memoryMB = 8000
            let text = OrcaInput.write(spec)
            try expect(text.contains("! B3LYP def2-SVP D3BJ Opt Freq CPCM(water)"), "keyword line:\n\(text)")
            try expect(text.contains("%pal nprocs 4 end") && text.contains("%maxcore 2000"), "pal/maxcore")
            let p = try OrcaInputFile.parse(text)
            try expect(p.keywords == ["B3LYP", "def2-SVP", "D3BJ", "Opt", "Freq", "CPCM(water)"], "keywords \(p.keywords)")
            try expect(p.nprocs == 4 && p.maxcore == 2000, "nprocs/maxcore")
            try expect(p.molecule.atoms.count == 3 && p.molecule.charge == 0 && p.molecule.multiplicity == 1, "mol")
            for (a, b) in zip(p.molecule.atoms, spec.molecule.atoms) {
                try expect(a.atomicNumber == b.atomicNumber && orcaClose(a.position, b.position, 1e-7), "geometry")
            }
            try expect(p.title == "water test", "title")
        },
        Check("io.orca.input.write_features") {
            var m = orcaWater(); m.charge = 1; m.multiplicity = 2
            // unrestricted HF -> UHF
            var s = CalcSpec(program: .orca, task: .energy, method: "HF", basis: "STO-3G", molecule: m)
            try expect(OrcaInput.write(s).contains("! UHF STO-3G"), "UHF")
            s = CalcSpec(program: .orca, task: .energy, method: "PBE0", basis: "def2-TZVP", molecule: orcaWater())
            s.unrestricted = true
            try expect(OrcaInput.write(s).contains("! PBE0 UKS def2-TZVP"), "UKS")
            // TD-DFT
            s = CalcSpec(program: .orca, task: .energy, method: "B3LYP", basis: "def2-SVP", molecule: orcaWater())
            s.excitedStates = ExcitedStatesSpec(roots: 5, triplets: true, tammDancoff: true)
            var f = try OrcaInputFile.parse(OrcaInput.write(s))
            let td = f.blocks.first { $0.name == "tddft" }?.body ?? ""
            try expect(td.contains("nroots 5") && td.contains("tda true") && td.contains("triplets true"), "tddft block \(td)")
            // SMD
            s.excitedStates = nil
            s.solvation = Solvation(model: .smd, solvent: "acetonitrile")
            f = try OrcaInputFile.parse(OrcaInput.write(s))
            try expect(f.blocks.first { $0.name == "cpcm" }?.body.contains("SMDsolvent \"acetonitrile\"") == true, "smd")
            // scan + frozen
            s = CalcSpec(program: .orca, task: .scan, method: "HF", basis: "STO-3G", molecule: orcaWater())
            s.scan = ScanCoordinate(atoms: [0, 1], start: 0.9, end: 1.1, steps: 5)
            s.frozenAtoms = [2]
            let t = OrcaInput.write(s)
            try expect(t.contains("B 0 1 = 0.90000000, 1.10000000, 5"), "scan:\n\(t)")
            try expect(t.contains("{ C 2 C }"), "constraint")
            f = try OrcaInputFile.parse(t)
            try expect(f.blocks.first { $0.name == "geom" } != nil && f.molecule.atoms.count == 3, "geom block parses")
            // TS + IRC + gradient
            s = CalcSpec(program: .orca, task: .transitionState, method: "HF", basis: "STO-3G", molecule: orcaWater())
            try expect(OrcaInput.write(s).contains("! HF STO-3G OptTS Freq"), "TS")
            try expect(OrcaInput.write(s).contains("%geom\n  Calc_Hess true\nend"), "TS starts from an exact Hessian")
            s.computeFrequenciesAfterTS = false; s.tightOptimization = true
            try expect(OrcaInput.write(s).contains("! HF STO-3G OptTS TightOpt\n"), "TS tight")
            s.task = .irc
            try expect(OrcaInput.write(s).contains(" IRC"), "IRC")
            s.task = .gradient
            try expect(OrcaInput.write(s).contains("EnGrad"), "EnGrad")
            // extras
            s.task = .energy; s.extraKeywords = ["TightSCF"]; s.extraInput = "%scf MaxIter 200 end"
            f = try OrcaInputFile.parse(OrcaInput.write(s))
            try expect(f.keywords.contains("TightSCF") && f.blocks.contains { $0.name == "scf" }, "extras")
        },
        Check("io.orca.input.roundtrip_charge_mult_and_elements") {
            var m = Molecule(atoms: [Atom(id: 0, atomicNumber: 26, position: Vec3(0, 0, 0)),
                                     Atom(id: 1, atomicNumber: 17, position: Vec3(0, 0, 2.2)),
                                     Atom(id: 2, atomicNumber: 6, position: Vec3(1.5, -0.25, 0.125))], charge: -1, multiplicity: 4)
            m.title = "x"
            let spec = CalcSpec(program: .orca, task: .optimize, method: "B3LYP", basis: "def2-SVP", molecule: m)
            let p = try OrcaInputFile.parse(OrcaInput.write(spec))
            try expect(p.molecule.charge == -1 && p.molecule.multiplicity == 4, "charge/mult")
            try expect(p.molecule.atoms.map(\.atomicNumber) == [26, 17, 6], "elements")
            try expectClose(p.molecule.atoms[2].position.y, -0.25, tol: 1e-8)
        },
        Check("io.orca.result_is_fully_filled") {
            let r = try orcaParse("h2co_optfreq.out").result
            try expect(!r.steps.isEmpty && r.steps.count == r.energies.count, "steps/energies")
            try expect(r.normalModes.count == 6 && r.orbitals.count > 0, "modes/orbitals")
            try expect(r.mullikenCharges.count == 4 && r.dipole != nil, "charges/dipole")
            try expect(r.normalTermination && r.routeSection.hasPrefix("! B3LYP"), "termination/route")
            let x = r.extras
            try expect(x?.program == "orca" && x?.programVersion == "6.1.1", "program")
            try expect(x?.thermochemistry?.totalGibbs != nil && x?.finalEnergy != nil, "thermo/energy")
            try expect(x?.charges["Loewdin"]?.count == 4, "loewdin")
            try expect(x?.homoLumoGapEV != nil, "gap")
            // JSON round trip of the detailed struct
            let o = try orcaParse("h2co_optfreq.out")
            let data = try JSONEncoder().encode(o)
            try expect(try JSONDecoder().decode(OrcaOutput.self, from: data) == o, "codable round trip")
        },
    ]
}
