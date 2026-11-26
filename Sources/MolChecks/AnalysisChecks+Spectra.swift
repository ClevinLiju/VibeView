import Foundation
import MolCore
import MolIO
import MolAnalysis

// Spectra, thermochemistry and energy-profile checks (worker D1).

private func mode(_ f: Double, _ i: Double, raman: Double? = nil, sym: String? = nil) -> NormalMode {
    NormalMode(frequency: f, irIntensity: i, ramanActivity: raman, symmetry: sym, displacements: [])
}

/// Width at half of the maximum of the highest peak, by linear interpolation.
private func measuredFWHM(_ pts: [SpectrumPoint]) -> (peakX: Double, peakY: Double, fwhm: Double) {
    let k = pts.indices.max { pts[$0].y < pts[$1].y }!
    let half = pts[k].y / 2
    var left = pts[0].x, right = pts[pts.count - 1].x
    var i = k
    while i > 0 { if pts[i - 1].y < half { let t = (half - pts[i - 1].y) / (pts[i].y - pts[i - 1].y); left = pts[i - 1].x + t * (pts[i].x - pts[i - 1].x); break }; i -= 1 }
    i = k
    while i < pts.count - 1 { if pts[i + 1].y < half { let t = (half - pts[i + 1].y) / (pts[i].y - pts[i + 1].y); right = pts[i + 1].x + t * (pts[i].x - pts[i + 1].x); break }; i += 1 }
    return (pts[k].x, pts[k].y, right - left)
}

private func trapezoid(_ pts: [SpectrumPoint]) -> Double {
    var a = 0.0
    for i in 1..<pts.count { a += 0.5 * (pts[i].y + pts[i - 1].y) * (pts[i].x - pts[i - 1].x) }
    return a
}

extension Checks {
    static let analysisSpectra: [Check] = analysisSpectraOnly + analysisThermoChecks + analysisLineShapeChecks

    static let analysisSpectraOnly: [Check] = [
        Check("analysis.spec.lorentzianBand") {
            let s = SpectrumBuilder.ir(modes: [mode(1650, 100)], fwhm: 10, shape: .lorentzian, range: 1550...1750, pointCount: 20001)
            let m = measuredFWHM(s.points)
            try expectClose(m.peakX, 1650, tol: 0.02)
            try expectClose(m.peakY, 100, tol: 1e-6)
            try expect(abs(m.fwhm - 10) / 10 < 0.01, "fwhm \(m.fwhm)")
            try expect(s.xAxisReversed && s.xLabel.contains("Wavenumber") && s.yLabel.contains("km/mol"))
            try expect(s.sticks.count == 1 && s.sticks[0].height == 100 && s.sticks[0].label == "mode 1")
        },
        Check("analysis.spec.gaussianBand") {
            let s = SpectrumBuilder.ir(modes: [mode(3000, 40, sym: "A1")], fwhm: 20, shape: .gaussian, range: 2900...3100, pointCount: 20001)
            let m = measuredFWHM(s.points)
            try expectClose(m.peakX, 3000, tol: 0.02)
            try expectClose(m.peakY, 40, tol: 1e-6)
            try expect(abs(m.fwhm - 20) / 20 < 0.01, "fwhm \(m.fwhm)")
            try expect(s.sticks[0].label == "mode 1 (A1)")
        },
        Check("analysis.spec.areaNormalized") {
            for fw in [4.0, 25.0] {
                let g = (0...40000).map { i -> SpectrumPoint in
                    let x = -400 + Double(i) * 0.02
                    return SpectrumPoint(x: x, y: Broadening.gaussianArea(x: x, center: 0, fwhm: fw))
                }
                try expectClose(trapezoid(g), 1, tol: 1e-6)
                let l = (0...400000).map { i -> SpectrumPoint in
                    let x = -4000 + Double(i) * 0.02
                    return SpectrumPoint(x: x, y: Broadening.lorentzianArea(x: x, center: 0, fwhm: fw))
                }
                // Lorentzian tail beyond ±4000: ≈ 2·(fw/2)/(π·4000)
                try expectClose(trapezoid(l), 1 - fw / (Double.pi * 4000), tol: 1e-4)
            }
            try expectClose(Broadening.lorentzian(x: 5, center: 5, fwhm: 3), 1)
            try expectClose(Broadening.gaussian(x: 6.5, center: 5, fwhm: 3), 0.5, tol: 1e-12)
            try expectClose(Broadening.lorentzian(x: 6.5, center: 5, fwhm: 3), 0.5, tol: 1e-12)
        },
        Check("analysis.spec.scaleAndSuperposition") {
            let modes = [mode(1000, 10), mode(1400, 30), mode(-200, 99)]
            let s = SpectrumBuilder.ir(modes: modes, scale: 0.96, fwhm: 8, range: 800...1600, pointCount: 8001)
            try expect(s.sticks.count == 2, "imaginary excluded")
            try expectClose(s.sticks[0].x, 960, tol: 1e-9)
            try expectClose(s.sticks[1].x, 1344, tol: 1e-9)
            // far-separated bands: curve at each center ≈ own intensity (+ tiny tail of the other)
            func y(_ x: Double) -> Double { s.points.min { abs($0.x - x) < abs($1.x - x) ? true : false }!.y }
            let expect960 = 10 + 30 * Broadening.lorentzian(x: 960, center: 1344, fwhm: 8)
            try expectClose(y(960), expect960, tol: 1e-6)
            // exact superposition at an in-between x
            let x = 1100.0
            let want = 10 * Broadening.lorentzian(x: x, center: 960, fwhm: 8) + 30 * Broadening.lorentzian(x: x, center: 1344, fwhm: 8)
            try expectClose(y(x), want, tol: 1e-6)
            let withImag = SpectrumBuilder.ir(modes: modes, range: -500...4000, includeImaginary: true)
            try expect(withImag.sticks.count == 3)
        },
        Check("analysis.spec.raman") {
            let a = SpectrumBuilder.raman(modes: [mode(500, 1, raman: 20), mode(1500, 1, raman: 5), mode(900, 1)],
                                          fwhm: 10, range: 400...1600, pointCount: 12001)
            try expect(a.sticks.count == 2 && a.sticks[0].height == 20)
            let b = SpectrumBuilder.raman(modes: [mode(500, 1, raman: 20), mode(1500, 1, raman: 5)],
                                          excitationNM: 532, temperature: 298.15)
            try expectClose(b.sticks.map { $0.height }.max()!, 1, tol: 1e-12)
            // manual: ratio of the two intensities
            let nu0 = 1e7 / 532.0
            func f(_ nu: Double, _ s: Double) -> Double { s * pow(nu0 - nu, 4) / nu / (1 - exp(-PhysConst.h * PhysConst.c * nu / (PhysConst.kB * 298.15))) }
            try expectClose(b.sticks[1].height / b.sticks[0].height, f(1500, 5) / f(500, 20), tol: 1e-12)
        },
        Check("analysis.spec.uvvisAnalytic") {
            var st = ExcitedState(energyEV: 4.0, wavelengthNM: 309.96, oscillatorStrength: 0.5)
            st.multiplicity = 1
            let s = SpectrumBuilder.uvVis(states: [st], fwhmEV: 0.3, shape: .gaussian, axis: .energyEV, range: 3...5, pointCount: 2001)
            let sigmaCM = 0.3 * 8065.543937 / (2 * log(2.0).squareRoot())
            let epsMax = 1.3062974e8 * 0.5 / sigmaCM
            let m = measuredFWHM(s.points)
            try expectClose(m.peakX, 4.0, tol: 1e-9)
            try expect(abs(m.peakY - epsMax) / epsMax < 1e-9, "eps \(m.peakY) vs \(epsMax)")
            try expect(abs(m.fwhm - 0.3) / 0.3 < 0.01)
            try expect(abs(s.sticks[0].height - epsMax) / epsMax < 1e-9)
            // integrated intensity in cm⁻¹: ∫ε dν̃ = 1.3062974e8·√π·f
            let wide = SpectrumBuilder.uvVis(states: [st], fwhmEV: 0.3, shape: .gaussian, axis: .wavenumber, range: 20000...45000, pointCount: 25001)
            try expect(abs(trapezoid(wide.points) / (1.3062974e8 * Double.pi.squareRoot() * 0.5) - 1) < 1e-6)
            // nm axis
            let nm = SpectrumBuilder.uvVis(states: [st], fwhmEV: 0.3, axis: .wavelengthNM, range: 250...400, pointCount: 15001)
            let k = nm.points.max { $0.y < $1.y }!
            try expectClose(k.x, 1239.84198 / 4.0, tol: 0.02)
            try expectClose(nm.sticks[0].x, 1239.84198 / 4.0, tol: 1e-9)
            try expect(abs(k.y - epsMax) / epsMax < 1e-4)
            // default range works
            let d = SpectrumBuilder.uvVis(states: [st])
            try expect(d.points.count == 1000 && d.points.first!.x < d.points.last!.x)
            // Lorentzian has the same integrated intensity
            let l = SpectrumBuilder.uvVis(states: [st], fwhmEV: 0.3, shape: .lorentzian, axis: .wavenumber, range: -2e6...2e6, pointCount: 400001)
            try expect(abs(trapezoid(l.points) / (1.3062974e8 * Double.pi.squareRoot() * 0.5) - 1) < 2e-3)
        },
        Check("analysis.spec.ecdSign") {
            let s1 = ExcitedState(energyEV: 4.0, wavelengthNM: 309.96, oscillatorStrength: 0.1)
            let s2 = ExcitedState(energyEV: 5.5, wavelengthNM: 225.4, oscillatorStrength: 0.1)
            let s = SpectrumBuilder.ecd(states: [s1, s2], rotatoryStrengths: [100, -60], fwhmEV: 0.2, axis: .energyEV, range: 3...7, pointCount: 4001)
            func y(_ x: Double) -> Double { s.points.min { abs($0.x - x) < abs($1.x - x) }!.y }
            try expect(y(4.0) > 0 && y(5.5) < 0)
            let sigma = 0.2 / (2 * log(2.0).squareRoot())
            let want = 4.0 * 100e-40 / (2.296e-39 * Double.pi.squareRoot() * sigma)
            try expect(abs(y(4.0) - want) / want < 1e-3, "\(y(4.0)) vs \(want)")
            try expect(s.sticks[0].height > 0 && s.sticks[1].height < 0)
            try expect(s.yLabel.contains("Δε"))
            let nm = SpectrumBuilder.ecd(states: [s1, s2], rotatoryStrengths: [100, -60], axis: .wavelengthNM)
            try expect(nm.points.contains { $0.y > 0 } && nm.points.contains { $0.y < 0 })
        },
        Check("analysis.spec.nmr") {
            let sh = [NMRShielding(atomIndex: 1, element: 1, isotropic: 31.0),
                      NMRShielding(atomIndex: 2, element: 1, isotropic: 29.0),
                      NMRShielding(atomIndex: 3, element: 1, isotropic: 29.01),
                      NMRShielding(atomIndex: 0, element: 6, isotropic: 150.0)]
            let s = SpectrumBuilder.nmr(shieldings: sh, element: 1, reference: .tms(shielding: 32.0), fwhm: 0.02, pointCount: 4001)
            try expect(s.xAxisReversed && s.xLabel.contains("δ"))
            try expect(s.sticks.count == 3)
            try expectClose(s.sticks[0].x, 1.0, tol: 1e-12)   // 32 - 31
            try expectClose(s.sticks[1].x, 2.99, tol: 1e-12)
            let c13 = SpectrumBuilder.nmr(shieldings: sh, element: 6, reference: .shielding(180))
            try expectClose(c13.sticks[0].x, 30.0, tol: 1e-12)
            let merged = SpectrumBuilder.nmr(shieldings: sh, element: 1, reference: .shielding(32.0), mergeEquivalent: 0.05)
            try expect(merged.sticks.count == 2)
            let big = merged.sticks.first { $0.height == 2 }!
            try expectClose(big.x, 2.995, tol: 1e-9)
            // peak of merged curve ≈ 2 at 2.995 (heights add)
            let top = merged.points.max { $0.y < $1.y }!
            try expect(abs(top.x - 2.995) < 0.01 && top.y > 1.9)
            // linear scaling: δ = (intercept − σ)/(−slope)
            let lin = SpectrumBuilder.nmr(shieldings: sh, element: 1, reference: .linear(slope: -1.0, intercept: 31.8))
            try expectClose(lin.sticks.map { $0.x }.min()!, 0.8, tol: 1e-12)
            let lin2 = SpectrumBuilder.nmr(shieldings: sh, element: 1, reference: .linear(slope: -0.9, intercept: 30.0))
            try expectClose(lin2.sticks.map { $0.x }.min()!, (30.0 - 31.0) / 0.9, tol: 1e-12)
        },

        // MARK: Energy profiles
        Check("analysis.profile.units") {
            let p = EnergyProfile(energies: [-1.0, -0.99, -0.995, -1.01], kind: .custom)
            let kc = p.relativeEnergies(unit: .kcalPerMol)
            try expectClose(kc[0], 0); try expectClose(kc[1], 0.01 * 627.509474, tol: 1e-9)
            try expectClose(p.relativeEnergies(unit: .kJPerMol)[1], 0.01 * 2625.499639, tol: 1e-9)
            try expectClose(p.relativeEnergies(unit: .eV)[1], 0.01 * 27.211386245988, tol: 1e-12)
            try expectClose(PhysConst.hartreeToKJMol, 2625.4996, tol: 1e-3)
            try expectClose(p.relativeEnergies(unit: .hartree, reference: .minimum)[3], 0, tol: 1e-15)
            try expectClose(p.relativeEnergies(unit: .hartree, reference: .minimum)[1], 0.02, tol: 1e-12)
            try expectClose(p.relativeEnergies(unit: .hartree, reference: .index(2))[0], -0.005, tol: 1e-12)
            try expectClose(p.relativeEnergies(unit: .hartree, reference: .value(-1.0))[3], -0.01, tol: 1e-12)
            try expectClose(p.barrier(unit: .kcalPerMol), 0.01 * 627.509474, tol: 1e-9)
            let sp = p.points(unit: .eV)
            try expect(sp.count == 4 && sp[2].x == 2)
            let c = EnergyProfile(energies: [0, 1], coordinates: [1.5, 2.5], kind: .scan)
            try expect(c.points[1].coordinate == 2.5 && c.kind == .scan)
        },
        Check("analysis.profile.ircOrdering") {
            // GaussianLog sub-structs have no public memberwise init: build them via Codable.
            let json = """
            [{"path":1,"point":0,"reactionCoordinate":0.0,"energy":-100.0},
             {"path":1,"point":1,"reactionCoordinate":0.1,"energy":-100.01},
             {"path":1,"point":2,"reactionCoordinate":0.2,"energy":-100.03},
             {"path":2,"point":1,"reactionCoordinate":0.1,"energy":-100.02},
             {"path":2,"point":2,"reactionCoordinate":0.2,"energy":-100.05}]
            """
            var log = GaussianLog()
            log.ircPoints = try JSONDecoder().decode([GaussianLog.IRCPoint].self, from: Data(json.utf8))
            let p = EnergyProfile.fromIRC(log)!
            try expect(p.kind == .irc && p.points.count == 5)
            try expect(p.points.map { $0.coordinate } == [-0.2, -0.1, 0.0, 0.1, 0.2], "\(p.points.map { $0.coordinate })")
            try expectClose(p.points[0].energy, -100.05)
            try expectClose(p.points[2].energy, -100.0)
            let rel = p.relativeEnergies(unit: .kcalPerMol, reference: .index(2))
            try expectClose(rel[0], -0.05 * 627.509474, tol: 1e-9)
            try expect(EnergyProfile.fromScan(GaussianLog()) == nil && EnergyProfile.fromOptimization(GaussianLog()) == nil)
        },
        Check("analysis.profile.scanAndOpt") {
            var log = GaussianLog()
            log.scanSummary = try JSONDecoder().decode([GaussianLog.ScanSummaryRow].self, from:
                Data(#"[{"index":0,"coordinates":[1.0],"energy":-10.0},{"index":1,"coordinates":[1.2],"energy":-10.05},{"index":2,"coordinates":[1.4],"energy":-10.03}]"#.utf8))
            let p = EnergyProfile.fromScan(log)!
            try expect(p.kind == .scan && p.points.map { $0.coordinate } == [1.0, 1.2, 1.4])
            try expectClose(p.barrier(unit: .hartree), 0.0, tol: 1e-12)  // first point is the max
            log.optimizationSteps = try JSONDecoder().decode([GaussianLog.OptimizationStep].self, from:
                Data(#"[{"stepNumber":1,"energy":-5.0,"criteria":[],"converged":false},{"stepNumber":2,"criteria":[],"converged":false},{"stepNumber":3,"energy":-5.1,"criteria":[],"converged":true}]"#.utf8))
            let o = EnergyProfile.fromOptimization(log)!
            try expect(o.kind == .optimization && o.points.map { $0.coordinate } == [1, 3])
        },
    ]
}
