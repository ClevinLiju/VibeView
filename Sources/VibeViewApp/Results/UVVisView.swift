import SwiftUI
import Charts
import MolCore

struct UVVisView: View {
    let result: CalculationResult

    @State private var fwhm = 0.35       // eV
    @State private var selected: Int?

    private struct Row: Identifiable { var id: Int; var s: ExcitedState }
    private var rows: [Row] { result.excitedStates.enumerated().map { Row(id: $0.offset, s: $0.element) } }
    private var sticks: [SpecStick] {
        result.excitedStates.enumerated().map { SpecStick(x: $0.element.wavelengthNM, height: $0.element.oscillatorStrength, index: $0.offset) }
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 6) {
                HStack {
                    Text("Absorption").font(.headline)
                    Spacer()
                    Text("FWHM").font(.caption).foregroundStyle(.secondary)
                    Slider(value: $fwhm, in: 0.05...1.0).frame(maxWidth: 140)
                    Text(String(format: "%.2f eV", fwhm)).monospacedDigit().font(.caption).frame(width: 52, alignment: .trailing)
                }
                chart
            }
            .padding(10).frame(minWidth: 320)
            Table(rows, selection: $selected) {
                TableColumn("State") { r in Text("S\(r.id + 1)").monospacedDigit() }.width(40)
                TableColumn("eV") { r in Text(String(format: "%.3f", r.s.energyEV)).monospacedDigit() }.width(min: 44, ideal: 56)
                TableColumn("nm") { r in Text(String(format: "%.1f", r.s.wavelengthNM)).monospacedDigit() }.width(min: 44, ideal: 56)
                TableColumn("f") { r in Text(String(format: "%.4f", r.s.oscillatorStrength)).monospacedDigit() }.width(min: 50, ideal: 64)
            }
            .frame(minWidth: 240)
        }
    }

    private var chart: some View {
        let s = sticks
        let nms = s.map(\.x).filter { $0 > 0 }
        let lo = max(100, (nms.min() ?? 200) - 60)
        let hi = min(1500, (nms.max() ?? 600) + 120)
        let curve = SpectrumMath.gaussianInEV(
            energiesEV: result.excitedStates.map { (e: $0.energyEV, h: $0.oscillatorStrength) },
            fwhmEV: fwhm, fromNM: lo, toNM: hi)
        let maxY = max(curve.map(\.y).max() ?? 0, s.map(\.height).max() ?? 0, 1e-6)
        return Chart {
            ForEach(curve) { p in
                LineMark(x: .value("Wavelength", p.x), y: .value("Intensity", p.y))
                    .foregroundStyle(Color.accentColor).lineStyle(StrokeStyle(lineWidth: 1.3))
            }
            ForEach(s) { st in
                RuleMark(x: .value("Wavelength", st.x), yStart: .value("", 0), yEnd: .value("", st.height))
                    .foregroundStyle(st.index == selected ? Color.orange : Color.secondary.opacity(0.55))
                    .lineStyle(StrokeStyle(lineWidth: st.index == selected ? 3 : 1.2))
            }
        }
        .chartXScale(domain: lo...hi)
        .chartYScale(domain: 0...(maxY * 1.1))
        .chartXAxisLabel("Wavelength (nm)")
        .chartYAxisLabel("Oscillator strength")
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onTapGesture(coordinateSpace: .local) { loc in
                        guard let plot = proxy.plotFrame else { return }
                        let x = loc.x - geo[plot].origin.x
                        if let v: Double = proxy.value(atX: x) { selected = SpectrumMath.nearest(s, to: v)?.index }
                    }
            }
        }
        .frame(minHeight: 120)
    }
}
