import Foundation
import MolCore
import MolIO

// fchk / CalcSpec / loader checks (Lead A, round 2).

fileprivate func lcFixture(_ name: String) throws -> String { try readText(testDataURL("io/" + name)) }

fileprivate func lcThrows(_ label: String, _ body: () throws -> Void) throws {
    do { try body() } catch is MolIOError { return } catch { throw CheckFailure(description: "\(label): non-MolIOError \(error)") }
    throw CheckFailure(description: "expected a throw: \(label)")
}

fileprivate func lcWater() -> Molecule {
    Molecule(atoms: [Atom(id: 0, atomicNumber: 8, position: Vec3(0, 0, 0.117)),
                     Atom(id: 1, atomicNumber: 1, position: Vec3(0, 0.757, -0.469)),
                     Atom(id: 2, atomicNumber: 1, position: Vec3(0, -0.757, -0.469))], title: "water")
}

extension Checks {
    static let ioCalcSpec: [Check] = [
        // MARK: fchk
        Check("io.fchk.h2Basic") {
            let f = try FormattedCheckpoint.parse(try lcFixture("fchk/h2_sto3g.fchk"))
            try expect(f.molecule.atoms.count == 2 && f.alphaElectrons == 1 && f.betaElectrons == 1)
            try expectClose(f.molecule.atoms[1].position.z, 0.699198669 * bohrToAngstrom, tol: 1e-9)
            try expectClose(f.scfEnergy ?? 0, -1.117505879, tol: 1e-9)
            let w = try f.wavefunction.unwrapLC("wavefunction")
            try expect(w.basis.shells.count == 2 && w.basis.functionCount == 2)
            try expect(w.basis.shellTypes == [0, 0] && w.basis.shellToAtomMap == [1, 2] && w.basis.primitivesPerShell == [3, 3])
            try expect(w.alpha.orbitalCount == 2 && w.beta == nil && !w.isUnrestricted && w.homoIndex == 0)
            try expectClose(w.alpha.orbital(0).first!, 0.548934, tol: 1e-9)
            try expectClose(w.alpha.energies[1], 0.670331, tol: 1e-9)
            try expectClose(w.nuclearPositions[1].z, 0.699198669, tol: 1e-12)   // Bohr
            try expect(w.totalDensity?.count == 3)
            try expect(f.calculationResult.orbitals.count == 2)
        },
        Check("io.fchk.mixedShellsAndDExponents") {
            let f = try FormattedCheckpoint.parse(try lcFixture("fchk/h2_mixed_shells.fchk"))
            let w = try f.wavefunction.unwrapLC("wavefunction")
            let b = w.basis
            try expect(b.shellTypes == [-1, 0, -2, 2], "types \(b.shellTypes)")
            try expect(b.functionCount == 16 && b.shellOffsets == [0, 4, 5, 10])
            try expect(b.shells[0].isSP && b.shells[0].spCoefficients == [0.4, 0.7])
            try expect(b.shells[2].isPure && b.shells[2].functionCount == 5 && !b.shells[3].isPure && b.shells[3].functionCount == 6)
            try expect(b.spContractionCoefficients == [0.4, 0.7, 0, 0, 0, 0, 0])
            try expect(b.primitiveExponents.count == 7 && b.contractionCoefficients.count == 7)
            try expect(b.shellCoordinates[3] == Vec3(0, 0, 0.699198669))
            try expect(w.isUnrestricted && w.alphaElectrons == 2 && w.betaElectrons == 1)
            try expect(w.beta?.occupiedCount == 1 && w.beta?.orbitalCount == 16)
            try expectClose(w.beta!.energies[0], -0.4, tol: 1e-12)
            try expect(f.molecule.multiplicity == 2)
        },
        Check("io.fchk.crlfTruncatedMalformed") {
            let s = try lcFixture("fchk/h2_mixed_shells.fchk")
            try expect(try FormattedCheckpoint.parse(s.replacingOccurrences(of: "\n", with: "\r\n")) == FormattedCheckpoint.parse(s))
            let lines = s.split(separator: "\n", omittingEmptySubsequences: false)
            // cutting inside any array must throw (declared N= is larger than what is present)
            for k in 3..<(lines.count - 2) where lines[k].hasPrefix("  ") || lines[k].hasPrefix("    ") {
                let t = lines.prefix(k).joined(separator: "\n") + "\n"
                do { _ = try FormattedCheckpoint.parse(t) } catch is MolIOError { continue }
                // a prefix that ends exactly at the end of an array may parse; it must then be self-consistent
                if let w = try FormattedCheckpoint.parse(t).wavefunction { try expect(w.alpha.basisCount == w.basis.functionCount) }
            }
            try lcThrows("empty") { _ = try FormattedCheckpoint.parse("") }
            try lcThrows("garbage") { _ = try FormattedCheckpoint.parse("a\nb\nc d e\n") }
            try lcThrows("bad count") { _ = try FormattedCheckpoint.parse(s.replacingOccurrences(of: "Number of basis functions                  I               16", with: "Number of basis functions                  I               15")) }
            try lcThrows("shell atom out of range") { _ = try FormattedCheckpoint.parse(s.replacingOccurrences(of: "           1           2           1           2", with: "           1           2           1           9")) }
            for f in stride(from: 0.02, to: 1.0, by: 0.017) { _ = try? FormattedCheckpoint.parse(String(s.prefix(Int(Double(s.count) * f)))) }
        },

        // MARK: CalcSpec
        Check("io.calcspec.validation") {
            var s = CalcSpec(program: .orca, task: .optimizeAndFrequencies, method: "B3LYP", basis: "def2-SVP", molecule: lcWater())
            try expect(s.validationErrors().isEmpty, "\(s.validationErrors())")
            try expect(s.includesOptimization && s.includesFrequencies && !s.isUnrestricted)
            s.molecule.multiplicity = 2
            try expect(s.validationErrors().contains { $0.contains("inconsistent") })
            s.molecule.multiplicity = 3
            try expect(s.validationErrors().isEmpty && s.isUnrestricted)
            s.task = .scan
            try expect(s.validationErrors().contains { $0.contains("scan") })
            s.scan = ScanCoordinate(atoms: [0, 1], start: 0.9, end: 1.2, steps: 4)
            try expect(s.validationErrors().isEmpty)
            try expectClose(s.scan!.stepSize, 0.1, tol: 1e-12)
            s.basis = ""
            try expect(s.validationErrors().contains { $0.contains("basis") })
            s.method = "r2SCAN-3c"
            try expect(s.validationErrors().isEmpty)
            var x = CalcSpec(program: .xtb, task: .optimize, method: "GFN2-xTB", molecule: lcWater())
            try expect(x.validationErrors().isEmpty)
            x.excitedStates = ExcitedStatesSpec(roots: 3)
            try expect(!x.validationErrors().isEmpty)
            do { _ = try CalcInputWriter.write(x); throw CheckFailure(description: "invalid spec written") } catch is MolIOError {}
        },
        Check("io.calcspec.gaussianAdapter") {
            var s = CalcSpec(program: .gaussian, task: .optimizeAndFrequencies, method: "B3LYP", basis: "6-31G(d)", molecule: lcWater())
            s.dispersion = .d3bj
            s.solvation = Solvation(model: .smd, solvent: "Water")
            s.excitedStates = ExcitedStatesSpec(roots: 3)
            s.nprocs = 4; s.memoryMB = 4000; s.checkpointName = "w"
            let text = try CalcInputWriter.write(s)
            let jobs = try GaussianInputReader.parse(text)
            try expect(jobs.count == 1)
            let j = jobs[0]
            try expect(j.link0.nprocShared == 4 && j.link0.checkpoint == "w.chk" && j.link0.memory == "4000MB")
            let r = j.route.text.lowercased()
            for k in ["b3lyp/6-31g(d)", "opt", "freq", "td(nstates=3)", "gd3bj", "smd", "water"] { try expect(r.contains(k), "route lacks \(k): \(r)") }
            try expect(j.molecule.atoms.count == 3)
            try expectClose(j.molecule.atoms[1].position.y, 0.757, tol: 1e-6)
            // scan + frozen atom → ModRedundant section
            var sc = CalcSpec(program: .gaussian, task: .scan, method: "HF", basis: "STO-3G", molecule: lcWater())
            sc.scan = ScanCoordinate(atoms: [0, 1], start: 0.9, end: 1.3, steps: 5)
            sc.frozenAtoms = [2]
            let t2 = try CalcInputWriter.write(sc)
            try expect(t2.contains("B 1 2 S 4 0.1000") && t2.contains("X 3 F") && t2.lowercased().contains("modredundant"), t2)
            try expect(try GaussianInputReader.parse(t2)[0].modRedundant.count == 2)
        },
    ]
}

extension Optional {
    fileprivate func unwrapLC(_ what: String) throws -> Wrapped {
        guard let v = self else { throw CheckFailure(description: "missing \(what)") }
        return v
    }
}
