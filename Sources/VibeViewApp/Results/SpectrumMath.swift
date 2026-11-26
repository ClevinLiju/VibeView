import Foundation
import SwiftUI
import MolAnalysis

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

/// Line-broadening helpers for the results panels. Curves are peak-height normalised: an isolated stick of
/// height h gives a band of height h for every line shape (MolAnalysis `LineShapeProfile`).
enum SpectrumMath {
    static let hartreeToKcal = 627.5095
    static let hartreeToEV = 27.211386
    static let evNanometer = 1239.841984

    /// Broadened curve on an x grid (widths of `profile` in x units, e.g. cm⁻¹). Empty for sticks only.
    static func broaden(_ sticks: [SpecStick], profile: LineShapeProfile, from lo: Double, to hi: Double, count: Int = 1600) -> [SpecPoint] {
        guard profile.hasCurve else { return [] }
        let xs = grid(lo, hi, count)
        let ys = profile.broaden(centers: sticks.map(\.x), weights: sticks.map(\.height), at: xs, normalization: .height)
        return zip(xs, ys).map { SpecPoint(x: $0, y: $1) }
    }

    /// Broadening in energy (profile widths in eV), sampled on a wavelength (nm) grid.
    static func broadenInEV(energiesEV: [(e: Double, h: Double)], profile: LineShapeProfile, fromNM lo: Double, toNM hi: Double, count: Int = 900) -> [SpecPoint] {
        guard profile.hasCurve else { return [] }
        let nms = grid(lo, hi, count)
        let ys = profile.broaden(centers: energiesEV.map(\.e), weights: energiesEV.map(\.h),
                                 at: nms.map { evNanometer / $0 }, normalization: .height)
        return zip(nms, ys).map { SpecPoint(x: $0, y: $1) }
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

/// The user's last line-shape / display choice for one panel kind, saved to UserDefaults on every change.
final class SpectrumDisplayStore: ObservableObject {
    let key: String
    @Published var settings: SpectrumDisplaySettings { didSet { settings.save(key: key) } }

    init(key: String, default def: SpectrumDisplaySettings) {
        self.key = key
        settings = SpectrumDisplaySettings.load(key: key, default: def)
    }

    static func vibrational() -> SpectrumDisplayStore { .init(key: SpectrumDisplaySettings.vibrationalKey, default: .vibrationalDefault) }
    static func electronic() -> SpectrumDisplayStore { .init(key: SpectrumDisplaySettings.electronicKey, default: .electronicDefault) }
}

/// Line-shape picker plus the width controls that shape needs. Widths are FWHM in `unit`.
struct LineShapeControls: View {
    @Binding var profile: LineShapeProfile
    let unit: String
    let range: ClosedRange<Double>
    let format: String

    var body: some View {
        HStack(spacing: 8) {
            Picker("Line shape", selection: $profile.kind) {
                ForEach(LineShapeKind.allCases) { Text($0.displayName).tag($0) }
            }
            .labelsHidden().fixedSize()
            .help("Line shape used to broaden the sticks. Curves are peak-height normalised.")
            switch profile.kind {
            case .gaussian, .lorentzian:
                width("FWHM", $profile.fwhm)
            case .pseudoVoigt:
                width("FWHM", $profile.fwhm)
                Text("η").font(.caption).foregroundStyle(.secondary)
                Slider(value: $profile.eta, in: 0...1).frame(maxWidth: 70)
                Text(String(format: "%.2f", profile.eta)).monospacedDigit().font(.caption).frame(width: 30, alignment: .trailing)
                    .help("Lorentzian fraction: η·Lorentzian + (1 − η)·Gaussian, same FWHM")
            case .voigt:
                width("Gauss", $profile.gaussianFWHM)
                width("Lorentz", $profile.lorentzianFWHM)
                Text(String(format: "→ \(format) \(unit)", profile.effectiveFWHM)).font(.caption).foregroundStyle(.secondary)
                    .monospacedDigit().help("FWHM of the resulting Voigt band")
            case .sticks:
                EmptyView()
            }
            Spacer(minLength: 0)
        }
    }

    private func width(_ label: String, _ value: Binding<Double>) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Slider(value: value, in: range).frame(minWidth: 50, maxWidth: 100)
            Text(String(format: "\(format) \(unit)", value.wrappedValue)).monospacedDigit().font(.caption)
                .frame(minWidth: 44, alignment: .trailing)
        }
        .help("\(label) FWHM in \(unit)")
    }
}
