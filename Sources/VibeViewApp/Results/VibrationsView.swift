import SwiftUI
import Charts
import MolCore
import MolAnalysis

struct VibrationsView: View {
    @ObservedObject var editor: EditorModel
    let result: CalculationResult

    enum Kind: String, CaseIterable, Identifiable { case ir = "IR", raman = "Raman"; var id: String { rawValue } }

    @State private var kind: Kind = .ir
    @StateObject private var display = SpectrumDisplayStore.vibrational()
    @State private var scale = 1.0
    @State private var scaleText = "1.000"

    private struct Row: Identifiable {
        var id: Int; var mode: NormalMode
        var freqText: String { mode.frequency < 0 ? String(format: "%.1fi", -mode.frequency) : String(format: "%.1f", mode.frequency) }
    }
    private var rows: [Row] { result.normalModes.enumerated().map { Row(id: $0.offset, mode: $0.element) } }
    private var hasRaman: Bool { result.normalModes.contains { $0.ramanActivity != nil } }

    private var sticks: [SpecStick] {
        result.normalModes.enumerated().compactMap { i, m in
            let h = kind == .ir ? m.irIntensity : (m.ramanActivity ?? 0)
            guard h > 0 else { return nil }
            return SpecStick(x: abs(m.frequency) * scale, height: h, index: i)
        }
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 6) {
                spectrumControls
                spectrumChart
                playbackControls
            }
            .padding(10).frame(minWidth: 320)
            modeTable.frame(minWidth: 280)
        }
        .onDisappear { editor.activeModeIndex = nil }
    }

    /// IR in %Transmittance (the default) rather than absorbance; Raman is always intensity.
    private var showsTransmittance: Bool { kind == .ir && display.settings.transmittance }

    private var spectrumControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                if hasRaman {
                    Picker("", selection: $kind) { ForEach(Kind.allCases) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                } else {
                    Text("IR spectrum").font(.headline)
                }
                if kind == .ir {
                    Picker("", selection: $display.settings.transmittance) {
                        Text("%T").tag(true)
                        Text("Absorbance").tag(false)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    .help("Transmittance T = 100·10^(−k·I), k chosen so the strongest band reaches 15 %T; or the absorbance-like intensity")
                }
                Text("Scale").font(.caption).foregroundStyle(.secondary)
                TextField("", text: $scaleText)
                    .frame(width: 56).textFieldStyle(.roundedBorder).monospacedDigit()
                    .onSubmit { if let v = Double(scaleText), v > 0.2, v < 2 { scale = v } else { scaleText = String(format: "%.3f", scale) } }
                Spacer(minLength: 0)
            }
            LineShapeControls(profile: $display.settings.profile, unit: "cm⁻¹", range: 1...100, format: "%.0f")
        }
    }

    private var spectrumChart: some View {
        let s = sticks
        let raw = SpectrumMath.broaden(s, profile: display.settings.profile, from: 0, to: 4000)
        let maxY = max(raw.map(\.y).max() ?? 0, s.map(\.height).max() ?? 0, 1e-9)
        let percentT = showsTransmittance
        // %T: Beer–Lambert mapping scaled so the strongest band (curve or stick) reaches 15 %T.
        let tScale = TransmittanceScale(maxIntensity: maxY, minimumPercent: 15)
        let curve = percentT ? raw.map { SpecPoint(x: $0.x, y: tScale.percent($0.y)) } : raw
        let base = percentT ? 100.0 : 0.0
        func tip(_ st: SpecStick) -> Double { percentT ? tScale.percent(st.height) : st.height }
        return Chart {
            ForEach(curve) { p in
                LineMark(x: .value("Wavenumber", -p.x), y: .value("Intensity", p.y))
                    .foregroundStyle(Color.accentColor).lineStyle(StrokeStyle(lineWidth: 1.3))
            }
            ForEach(s) { st in
                RuleMark(x: .value("Wavenumber", -st.x), yStart: .value("", base), yEnd: .value("", tip(st)))
                    .foregroundStyle(st.index == editor.activeModeIndex ? Color.orange : Color.secondary.opacity(0.55))
                    .lineStyle(StrokeStyle(lineWidth: st.index == editor.activeModeIndex ? 3 : 1.2))
            }
        }
        .chartXScale(domain: -4000...0)
        .chartYScale(domain: percentT ? 0...105 : 0...(maxY * 1.08))
        .chartXAxis {
            AxisMarks(values: .stride(by: 500)) { v in
                AxisGridLine(); AxisTick()
                AxisValueLabel { if let d = v.as(Double.self) { Text("\(Int(-d))") } }
            }
        }
        .chartXAxisLabel("Wavenumber (cm⁻¹)")
        .chartYAxisLabel(percentT ? "Transmittance (%)" : (kind == .ir ? "IR intensity (km/mol)" : "Raman activity (Å⁴/amu)"))
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onTapGesture(coordinateSpace: .local) { loc in
                        guard let plot = proxy.plotFrame else { return }
                        let x = loc.x - geo[plot].origin.x
                        if let v: Double = proxy.value(atX: x), let hit = SpectrumMath.nearest(s, to: -v) {
                            editor.activeModeIndex = hit.index
                        }
                    }
            }
        }
        .frame(minHeight: 120)
    }

    private var playbackControls: some View {
        HStack(spacing: 10) {
            Text("Amplitude").font(.caption).foregroundStyle(.secondary)
            Slider(value: $editor.vibrationAmplitude, in: 0.1...2).frame(maxWidth: 140)
            Toggle("Arrows", isOn: $editor.showDisplacementArrows).toggleStyle(.checkbox).font(.caption)
            Spacer()
            Button { editor.activeModeIndex = nil } label: { Label("Stop", systemImage: "stop.fill") }
                .controlSize(.small).disabled(editor.activeModeIndex == nil)
        }
    }

    private var modeTable: some View {
        Table(rows, selection: Binding<Int?>(get: { editor.activeModeIndex }, set: { editor.activeModeIndex = $0 })) {
            TableColumn("#") { r in Text("\(r.id + 1)").monospacedDigit() }.width(28)
            TableColumn("ν (cm⁻¹)") { r in
                Text(r.freqText).monospacedDigit().foregroundStyle(r.mode.frequency < 0 ? Color.red : Color.primary)
            }.width(min: 60, ideal: 74)
            TableColumn("Sym.") { r in Text(r.mode.symmetry ?? "–").foregroundStyle(.secondary) }.width(min: 36, ideal: 50)
            TableColumn("IR") { r in Text(String(format: "%.2f", r.mode.irIntensity)).monospacedDigit() }.width(min: 44, ideal: 56)
            TableColumn("Raman") { r in
                Text(r.mode.ramanActivity.map { String(format: "%.2f", $0) } ?? "–").monospacedDigit()
            }.width(min: 44, ideal: 56)
        }
    }
}
