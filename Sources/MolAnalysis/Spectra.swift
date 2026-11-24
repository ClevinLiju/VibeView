import Foundation
import MolCore

// Spectrum construction: IR, Raman, UV-Vis, ECD, NMR. Textbook line shapes and standard
// published conversion formulas only.

// MARK: - Line shapes

/// Line-shape functions. "Height" variants peak at 1 at `center`; "Area" variants integrate to 1.
/// `fwhm` is the full width at half maximum in the same unit as `x`.
public enum Broadening {
    /// Lorentzian with unit peak height.
    public static func lorentzian(x: Double, center: Double, fwhm: Double) -> Double {
        let g = fwhm / 2
        let d = x - center
        return g * g / (d * d + g * g)
    }
    /// Gaussian with unit peak height.
    public static func gaussian(x: Double, center: Double, fwhm: Double) -> Double {
        let d = (x - center) / fwhm
        return exp(-4 * log(2.0) * d * d)
    }
    /// Lorentzian normalised to unit area.
    public static func lorentzianArea(x: Double, center: Double, fwhm: Double) -> Double {
        lorentzian(x: x, center: center, fwhm: fwhm) * 2 / (Double.pi * fwhm)
    }
    /// Gaussian normalised to unit area.
    public static func gaussianArea(x: Double, center: Double, fwhm: Double) -> Double {
        gaussian(x: x, center: center, fwhm: fwhm) * (4 * log(2.0) / Double.pi).squareRoot() / fwhm
    }
    static func height(_ shape: LineShape, x: Double, center: Double, fwhm: Double) -> Double {
        shape == .lorentzian ? lorentzian(x: x, center: center, fwhm: fwhm) : gaussian(x: x, center: center, fwhm: fwhm)
    }
    static func area(_ shape: LineShape, x: Double, center: Double, fwhm: Double) -> Double {
        shape == .lorentzian ? lorentzianArea(x: x, center: center, fwhm: fwhm) : gaussianArea(x: x, center: center, fwhm: fwhm)
    }
}

/// Horizontal axis of an electronic spectrum.
public enum SpectrumAxis: String, Sendable, Codable, CaseIterable {
    case wavelengthNM, energyEV, wavenumber
}

/// One NMR isotropic shielding (ppm) for an atom.
public struct NMRShielding: Sendable, Equatable, Codable {
    public var atomIndex: Int      // 0-based
    public var element: Int        // atomic number
    public var isotropic: Double   // ppm
    public init(atomIndex: Int, element: Int, isotropic: Double) {
        self.atomIndex = atomIndex; self.element = element; self.isotropic = isotropic
    }
}

/// Reference for converting shieldings to chemical shifts.
public enum NMRReference: Sendable, Equatable, Codable {
    /// δ = σ_ref − σ, with σ_ref the shielding of the reference compound (e.g. TMS) at the same level.
    case shielding(Double)
    /// Empirical scaling σ = intercept + slope·δ, i.e. δ = (σ − intercept)/slope (slope is usually ≈ −1).
    case linear(slope: Double, intercept: Double)

    /// Convenience: reference given by the computed shielding of TMS.
    public static func tms(shielding: Double) -> NMRReference { .shielding(shielding) }

    /// Chemical shift (ppm) for a shielding (ppm).
    public func shift(forShielding sigma: Double) -> Double {
        switch self {
        case .shielding(let r): return r - sigma
        case .linear(let slope, let intercept): return (intercept - sigma) / (-slope)
        }
    }
}

// MARK: - Spectrum builder

public enum SpectrumBuilder {
    /// cm⁻¹ per eV
    static let evToWavenumber = 8065.543937349211
    /// ε integral constant: ∫ε dν̃ = 1.3062974e8·√π·f ≈ 2.3154e8·f (L mol⁻¹ cm⁻² per unit f).
    static let epsilonAreaConstant = 1.3062974e8 * Double.pi.squareRoot()
    /// Δε prefactor of the standard ECD formula (R in cgs units, energies in eV).
    static let ecdConstant = 2.296e-39

    static func grid(_ range: ClosedRange<Double>, _ n: Int) -> [Double] {
        let n = max(2, n)
        let step = (range.upperBound - range.lowerBound) / Double(n - 1)
        return (0..<n).map { range.lowerBound + Double($0) * step }
    }

    // MARK: IR / Raman

    /// IR spectrum. Sticks sit at `scale·ν` with height = IR intensity (km/mol). The curve is the sum of
    /// height-normalised line shapes weighted by intensity: a single isolated band of intensity I has a
    /// peak height of I (not area I). The x axis is reversed (conventional IR display).
    public static func ir(modes: [NormalMode], scale: Double = 1.0, fwhm: Double = 10,
                          shape: LineShape = .lorentzian, range: ClosedRange<Double> = 0...4000,
                          pointCount: Int = 2000, includeImaginary: Bool = false) -> Spectrum {
        var sticks: [SpectrumStick] = []
        for (i, m) in modes.enumerated() {
            if m.frequency < 0 && !includeImaginary { continue }
            let nu = m.frequency * scale
            sticks.append(SpectrumStick(x: nu, height: m.irIntensity, label: label(i, m.symmetry), sourceIndex: i))
        }
        let pts = curve(sticks: sticks, shape: shape, fwhm: fwhm, range: range, count: pointCount)
        return Spectrum(points: pts, sticks: sticks.filter { range.contains($0.x) },
                        xLabel: "Wavenumber (cm⁻¹)", yLabel: "IR intensity (km/mol)", xAxisReversed: true)
    }

    /// Raman spectrum. Without `excitationNM` the y axis is the Raman activity (Å⁴/amu) and each isolated
    /// band peaks at its activity. With `excitationNM` the activities are converted to relative scattering
    /// intensities I ∝ S·(ν0−νi)⁴ / (νi·(1−exp(−hcνi/kT))) (cm⁻¹ units) and everything is normalised so the
    /// strongest stick is 1.
    public static func raman(modes: [NormalMode], scale: Double = 1.0, fwhm: Double = 10,
                             shape: LineShape = .lorentzian, range: ClosedRange<Double> = 0...4000,
                             pointCount: Int = 2000, excitationNM: Double? = nil,
                             temperature: Double = 298.15) -> Spectrum {
        var sticks: [SpectrumStick] = []
        for (i, m) in modes.enumerated() {
            guard m.frequency > 0, let s = m.ramanActivity else { continue }
            let nu = m.frequency * scale
            var h = s
            if let l0 = excitationNM, l0 > 0 {
                let nu0 = 1e7 / l0
                let x = PhysConst.h * PhysConst.c * nu / (PhysConst.kB * temperature)
                h = s * pow(nu0 - nu, 4) / nu / (1 - exp(-x))
            }
            sticks.append(SpectrumStick(x: nu, height: h, label: label(i, m.symmetry), sourceIndex: i))
        }
        if excitationNM != nil, let mx = sticks.map({ abs($0.height) }).max(), mx > 0 {
            for k in sticks.indices { sticks[k].height /= mx }
        }
        let pts = curve(sticks: sticks, shape: shape, fwhm: fwhm, range: range, count: pointCount)
        return Spectrum(points: pts, sticks: sticks.filter { range.contains($0.x) },
                        xLabel: "Raman shift (cm⁻¹)",
                        yLabel: excitationNM == nil ? "Raman activity (Å⁴/amu)" : "Raman intensity (relative)",
                        xAxisReversed: false)
    }

    private static func label(_ i: Int, _ sym: String?) -> String {
        if let s = sym, !s.isEmpty { return "mode \(i + 1) (\(s))" }
        return "mode \(i + 1)"
    }

    private static func curve(sticks: [SpectrumStick], shape: LineShape, fwhm: Double,
                              range: ClosedRange<Double>, count: Int) -> [SpectrumPoint] {
        grid(range, count).map { x in
            var y = 0.0
            for s in sticks { y += s.height * Broadening.height(shape, x: x, center: s.x, fwhm: fwhm) }
            return SpectrumPoint(x: x, y: y)
        }
    }

    // MARK: Electronic spectra

    private static func axisValue(_ axis: SpectrumAxis, eV: Double) -> Double {
        switch axis {
        case .wavelengthNM: return PhysConst.evToNMFactor / eV
        case .energyEV: return eV
        case .wavenumber: return eV * evToWavenumber
        }
    }
    private static func eVFromAxis(_ axis: SpectrumAxis, x: Double) -> Double {
        switch axis {
        case .wavelengthNM: return PhysConst.evToNMFactor / x
        case .energyEV: return x
        case .wavenumber: return x / evToWavenumber
        }
    }
    private static func defaultRange(axis: SpectrumAxis, energies: [Double], fwhmEV: Double,
                                     shape: LineShape) -> ClosedRange<Double> {
        let pad = fwhmEV * (shape == .lorentzian ? 12 : 4)
        let lo = max(0.2, (energies.min() ?? 3) - pad)
        let hi = (energies.max() ?? 6) + pad
        let a = axisValue(axis, eV: lo), b = axisValue(axis, eV: hi)
        return min(a, b)...max(a, b)
    }

    /// Electronic absorption spectrum. Broadening is applied in energy space with FWHM `fwhmEV`, then the
    /// curve is sampled on the chosen axis. y = molar absorptivity ε (L mol⁻¹ cm⁻¹) from the standard
    /// relation ε(ν̃) = 1.3062974e8·f/σ·exp(−((ν̃−ν̃ᵢ)/σ)²) with σ = FWHM/(2√ln2) the 1/e half-width in cm⁻¹
    /// (Gaussian); the Lorentzian uses the same integrated intensity (∫ε dν̃ = 2.3154e8·f).
    /// Sticks are drawn at the band centre with height = ε at the maximum of that isolated band
    /// (same y unit as the curve), not the raw oscillator strength.
    public static func uvVis(states: [ExcitedState], fwhmEV: Double = 0.3, shape: LineShape = .gaussian,
                             axis: SpectrumAxis = .wavelengthNM, range: ClosedRange<Double>? = nil,
                             pointCount: Int = 1000) -> Spectrum {
        electronic(states: states, strengths: states.map { $0.oscillatorStrength }, prefactor: { _, f in
            epsilonAreaConstant * f
        }, fwhmEV: fwhmEV, shape: shape, axis: axis, range: range, pointCount: pointCount,
        yLabel: "ε (L mol⁻¹ cm⁻¹)", wavenumberDomain: true)
    }

    /// Electronic circular dichroism. `rotatoryStrengths` are in 1e-40 erg·esu·cm/G (cgs, length or velocity
    /// gauge as supplied). Δε(E) = 1/(2.296e-39·√π·σ) · Eᵢ · Rᵢ · exp(−((E−Eᵢ)/σ)²) with E, σ in eV and
    /// R in cgs (σ = FWHM/(2√ln2)); the sign of Δε follows the sign of R. Sticks are the isolated-band
    /// Δε maxima. y = Δε (L mol⁻¹ cm⁻¹).
    public static func ecd(states: [ExcitedState], rotatoryStrengths: [Double], fwhmEV: Double = 0.3,
                           shape: LineShape = .gaussian, axis: SpectrumAxis = .wavelengthNM,
                           range: ClosedRange<Double>? = nil, pointCount: Int = 1000) -> Spectrum {
        let n = min(states.count, rotatoryStrengths.count)
        let st = Array(states.prefix(n))
        return electronic(states: st, strengths: Array(rotatoryStrengths.prefix(n)), prefactor: { s, r in
            s.energyEV * r * 1e-40 / ecdConstant
        }, fwhmEV: fwhmEV, shape: shape, axis: axis, range: range, pointCount: pointCount,
        yLabel: "Δε (L mol⁻¹ cm⁻¹)", wavenumberDomain: false)
    }

    private static func electronic(states: [ExcitedState], strengths: [Double],
                                   prefactor: (ExcitedState, Double) -> Double,
                                   fwhmEV: Double, shape: LineShape, axis: SpectrumAxis,
                                   range: ClosedRange<Double>?, pointCount: Int,
                                   yLabel: String, wavenumberDomain: Bool) -> Spectrum {
        // wavenumberDomain: area measured per cm⁻¹ (ε); otherwise per eV (Δε).
        let width = wavenumberDomain ? fwhmEV * evToWavenumber : fwhmEV
        let amps = zip(states, strengths).map { prefactor($0, $1) }
        let rng = range ?? defaultRange(axis: axis, energies: states.map { $0.energyEV }, fwhmEV: fwhmEV, shape: shape)
        let xs = grid(rng, pointCount)
        let pts: [SpectrumPoint] = xs.map { x in
            let e = eVFromAxis(axis, x: x)
            let v = wavenumberDomain ? e * evToWavenumber : e
            var y = 0.0
            for (i, s) in states.enumerated() {
                let c = wavenumberDomain ? s.energyEV * evToWavenumber : s.energyEV
                y += amps[i] * Broadening.area(shape, x: v, center: c, fwhm: width)
            }
            return SpectrumPoint(x: x, y: y)
        }
        let sticks = states.enumerated().map { i, s in
            SpectrumStick(x: axisValue(axis, eV: s.energyEV),
                          height: amps[i] * Broadening.area(shape, x: 0, center: 0, fwhm: width),
                          label: "S\(i + 1)", sourceIndex: i)
        }
        let xLabel: String
        switch axis {
        case .wavelengthNM: xLabel = "Wavelength (nm)"
        case .energyEV: xLabel = "Energy (eV)"
        case .wavenumber: xLabel = "Wavenumber (cm⁻¹)"
        }
        return Spectrum(points: pts, sticks: sticks, xLabel: xLabel, yLabel: yLabel, xAxisReversed: false)
    }

    // MARK: NMR

    /// NMR spectrum of one element. δ = σ_ref − σ (or the linear-scaling formula). Each nucleus is a
    /// height-1 band (height = number of nuclei when merged). `mergeEquivalent` (ppm) merges shifts closer
    /// than the tolerance into one stick at their mean shift with height = count. The x axis is reversed.
    public static func nmr(shieldings: [NMRShielding], element: Int, reference: NMRReference,
                           fwhm: Double = 0.02, range: ClosedRange<Double>? = nil, pointCount: Int = 2000,
                           mergeEquivalent: Double? = nil) -> Spectrum {
        let items = shieldings.filter { $0.element == element }
            .map { (idx: $0.atomIndex, delta: reference.shift(forShielding: $0.isotropic)) }
            .sorted { $0.delta < $1.delta }
        var sticks: [SpectrumStick] = []
        if let tol = mergeEquivalent, tol > 0 {
            var group: [(idx: Int, delta: Double)] = []
            func flush() {
                guard !group.isEmpty else { return }
                let mean = group.map { $0.delta }.reduce(0, +) / Double(group.count)
                sticks.append(SpectrumStick(x: mean, height: Double(group.count),
                                            label: group.count > 1 ? "\(group.count)× atoms" : "atom \(group[0].idx + 1)",
                                            sourceIndex: group[0].idx))
                group = []
            }
            for it in items {
                if let last = group.last, it.delta - last.delta > tol { flush() }
                group.append(it)
            }
            flush()
        } else {
            sticks = items.map { SpectrumStick(x: $0.delta, height: 1, label: "atom \($0.idx + 1)", sourceIndex: $0.idx) }
        }
        let xs = sticks.map { $0.x }
        let rng = range ?? ((xs.min() ?? 0) - 1)...((xs.max() ?? 10) + 1)
        let pts = curve(sticks: sticks, shape: .lorentzian, fwhm: fwhm, range: rng, count: pointCount)
        return Spectrum(points: pts, sticks: sticks, xLabel: "δ (ppm)", yLabel: "Intensity (nuclei)", xAxisReversed: true)
    }
}
