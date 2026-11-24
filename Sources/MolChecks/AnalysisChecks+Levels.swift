import Foundation
import simd
import MolCore
import MolIO
import MolAnalysis

// Round 3 (Lead D): orbital level diagram, density of states, vibrational-mode labels.

private func orca(_ name: String) -> URL { testDataURL("io/orca/\(name)") }

extension Checks {
    static let analysisLevels: [Check] = [
        Check("analysis.levels.diagramRestricted") {
            guard let wf = try MoldenFile.read(url: orca("h2co_tddft.molden.input")).wavefunction else { throw CheckFailure(description: "no wf") }
            let d = OrbitalLevelDiagram(wavefunction: wf)
            try expect(d.columns.count == 1 && d.columns[0].spin == .restricted)
            let c = d.columns[0]
            let homo = try c.homo.need("homo"), lumo = try c.lumo.need("lumo")
            try expect(homo.orbitalIndices == [7] && homo.occupation == 2, "\(homo)")
            try expect(lumo.orbitalIndices == [8] && lumo.occupation == 0 && lumo.label == "LUMO", "\(lumo)")
            try expect(c.levels.reduce(0) { $0 + $1.degeneracy } == wf.alpha.orbitalCount)
            let gap = try d.homoLumoGapEV.need("gap")
            print(String(format: "    h2co HOMO %.3f eV, LUMO %.3f eV, gap %.3f eV, %d levels", homo.energyEV, lumo.energyEV, gap, c.levels.count))
            try expect(gap > 3 && gap < 15, "gap \(gap)")
            try expect(c.levels.contains { $0.label == "HOMO−1" } && c.levels.contains { $0.label == "LUMO+1" })
        },
        Check("analysis.levels.degeneracyAndUnrestricted") {
            // Synthetic: a doubly degenerate HOMO pair is grouped; occupied and virtual are never merged.
            let col = OrbitalLevelDiagram.column(energies: [-1.0, -0.5, -0.5004, 0.1, 0.1002, 0.3],
                                                 occupations: [2, 2, 2, 0, 0, 0], spin: .restricted)
            try expect(col.levels.map(\.degeneracy) == [1, 2, 2, 1], "\(col.levels.map(\.degeneracy))")
            try expect(col.homo?.orbitalIndices.sorted() == [1, 2] && col.lumo?.orbitalIndices.sorted() == [3, 4])
            // A near-degenerate occupied/virtual pair is never merged.
            let mixed = OrbitalLevelDiagram.column(energies: [-0.5, -0.5001], occupations: [0, 2], spin: .restricted)
            try expect(mixed.levels.count == 2 && mixed.homo?.orbitalIndices == [1] && mixed.lumo?.orbitalIndices == [0])
            guard let wf = try MoldenFile.read(url: orca("oh_uhf.molden.input")).wavefunction else { throw CheckFailure(description: "no wf") }
            let d = OrbitalLevelDiagram(wavefunction: wf)
            try expect(d.columns.map(\.spin) == [.alpha, .beta], "\(d.columns.map(\.spin))")
            try expect(d.columns[0].homo?.orbitalIndices.max() == wf.alphaElectrons - 1)
            try expect(d.columns[1].homo?.orbitalIndices.max() == wf.betaElectrons - 1)
            // From parsed tables (1-based indices).
            let infos = [OrbitalInfo(index: 1, energy: -0.6, occupied: true), OrbitalInfo(index: 2, energy: -0.3, occupied: true),
                         OrbitalInfo(index: 3, energy: 0.05, occupied: false)]
            let t = OrbitalLevelDiagram(orbitals: infos)
            try expect(t.columns.first?.homo?.orbitalIndices == [1] && t.columns.first?.lumo?.orbitalIndices == [2])
        },
        Check("analysis.levels.dos") {
            let s = DensityOfStates.compute(energies: [-0.5, -0.3, 0.1].map { $0 / PhysConst.hartreeToEV * 10 }, fwhmEV: 0.4,
                                            rangeEV: -12...6, pointCount: 3000)
            let dx = s.points[1].x - s.points[0].x
            let area = s.points.reduce(0) { $0 + $1.y } * dx
            try expect(abs(area - 3) < 0.01, "area \(area)")
            try expect(s.sticks.count == 3 && s.xLabel.contains("eV"))
            let peak = s.points.max { $0.y < $1.y }!
            try expect([-5.0, -3.0, 1.0].contains { abs($0 - peak.x) < 0.05 }, "peak \(peak.x)")
            guard let wf = try MoldenFile.read(url: orca("h2co_tddft.molden.input")).wavefunction else { throw CheckFailure(description: "no wf") }
            let (tot, occ) = DensityOfStates.compute(wf, fwhmEV: 0.5, rangeEV: -620...40, pointCount: 40000)
            let h = tot.points[1].x - tot.points[0].x
            let occArea = occ.points.reduce(0) { $0 + $1.y } * h
            try expect(abs(occArea - 16) < 0.2, "occupied DOS area \(occArea) (16 electrons)")
            try expect(zip(tot.points, occ.points).allSatisfy { $0.y >= $1.y - 1e-12 })
        },
        Check("analysis.evaluateAsync.cancel") {
            // Regression: cancellation used to be invisible to the concurrentPerform workers.
            guard let wf = try MoldenFile.read(url: orca("h2co_tddft.molden.input")).wavefunction else { throw CheckFailure(description: "no wf") }
            let ev = OrbitalEvaluator(wavefunction: wf)
            let grid = GridSpec.automatic(around: WavefunctionSurfaces.atomPositions(wf), padding: 6, spacing: 0.04, maxPoints: 40_000_000)
            let coeffs = Array(wf.alpha.orbital(7))
            let r: (cancelled: Bool, secs: Double) = try computeRunAsync(timeout: 120) {
                let t = Task { try await ev.evaluateAsync(.orbital(coeffs), on: grid) }
                try await Task.sleep(nanoseconds: 100_000_000)
                let c0 = Date()
                t.cancel()
                do { _ = try await t.value; return (false, Date().timeIntervalSince(c0)) } catch { return (error is CancellationError, Date().timeIntervalSince(c0)) }
            }
            print(String(format: "    %d points, cancel honoured in %.3f s", grid.pointCount, r.secs))
            try expect(r.cancelled, "evaluation finished instead of cancelling")
            try expect(r.secs < 2, "cancel took \(r.secs) s")
        },
        Check("analysis.vib.waterSynthetic") {
            let O = Vec3(0, 0, 0.1173), H1 = Vec3(0, 0.7572, -0.4692), H2 = Vec3(0, -0.7572, -0.4692)
            var w = Molecule(atoms: [Atom(id: 0, atomicNumber: 8, position: O), Atom(id: 1, atomicNumber: 1, position: H1),
                                     Atom(id: 2, atomicNumber: 1, position: H2)])
            w.bonds = [Bond(0, 1), Bond(0, 2)]
            let u1 = simd_normalize(H1 - O), u2 = simd_normalize(H2 - O)
            func mode(_ d: [Vec3], _ f: Double = 1600) -> NormalMode { NormalMode(frequency: f, irIntensity: 1, displacements: d) }
            let sym = VibrationalModeAnalysis.analyze(mode: mode([-(u1 + u2) / 16, u1, u2]), molecule: w)
            let asym = VibrationalModeAnalysis.analyze(mode: mode([-(u1 - u2) / 16, u1, -u2]), molecule: w)
            let p1 = simd_normalize(simd_cross(simd_cross(u1, u2), u1)), p2 = simd_normalize(simd_cross(simd_cross(u2, u1), u2))
            let bend = VibrationalModeAnalysis.analyze(mode: mode([-(p1 + p2) / 16, p1, p2]), molecule: w)
            print("    \(sym.label) | \(asym.label) | \(bend.label)")
            try expect(sym.label == "O–H stretch (sym)", sym.label)
            try expect(asym.label == "O–H stretch (asym)", asym.label)
            try expect(bend.label == "H–O–H bend", bend.label)
            try expect(abs(sym.contributions.reduce(0) { $0 + $1.percent } - 100) < 1e-6)
        },
        Check("analysis.vib.h2coRealModes") {
            let hess = try OrcaHessian.read(url: orca("h2co_optfreq.hess"))
            let modes = hess.normalModes
            let labels = VibrationalModeAnalysis.labels(for: modes, molecule: hess.molecule)
            for (m, l) in zip(modes, labels) { print(String(format: "    %7.1f cm-1  %@", m.frequency, l)) }
            try expect(modes.count == 6, "\(modes.count) modes")
            let byFreq = zip(modes.map(\.frequency), labels).sorted { $0.0 < $1.0 }
            try expect(byFreq[5].1.hasPrefix("C–H stretch (asym)"), byFreq[5].1)
            try expect(byFreq[4].1.hasPrefix("C–H stretch (sym)"), byFreq[4].1)
            try expect(byFreq[3].1.contains("C=O stretch"), byFreq[3].1)
            try expect(byFreq[0].1.contains("C out-of-plane bend"), byFreq[0].1)
            try expect(byFreq[2].1.contains("H–C–H bend") || byFreq[2].1.contains("H–C–O bend"), byFreq[2].1)
        },
    ]
}

fileprivate extension Optional {
    func need(_ what: String) throws -> Wrapped {
        guard let v = self else { throw CheckFailure(description: "missing \(what)") }
        return v
    }
}
