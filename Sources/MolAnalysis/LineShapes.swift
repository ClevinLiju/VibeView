import Foundation

// Line-shape functions for broadened spectra (IR, Raman, UV-Vis, ECD): Gaussian, Lorentzian, true Voigt
// (via the Faddeeva function), pseudo-Voigt and sticks only. Every width is a full width at half maximum
// (FWHM) in the unit of the spectrum's broadening axis.

// MARK: - Faddeeva function

/// The Faddeeva function w(z) = exp(−z²)·erfc(−iz), evaluated for Im z ≥ 0 (the half plane the Voigt profile
/// needs). Near the origin it uses Weideman's rational approximation (J. A. C. Weideman, "Computation of the
/// complex error function", SIAM J. Numer. Anal. 31, 1497 (1994)) with N = 32 terms. Far from the origin
/// it uses the Laplace continued fraction, w(z) = (i/√π) / (z − (1/2)/(z − 1/(z − (3/2)/(z − …)))), which
/// keeps the relative accuracy in the far wings where w is small. Measured against direct numerical
/// convolution, Re w has a relative error below ~1e-9 wherever Re w ≳ 1e-8; the absolute error is ~1e-15
/// everywhere. (Very close to the real axis with |x| ≈ 3…6, Re w ≈ exp(−x²) falls below 1e-8 and only the
/// absolute bound holds; that is a Voigt band below 1e-8 of its peak.) The checks verify 1e-6 relative.
public enum Faddeeva {
    /// Weideman N = 32 polynomial coefficients p(Z) = Σ a[n]·Zⁿ, n = 0…N−1.
    private static let n = 32
    private static let L = (Double(n) / 2.0.squareRoot()).squareRoot()
    private static let coefficients: [Double] = {
        // a_k = (1/2M) Σ_{j=−M+1}^{M−1} f(j)·cos(π j k / M), f(j) = exp(−t²)(L² + t²), t = L·tan(θ/2), θ = jπ/M.
        let m = 2 * n
        var f = [Double](repeating: 0, count: 2 * m)
        for j in (-m + 1)...(m - 1) {
            let t = L * tan(Double(j) * Double.pi / Double(m) / 2)
            f[j + m] = exp(-t * t) * (L * L + t * t)
        }
        var a = [Double](repeating: 0, count: n)
        for k in 1...n {
            var s = 0.0
            for j in (-m + 1)...(m - 1) { s += f[j + m] * cos(Double.pi * Double(j * k) / Double(m)) }
            a[k - 1] = s / Double(2 * m)   // coefficient of Z^(k−1)
        }
        return a
    }()
    private static let invSqrtPi = 1 / Double.pi.squareRoot()

    /// w(x + iy) for y ≥ 0. Returns (real, imaginary).
    public static func w(x: Double, y: Double) -> (re: Double, im: Double) {
        let y = max(0, y)
        if x * x + y * y > 36 { return continuedFraction(x: x, y: y) }
        // Z = (L + iz)/(L − iz), iz = −y + ix.
        let nr = L - y, ni = x          // L + iz
        let dr = L + y, di = -x         // L − iz
        let dd = dr * dr + di * di
        let zr = (nr * dr + ni * di) / dd, zi = (ni * dr - nr * di) / dd
        // Horner: p(Z) = Σ a_k Z^k
        var pr = 0.0, pi = 0.0
        for k in stride(from: n - 1, through: 0, by: -1) {
            let tr = pr * zr - pi * zi + coefficients[k]
            pi = pr * zi + pi * zr
            pr = tr
        }
        // w = 2p/(L − iz)² + (1/√π)/(L − iz)
        let inv1r = dr / dd, inv1i = -di / dd                 // 1/(L − iz)
        let inv2r = inv1r * inv1r - inv1i * inv1i, inv2i = 2 * inv1r * inv1i
        return (2 * (pr * inv2r - pi * inv2i) + invSqrtPi * inv1r,
                2 * (pr * inv2i + pi * inv2r) + invSqrtPi * inv1i)
    }

    /// Laplace continued fraction, evaluated bottom-up; |z| > 6 so 40 levels converge to machine precision.
    private static func continuedFraction(x: Double, y: Double) -> (re: Double, im: Double) {
        var tr = x, ti = y                 // tail ≈ z
        for k in stride(from: 40, through: 1, by: -1) {
            let c = Double(k) / 2
            let dd = tr * tr + ti * ti
            tr = x - c * tr / dd
            ti = y + c * ti / dd
        }
        let dd = tr * tr + ti * ti          // w = (i/√π)/t
        return (invSqrtPi * ti / dd, invSqrtPi * tr / dd)
    }
}

// MARK: - Line shapes

/// Which line shape to broaden sticks with.
public enum LineShapeKind: String, Sendable, Codable, CaseIterable, Identifiable {
    case gaussian, lorentzian, voigt, pseudoVoigt, sticks
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .gaussian: return "Gaussian"
        case .lorentzian: return "Lorentzian"
        case .voigt: return "Voigt"
        case .pseudoVoigt: return "Pseudo-Voigt"
        case .sticks: return "Sticks only"
        }
    }
}

/// A complete line-shape choice with its widths. All widths are FWHM in the broadening axis unit.
/// - `.gaussian`, `.lorentzian`, `.pseudoVoigt` use `fwhm`.
/// - `.pseudoVoigt` mixes η·Lorentzian + (1 − η)·Gaussian, both unit-area with the same FWHM (the standard
///   definition), so its FWHM is exactly `fwhm`; the height form is that shape scaled to a peak of 1.
/// - `.voigt` is the exact convolution of a Gaussian (FWHM `gaussianFWHM`) with a Lorentzian (FWHM
///   `lorentzianFWHM`); its own FWHM is `voigtFWHM` (Olivero–Longbothum, 0.02 %).
/// - `.sticks` has no curve.
public struct LineShapeProfile: Sendable, Codable, Equatable {
    public var kind: LineShapeKind
    public var fwhm: Double
    public var gaussianFWHM: Double
    public var lorentzianFWHM: Double
    public var eta: Double

    public init(kind: LineShapeKind, fwhm: Double, gaussianFWHM: Double? = nil, lorentzianFWHM: Double? = nil, eta: Double = 0.5) {
        self.kind = kind
        self.fwhm = fwhm
        self.gaussianFWHM = gaussianFWHM ?? fwhm / 2
        self.lorentzianFWHM = lorentzianFWHM ?? fwhm / 2
        self.eta = min(1, max(0, eta))
    }

    public static func gaussian(fwhm: Double) -> LineShapeProfile { .init(kind: .gaussian, fwhm: fwhm) }
    public static func lorentzian(fwhm: Double) -> LineShapeProfile { .init(kind: .lorentzian, fwhm: fwhm) }
    public static func voigt(gaussianFWHM: Double, lorentzianFWHM: Double) -> LineShapeProfile {
        .init(kind: .voigt, fwhm: voigtFWHM(gaussian: gaussianFWHM, lorentzian: lorentzianFWHM),
              gaussianFWHM: gaussianFWHM, lorentzianFWHM: lorentzianFWHM)
    }
    public static func pseudoVoigt(fwhm: Double, eta: Double) -> LineShapeProfile { .init(kind: .pseudoVoigt, fwhm: fwhm, eta: eta) }
    public static let sticksOnly = LineShapeProfile(kind: .sticks, fwhm: 0)

    /// Bridge from the two-case `LineShape` used by older call sites.
    public init(_ shape: LineShape, fwhm: Double) {
        self.init(kind: shape == .lorentzian ? .lorentzian : .gaussian, fwhm: fwhm)
    }

    /// Approximate Voigt FWHM (Olivero & Longbothum 1977, accurate to 0.02 %).
    public static func voigtFWHM(gaussian fG: Double, lorentzian fL: Double) -> Double {
        0.5346 * fL + (0.2166 * fL * fL + fG * fG).squareRoot()
    }

    public var hasCurve: Bool { kind != .sticks }

    /// FWHM of the resulting band.
    public var effectiveFWHM: Double {
        switch kind {
        case .voigt: return Self.voigtFWHM(gaussian: gaussianFWHM, lorentzian: lorentzianFWHM)
        case .sticks: return 0
        default: return fwhm
        }
    }

    /// How far (in x units) from the centre the band is evaluated. Only the pure Gaussian is cut (at 8 FWHM,
    /// where it is below 1e-76); shapes with Lorentzian wings are summed everywhere so areas stay exact.
    public var reach: Double {
        switch kind {
        case .gaussian: return 8 * fwhm
        case .lorentzian, .pseudoVoigt, .voigt: return .infinity
        case .sticks: return 0
        }
    }

    /// The same shape with every width multiplied by `factor` (unit conversion, e.g. eV → cm⁻¹).
    public func scaled(by factor: Double) -> LineShapeProfile {
        var p = self
        p.fwhm *= factor; p.gaussianFWHM *= factor; p.lorentzianFWHM *= factor
        return p
    }

    /// Unit-area profile at offset `d = x − centre`. `.sticks` returns 0.
    public func area(_ d: Double) -> Double {
        switch kind {
        case .gaussian: return Broadening.gaussianArea(x: d, center: 0, fwhm: fwhm)
        case .lorentzian: return Broadening.lorentzianArea(x: d, center: 0, fwhm: fwhm)
        case .pseudoVoigt:
            return eta * Broadening.lorentzianArea(x: d, center: 0, fwhm: fwhm)
                + (1 - eta) * Broadening.gaussianArea(x: d, center: 0, fwhm: fwhm)
        case .voigt: return Broadening.voigtArea(x: d, center: 0, gaussianFWHM: gaussianFWHM, lorentzianFWHM: lorentzianFWHM)
        case .sticks: return 0
        }
    }

    /// Unit-peak-height profile at offset `d` (1 at d = 0). `.sticks` returns 0.
    public func height(_ d: Double) -> Double {
        switch kind {
        case .gaussian: return Broadening.gaussian(x: d, center: 0, fwhm: fwhm)
        case .lorentzian: return Broadening.lorentzian(x: d, center: 0, fwhm: fwhm)
        case .pseudoVoigt: return area(d) / area(0)     // same shape as the area form, scaled to peak 1
        case .voigt: return Broadening.voigt(x: d, center: 0, gaussianFWHM: gaussianFWHM, lorentzianFWHM: lorentzianFWHM)
        case .sticks: return 0
        }
    }

    /// Peak value of the unit-area profile (converts area- to height-normalisation).
    public var areaPeak: Double { area(0) }

    /// Sum of `heights[i] · profile(x − centres[i])` on `xs` (height- or area-normalised), with a wing
    /// cutoff at `reach` for speed. Returns zeros for `.sticks`.
    public func broaden(centers: [Double], weights: [Double], at xs: [Double], normalization: Normalization) -> [Double] {
        var y = [Double](repeating: 0, count: xs.count)
        guard hasCurve, !xs.isEmpty else { return y }
        let r = reach
        let ascending = xs.count < 2 || xs[1] >= xs[0]
        for (c, wt) in zip(centers, weights) where wt != 0 {
            for i in xs.indices {
                let d = xs[i] - c
                if abs(d) > r {
                    if ascending && d > 0 { break }
                    continue
                }
                y[i] += wt * (normalization == .height ? height(d) : area(d))
            }
        }
        return y
    }

    public enum Normalization: String, Sendable, Codable { case height, area }
}

extension Broadening {
    /// Voigt profile normalised to unit area: V = Re w((d + iγ)/(σ√2)) / (σ√(2π)), with σ = fG/(2√(2 ln 2))
    /// and γ = fL/2. Exact limits: fG = 0 gives the Lorentzian, fL = 0 the Gaussian.
    public static func voigtArea(x: Double, center: Double, gaussianFWHM fG: Double, lorentzianFWHM fL: Double) -> Double {
        let d = x - center
        if fG <= 0 { return fL > 0 ? lorentzianArea(x: x, center: center, fwhm: fL) : (d == 0 ? .infinity : 0) }
        if fL <= 0 { return gaussianArea(x: x, center: center, fwhm: fG) }
        let sigma = fG / (2 * (2 * log(2.0)).squareRoot())
        let s2 = sigma * 2.0.squareRoot()
        return Faddeeva.w(x: d / s2, y: fL / 2 / s2).re / (sigma * (2 * Double.pi).squareRoot())
    }

    /// Voigt profile scaled to unit peak height.
    public static func voigt(x: Double, center: Double, gaussianFWHM fG: Double, lorentzianFWHM fL: Double) -> Double {
        if fG <= 0 { return lorentzian(x: x, center: center, fwhm: fL) }
        if fL <= 0 { return gaussian(x: x, center: center, fwhm: fG) }
        return voigtArea(x: x, center: center, gaussianFWHM: fG, lorentzianFWHM: fL)
            / voigtArea(x: 0, center: 0, gaussianFWHM: fG, lorentzianFWHM: fL)
    }
}

// MARK: - Transmittance

/// IR %Transmittance from an absorbance-like intensity curve, by Beer–Lambert: T = 100·10^(−k·I).
/// `k` is chosen so the strongest value `maxIntensity` reaches `minimumPercent` (default 15 %T):
/// k = −log10(minimumPercent/100) / maxIntensity. Zero intensity maps to exactly 100 %T; T stays in (0, 100].
/// The logarithmic mapping compresses the strongest bands, so a band at 5 % of the strongest one still dips
/// to ≈ 91 %T (a linear 100 − 85·I/Imax mapping would only reach ≈ 96 %T).
public struct TransmittanceScale: Sendable, Equatable {
    public var k: Double
    public init(maxIntensity: Double, minimumPercent: Double = 15) {
        let tMin = min(99.9, max(0.1, minimumPercent)) / 100
        k = maxIntensity > 0 ? -log10(tMin) / maxIntensity : 0
    }
    public func percent(_ intensity: Double) -> Double {
        min(100, max(0, 100 * pow(10, -k * max(0, intensity))))
    }

    /// The same spectrum as %T: points and stick tips mapped, y label "Transmittance (%)". The scale uses the
    /// larger of the curve maximum and the strongest stick.
    public static func transmittance(_ s: Spectrum, minimumPercent: Double = 15) -> Spectrum {
        let mx = max(s.points.map(\.y).max() ?? 0, s.sticks.map(\.height).max() ?? 0)
        let t = TransmittanceScale(maxIntensity: mx, minimumPercent: minimumPercent)
        var out = s
        out.points = s.points.map { SpectrumPoint(x: $0.x, y: t.percent($0.y)) }
        out.sticks = s.sticks.map { var st = $0; st.height = t.percent($0.height); return st }
        out.yLabel = "Transmittance (%)"
        return out
    }
}

// MARK: - Persisted display choice

/// The user's spectrum display choice for one panel, persisted as JSON in UserDefaults.
public struct SpectrumDisplaySettings: Sendable, Codable, Equatable {
    public var profile: LineShapeProfile
    /// IR only: show %Transmittance (default) instead of absorbance/intensity.
    public var transmittance: Bool

    public init(profile: LineShapeProfile, transmittance: Bool = true) {
        self.profile = profile; self.transmittance = transmittance
    }

    /// Defaults: vibrational Lorentzian 20 cm⁻¹ with %T; electronic Gaussian 0.35 eV.
    public static let vibrationalDefault = SpectrumDisplaySettings(
        profile: LineShapeProfile(kind: .lorentzian, fwhm: 20, gaussianFWHM: 10, lorentzianFWHM: 10, eta: 0.5), transmittance: true)
    public static let electronicDefault = SpectrumDisplaySettings(
        profile: LineShapeProfile(kind: .gaussian, fwhm: 0.35, gaussianFWHM: 0.25, lorentzianFWHM: 0.15, eta: 0.5), transmittance: false)

    public static let vibrationalKey = "spectrum.vibrational.display"
    public static let electronicKey = "spectrum.electronic.display"

    public static func load(key: String, default def: SpectrumDisplaySettings, from defaults: UserDefaults = .standard) -> SpectrumDisplaySettings {
        guard let data = defaults.data(forKey: key),
              let s = try? JSONDecoder().decode(SpectrumDisplaySettings.self, from: data) else { return def }
        return s
    }

    public func save(key: String, to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: key) }
    }
}
