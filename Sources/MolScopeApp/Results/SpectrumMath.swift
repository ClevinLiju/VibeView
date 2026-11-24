import Foundation

struct SpecPoint: Identifiable, Equatable {
    var x: Double
    var y: Double
    var id: Double { x }
}

struct SpecStick: Identifiable, Equatable {
    var x: Double
    var height: Double
    var index: Int          // index into the source array
    var id: Int { index }
}

/// Small line-broadening helpers. Peak heights are preserved (a stick of height h gives a peak of height h).
enum SpectrumMath {
    static let hartreeToKcal = 627.5095
    static let hartreeToEV = 27.211386
    static let evNanometer = 1239.841984

    /// Lorentzian with FWHM in x units (cm-1).
    static func lorentzian(_ sticks: [SpecStick], fwhm: Double, from lo: Double, to hi: Double, count: Int = 1600) -> [SpecPoint] {
        let g = max(fwhm, 0.01) / 2
        return grid(lo, hi, count).map { x in
            var y = 0.0
            for s in sticks { let d = x - s.x; y += s.height * g * g / (d * d + g * g) }
            return SpecPoint(x: x, y: y)
        }
    }

    /// Gaussian broadening in energy (FWHM in eV), evaluated on a wavelength (nm) grid.
    static func gaussianInEV(energiesEV: [(e: Double, h: Double)], fwhmEV: Double, fromNM lo: Double, toNM hi: Double, count: Int = 900) -> [SpecPoint] {
        let sigma = max(fwhmEV, 0.005) / 2.354820045
        return grid(lo, hi, count).map { nm in
            let e = evNanometer / nm
            var y = 0.0
            for s in energiesEV { let d = e - s.e; y += s.h * exp(-d * d / (2 * sigma * sigma)) }
            return SpecPoint(x: nm, y: y)
        }
    }

    private static func grid(_ lo: Double, _ hi: Double, _ n: Int) -> [Double] {
        guard n > 1, hi > lo else { return [lo] }
        let step = (hi - lo) / Double(n - 1)
        return (0..<n).map { lo + Double($0) * step }
    }

    static func nearest(_ sticks: [SpecStick], to x: Double) -> SpecStick? {
        sticks.min { abs($0.x - x) < abs($1.x - x) }
    }
}
