import Foundation
import MolCore
import simd
import MolIO

// Q-Chem checks. Q-Chem is not installed: the fixtures in TestData/io/qchem/ are hand-written from the
// public Q-Chem manual formats (input) and documented output layout, so these checks validate the
// parser against the documented format, not against real program output.

fileprivate func qcFixture(_ n: String) throws -> String { try readText(testDataURL("io/qchem/" + n)) }

fileprivate func qcWater(mult: Int = 1) -> Molecule {
    var m = Molecule(atoms: [], bonds: [], charge: mult == 1 ? 0 : 1, multiplicity: mult, title: "water")
    m.atoms = [Atom(id: 0, atomicNumber: 8, position: Vec3(0, 0, 0.1173)),
               Atom(id: 1, atomicNumber: 1, position: Vec3(0, 0.7572, -0.4692)),
               Atom(id: 2, atomicNumber: 1, position: Vec3(0, -0.7572, -0.4692))]
    return m
}

fileprivate func qcSpec(_ task: CalcTask, mult: Int = 1) -> CalcSpec {
    var s = CalcSpec(program: .qchem, task: task, method: "B3LYP", basis: "def2-SVP", molecule: qcWater(mult: mult), title: "water test")
    s.memoryMB = 4000
    return s
}

fileprivate func qcThrowsInput(_ label: String, _ s: String) throws {
    do { _ = try QChemInputFile.parse(s) } catch is MolIOError { return } catch {
        throw CheckFailure(description: "wrong error type for \(label): \(error)")
    }
    throw CheckFailure(description: "expected a throw: \(label)")
}

fileprivate func qcThrowsOutput(_ label: String, _ s: String) throws {
    do { _ = try QChemOutput.parse(s) } catch is MolIOError { return } catch {
        throw CheckFailure(description: "wrong error type for \(label): \(error)")
    }
    throw CheckFailure(description: "expected a throw: \(label)")
}

fileprivate func qcKeep(_ s: String, _ k: Int) -> String {
    s.split(separator: "\n", omittingEmptySubsequences: false).prefix(k).joined(separator: "\n") + "\n"
}

extension Checks {
    static let ioQChem: [Check] = [
        Check("io.qchem.input.fixture_optfreq") {
            let f = try QChemInputFile.parse(try qcFixture("water_optfreq.in"))
            try expect(f.jobs.count == 2, "2 jobs, got \(f.jobs.count)")
            try expect(f.jobs[0].jobType == "opt" && f.jobs[1].jobType == "freq", "job types")
            try expect(f.jobs[1].readsGeometry && !f.jobs[0].readsGeometry, "read flag")
            try expect(f.jobs[0].molecule?.atoms.count == 3 && f.jobs[1].molecule == f.jobs[0].molecule, "read geometry resolves to job 1")
            try expect(f.jobs[0].rem["METHOD"] == "b3lyp" && f.jobs[0].rem["BASIS"] == "def2-svp" && f.jobs[0].rem["DFT_D"] == "D3_BJ", "rem")
            try expect(f.jobs[0].sections["comment"]?.contains("water") == true, "comment kept raw")
            try expectClose(f.jobs[0].molecule!.atoms[1].position.y, 0.7572, tol: 1e-12)
        },
        Check("io.qchem.input.write_optfreq_roundtrip") {
            let spec = qcSpec(.optimizeAndFrequencies)
            let text = QChemInput.write(spec)
            try expect(text.contains("@@@"), "job separator")
            let f = try QChemInputFile.parse(text)
            try expect(f.jobs.count == 2 && f.jobs[0].jobType == "opt" && f.jobs[1].jobType == "freq", "jobs")
            try expect(f.jobs[1].readsGeometry, "second job reads geometry")
            let m = try { () throws -> Molecule in guard let m = f.jobs[0].molecule else { throw CheckFailure(description: "no molecule") }; return m }()
            try expect(m.atoms.map(\.atomicNumber) == [8, 1, 1] && m.charge == 0 && m.multiplicity == 1, "molecule meta")
            for (a, b) in zip(m.atoms, spec.molecule.atoms) { try expect(simd_length(a.position - b.position) < 1e-7, "position") }
            try expect(f.jobs[0].rem["METHOD"] == "b3lyp" && f.jobs[0].rem["BASIS"] == "def2-SVP" && f.jobs[1].rem["BASIS"] == "def2-SVP", "method/basis")
            try expect(f.jobs[0].rem["MEM_TOTAL"] == "4000", "memory")
        },
        Check("io.qchem.input.write_task_jobtypes") {
            let map: [(CalcTask, String)] = [(.energy, "sp"), (.optimize, "opt"), (.frequencies, "freq"), (.gradient, "force"),
                                             (.transitionState, "ts"), (.irc, "rpath")]
            for (t, jt) in map {
                let f = try QChemInputFile.parse(QChemInput.write(qcSpec(t)))
                try expect(f.jobs[0].jobType == jt, "\(t) -> \(f.jobs[0].jobType)")
            }
            let ts = try QChemInputFile.parse(QChemInput.write(qcSpec(.transitionState)))
            try expect(ts.jobs.count == 2 && ts.jobs[1].jobType == "freq", "TS + freq")
            var noFreq = qcSpec(.transitionState); noFreq.computeFrequenciesAfterTS = false
            try expect(try QChemInputFile.parse(QChemInput.write(noFreq)).jobs.count == 1, "TS without freq")
        },
        Check("io.qchem.input.dispersion_unrestricted_tight") {
            for (d, k) in [(DispersionCorrection.d3bj, "D3_BJ"), (.d3zero, "D3_ZERO"), (.d4, "D4")] {
                var s = qcSpec(.energy); s.dispersion = d
                try expect(try QChemInputFile.parse(QChemInput.write(s)).jobs[0].rem["DFT_D"] == k, "dispersion \(k)")
            }
            let singlet = try QChemInputFile.parse(QChemInput.write(qcSpec(.energy))).jobs[0]
            try expect(singlet.rem["UNRESTRICTED"] == nil && singlet.rem["DFT_D"] == nil, "singlet defaults")
            let radical = try QChemInputFile.parse(QChemInput.write(qcSpec(.energy, mult: 2))).jobs[0]
            try expect(radical.rem["UNRESTRICTED"] == "true" && radical.molecule?.multiplicity == 2 && radical.molecule?.charge == 1, "open shell")
            var t = qcSpec(.optimize); t.tightOptimization = true
            let rem = try QChemInputFile.parse(QChemInput.write(t)).jobs[0].rem
            try expect(rem["GEOM_OPT_TOL_GRADIENT"] == "15", "tight optimization")
        },
        Check("io.qchem.input.tddft") {
            var s = qcSpec(.energy); s.excitedStates = ExcitedStatesSpec(roots: 6, triplets: true)
            let rem = try QChemInputFile.parse(QChemInput.write(s)).jobs[0].rem
            try expect(rem["CIS_N_ROOTS"] == "6" && rem["CIS_TRIPLETS"] == "true" && rem["RPA"] == "true", "TDDFT rem \(rem)")
            s.excitedStates = ExcitedStatesSpec(roots: 3, tammDancoff: true)
            let tda = try QChemInputFile.parse(QChemInput.write(s)).jobs[0].rem
            try expect(tda["RPA"] == nil && tda["CIS_TRIPLETS"] == nil && tda["CIS_N_ROOTS"] == "3", "TDA rem")
        },
        Check("io.qchem.input.solvation") {
            var s = qcSpec(.energy)
            s.solvation = Solvation(model: .smd, solvent: "water")
            var f = try QChemInputFile.parse(QChemInput.write(s)).jobs[0]
            try expect(f.rem["SOLVENT_METHOD"] == "SMD" && f.sections["smx"]?.contains("water") == true, "SMD")
            s.solvation = Solvation(model: .cpcm, solvent: "acetonitrile")
            f = try QChemInputFile.parse(QChemInput.write(s)).jobs[0]
            try expect(f.rem["SOLVENT_METHOD"] == "PCM" && f.sections["solvent"]?.contains("SolventName acetonitrile") == true
                       && f.sections["pcm"]?.contains("cpcm") == true, "CPCM")
        },
        Check("io.qchem.input.frozen_and_scan") {
            var s = qcSpec(.optimize); s.frozenAtoms = [2, 0]
            let f = try QChemInputFile.parse(QChemInput.write(s)).jobs[0]
            let opt = f.sections["opt"] ?? ""
            try expect(opt.contains("FIXED") && opt.contains("1 XYZ") && opt.contains("3 XYZ") && opt.contains("ENDFIXED") && !opt.contains("2 XYZ"), "FIXED block: \(opt)")
            var sc = qcSpec(.scan); sc.scan = ScanCoordinate(atoms: [0, 1], start: 0.9, end: 1.5, steps: 7)
            let g = try QChemInputFile.parse(QChemInput.write(sc)).jobs[0]
            try expect(g.jobType == "pes_scan", "scan job type")
            let tk = (g.sections["scan"] ?? "").split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
            try expect(tk.prefix(3) == ["stre", "1", "2"], "scan tag/atoms \(tk)")
            try expectClose(Double(tk[3]) ?? 0, 0.9, tol: 1e-9); try expectClose(Double(tk[4]) ?? 0, 1.5, tol: 1e-9)
            try expectClose(Double(tk[5]) ?? 0, 0.1, tol: 1e-9)
        },
        Check("io.qchem.input.crlf_equals_lf") {
            let t = try qcFixture("water_optfreq.in")
            let a = try QChemInputFile.parse(t), b = try QChemInputFile.parse(t.replacingOccurrences(of: "\n", with: "\r\n"))
            try expect(a.jobs.count == b.jobs.count, "job count")
            for (x, y) in zip(a.jobs, b.jobs) {
                try expect(x.molecule == y.molecule && x.rem == y.rem && x.sections == y.sections && x.readsGeometry == y.readsGeometry, "CRLF differs")
            }
        },
        Check("io.qchem.input.malformed_throws") {
            try qcThrowsInput("empty", "")
            try qcThrowsInput("garbage", "hello\nworld\n")
            try qcThrowsInput("no $end", "$molecule\n0 1\nH 0 0 0\nH 0 0 0.74\n")
            try qcThrowsInput("no molecule", "$rem\nJOBTYPE sp\n$end\n")
            try qcThrowsInput("no rem", "$molecule\n0 1\nH 0 0 0\n$end\n")
            try qcThrowsInput("bad atom", "$molecule\n0 1\nH 0 zero 0\n$end\n$rem\nMETHOD hf\n$end\n")
            try qcThrowsInput("bad charge line", "$molecule\nfoo bar\nH 0 0 0\n$end\n$rem\nMETHOD hf\n$end\n")
            try qcThrowsInput("rem key without value", "$molecule\n0 1\nH 0 0 0\n$end\n$rem\nMETHOD\n$end\n")
        },
        Check("io.qchem.input.truncation_never_crashes") {
            let t = try qcFixture("water_optfreq.in")
            let n = t.split(separator: "\n", omittingEmptySubsequences: false).count
            for k in 0...n { do { _ = try QChemInputFile.parse(qcKeep(t, k)) } catch is MolIOError {} }
            for p in stride(from: 1, to: 100, by: 2) { do { _ = try QChemInputFile.parse(String(t.prefix(t.count * p / 100))) } catch is MolIOError {} }
            // cut inside $rem (no $end) must throw
            try qcThrowsInput("cut in rem", "$molecule\n0 1\nH 0 0 0\n$end\n$rem\nMETHOD hf\n")
        },
        Check("io.qchem.output.optfreq_basics") {
            let o = try QChemOutput.parse(try qcFixture("water_optfreq.out"))
            try expect(o.jobs.count == 2, "2 jobs, got \(o.jobs.count)")
            try expect(o.version == "6.1", "version \(o.version ?? "nil")")
            try expect(o.normalTermination && o.result.normalTermination, "normal termination")
            let j = o.jobs[0]
            try expect(j.geometries.count == 3 && j.scfEnergies.count == 3 && j.optimizationCycles == 2, "opt bookkeeping")
            try expect(j.optimizationConverged == true && o.result.extras?.optimizationConverged == true, "converged")
            try expectClose(j.finalEnergy ?? 0, -76.315, tol: 1e-9)
            try expect(j.rem["JOBTYPE"] == "opt" && o.jobs[1].jobType == "freq", "echoed rem")
            try expect(j.charge == 0 && j.multiplicity == 1 && j.geometries[0].multiplicity == 1, "charge/mult")
            try expectClose(j.geometries[2].atoms[0].position.z, 0.122, tol: 1e-9)
            try expect(j.geometries[0].atoms.map(\.atomicNumber) == [8, 1, 1], "elements")
        },
        Check("io.qchem.output.result_steps_energies") {
            let r = try QChemOutput.parse(try qcFixture("water_optfreq.out")).result
            try expect(r.steps.count == 3, "duplicate final geometry dropped: \(r.steps.count)")
            try expect(r.energies == [-76.3, -76.31, -76.315], "energies \(r.energies)")
            try expectClose(r.extras?.finalEnergy ?? 0, -76.315, tol: 1e-9)
            try expect(r.extras?.program == "Q-Chem" && r.extras?.programVersion == "6.1", "program")
            try expect(r.routeSection.contains("JOBTYPE opt") && r.routeSection.contains("METHOD b3lyp"), "route: \(r.routeSection)")
        },
        Check("io.qchem.output.vibrations") {
            let r = try QChemOutput.parse(try qcFixture("water_optfreq.out")).result
            try expect(r.normalModes.count == 3, "3 modes")
            try expectClose(r.normalModes[0].frequency, 1620.45, tol: 1e-9)
            try expectClose(r.normalModes[2].frequency, 3860.77, tol: 1e-9)
            try expectClose(r.normalModes[0].irIntensity, 71.2, tol: 1e-9)
            try expectClose(r.normalModes[1].irIntensity, 10.5, tol: 1e-9)
            for m in r.normalModes { try expect(m.displacements.count == 3, "one displacement per atom") }
            try expect(r.normalModes[0].displacements[1] == Vec3(0, 0.43, -0.56), "mode 1 H displacement")
            try expect(r.normalModes[2].displacements[1] == Vec3(0, 0.56, -0.43), "mode 3 H displacement (3rd column group)")
        },
        Check("io.qchem.output.orbitals_charges_dipole") {
            let r = try QChemOutput.parse(try qcFixture("water_optfreq.out")).result
            try expect(r.orbitals.count == 8 && r.orbitals.filter(\.occupied).count == 5, "orbitals")
            try expect(r.orbitals.allSatisfy { $0.spin == .restricted } && r.orbitals[0].index == 1, "spin/index")
            try expectClose(r.orbitals[4].energy, -0.36, tol: 1e-9)
            try expectClose(r.extras?.homoLumoGapEV ?? 0, 0.41 * 27.211386, tol: 1e-4)
            try expect(r.mullikenCharges == [-0.452, 0.226, 0.226] && r.extras?.charges["mulliken"] == r.mullikenCharges, "Mulliken")
            try expect(r.dipole == Vec3(0, 0, 2.05), "dipole")
        },
        Check("io.qchem.output.thermochemistry") {
            let th = try QChemOutput.parse(try qcFixture("water_optfreq.out")).result.thermochemistry
            let k = 627.5094740631
            try expect(th != nil, "thermo present")
            try expectClose(th?.temperature ?? 0, 298.15, tol: 1e-9); try expectClose(th?.pressure ?? 0, 1.0, tol: 1e-9)
            try expectClose(th?.zeroPointEnergy ?? 0, 13.5 / k, tol: 1e-12)
            try expectClose(th?.enthalpyCorrection ?? 0, 16.5 / k, tol: 1e-12)
            try expectClose(th?.entropy ?? 0, 45.0 * 298.15 / 1000 / k, tol: 1e-12)
            try expectClose(th?.totalEnthalpy ?? 0, -76.315 + 16.5 / k, tol: 1e-9)
            try expectClose(th?.gibbsCorrection ?? 0, 16.5 / k - 45.0 * 298.15 / 1000 / k, tol: 1e-12)
        },
        Check("io.qchem.output.tddft") {
            let o = try QChemOutput.parse(try qcFixture("h2co_tddft.out"))
            let st = o.result.excitedStates
            try expect(st.count == 3, "TDA set replaced by full TDDFT, singlets+triplet kept: \(st.count)")
            try expectClose(st[0].energyEV, 3.85, tol: 1e-9)
            try expectClose(st[1].energyEV, 8.42, tol: 1e-9); try expectClose(st[1].oscillatorStrength, 0.0215, tol: 1e-9)
            try expectClose(st[0].wavelengthNM, 1239.841984 / 3.85, tol: 1e-6)
            try expect(st[0].multiplicity == 1 && st[2].multiplicity == 3, "multiplicities")
            try expectClose(st[2].energyEV, 3.2, tol: 1e-9)
            try expect(o.jobs.count == 1 && o.jobs[0].rem["CIS_N_ROOTS"] == "2" && o.result.steps.count == 1 && o.result.steps[0].atoms.count == 4, "job/rem/geometry")
            try expectClose(o.result.energies.first ?? 0, -114.35, tol: 1e-9)
        },
        Check("io.qchem.output.unrestricted_orbitals") {
            let text = """
             Q-Chem 6.0
             Running Job 1 of 1 oh.in
                                Standard Nuclear Orientation (Angstroms)
                I     Atom           X                Y                Z
             ----------------------------------------------------------------
                1      O       0.000000     0.000000     0.000000
                2      H       0.000000     0.000000     0.970000
             ----------------------------------------------------------------
             Total energy in the final basis set =      -75.7000000000
                      Orbital Energies (a.u.)
                      -----------------------
             Alpha MOs
             -- Occupied --
            -20.5000  -1.3000  -0.7000  -0.5000  -0.4500
             -- Virtual --
              0.1000   0.5000
             Beta MOs
             -- Occupied --
            -20.4000  -1.1000  -0.6000  -0.4000
             -- Virtual --
              0.0500   0.3000   0.6000
             -----------------------------------------------------------------
             Thank you very much for using Q-Chem.  Have a nice day.
            """.split(separator: "\n", omittingEmptySubsequences: false).map { $0.hasPrefix("        ") ? String($0.dropFirst(8)) : String($0) }.joined(separator: "\n")
            let r = try QChemOutput.parse(text).result
            let a = r.orbitals.filter { $0.spin == .alpha }, b = r.orbitals.filter { $0.spin == .beta }
            try expect(a.count == 7 && b.count == 7, "alpha/beta counts \(a.count)/\(b.count)")
            try expect(a.filter(\.occupied).count == 5 && b.filter(\.occupied).count == 4, "5 alpha / 4 beta occupied")
            try expectClose(b[0].energy, -20.4, tol: 1e-9)
        },
        Check("io.qchem.output.crlf_equals_lf") {
            let t = try qcFixture("water_optfreq.out")
            let a = try QChemOutput.parse(t).result, b = try QChemOutput.parse(t.replacingOccurrences(of: "\n", with: "\r\n")).result
            try expect(a == b, "CRLF result differs")
        },
        Check("io.qchem.output.unterminated_is_not_normal") {
            let t = try qcFixture("water_optfreq.out")
            let cut = t.components(separatedBy: " Total job time").first ?? t
            let o = try QChemOutput.parse(cut)
            try expect(!o.normalTermination && !o.result.normalTermination, "no termination line")
            try expect(o.result.normalModes.count == 3, "data before the cut still parsed")
            let err = try QChemOutput.parse(t + "\n Q-Chem fatal error occurred in module qparser\n")
            try expect(!err.messages.isEmpty && err.result.extras?.messages.isEmpty == false, "fatal error message captured")
        },
        Check("io.qchem.output.malformed_throws") {
            try qcThrowsOutput("empty", "")
            try qcThrowsOutput("garbage", "this is not a quantum chemistry output\n12345\n")
        },
        Check("io.qchem.output.truncation_never_crashes") {
            for name in ["water_optfreq.out", "h2co_tddft.out"] {
                let t = try qcFixture(name)
                let n = t.split(separator: "\n", omittingEmptySubsequences: false).count
                for k in 0...n {
                    do {
                        let o = try QChemOutput.parse(qcKeep(t, k))
                        for m in o.result.normalModes { try expect(m.displacements.count == 3 || m.displacements.count == 0, "partial displacement count") }
                        try expect(o.result.orbitals.allSatisfy { $0.index >= 1 }, "orbital indices")
                    } catch is MolIOError {}
                }
                for p in stride(from: 1, to: 100, by: 2) { do { _ = try QChemOutput.parse(String(t.prefix(t.count * p / 100))) } catch is MolIOError {} }
            }
        },
        Check("io.qchem.calcspec_dispatch") {
            let text = try CalcInputWriter.write(qcSpec(.optimize))
            try expect(text.contains("$molecule") && text.contains("JOBTYPE") && text.contains("$end"), "CalcInputWriter routes to Q-Chem")
            try expect(QCProgram.qchem.inputExtension == "in", "extension")
        },
    ]
}
