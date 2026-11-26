import Foundation
import MolCore
import MolIO

// Geometry optimizations as trajectories (Trajectory tab playback): every program's output yields one frame per
// optimizer step, energies parallel to the frames, optimizer convergence data per frame (`extras.stepInfo`), and no
// repeated final geometry (Gaussian Link1 freq job, ORCA final evaluation at the stationary point).

fileprivate func optText(_ name: String) throws -> String { try readText(testDataURL(name)) }

fileprivate func water(_ z: Double, e: Double? = nil) -> Molecule {
    Molecule(atoms: [Atom(id: 0, atomicNumber: 8, position: Vec3(0, 0, z)),
                     Atom(id: 1, atomicNumber: 1, position: Vec3(0, 0.76, -0.47)),
                     Atom(id: 2, atomicNumber: 1, position: Vec3(0, -0.76, -0.47))])
}

/// Every parallel array of a result agrees with `steps`.
fileprivate func expectParallel(_ r: CalculationResult, _ label: String) throws {
    try expect(r.energies.isEmpty || r.energies.count == r.steps.count, "\(label): \(r.energies.count) energies for \(r.steps.count) steps")
    if let si = r.extras?.stepInfo { try expect(si.count == r.steps.count, "\(label): \(si.count) step infos for \(r.steps.count) steps") }
}

extension Checks {
    static let ioOptTrajectory: [Check] = [
        Check("io.opt.gaussian.optfreq_frames") {
            // opt freq with a Link1 frequency job that re-prints the converged geometry: 2 frames, not 3.
            let log = try GaussianLog.parse(try optText("io/gaussian/water_optfreq_td.log"))
            let r = log.result
            try expect(r.steps.count == 2, "steps \(r.steps.count)")
            try expectParallel(r, "gaussian")
            try expectClose(r.energies[0], -74.9590412345, tol: 1e-10)
            try expectClose(r.energies[1], -74.9659011234, tol: 1e-10)
            try expectClose(r.steps[1].atoms[0].position.z, 0.127, tol: 1e-9)
            let si = r.extras?.stepInfo ?? []
            try expectClose(si.first?.maxForce ?? 0, 0.031246, tol: 1e-12)
            try expectClose(si.first?.rmsStep ?? 0, 0.052261, tol: 1e-12)
            try expect(si.first?.converged == false && si.last?.converged == true, "per-step convergence")
            try expect(r.extras?.optimizationConverged == true, "optimization converged")
            let f = try MolecularFileLoader.load(text: try optText("io/gaussian/water_optfreq_td.log"), format: .gaussianOutput)
            try expect(f.molecules.count == 2, "loader frames \(f.molecules.count)")
        },
        Check("io.opt.gaussian.unfinished_step_dropped") {
            // A running optimization: the newest geometry has no SCF energy yet and is not a frame.
            let lines = try optText("io/gaussian/water_optfreq_td.log").components(separatedBy: "\n")
            guard let cut = lines.indices.filter({ lines[$0].contains("SCF Done") }).dropFirst().first else {
                throw CheckFailure(description: "fixture has fewer than two SCF Done lines")
            }
            let r = try GaussianLog.parse(lines[..<cut].joined(separator: "\n") + "\n").result
            try expect(r.steps.count == 1 && r.energies.count == 1, "steps \(r.steps.count) energies \(r.energies.count)")
            try expectParallel(r, "running gaussian")
            try expectClose(r.steps[0].atoms[0].position.z, 0.12, tol: 1e-9)
        },
        Check("io.opt.orca.final_evaluation_merged") {
            let o = try OrcaOutput.parse(try optText("analysis/water_sto3g_optfreq.orca.out"))
            let r = o.result
            try expect(o.geometries.count == 5 && r.steps.count == 4, "geometries \(o.geometries.count) steps \(r.steps.count)")
            try expectParallel(r, "orca")
            try expectClose(r.energies[3], -74.965901192191, tol: 1e-10)   // the final evaluation survives
            let si = r.extras?.stepInfo ?? []
            try expectClose(si[0].maxForce ?? 0, 0.0374982982, tol: 1e-12)
            try expect(si[0].energyChange == nil || si[0].energyChange != 0, "energy change")
            try expect(si.last?.converged == true && si.dropLast().allSatisfy { $0.converged == false }, "converged only at the end")
            try expectClose(si.last?.rmsForce ?? 0, 0.0000075998, tol: 1e-14)
        },
        Check("io.opt.orca.distinct_final_kept") {
            // h2co: the final evaluation moved the atoms (energy differs by 5e-6 Eh): it stays a frame of its own.
            let r = try OrcaOutput.parse(try optText("io/orca/h2co_optfreq.out")).result
            try expect(r.steps.count == 6, "steps \(r.steps.count)")
            try expectParallel(r, "h2co")
            // Cycle 5 met every criterion but the energy change; ORCA still signalled convergence ("close enough").
            let si = r.extras?.stepInfo ?? []
            try expect(si.count == 6 && si[4].converged == false && si[5].isEmpty, "cycle 5 table / final evaluation")
            try expectClose(si[4].maxForce ?? 0, 0.0002038440, tol: 1e-12)
            try expectClose(si[4].energyChange ?? 0, 0.0000072238, tol: 1e-13)
            try expect(r.extras?.optimizationConverged == true, "converged")
        },
        Check("io.opt.orca.relaxed_scan_frames") {
            let r = try OrcaOutput.parse(try optText("io/orca/water_scan.out")).result
            try expectParallel(r, "scan")
            try expect(r.steps.count >= 9, "steps \(r.steps.count)")
            try expect((r.extras?.stepInfo ?? []).filter { $0.converged == true }.count >= 1, "a converged cycle per point")
        },
        Check("io.opt.qchem.criteria") {
            var t = try optText("io/qchem/water_optfreq.out")
            let open = "\n                                 Maximum     Tolerance    Cnvgd?\n"
            t = t.replacingOccurrences(of: " Optimization Cycle:   1\n", with: " Optimization Cycle:   1\n" + open
                + "          Gradient               0.012345     0.000300      NO\n"
                + "          Displacement           0.054321     0.001200      NO\n"
                + "          Energy change          ********     0.000001      NO\n")
            t = t.replacingOccurrences(of: " Optimization Cycle:   2\n", with: " Optimization Cycle:   2\n" + open
                + "          Gradient               0.000123     0.000300     YES\n"
                + "          Displacement           0.000321     0.001200     YES\n"
                + "          Energy change         -0.000005     0.000001      NO\n")
            let r = try QChemOutput.parse(t).result
            try expect(r.steps.count == 3, "steps \(r.steps.count)")
            try expectParallel(r, "qchem")
            let si = r.extras?.stepInfo ?? []
            try expectClose(si[0].maxForce ?? 0, 0.012345, tol: 1e-12)
            try expectClose(si[0].maxStep ?? 0, 0.054321, tol: 1e-12)
            try expect(si[0].energyChange == nil && si[0].converged == false, "overflowed energy change")
            try expectClose(si[1].energyChange ?? 0, -0.000005, tol: 1e-12)
            try expect(si[1].converged == false && si[2].isEmpty, "row 2 / final")
            // Without tables there is no step info at all.
            try expect(try QChemOutput.parse(try optText("io/qchem/water_optfreq.out")).result.extras?.stepInfo == nil, "no tables")
        },
        Check("io.opt.qchem.unfinished_step_dropped") {
            let t = try optText("io/qchem/water_optfreq.out")
            guard let r0 = t.range(of: " Total energy in the final basis set =      -76.3150000000") else {
                throw CheckFailure(description: "fixture changed")
            }
            let r = try QChemOutput.parse(String(t[..<r0.lowerBound])).result
            try expect(r.steps.count == 2 && r.energies == [-76.3, -76.31], "steps \(r.steps.count) energies \(r.energies)")
        },
        Check("io.opt.xtb.gnorm_and_companions") {
            let tr = try XTBTrajectory.parse(try optText("io/xtb/xtbopt.log"))
            let si = tr.result.extras?.stepInfo ?? []
            try expect(si.count == 3, "step info \(si.count)")
            try expectClose(si[0].gradientNorm ?? 0, 0.045678901234, tol: 1e-15)
            let d = FileManager.default.temporaryDirectory.appendingPathComponent("vv-opt-xtb-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: d) }
            for n in ["xtb_water.out", "xtbopt.log", "xtbopt.xyz"] {
                try FileManager.default.copyItem(at: testDataURL("io/xtb/" + n), to: d.appendingPathComponent(n))
            }
            let f = try MolecularFileLoader.loadWithCompanions(url: d.appendingPathComponent("xtb_water.out")).file
            let r = f.result ?? CalculationResult()
            try expect(f.molecules.count == 3 && r.steps.count == 3, "frames \(f.molecules.count)")
            try expectParallel(r, "xtb")
            try expectClose(r.extras?.stepInfo?.last?.gradientNorm ?? 0, (tr.gradientNorms.last ?? nil) ?? -1, tol: 1e-15)
            try expect(r.extras?.optimizationConverged == true, "converged")
        },
        Check("io.opt.xyz.comment_energies") {
            try expect(XYZFormat.commentEnergy(" energy:     -5.068912345678 gnorm:      0.045678901234 xtb: 6.7.1 (edcfbbe)") == -5.068912345678, "xtb")
            try expect(XYZFormat.commentEnergy("Coordinates from ORCA-job water_optfreq E -74.963805061084") == -74.963805061084, "orca")
            try expect(XYZFormat.commentEnergy("Frame 1 water E=-76.0107") == -76.0107, "E=")
            try expect(XYZFormat.commentEnergy("step 3, Energy = -76.5") == -76.5, "Energy =")
            try expect(XYZFormat.commentEnergy("-40.123456") == -40.123456, "bare number")
            try expect(XYZFormat.commentEnergy("12") == nil, "a lone integer is a counter")
            try expect(XYZFormat.commentEnergy("Frame 3 water extended-xyz style forces") == nil, "no energy")
            try expect(XYZFormat.commentEnergy("") == nil, "empty")
            try expect(XYZFormat.commentGradientNorm(" energy: -5.07 gnorm:      0.045678901234 xtb") == 0.045678901234, "gnorm")
            try expect(XYZFormat.commentGradientNorm("E=-1") == nil, "no gnorm")
            let frames = try XYZFormat.parse(try optText("io/xyz_traj.xyz"))
            try expect(frames.map { XYZFormat.commentEnergy($0.title) } == [-76.0107, -76.005, nil], "fixture comments")
        },
        Check("io.opt.dropRepeatedSteps") {
            var r = CalculationResult()
            r.steps = [water(0.10), water(0.12), water(0.12 + 5e-5), water(0.13)]
            r.energies = [-1.0, -1.1, -1.1 - 1e-7, -1.05]
            var x = CalculationExtras()
            x.stepInfo = [OptimizationStepInfo(maxForce: 0.1), OptimizationStepInfo(maxForce: 0.01, converged: true),
                          OptimizationStepInfo(), OptimizationStepInfo(maxForce: 0.2)]
            r.extras = x
            r.dropRepeatedSteps()
            try expect(r.steps.count == 3 && r.energies == [-1.0, -1.1 - 1e-7, -1.05], "energies \(r.energies)")
            try expectClose(r.steps[1].atoms[0].position.z, 0.12 + 5e-5, tol: 1e-12)          // the later copy survives
            try expect(r.extras?.stepInfo?[1] == OptimizationStepInfo(maxForce: 0.01, converged: true), "inherits optimizer data")
            // Same geometry, different energy (e.g. another method at the end): both stay.
            var s = CalculationResult()
            s.steps = [water(0.12), water(0.12)]; s.energies = [-1.0, -1.2]
            s.dropRepeatedSteps()
            try expect(s.steps.count == 2, "energy differs")
            // Different elements or atom count: both stay; no energies: geometry alone decides.
            var u = CalculationResult()
            var m = water(0.12); m.atoms[1].atomicNumber = 9
            u.steps = [water(0.12), m, water(0.12), water(0.12)]
            u.dropRepeatedSteps()
            try expect(u.steps.count == 3, "elements \(u.steps.count)")
            var one = CalculationResult(); one.steps = [water(0.1)]
            one.dropRepeatedSteps()
            try expect(one.steps.count == 1)
        },
    ]
}
