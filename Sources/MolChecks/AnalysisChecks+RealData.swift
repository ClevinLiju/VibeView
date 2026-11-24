import Foundation
import simd
import MolCore
import MolIO
import MolAnalysis

// Lead D round 2: orbitals, densities, ESP, spectra and thermochemistry from the real ORCA 6 fixtures in
// TestData/io/orca (read through Lead A's MolIO readers) plus the fchk fixtures.

private func orcaURL(_ name: String) -> URL { testDataURL("io/orca/\(name)") }
private func msSince(_ t0: DispatchTime) -> Double { Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6 }

private func moldenWavefunction(_ name: String) throws -> Wavefunction {
    guard let wf = try MoldenFile.read(url: orcaURL(name)).wavefunction else {
        throw CheckFailure(description: "no wavefunction in \(name)")
    }
    return wf
}

/// ∫ a·b on a Becke grid (orbital overlaps; exact enough to verify normalization conventions).
private func beckeOverlap(_ ev: OrbitalEvaluator, _ q: MolecularQuadrature, _ a: [Double], _ b: [Double]) -> Double {
    let va = ev.evaluate(.orbital(a), atBohr: q.points), vb = ev.evaluate(.orbital(b), atBohr: q.points)
    return q.integrate(zip(va, vb).map { $0 * $1 })
}

/// "Label ... value Eh" from an ORCA thermochemistry block (last occurrence).
private func orcaValue(_ text: String, _ label: String) -> Double? {
    var v: Double?
    for line in text.split(separator: "\n") where line.hasPrefix(label) {
        let toks = line.replacingOccurrences(of: "...", with: " ").split(separator: " ")
        if let i = toks.firstIndex(of: "Eh"), i > 0, let d = Double(toks[i - 1]) { v = d }
    }
    return v
}

extension Checks {
    static let analysisRealData: [Check] = [
        Check("analysis.realdata.orcaMoldenOrbitals") {
            // HOMO normalization + MO orthogonality (Becke grid), electron counts (Becke and uniform grid).
            let cases: [(String, Int, Int)] = [("water_optfreq.molden.input", 5, 5), ("oh_uhf.molden.input", 5, 4), ("h2co_tddft.molden.input", 8, 8)]
            for (name, na, nb) in cases {
                let wf = try moldenWavefunction(name)
                try expect(wf.alphaElectrons == na && wf.betaElectrons == nb, "\(name) electrons \(wf.alphaElectrons)/\(wf.betaElectrons)")
                let ev = OrbitalEvaluator(wavefunction: wf)
                let q = MolecularQuadrature(wavefunction: wf)
                guard let homo = wf.homoIndex else { throw CheckFailure(description: "no HOMO") }
                let h = Array(wf.alpha.orbital(homo))
                let nH = beckeOverlap(ev, q, h, h)
                var worst = abs(nH - 1)
                for mo in 0..<min(wf.alpha.orbitalCount, homo + 3) {
                    let c = Array(wf.alpha.orbital(mo))
                    worst = max(worst, abs(beckeOverlap(ev, q, c, c) - 1))
                    if mo != homo { worst = max(worst, abs(beckeOverlap(ev, q, c, h))) }
                }
                let t0 = DispatchTime.now()
                let n = WavefunctionSurfaces.electronCount(wf, quadrature: q, evaluator: ev)
                let tN = msSince(t0)
                let spin = WavefunctionSurfaces.electronCount(wf, kind: .spin, quadrature: q, evaluator: ev)
                // Uniform HOMO grid (what the viewer draws).
                let grid = WavefunctionSurfaces.defaultGrid(wf, padding: 5.0, spacing: 0.08, maxPoints: 8_000_000)
                let g = WavefunctionSurfaces.orbitalGrid(wf, mo: homo, grid: grid, evaluator: ev)
                let sq = g.values.reduce(0.0) { $0 + Double($1) * Double($1) } * grid.voxelVolume * pow(PhysConst.angstromToBohr, 3)
                let rhoU = WavefunctionSurfaces.densityGrid(wf, grid: grid, evaluator: ev).integral() * pow(PhysConst.angstromToBohr, 3)
                print("    \(name): nbf=\(ev.functionCount) Becke \(q.pointCount) pts: <HOMO|HOMO>=\(String(format: "%.6f", nH)) max|S−δ|=\(String(format: "%.1e", worst)) ∫ρ=\(String(format: "%.5f", n)) (\(na + nb) e, \(String(format: "%.0f", tN)) ms) ∫ρs=\(String(format: "%.5f", spin)); uniform 0.08 Å: ∫|HOMO|²=\(String(format: "%.5f", sq)) ∫ρ=\(String(format: "%.3f", rhoU))")
                try expect(worst < 1e-4, "\(name) orthonormality \(worst)")
                try expect(abs(n - Double(na + nb)) < 2e-3, "\(name) ∫ρ = \(n)")
                try expect(abs(spin - Double(na - nb)) < 2e-3, "\(name) ∫ρs = \(spin)")
                try expect(abs(sq - 1) < 5e-3, "\(name) uniform ∫|HOMO|² = \(sq)")
            }
        },
        Check("analysis.realdata.fchkConventions") {
            // fchk path: MO-built density matrix vs the stored Total SCF Density, and electron counts.
            for name in ["h2_sto3g.fchk", "h2_mixed_shells.fchk"] {
                guard let wf = try FormattedCheckpoint.read(url: testDataURL("io/fchk/\(name)")).wavefunction else {
                    throw CheckFailure(description: "no wavefunction in \(name)") }
                let nbf = wf.basis.functionCount
                let pMO = WavefunctionSurfaces.densityMatrix(wf)
                let q = MolecularQuadrature(wavefunction: wf)
                let ev = OrbitalEvaluator(wavefunction: wf)
                let nMO = q.integrate(ev.evaluate(.densityMatrix(pMO), atBohr: q.points))
                var line = "    \(name): nbf=\(nbf) ∫ρ(MO)=\(String(format: "%.5f", nMO))"
                if let packed = wf.totalDensity, let pF = PackedMatrix.unpackLowerTriangle(packed, n: nbf) {
                    let nF = q.integrate(ev.evaluate(.densityMatrix(pF), atBohr: q.points))
                    let dmax = zip(pMO, pF).map { abs($0 - $1) }.max() ?? 0
                    line += " ∫ρ(fchk P)=\(String(format: "%.5f", nF)) max|P_MO−P_fchk|=\(String(format: "%.1e", dmax))"
                    // The fixtures are hand-written: h2_sto3g stores P rounded to 0.6 (MO-built 0.6027); mixed shells is synthetic.
                    if name == "h2_sto3g.fchk" { try expect(dmax < 5e-3 && abs(nF - 2) < 1e-2, "\(name) density matrices differ by \(dmax)") }
                }
                print(line)
                // MO-built density integrates to the electron count (SP, s, pure d and Cartesian d shells in the mixed file).
                try expect(abs(nMO - Double(wf.alphaElectrons + wf.betaElectrons)) < 1e-3, "∫ρ = \(nMO)")
            }
        },
        Check("analysis.realdata.grid80Timing") {
            let wf = try moldenWavefunction("h2co_tddft.molden.input")
            let ev = OrbitalEvaluator(wavefunction: wf)
            let base = WavefunctionSurfaces.defaultGrid(wf, padding: 4.0, spacing: 0.1)
            // 80³ box with the default extent.
            let ext = (0..<3).map { Double(base.counts[$0] - 1) * simd_length(base.axes[$0]) }
            let spec = GridSpec(origin: base.origin, axes: (0..<3).map { a in var v = Vec3.zero; v[a] = ext[a] / 79; return v }, counts: [80, 80, 80])
            let t0 = DispatchTime.now()
            let g = WavefunctionSurfaces.orbitalGrid(wf, mo: wf.homoIndex!, grid: spec, evaluator: ev)
            let tMO = msSince(t0)
            let t1 = DispatchTime.now()
            _ = WavefunctionSurfaces.densityGrid(wf, grid: spec, evaluator: ev)
            let tD = msSince(t1)
            let t2 = DispatchTime.now()
            let lobes = MarchingCubes.orbitalLobes(grid: g, isovalue: 0.03)
            let tMC = msSince(t2)
            print("    h2co def2-SVP (\(ev.functionCount) bf) 80³: HOMO \(String(format: "%.0f", tMO)) ms, density (8 occ) \(String(format: "%.0f", tD)) ms, MC \(String(format: "%.0f", tMC)) ms (\(lobes[0].triangleCount + lobes[1].triangleCount) tris)")
            try expect(lobes.allSatisfy { !$0.isEmpty && MarchingCubes.isClosedManifold($0) })
        },
        Check("analysis.realdata.espH2CO") {
            let wf = try moldenWavefunction("h2co_tddft.molden.input")
            let t0 = DispatchTime.now()
            let mesh = WavefunctionSurfaces.espMappedDensity(wf, isovalue: 0.001)
            let t = msSince(t0)
            guard let s = mesh.vertexScalars, let colors = mesh.vertexColors else { throw CheckFailure(description: "no ESP") }
            try expect(colors.count == mesh.vertices.count && MarchingCubes.isClosedManifold(mesh))
            let pos = WavefunctionSurfaces.atomPositions(wf)
            let oIdx = wf.atomicNumbers.firstIndex(of: 8)!, hIdx = wf.atomicNumbers.firstIndex(of: 1)!
            func nearest(_ p: Vec3) -> Int { mesh.vertices.indices.min { simd_distance(SIMD3<Double>(mesh.vertices[$0]), p) < simd_distance(SIMD3<Double>(mesh.vertices[$1]), p) }! }
            let sO = s[nearest(pos[oIdx])], sH = s[nearest(pos[hIdx])]
            print("    h2co ESP on ρ=0.001: \(mesh.vertices.count) verts, near O \(String(format: "%.4f", sO)), near H \(String(format: "%.4f", sH)) Eh/e, \(String(format: "%.0f", t)) ms")
            try expect(sO < 0 && sH > 0)
        },
        Check("analysis.realdata.orcaThermo") {
            // ORCA 6 thermochemistry (298.15 K, 1 atm, its default quasi-RRHO entropy) reproduced from the parsed output.
            for name in ["water_optfreq.out", "h2co_optfreq.out"] {
                let text = try String(contentsOf: orcaURL(name), encoding: .utf8)
                let out = try OrcaOutput.parse(text)
                guard let inp = ThermoInput(orca: out) else { throw CheckFailure(description: "ThermoInput(orca:) failed for \(name)") }
                let r = Thermochemistry.compute(inp, temperature: 298.15, pressure: 1, quasiRRHO: QuasiRRHO())
                let zpe = orcaValue(text, "Zero point energy")!, thermal = orcaValue(text, "Total thermal correction")!
                let hc = orcaValue(text, "Thermal Enthalpy correction")!, ts = -orcaValue(text, "Total entropy correction")!
                let g = orcaValue(text, "Final Gibbs free energy")!
                print("    \(name): \(inp.frequencies.count) freqs σ=\(r.symmetryNumber); ΔZPE=\(String(format: "%.1e", r.zeroPointEnergy - zpe)) ΔTS=\(String(format: "%.1e", r.tsTerm - ts)) ΔG=\(String(format: "%.1e", r.sumG - g)) Eh")
                try expectClose(r.zeroPointEnergy, zpe, tol: 2e-6)
                try expectClose(r.thermalEnergyCorrection - r.zeroPointEnergy, thermal, tol: 2e-6)
                try expectClose(r.enthalpyCorrection - r.thermalEnergyCorrection, hc, tol: 2e-6)
                try expectClose(r.tsTerm, ts, tol: 5e-6)
                try expectClose(r.sumG, g, tol: 5e-6)
                // Chosen T and P: pressure only changes S_trans by −R ln(P2/P1); G(T) is consistent with S = −∂G/∂T.
                let p2 = Thermochemistry.compute(inp, temperature: 350, pressure: 2, quasiRRHO: QuasiRRHO())
                let p1 = Thermochemistry.compute(inp, temperature: 350, pressure: 1, quasiRRHO: QuasiRRHO())
                try expectClose((p1.sTrans - p2.sTrans) * 4.184, 8.314462618 * log(2.0), tol: 1e-6)
                try expectClose(p2.sumG - p1.sumG, 8.314462618 * 350 * log(2.0) / 2625499.64, tol: 1e-8)
                let lo = Thermochemistry.compute(inp, temperature: 349.5, pressure: 1, quasiRRHO: QuasiRRHO())
                let hi = Thermochemistry.compute(inp, temperature: 350.5, pressure: 1, quasiRRHO: QuasiRRHO())
                let sNum = -(hi.sumG - lo.sumG) / 1.0 / Thermochemistry.calPerMolKToHartreePerK
                try expect(abs(sNum - p1.entropy) / p1.entropy < 2e-3, "S=-dG/dT \(sNum) vs \(p1.entropy)")
            }
        },
        Check("analysis.realdata.orcaSpectra") {
            // UV-Vis from the TDDFT output and IR from the frequency run, through the shared result model.
            let td = try OrcaOutput.read(url: orcaURL("h2co_tddft.out")).result
            try expect(!td.excitedStates.isEmpty)
            let uv = SpectrumBuilder.uvVis(states: td.excitedStates, fwhmEV: 0.3, axis: .energyEV)
            let strongest = td.excitedStates.max { $0.oscillatorStrength < $1.oscillatorStrength }!
            if strongest.oscillatorStrength > 1e-4 {
                let peak = uv.points.max { $0.y < $1.y }!
                try expect(abs(peak.x - strongest.energyEV) < 0.2, "UV peak \(peak.x) vs \(strongest.energyEV)")
            }
            let fr = try OrcaOutput.read(url: orcaURL("h2co_optfreq.out")).result
            let modes = fr.normalModes.filter { $0.frequency > 1 }
            try expect(modes.count == 6, "h2co modes \(modes.count)")
            let ir = SpectrumBuilder.ir(modes: modes, fwhm: 10)
            let top = modes.max { $0.irIntensity < $1.irIntensity }!
            let peak = ir.points.max { $0.y < $1.y }!
            print("    h2co: \(td.excitedStates.count) states, strongest \(String(format: "%.2f", strongest.energyEV)) eV f=\(strongest.oscillatorStrength); IR max \(String(format: "%.0f", peak.x)) cm⁻¹ (strongest stick \(String(format: "%.0f", top.frequency)))")
            try expect(abs(peak.x - top.frequency) < 5)
            try expect(modes.contains { $0.frequency > 1700 && $0.frequency < 1950 && $0.irIntensity > 10 }, "C=O stretch")
        },
    ]
}
