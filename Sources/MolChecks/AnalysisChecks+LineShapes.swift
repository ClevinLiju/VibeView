import Foundation
import MolCore
import MolAnalysis

// Line-shape checks: Gaussian / Lorentzian / Voigt (Faddeeva) / pseudo-Voigt / sticks, IR transmittance,
// persisted display choice.

private func lsMode(_ f: Double, _ i: Double, raman: Double? = nil) -> NormalMode {
    NormalMode(frequency: f, irIntensity: i, ramanActivity: raman, symmetry: nil, displacements: [])
}

/// FWHM of a sampled single peak by linear interpolation of the half-maximum crossings.
private func lsFWHM(_ xs: [Double], _ ys: [Double]) -> (peakX: Double, peakY: Double, fwhm: Double) {
    let k = ys.indices.max { ys[$0] < ys[$1] }!
    let half = ys[k] / 2
    var left = xs.first!, right = xs.last!
    var i = k
    while i > 0 { if ys[i - 1] < half { let t = (half - ys[i - 1]) / (ys[i] - ys[i - 1]); left = xs[i - 1] + t * (xs[i] - xs[i - 1]); break }; i -= 1 }
    i = k
    while i < ys.count - 1 { if ys[i + 1] < half { let t = (half - ys[i + 1]) / (ys[i] - ys[i + 1]); right = xs[i + 1] + t * (xs[i] - xs[i + 1]); break }; i += 1 }
    return (xs[k], ys[k], right - left)
}

/// ∫ f(x) dx over the real line via x = s·tan θ (finite integrand for 1/x² wings), composite Simpson in θ.
private func lsIntegral(scale s: Double, _ f: (Double) -> Double, n: Int = 200_000) -> Double {
    let a = -Double.pi / 2, h = Double.pi / Double(n)
    var sum = 0.0
    for i in 1..<n {
        let th = a + Double(i) * h
        let c = cos(th)
        let v = f(s * tan(th)) * s / (c * c)
        sum += v * (i % 2 == 1 ? 4 : 2)
    }
    // θ → ±π/2 limit of the integrand: s·f(s·tanθ)/cos²θ → x²·f(x)/s for x → ±∞ (finite for 1/x² wings).
    let big = 1e9 * s
    let ends = big * big * (f(big) + f(-big)) / s
    return (sum + ends) * h / 3
}

/// Independent Voigt reference: direct convolution ∫ G(t; σ) L(x − t; γ) dt (unit-area), Simpson in t.
private func voigtByConvolution(_ x: Double, sigma: Double, gamma: Double) -> Double {
    let lo = -12 * sigma, hi = 12 * sigma
    let n = 400_000
    let h = (hi - lo) / Double(n)
    var s = 0.0
    for i in 0...n {
        let t = lo + Double(i) * h
        let g = exp(-t * t / (2 * sigma * sigma)) / (sigma * (2 * Double.pi).squareRoot())
        let d = x - t
        let l = gamma / Double.pi / (d * d + gamma * gamma)
        s += g * l * (i == 0 || i == n ? 1 : (i % 2 == 1 ? 4 : 2))
    }
    return s * h / 3
}

private func rel(_ a: Double, _ b: Double) -> Double { abs(a - b) / max(abs(b), 1e-300) }

extension Checks {
    static let analysisLineShapeChecks: [Check] = [
        Check("analysis.lineshape.faddeevaKnownValues") {
            // w(0) = 1; w(iy) = erfcx(y); Re w(x) = exp(−x²); w(1+i) tabulated value.
            let w0 = Faddeeva.w(x: 0, y: 0)
            try expectClose(w0.re, 1, tol: 1e-12); try expectClose(w0.im, 0, tol: 1e-12)
            for y in [1e-4, 0.1, 0.5, 1, 2, 5, 5.99, 6.01, 10, 20] {
                let want = exp(y * y) * erfc(y)
                let got = Faddeeva.w(x: 0, y: y).re
                try expect(rel(got, want) < 1e-10, "w(i\(y)) = \(got) vs \(want)")
            }
            for x in [0.3, 1, 2.5, 3] { try expect(rel(Faddeeva.w(x: x, y: 0).re, exp(-x * x)) < 1e-9, "Re w(\(x))") }
            // Where Re w is ~1e-7 on the real axis only the absolute accuracy (~1e-15) holds.
            try expectClose(Faddeeva.w(x: 4, y: 0).re, exp(-16), tol: 1e-14)
            let w11 = Faddeeva.w(x: 1, y: 1)
            try expect(rel(w11.re, 0.30474420525691259) < 1e-12 && rel(w11.im, 0.20821893820283163) < 1e-12, "w(1+i) = \(w11)")
            // Im w(1) = 2/√π · Dawson(1), Dawson(1) = 0.5380795069127684
            try expect(rel(Faddeeva.w(x: 1, y: 0).im, 2 / Double.pi.squareRoot() * 0.5380795069127684) < 1e-10)
            // Far field: w ≈ i/(√π z), Re w(x+iy) ≈ y/(√π|z|²)
            let far = Faddeeva.w(x: 0, y: 1e4).re
            try expect(rel(far, 1 / (Double.pi.squareRoot() * 1e4) * (1 - 0.5e-8)) < 1e-8)
        },
        Check("analysis.lineshape.voigtKnownPointsAndConvolution") {
            // V(0; σ, γ) = erfcx(γ/(σ√2)) / (σ√(2π)), and direct-convolution cross-check off-centre (1e-6 relative).
            for (sigma, gamma) in [(1.0, 1.0), (1.0, 0.1), (0.3, 2.0), (2.0, 0.01)] {
                let fG = sigma * 2 * (2 * log(2.0)).squareRoot(), fL = 2 * gamma
                let want0 = exp(pow(gamma / (sigma * 2.0.squareRoot()), 2)) * erfc(gamma / (sigma * 2.0.squareRoot())) / (sigma * (2 * Double.pi).squareRoot())
                let v0 = Broadening.voigtArea(x: 0, center: 0, gaussianFWHM: fG, lorentzianFWHM: fL)
                try expect(rel(v0, want0) < 1e-10, "V(0) σ=\(sigma) γ=\(gamma): \(v0) vs \(want0)")
                for x in [0.5, 1.7, 4.0, 15.0] {
                    let v = Broadening.voigtArea(x: x * sigma, center: 0, gaussianFWHM: fG, lorentzianFWHM: fL)
                    let r = voigtByConvolution(x * sigma, sigma: sigma, gamma: gamma)
                    try expect(rel(v, r) < 1e-6, "V(\(x)σ) σ=\(sigma) γ=\(gamma): \(v) vs \(r) rel \(rel(v, r))")
                }
            }
        },
        Check("analysis.lineshape.voigtLimits") {
            // σ → 0 gives the Lorentzian, γ → 0 the Gaussian (also exactly at 0).
            for x in [0.0, 0.7, 3.0, 25.0] {
                let l = Broadening.lorentzianArea(x: x, center: 0, fwhm: 2)
                let vSmallG = Broadening.voigtArea(x: x, center: 0, gaussianFWHM: 1e-7, lorentzianFWHM: 2)
                try expect(rel(vSmallG, l) < 1e-6, "σ→0 at \(x): \(vSmallG) vs \(l)")
                try expectClose(Broadening.voigtArea(x: x, center: 0, gaussianFWHM: 0, lorentzianFWHM: 2), l, tol: 1e-15)
            }
            for x in [0.0, 0.7, 1.5, 3.0] {
                let g = Broadening.gaussianArea(x: x, center: 0, fwhm: 2)
                let vSmallL = Broadening.voigtArea(x: x, center: 0, gaussianFWHM: 2, lorentzianFWHM: 1e-9)
                try expect(rel(vSmallL, g) < 1e-6, "γ→0 at \(x): \(vSmallL) vs \(g)")
                try expectClose(Broadening.voigtArea(x: x, center: 0, gaussianFWHM: 2, lorentzianFWHM: 0), g, tol: 1e-15)
            }
            // Height-normalised Voigt limits too
            try expectClose(Broadening.voigt(x: 1, center: 0, gaussianFWHM: 1e-7, lorentzianFWHM: 2), 0.5, tol: 1e-6)
            try expectClose(Broadening.voigt(x: 1, center: 0, gaussianFWHM: 2, lorentzianFWHM: 1e-9), 0.5, tol: 1e-6)
        },
        Check("analysis.lineshape.fwhmPeakArea") {
            // Every shape: peak at the centre, height 1 (height mode), FWHM as requested, unit area (area mode).
            let shapes: [LineShapeProfile] = [
                .gaussian(fwhm: 10), .lorentzian(fwhm: 10), .pseudoVoigt(fwhm: 10, eta: 0.3),
                .pseudoVoigt(fwhm: 10, eta: 1), .voigt(gaussianFWHM: 6, lorentzianFWHM: 5), .voigt(gaussianFWHM: 1, lorentzianFWHM: 9),
            ]
            let xs = (0...200_000).map { 1000 + Double($0) * 0.001 }   // 1000…1200, centre 1100
            for p in shapes {
                let y = p.broaden(centers: [1100], weights: [1], at: xs, normalization: .height)
                let m = lsFWHM(xs, y)
                try expectClose(m.peakX, 1100, tol: 1e-3)
                try expectClose(m.peakY, 1, tol: 1e-9)
                let want = p.effectiveFWHM
                let tol = p.kind == .voigt ? 3e-4 : 1e-5      // Olivero–Longbothum is good to 0.02 %
                try expect(rel(m.fwhm, want) < tol, "\(p.kind) fwhm \(m.fwhm) vs \(want)")
                // Area normalisation, wings integrated exactly with x = s·tanθ.
                let area = lsIntegral(scale: p.effectiveFWHM) { p.area($0) }
                try expect(abs(area - 1) < 1e-6, "\(p.kind) area \(area)")
                // Height × (area peak) consistency.
                try expectClose(p.height(3.3) * p.areaPeak, p.area(3.3), tol: 1e-12)
            }
            // Pseudo-Voigt endpoints
            try expectClose(LineShapeProfile.pseudoVoigt(fwhm: 4, eta: 0).height(1.3), Broadening.gaussian(x: 1.3, center: 0, fwhm: 4), tol: 1e-15)
            try expectClose(LineShapeProfile.pseudoVoigt(fwhm: 4, eta: 1).height(1.3), Broadening.lorentzian(x: 1.3, center: 0, fwhm: 4), tol: 1e-15)
            try expectClose(LineShapeProfile.pseudoVoigt(fwhm: 4, eta: 0.3).height(2), 0.5, tol: 1e-14)   // FWHM exactly 4
            // Sticks only: no curve.
            try expect(LineShapeProfile.sticksOnly.broaden(centers: [1], weights: [1], at: [1, 2], normalization: .height) == [0, 0])
        },
        Check("analysis.lineshape.spectraEveryShape") {
            let shapes: [LineShapeProfile] = [.gaussian(fwhm: 12), .lorentzian(fwhm: 12), .pseudoVoigt(fwhm: 12, eta: 0.5),
                                              .voigt(gaussianFWHM: 8, lorentzianFWHM: 6)]
            for p in shapes {
                // IR / Raman: height-normalised, isolated band peaks at its intensity.
                let ir = SpectrumBuilder.ir(modes: [lsMode(1700, 250)], profile: p, range: 1500...1900, pointCount: 40001)
                let m = lsFWHM(ir.points.map(\.x), ir.points.map(\.y))
                try expectClose(m.peakX, 1700, tol: 0.011); try expectClose(m.peakY, 250, tol: 1e-6)
                try expect(rel(m.fwhm, p.effectiveFWHM) < 5e-4, "IR \(p.kind) fwhm \(m.fwhm)")
                let ra = SpectrumBuilder.raman(modes: [lsMode(900, 1, raman: 30)], profile: p, range: 700...1100, pointCount: 40001)
                try expectClose(ra.points.map(\.y).max()!, 30, tol: 1e-6)
                // UV-Vis: area-normalised in wavenumber, ∫ε dν̃ = 2.3154e8·f for every shape.
                let st = ExcitedState(energyEV: 4.0, wavelengthNM: 309.96, oscillatorStrength: 0.5)
                let pe = p.scaled(by: 0.3 / 12)      // widths now in eV
                let ev = SpectrumBuilder.uvVis(states: [st], profile: pe, axis: .energyEV, range: 3...5, pointCount: 4001)
                let k = ev.points.max { $0.y < $1.y }!
                try expectClose(k.x, 4.0, tol: 1e-9)
                try expect(rel(ev.sticks[0].height, k.y) < 1e-9, "UV stick = band max")
                let cm = 8065.543937349211
                let area = lsIntegral(scale: pe.effectiveFWHM * cm) { d in pe.scaled(by: cm).area(d) } * 1.3062974e8 * Double.pi.squareRoot() * 0.5
                try expect(rel(area, 1.3062974e8 * Double.pi.squareRoot() * 0.5) < 1e-6)
                try expect(rel(k.y, 1.3062974e8 * Double.pi.squareRoot() * 0.5 * pe.scaled(by: cm).areaPeak) < 1e-9)
                // ECD keeps signs.
                let s2 = ExcitedState(energyEV: 5.5, wavelengthNM: 225.4, oscillatorStrength: 0.1)
                let ecd = SpectrumBuilder.ecd(states: [st, s2], rotatoryStrengths: [50, -80], profile: pe, axis: .energyEV, range: 3...7, pointCount: 4001)
                func y(_ x: Double) -> Double { ecd.points.min { abs($0.x - x) < abs($1.x - x) }!.y }
                try expect(y(4.0) > 0 && y(5.5) < 0)
            }
            // Old two-case API is unchanged by the bridge.
            let a = SpectrumBuilder.ir(modes: [lsMode(1000, 5)], fwhm: 9, shape: .gaussian, range: 900...1100, pointCount: 2001)
            let b = SpectrumBuilder.ir(modes: [lsMode(1000, 5)], profile: .gaussian(fwhm: 9), range: 900...1100, pointCount: 2001)
            try expect(a == b)
            // Sticks only: empty curve, sticks kept.
            let s = SpectrumBuilder.ir(modes: [lsMode(1000, 5), lsMode(2000, 3)], profile: .sticksOnly)
            try expect(s.points.isEmpty && s.sticks.count == 2)
            let uv = SpectrumBuilder.uvVis(states: [ExcitedState(energyEV: 4, wavelengthNM: 310, oscillatorStrength: 0.2)], profile: .sticksOnly)
            try expect(uv.points.isEmpty && uv.sticks.count == 1 && uv.sticks[0].height > 0)
        },
        Check("analysis.lineshape.transmittance") {
            let modes = [lsMode(1750, 300), lsMode(2900, 15), lsMode(1200, 60)]
            for p: LineShapeProfile in [.gaussian(fwhm: 20), .lorentzian(fwhm: 20), .voigt(gaussianFWHM: 12, lorentzianFWHM: 10)] {
                let ir = SpectrumBuilder.ir(modes: modes, profile: p, range: 0...4000, pointCount: 8001)
                let t = TransmittanceScale.transmittance(ir)
                try expect(t.points.allSatisfy { (0...100).contains($0.y) }, "T within 0…100")
                try expect(t.yLabel == "Transmittance (%)" && t.xAxisReversed)
                let minT = t.points.map(\.y).min()!
                try expect(minT >= 15 - 1e-9 && minT < 16, "deepest band \(minT) %T")
                // Weak band (5 % of the strongest) is still a visible dip.
                let weak = t.points.min { abs($0.x - 2900) < abs($1.x - 2900) }!.y
                try expect(weak < 93 && weak > 85, "weak band at \(weak) %T")
                if p.kind == .gaussian {
                    try expectClose(t.points.first { $0.x == 500 }!.y, 100, tol: 1e-12)     // baseline exactly 100
                }
            }
            let sc = TransmittanceScale(maxIntensity: 300)
            try expectClose(sc.percent(0), 100, tol: 0); try expectClose(sc.percent(300), 15, tol: 1e-9)
            try expect(sc.percent(1e9) >= 0 && sc.percent(-5) == 100)
            try expectClose(TransmittanceScale(maxIntensity: 0).percent(7), 100, tol: 0)
        },
        Check("analysis.lineshape.settingsPersist") {
            let suite = "vibeview.checks.lineshape.\(UUID().uuidString)"
            guard let d = UserDefaults(suiteName: suite) else { throw CheckFailure(description: "no defaults suite") }
            defer { d.removePersistentDomain(forName: suite) }
            let key = SpectrumDisplaySettings.vibrationalKey
            // Nothing stored: default is Lorentzian with %T on.
            let def = SpectrumDisplaySettings.load(key: key, default: .vibrationalDefault, from: d)
            try expect(def == .vibrationalDefault && def.transmittance && def.profile.kind == .lorentzian)
            var s = def
            s.profile = .voigt(gaussianFWHM: 7.5, lorentzianFWHM: 3.25)
            s.transmittance = false
            s.save(key: key, to: d)
            let back = SpectrumDisplaySettings.load(key: key, default: .vibrationalDefault, from: d)
            try expect(back == s, "round trip \(back)")
            var e = SpectrumDisplaySettings.electronicDefault
            e.profile = .pseudoVoigt(fwhm: 0.27, eta: 0.4)
            e.save(key: SpectrumDisplaySettings.electronicKey, to: d)
            try expect(SpectrumDisplaySettings.load(key: SpectrumDisplaySettings.electronicKey, default: .electronicDefault, from: d) == e)
            // Corrupt data falls back to the default.
            d.set(Data("nope".utf8), forKey: key)
            try expect(SpectrumDisplaySettings.load(key: key, default: .vibrationalDefault, from: d) == .vibrationalDefault)
        },
    ]
}
