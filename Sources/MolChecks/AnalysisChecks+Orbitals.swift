import Foundation
import simd
import MolCore
import MolIO
import MolAnalysis

// Lead D: basis functions, MO / density grids, ESP, real ORCA molden data.
private let b2a = PhysConst.bohrToAngstrom

/// Cubic grid centred at the origin, half-width `w` Bohr, spacing `h` Bohr (returned in Å).
private func bohrGrid(halfWidth w: Double, spacing h: Double) -> GridSpec {
    let n = Int((2 * w / h).rounded()) + 1
    let s = h * b2a
    return GridSpec(origin: Vec3(repeating: -w * b2a), axes: [Vec3(s, 0, 0), Vec3(0, s, 0), Vec3(0, 0, s)], counts: [n, n, n])
}

/// ∫ a·b dV in Bohr³ over a grid.
private func overlap(_ a: VolumeGrid, _ b: VolumeGrid) -> Double {
    let dv = GridSpec(a).voxelVolume * pow(PhysConst.angstromToBohr, 3)
    var s = 0.0
    for i in a.values.indices { s += Double(a.values[i]) * Double(b.values[i]) }
    return s * dv
}

private func integrateBohr(_ g: VolumeGrid) -> Double { g.integral() * pow(PhysConst.angstromToBohr, 3) }

private func moldenWF(_ name: String) throws -> Wavefunction {
    try MoldenWavefunctionReader.read(url: testDataURL("analysis/\(name)"))
}

private func ms(_ t0: DispatchTime) -> Double { Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6 }

extension Checks {
    static let analysisOrbitals: [Check] = [
        Check("analysis.orbitals.solidHarmonics") {
            // Pure d(xy) equals the normalized Cartesian xy function; d(x²−y²) = (xx − yy)·√3/2 in normalized Cartesians.
            let pure = OrbitalEvaluator(basis: AnalysisBasis(shells: [AnalysisShell(center: .zero, atomIndex: 0, l: 2, pure: true, exponents: [0.7], coefficients: [1])]))
            let cart = OrbitalEvaluator(basis: AnalysisBasis(shells: [AnalysisShell(center: .zero, atomIndex: 0, l: 2, pure: false, exponents: [0.7], coefficients: [1])]))
            let pts = [Vec3(0.3, -0.4, 0.7), Vec3(-1.1, 0.2, 0.5)]
            let p = pure.basisValues(atBohr: pts), c = cart.basisValues(atBohr: pts)
            for k in pts.indices {
                try expectClose(p[k][4], c[k][3], tol: 1e-12)                          // m = −2 ↔ xy
                try expectClose(p[k][3], (c[k][0] - c[k][1]) * 3.0.squareRoot() / 2, tol: 1e-12)  // m = +2
                try expectClose(p[k][1], c[k][4], tol: 1e-12)                          // m = +1 ↔ xz
            }
        },
        Check("analysis.orbitals.normalization") {
            // Every function of s…g shells (pure and Cartesian, plus a 2-primitive contraction and SP) has unit norm;
            // pure functions within a shell are orthogonal.
            let grid = bohrGrid(halfWidth: 7.5, spacing: 0.15)
            var worst = 0.0, worstOff = 0.0
            for l in 0...4 {
                for pure in [false, true] where !(pure && l < 2) {
                    let shell = AnalysisShell(center: .zero, atomIndex: 0, l: l, pure: pure, exponents: [1.3, 0.4], coefficients: [0.6, 0.5])
                    let ev = OrbitalEvaluator(basis: AnalysisBasis(shells: [shell]))
                    let n = ev.functionCount
                    var grids: [VolumeGrid] = []
                    for f in 0..<n {
                        var c = [Double](repeating: 0, count: n); c[f] = 1
                        grids.append(ev.moGrid(coefficients: c, grid: grid))
                    }
                    for f in 0..<n {
                        let s = overlap(grids[f], grids[f])
                        worst = max(worst, abs(s - 1))
                        try expect(abs(s - 1) < 1e-4, "l=\(l) pure=\(pure) f=\(f): \(s)")
                        if pure { for g in 0..<f { worstOff = max(worstOff, abs(overlap(grids[f], grids[g]))) } }
                    }
                }
            }
            let sp = AnalysisShell(center: .zero, atomIndex: 0, l: 1, pure: false, exponents: [2.0, 0.5], coefficients: [-0.1, 1.0], spCoefficients: [0.3, 0.8])
            let ev = OrbitalEvaluator(basis: AnalysisBasis(shells: [sp]))
            for f in 0..<4 {
                var c = [Double](repeating: 0, count: 4); c[f] = 1
                let g = ev.moGrid(coefficients: c, grid: grid)
                try expect(abs(overlap(g, g) - 1) < 1e-4, "SP f=\(f)")
            }
            print("    max |<χ|χ>−1| = \(String(format: "%.2e", worst)), max pure off-diagonal = \(String(format: "%.2e", worstOff))")
            try expect(worstOff < 1e-4)
        },
        Check("analysis.orbitals.hydrogen1s") {
            // A single normalized primitive is exactly (2α/π)^{3/4} e^{−αr²}.
            let a = 0.85
            let ev1 = OrbitalEvaluator(basis: AnalysisBasis(shells: [AnalysisShell(center: .zero, atomIndex: 0, l: 0, pure: false, exponents: [a], coefficients: [1])]))
            for r in [0.0, 0.5, 1.0, 2.5] {
                try expectClose(ev1.values(coefficients: [1], atBohr: [Vec3(0, r, 0)])[0], pow(2 * a / .pi, 0.75) * exp(-a * r * r), tol: 1e-12)
            }
            // STO-3G (ζ = 1) against the analytic hydrogen 1s, ψ = e^{−r}/√π.
            let sto = AnalysisShell(center: .zero, atomIndex: 0, l: 0, pure: false,
                                    exponents: [2.227660584, 0.405771156, 0.109818036], coefficients: [0.154328967, 0.535328142, 0.444634542])
            let ev = OrbitalEvaluator(basis: AnalysisBasis(shells: [sto]))
            for r in [0.5, 1.0, 2.0] {
                let v = ev.values(coefficients: [1], atBohr: [Vec3(r, 0, 0)])[0]
                let exact = exp(-r) / Double.pi.squareRoot()
                try expect(abs(v - exact) / exact < 0.05, "r=\(r) \(v) vs \(exact)")
            }
            let grid = bohrGrid(halfWidth: 12, spacing: 0.12)
            let g = ev.moGrid(coefficients: [1], grid: grid)
            var s = 0.0
            for i in 0..<grid.counts[0] { for j in 0..<grid.counts[1] { for k in 0..<grid.counts[2] {
                let r = simd_length(grid.point(i, j, k)) * PhysConst.angstromToBohr
                s += Double(g.values[(i * grid.counts[1] + j) * grid.counts[2] + k]) * exp(-r) / Double.pi.squareRoot()
            } } }
            s *= grid.voxelVolume * pow(PhysConst.angstromToBohr, 3)
            print("    <STO-3G|1s> = \(String(format: "%.5f", s))")
            try expect(s > 0.99 && s < 1.0001)
        },
        Check("analysis.orbitals.espAnalytic") {
            // One electron in a normalized s Gaussian: V(r) = −erf(√(2α) r)/r.
            let a = 0.9
            let esp = ElectrostaticPotential(basis: AnalysisBasis(shells: [AnalysisShell(center: .zero, atomIndex: 0, l: 0, pure: false, exponents: [a], coefficients: [1])]),
                                             densityMatrix: [1], nuclearCharges: [], nuclearPositions: [])
            for r in [0.3, 1.0, 2.5, 7.0] {
                try expectClose(esp.evaluate(atBohr: [Vec3(r, 0, 0)])[0], -erf((2 * a).squareRoot() * r) / r, tol: 1e-9)
            }
            // Two-center overlap density: χ_Aχ_B = N_aN_b e^{−μ|AB|²} e^{−p|r−P|²}.
            let A = Vec3(0, 0, -0.7), B = Vec3(0, 0, 0.7), ea = 1.1, eb = 0.6
            let basis = AnalysisBasis(shells: [AnalysisShell(center: A, atomIndex: 0, l: 0, pure: false, exponents: [ea], coefficients: [1]),
                                               AnalysisShell(center: B, atomIndex: 1, l: 0, pure: false, exponents: [eb], coefficients: [1])])
            let e2 = ElectrostaticPotential(basis: basis, densityMatrix: [0, 0.5, 0.5, 0], nuclearCharges: [], nuclearPositions: [])
            let p = ea + eb, mu = ea * eb / p, P = (ea * A + eb * B) / p
            let pref = pow(2 * ea / .pi, 0.75) * pow(2 * eb / .pi, 0.75) * exp(-mu * simd_length_squared(A - B)) * pow(.pi / p, 1.5)
            for C in [Vec3(0.4, 0.2, 0.1), Vec3(2, -1, 3)] {
                let d = simd_length(C - P)
                try expectClose(e2.evaluate(atBohr: [C])[0], -pref * erf(p.squareRoot() * d) / d, tol: 1e-9)
            }
            // High angular momentum far field: a normalized f function looks like −1/r far away.
            let f = ElectrostaticPotential(basis: AnalysisBasis(shells: [AnalysisShell(center: .zero, atomIndex: 0, l: 3, pure: true, exponents: [0.8], coefficients: [1])]),
                                           densityMatrix: { var m = [Double](repeating: 0, count: 49); m[3 * 7 + 3] = 1; return m }(),
                                           nuclearCharges: [], nuclearPositions: [])
            let far = f.evaluate(atBohr: [Vec3(25, 13, -17)])[0]
            let r = simd_length(Vec3(25, 13, -17))
            try expect(abs(far * r + 1) < 1e-3, "far field \(far * r)")
        },
        Check("analysis.orbitals.waterHOMO") {
            // Real data: ORCA 6.1.1 HF water → orca_2mkl -molden. HOMO (1b1) must integrate to 1.
            for name in ["water_sto3g.molden", "water_tzvp.molden"] {
                let wf = try moldenWF(name)
                try expect(wf.alphaElectrons == 5 && wf.betaElectrons == 5 && !wf.isUnrestricted)
                guard let homo = wf.homoIndex else { throw CheckFailure(description: "no HOMO") }
                let ev = OrbitalEvaluator(wavefunction: wf)
                let grid = WavefunctionSurfaces.defaultGrid(wf, padding: 5.0, spacing: 0.06, maxPoints: 8_000_000)
                let t0 = DispatchTime.now()
                let g = WavefunctionSurfaces.orbitalGrid(wf, mo: homo, grid: grid, evaluator: ev)
                let t = ms(t0)
                let g2 = WavefunctionSurfaces.orbitalGrid(wf, mo: homo - 1, grid: grid, evaluator: ev)
                let n = overlap(g, g), o = overlap(g, g2)
                print("    \(name): nbf=\(ev.functionCount) grid \(grid.counts) (\(grid.pointCount) pts) HOMO in \(String(format: "%.0f", t)) ms; ∫|ψ|² = \(String(format: "%.5f", n)), <HOMO|HOMO−1> = \(String(format: "%.1e", o))")
                try expect(abs(n - 1) < 2e-3, "\(name) norm \(n)")
                try expect(abs(o) < 2e-3, "\(name) overlap \(o)")
                let lobes = MarchingCubes.orbitalLobes(grid: g, isovalue: 0.05)
                try expect(lobes.allSatisfy { !$0.isEmpty && MarchingCubes.isClosedManifold($0) })
            }
        },
        Check("analysis.orbitals.gridTiming") {
            // Default-resolution HOMO for the TZVP water (0.1 Å grid, automatic bounds).
            let wf = try moldenWF("water_tzvp.molden")
            let ev = OrbitalEvaluator(wavefunction: wf)
            let grid = WavefunctionSurfaces.defaultGrid(wf, padding: 4.0, spacing: 0.1)
            let t0 = DispatchTime.now()
            let g = WavefunctionSurfaces.orbitalGrid(wf, mo: wf.homoIndex!, grid: grid, evaluator: ev)
            let tMO = ms(t0)
            let t1 = DispatchTime.now()
            let lobes = MarchingCubes.orbitalLobes(grid: g, isovalue: 0.02)
            let tMC = ms(t1)
            let t2 = DispatchTime.now()
            _ = WavefunctionSurfaces.densityGrid(wf, grid: grid, evaluator: ev)
            let tD = ms(t2)
            print("    TZVP water (\(ev.functionCount) bf), \(grid.pointCount) pts: MO \(String(format: "%.0f", tMO)) ms, density \(String(format: "%.0f", tD)) ms, marching cubes (2 lobes, \(lobes[0].triangleCount + lobes[1].triangleCount) tris) \(String(format: "%.0f", tMC)) ms")
            try expect(tMO < 10_000)
        },
        Check("analysis.orbitals.spinDensityOH") {
            let wf = try moldenWF("oh_uhf_svp.molden")
            try expect(wf.isUnrestricted && wf.alphaElectrons == 5 && wf.betaElectrons == 4)
            let grid = WavefunctionSurfaces.defaultGrid(wf, padding: 5.0, spacing: 0.06, maxPoints: 8_000_000)
            let spin = WavefunctionSurfaces.spinDensityGrid(wf, grid: grid)
            let ns = integrateBohr(spin)
            let somo = WavefunctionSurfaces.orbitalGrid(wf, mo: 4, spin: .alpha, grid: grid)
            print("    OH UHF: ∫ spin density = \(String(format: "%.4f", ns)), ∫|SOMO|² = \(String(format: "%.5f", overlap(somo, somo)))")
            try expect(abs(ns - 1) < 1e-2, "spin \(ns)")
            try expect(abs(overlap(somo, somo) - 1) < 2e-3)
            let betaHOMO = WavefunctionSurfaces.orbitalGrid(wf, mo: 3, spin: .beta, grid: grid)
            try expect(abs(overlap(betaHOMO, betaHOMO) - 1) < 2e-3)
        },
        Check("analysis.orbitals.espWater") {
            let wf = try moldenWF("water_sto3g.molden")
            let t0 = DispatchTime.now()
            let mesh = WavefunctionSurfaces.espMappedDensity(wf, isovalue: 0.002, grid: WavefunctionSurfaces.defaultGrid(wf, padding: 3.5, spacing: 0.15))
            let t = ms(t0)
            guard let s = mesh.vertexScalars else { throw CheckFailure(description: "no ESP") }
            let lo = s.min()!, hi = s.max()!
            print("    water ESP on ρ=0.002 surface: \(mesh.vertices.count) verts, range [\(String(format: "%.4f", lo)), \(String(format: "%.4f", hi))] Eh/e, \(String(format: "%.0f", t)) ms")
            try expect(lo < 0 && hi > 0 && MarchingCubes.isClosedManifold(mesh))
            try expect(mesh.vertexColors?.count == mesh.vertices.count)
            // Negative region near O (opposite the H atoms, −z side in this frame is H; O lone pairs at +z).
            let pos = WavefunctionSurfaces.atomPositions(wf)
            let oSide = mesh.vertices.indices.max { mesh.vertices[$0].z < mesh.vertices[$1].z }!
            let hNear = mesh.vertices.indices.min { simd_distance(SIMD3<Double>(mesh.vertices[$0]), pos[1]) < simd_distance(SIMD3<Double>(mesh.vertices[$1]), pos[1]) }!
            try expect(s[oSide] < 0 && s[hNear] > 0, "O side \(s[oSide]) H side \(s[hNear])")
            // Neutral molecule: potential far away is tiny.
            let far = ElectrostaticPotential(wavefunction: wf).evaluate(atBohr: [Vec3(40, 30, 20)])[0]
            try expect(abs(far) < 1e-3, "far \(far)")
        },
    ]
}
