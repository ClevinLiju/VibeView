import Foundation
import MolCore
import MolIO

// Gaussian output (.log) checks (Lead A, round 2). Gaussian is not installed, so the fixture
// io/gaussian/water_optfreq_td.log is hand-written in the public log layout; the inline snippets
// below cover TD-DFT, unrestricted orbitals, scans and IRC.

fileprivate func glFixture(_ name: String) throws -> String { try readText(testDataURL("io/gaussian/" + name)) }

fileprivate func glThrows(_ label: String, _ body: () throws -> Void) throws {
    do { try body() } catch is MolIOError { return } catch { throw CheckFailure(description: "\(label): non-MolIOError \(error)") }
    throw CheckFailure(description: "expected a throw: \(label)")
}

fileprivate let glHead = " Entering Gaussian System, Link 0=g16\n Gaussian 16:  ES64L-G16RevC.01  3-Jul-2019\n"

fileprivate func glOrient(_ rows: [(Int, Double, Double, Double)], standard: Bool = true) -> String {
    var s = standard ? "                         Standard orientation:\n" : "                          Input orientation:\n"
    s += " ---------------------------------------------------------------------\n"
    s += " Center     Atomic      Atomic             Coordinates (Angstroms)\n"
    s += " Number     Number       Type             X           Y           Z\n"
    s += " ---------------------------------------------------------------------\n"
    for (k, r) in rows.enumerated() {
        s += String(format: " %6d %10d %11d %15.6f %11.6f %11.6f\n", k + 1, r.0, 0, r.1, r.2, r.3)
    }
    s += " ---------------------------------------------------------------------\n"
    return s
}

fileprivate let glTDSnippet = glHead + """
 #p td(nstates=3) b3lyp/def2svp
 Charge =  0 Multiplicity = 1

""" + glOrient([(6, 0, 0, -0.53), (8, 0, 0, 0.68), (1, 0, 0.94, -1.11), (1, 0, -0.94, -1.11)]) + """
 SCF Done:  E(RB3LYP) =  -114.501234567     A.U. after   12 cycles
 Excited State   1:      Singlet-A2     3.9861 eV  311.04 nm  f=0.0000  <S**2>=0.000
       8 ->  9         0.70461
 This state for optimization and/or second-order correction.
 Total Energy, E(TD-HF/TD-DFT) =  -114.354748120
 Copying the excited state density for this state as the 1-particle RhoCI density.

 Excited State   2:      Singlet-B1     8.9124 eV  139.11 nm  f=0.0012  <S**2>=0.000
       7 ->  9         0.69802
       7 <-  9        -0.10234

 Excited State   3:      Singlet-A1     9.4012 eV  131.88 nm  f=0.0855  <S**2>=0.000
       6 ->  9         0.66123
       8 -> 10        -0.20112
 Normal termination of Gaussian 16 at Mon Nov 23 10:00:00 2026.

"""

fileprivate let glUHFSnippet = glHead + """
 #p uhf/sto-3g
 Charge =  0 Multiplicity = 2

""" + glOrient([(8, 0, 0, 0), (1, 0, 0, 0.97)]) + """
 SCF Done:  E(UHF) =  -74.3612345678     A.U. after   10 cycles
 Alpha  occ. eigenvalues --  -20.31111  -1.30022  -0.57033  -0.51044  -0.45055
 Alpha virt. eigenvalues --    0.60066
 Beta  occ. eigenvalues --  -20.29111  -1.20022  -0.55033  -0.47044
 Beta virt. eigenvalues --    0.10055   0.62066
 Normal termination of Gaussian 16 at Mon Nov 23 10:00:00 2026.

"""

extension Checks {
    static let ioGaussianOutput: [Check] = [
        Check("io.glog.optFreqFixture") {
            let log = try GaussianLog.parse(try glFixture("water_optfreq_td.log"))
            try expect(log.jobCount == 2 && log.normalTerminationCount >= 0, "jobs \(log.jobCount)")
            try expect(log.programVersion?.hasPrefix("Gaussian 16") == true, "version \(String(describing: log.programVersion))")
            try expect(log.charge == 0 && log.multiplicity == 1)
            try expect(log.optimizationCompleted && log.stationaryPointFound)
            try expect(log.optimizationSteps.count == 2, "opt steps \(log.optimizationSteps.count)")
            try expect(log.optimizationSteps[0].converged == false && log.optimizationSteps[1].converged)
            try expectClose(log.optimizationSteps[0].criteria[0].value, 0.031246, tol: 1e-9)
            try expect(log.scfEnergies.count == 3)
            let r = log.result
            try expect(r.normalTermination)
            try expect(r.steps.count >= 2 && r.energies.count == r.steps.count, "steps \(r.steps.count) energies \(r.energies.count)")
            try expectClose(r.energies[0], -74.9590412345, tol: 1e-10)
            try expectClose(r.energies.last!, -74.9659011234, tol: 1e-10)
            let fin = r.finalMolecule!
            try expect(fin.atoms.map(\.atomicNumber) == [8, 1, 1])
            try expectClose(fin.atoms[1].position.y, 0.763, tol: 1e-9)
            try expect(r.routeSection.lowercased().contains("opt freq"), r.routeSection)
        },
        Check("io.glog.vibrationsAndThermo") {
            let r = try GaussianLog.parse(try glFixture("water_optfreq_td.log"))
            try expect(r.vibrations.count == 3, "modes \(r.vibrations.count)")
            let f = r.vibrations.map(\.frequency)
            try expectClose(f[0], 2170.0050, tol: 1e-6); try expectClose(f[2], 4391.5678, tol: 1e-6)
            try expect(r.vibrations.map(\.symmetry) == ["A1", "A1", "B2"])
            try expectClose(r.vibrations[0].irIntensity ?? -1, 24.2121, tol: 1e-6)
            try expectClose(r.vibrations[1].reducedMass ?? -1, 1.0441, tol: 1e-6)
            try expectClose(r.vibrations[2].forceConstant ?? -1, 12.1632, tol: 1e-6)
            try expect(r.vibrations[0].displacements.count == 3)
            try expectClose(r.vibrations[0].displacements[1].y, -0.42, tol: 1e-9)
            try expectClose(r.vibrations[2].displacements[2].z, -0.43, tol: 1e-9)
            try expect(r.lowFrequencies.count == 9)
            let nm = r.result.normalModes
            try expect(nm.count == 3 && nm[0].reducedMass == 1.0823 && nm[1].forceConstant == 10.5450)
            let t = try r.thermochemistry.unwrap("thermo")
            try expectClose(t.temperature ?? 0, 298.15, tol: 1e-9)
            try expectClose(t.zeroPointCorrection ?? 0, 0.023834, tol: 1e-9)
            try expectClose(t.sumElectronicThermalGibbs ?? 0, -74.959671, tol: 1e-9)
            let x = try r.result.thermochemistry.unwrap("summary")
            try expectClose(x.gibbsCorrection ?? 0, 0.006230, tol: 1e-9)
            try expectClose(x.electronicEnergy ?? 0, -74.942067 - 0.023834, tol: 1e-9)
        },
        Check("io.glog.orbitalsChargesDipole") {
            let r = try GaussianLog.parse(try glFixture("water_optfreq_td.log"))
            try expect(r.orbitals.alphaOccupied.count == 5 && r.orbitals.alphaVirtual.count == 2)
            try expect(!r.orbitals.isUnrestricted)
            try expectClose(r.orbitals.homo ?? 0, -0.39261, tol: 1e-9)
            try expectClose(r.orbitals.gap ?? 0, 0.58179 + 0.39261, tol: 1e-9)
            try expect(r.result.orbitals.count == 7 && r.result.orbitals.filter(\.occupied).count == 5)
            try expect(r.result.orbitals.allSatisfy { $0.spin == .restricted })
            try expect(r.mullikenCharges.count == 3)
            try expectClose(r.mullikenCharges.reduce(0, +), 0, tol: 1e-5)
            try expect(r.result.chargesByScheme["Mulliken"] == r.mullikenCharges)
            try expectClose(r.result.finalMolecule!.atoms[0].charge, -0.366733, tol: 1e-9)
            let d = try r.dipole.unwrap("dipole")
            try expectClose(d.z, -1.7094, tol: 1e-9)
            try expect(r.result.program == "gaussian")
            try expectClose(r.result.extras?.homoLumoGapEV ?? 0, (0.58179 + 0.39261) * 27.211386245988, tol: 1e-6)
        },
        Check("io.glog.tddft") {
            let r = try GaussianLog.parse(glTDSnippet)
            try expect(r.excitedStates.count == 3)
            let s = r.excitedStates
            try expectClose(s[0].energyEV, 3.9861, tol: 1e-9); try expectClose(s[0].wavelengthNM, 311.04, tol: 1e-9)
            try expectClose(s[2].oscillatorStrength, 0.0855, tol: 1e-9)
            try expect(s[0].multiplicity == 1 && s[1].symmetry == "B1", "\(String(describing: s[0].multiplicity)) \(String(describing: s[1].symmetry))")
            try expect(s[0].transitions.count == 1 && s[0].transitions[0].from == 8 && s[0].transitions[0].to == 9)
            try expect(s[1].transitions.count == 2 && s[1].transitions[1].isDeexcitation)
            try expectClose(s[0].totalEnergy ?? 0, -114.354748120, tol: 1e-9)
            try expect(r.result.excitedStates.count == 3 && r.result.excitedStates[1].symmetry == "B1")
            try expect(r.result.excitedStates[0].multiplicity == 1)
        },
        Check("io.glog.unrestrictedOrbitals") {
            let r = try GaussianLog.parse(glUHFSnippet)
            try expect(r.multiplicity == 2 && r.orbitals.isUnrestricted)
            try expect(r.orbitals.betaOccupied.count == 4 && r.orbitals.betaVirtual.count == 2)
            try expect(r.result.orbitals.filter { $0.spin == .beta }.count == 6)
            try expect(r.result.orbitals.filter { $0.spin == .alpha && $0.occupied }.count == 5)
            // SOMO-based gap: lowest of the two LUMOs minus highest HOMO
            try expect(r.orbitals.lumo != nil && r.orbitals.homo != nil)
        },
        Check("io.glog.scanAndIRC") {
            let g1 = glOrient([(8, 0, 0, 0), (1, 0, 0, 0.9)]), g2 = glOrient([(8, 0, 0, 0), (1, 0, 0, 1.0)])
            let scan = glHead + " #p hf/sto-3g opt=modredundant\n Charge =  0 Multiplicity = 2\n"
                + " Step number   1 out of a maximum of   20 on scan point     1 out of     2\n" + g1
                + " SCF Done:  E(UHF) =  -74.30000000     A.U. after    5 cycles\n Optimization completed.\n    -- Stationary point found.\n"
                + " Step number   1 out of a maximum of   20 on scan point     2 out of     2\n" + g2
                + " SCF Done:  E(UHF) =  -74.31000000     A.U. after    5 cycles\n Optimization completed.\n    -- Stationary point found.\n"
                + " Normal termination of Gaussian 16 at Mon Nov 23 10:00:00 2026.\n"
            let s = try GaussianLog.parse(scan)
            try expect(s.scanPoints.count == 2, "scan points \(s.scanPoints.count)")
            try expect(s.scanPoints.map(\.index) == [1, 2] && s.scanPoints[1].total == 2)
            try expectClose(s.scanPoints[1].energy ?? 0, -74.31, tol: 1e-9)
            try expectClose(s.scanPoints[0].geometry?.atoms[1].position.z ?? 0, 0.9, tol: 1e-9)

            let irc = glHead + " #p irc=calcfc hf/sto-3g\n Charge =  0 Multiplicity = 2\n" + g1
                + " SCF Done:  E(UHF) =  -74.30000000     A.U. after    5 cycles\n"
                + " Point Number:   1          Path Number:   1\n"
                + " NET REACTION COORDINATE UP TO THIS POINT =    0.09999\n" + g2
                + " SCF Done:  E(UHF) =  -74.31000000     A.U. after    5 cycles\n"
                + " Point Number:   2          Path Number:   1\n"
                + " NET REACTION COORDINATE UP TO THIS POINT =    0.19998\n"
                + " Normal termination of Gaussian 16 at Mon Nov 23 10:00:00 2026.\n"
            let i = try GaussianLog.parse(irc)
            try expect(i.ircPoints.count == 2, "irc \(i.ircPoints.count)")
            try expectClose(i.ircPoints[1].reactionCoordinate ?? 0, 0.19998, tol: 1e-9)
            try expect(i.ircPoints[1].path == 1 && i.ircPoints[1].point == 2)
        },
        Check("io.glog.crlfAndFortranD") {
            let s = try glFixture("water_optfreq_td.log")
            let a = try GaussianLog.parse(s)
            let b = try GaussianLog.parse(s.replacingOccurrences(of: "\n", with: "\r\n"))
            try expect(a == b, "CRLF parse differs")
            // "Predicted change in Energy=-1.512313D-03" uses a Fortran D exponent
            try expectClose(a.optimizationSteps[0].predictedEnergyChange ?? 0, -1.512313e-3, tol: 1e-12)
        },
        Check("io.glog.errorTermination") {
            let t = glHead + " #p hf/sto-3g opt\n Charge =  0 Multiplicity = 1\n" + glOrient([(2, 0, 0, 0)])
                + " SCF Done:  E(RHF) =  -2.80778     A.U. after    3 cycles\n"
                + " Error termination via Lnk1e in /opt/g16/l9999.exe at Mon Nov 23 10:00:00 2026.\n"
            let r = try GaussianLog.parse(t)
            try expect(r.errorTermination && !r.normalTermination)
            try expect(r.errorMessage?.contains("l9999") == true)
            try expect(r.result.extras?.messages.isEmpty == false)
        },
        Check("io.glog.truncatedAndMalformed") {
            try glThrows("empty") { _ = try GaussianLog.parse("") }
            try glThrows("garbage") { _ = try GaussianLog.parse("hello\nworld\n1 2 3\n") }
            try glThrows("xyz file") { _ = try GaussianLog.parse("3\nwater\nO 0 0 0\nH 0 0 1\nH 0 1 0\n") }
            let s = try glFixture("water_optfreq_td.log")
            let lines = s.split(separator: "\n", omittingEmptySubsequences: false)
            // every prefix: must either throw MolIOError or parse; never crash; never claim normal termination early
            var parsed = 0
            for k in stride(from: 1, to: lines.count, by: 1) {
                let t = lines.prefix(k).joined(separator: "\n") + "\n"
                do {
                    let r = try GaussianLog.parse(t)
                    parsed += 1
                    if k < lines.count - 2 { try expect(!r.normalTermination || r.jobCount < 2 || r.normalTerminationCount >= 1) }
                } catch is MolIOError {}
            }
            try expect(parsed > lines.count / 2, "too many prefixes rejected: \(parsed)/\(lines.count)")
            // a cut mid-way through the last job never reports normal termination of that job
            let half = lines.prefix(lines.count - 12).joined(separator: "\n") + "\n"
            try expect(try GaussianLog.parse(half).normalTermination == false)
            // mid-line cuts never crash
            for f in stride(from: 0.01, to: 1.0, by: 0.013) {
                _ = try? GaussianLog.parse(String(s.prefix(Int(Double(s.count) * f))))
            }
        },
    ]
}

extension Optional {
    fileprivate func unwrap(_ what: String) throws -> Wrapped {
        guard let v = self else { throw CheckFailure(description: "missing \(what)") }
        return v
    }
}
