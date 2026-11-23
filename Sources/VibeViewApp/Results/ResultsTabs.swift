import SwiftUI
import Charts
import MolCore

let hartreeToKcal = 627.5094740631
let hartreeToEV = 27.211386245988

// MARK: Convergence

struct ConvergenceTab: View {
    @ObservedObject var editor: EditorModel
    let result: CalculationResult
    @StateObject private var relBox = VMBox(true)

    private var values: [Double] {
        guard relBox.value, let ref = result.energies.min() else { return result.energies }
        return result.energies.map { ($0 - ref) * hartreeToKcal }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle("Relative (kcal/mol)", isOn: $relBox.value)
                Spacer()
                if let last = result.energies.last { Text(String(format: "Final: %.8f Eh", last)).monospacedDigit().foregroundStyle(.secondary) }
                Text(result.normalTermination ? "Normal termination" : "No normal termination")
                    .font(.caption).foregroundStyle(result.normalTermination ? .green : .orange)
            }
            let vals = values
            Chart {
                ForEach(Array(vals.enumerated()), id: \.offset) { i, v in
                    LineMark(x: .value("Step", i + 1), y: .value("Energy", v)).foregroundStyle(.blue)
                    PointMark(x: .value("Step", i + 1), y: .value("Energy", v)).symbolSize(20).foregroundStyle(.blue)
                }
                if let f = editor.frameIndex, vals.indices.contains(f) {
                    RuleMark(x: .value("Step", f + 1)).foregroundStyle(.orange)
                    PointMark(x: .value("Step", f + 1), y: .value("Energy", vals[f])).symbolSize(90).foregroundStyle(.orange)
                }
            }
            .chartXAxisLabel("Step")
            .chartYAxisLabel(relBox.value ? "\u{0394}E (kcal/mol)" : "E (Hartree)")
            .chartYScale(domain: .automatic(includesZero: false))
        }
        .padding(10)
    }
}

// MARK: Frames

struct FramesTab: View {
    @ObservedObject var editor: EditorModel
    let result: CalculationResult
    @StateObject private var play_ = VMBox(false)
    @StateObject private var timerBox = VMBox<Timer?>(nil)

    private var count: Int { result.steps.count }
    private var index: Int { min(max(editor.frameIndex ?? (count - 1), 0), max(count - 1, 0)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Frame \(index + 1) of \(count)").font(.headline)
            if result.energies.indices.contains(index) {
                Text(String(format: "Energy: %.8f Eh", result.energies[index])).monospacedDigit().foregroundStyle(.secondary)
            }
            HStack {
                Button { step(-1) } label: { Image(systemName: "backward.frame") }.disabled(count < 2)
                Button { togglePlay() } label: { Image(systemName: play_.value ? "pause.fill" : "play.fill") }.disabled(count < 2)
                Button { step(1) } label: { Image(systemName: "forward.frame") }.disabled(count < 2)
                if count > 1 {
                    Slider(value: Binding(get: { Double(index) }, set: { editor.frameIndex = Int($0.rounded()) }), in: 0...Double(count - 1), step: 1)
                } else { Spacer() }
            }
            HStack {
                Button("Adopt Frame") {
                    let i = index
                    if result.steps.indices.contains(i) {
                        var m = result.steps[i]
                        m.charge = editor.molecule.charge; m.multiplicity = editor.molecule.multiplicity; m.title = editor.molecule.title
                        editor.replaceMolecule(m, actionName: "Adopt Frame")
                    }
                }.disabled(count == 0)
                Button("Show Editable Molecule") { editor.frameIndex = nil }.disabled(editor.frameIndex == nil)
            }
            Spacer()
        }
        .padding(10)
        .onDisappear { stop() }
    }

    private func step(_ d: Int) {
        guard count > 0 else { return }
        editor.frameIndex = (index + d + count) % count
    }
    private func togglePlay() { play_.value ? stop() : play() }
    private func play() {
        play_.value = true
        if editor.frameIndex == nil || index == count - 1 { editor.frameIndex = 0 }
        timerBox.value = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
            Task { @MainActor in
                if index >= count - 1 { stop() } else { editor.frameIndex = index + 1 }
            }
        }
    }
    private func stop() { timerBox.value?.invalidate(); timerBox.value = nil; play_.value = false }
}

// MARK: Vibrations

struct VibrationsTab: View {
    @ObservedObject var editor: EditorModel
    let result: CalculationResult

    static func frequencyText(_ f: Double) -> String {
        f < 0 ? String(format: "%.2f i", -f) : String(format: "%.2f", f)
    }

    var body: some View {
        VStack(spacing: 6) {
            let imag = result.normalModes.filter { $0.frequency < 0 }.count
            if imag > 0 {
                Label("\(imag) imaginary frequenc\(imag == 1 ? "y" : "ies")", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.top, 6)
            }
            List(selection: Binding(get: { editor.activeModeIndex }, set: { editor.activeModeIndex = $0 })) {
                HStack {
                    Text("#").frame(width: 30, alignment: .trailing)
                    Text("Freq (cm\u{207B}\u{00B9})").frame(width: 110, alignment: .trailing)
                    Text("IR (km/mol)").frame(width: 90, alignment: .trailing)
                    Text("Symmetry").frame(maxWidth: .infinity, alignment: .leading)
                }.font(.caption.bold()).foregroundStyle(.secondary).selectionDisabled()
                ForEach(Array(result.normalModes.enumerated()), id: \.offset) { i, m in
                    HStack {
                        Text("\(i + 1)").frame(width: 30, alignment: .trailing)
                        Text(Self.frequencyText(m.frequency)).frame(width: 110, alignment: .trailing)
                            .foregroundStyle(m.frequency < 0 ? .red : .primary)
                        Text(String(format: "%.2f", m.irIntensity)).frame(width: 90, alignment: .trailing)
                        Text(m.symmetry ?? "").frame(maxWidth: .infinity, alignment: .leading)
                    }.monospacedDigit().tag(i)
                }
            }
            HStack {
                Text("Amplitude")
                Slider(value: $editor.vibrationAmplitude, in: 0.05...2.0)
                Button { editor.activeModeIndex = nil } label: { Label("Stop", systemImage: "stop.fill") }
                    .disabled(editor.activeModeIndex == nil)
            }.padding(.horizontal, 10).padding(.bottom, 8)
        }
    }
}

// MARK: Orbitals

struct OrbitalsTab: View {
    @ObservedObject var editor: EditorModel
    let result: CalculationResult

    /// Orbitals shown (alpha / restricted only; the list is long enough already), sorted by index.
    private var shown: [OrbitalInfo] {
        result.orbitals.filter { $0.spin != .beta }.sorted { $0.index < $1.index }
    }
    private var homo: OrbitalInfo? { shown.last { $0.occupied } }
    private var lumo: OrbitalInfo? { shown.first { !$0.occupied } }

    var body: some View {
        VStack(spacing: 6) {
            if let h = homo, let l = lumo {
                let gap = l.energy - h.energy
                Text(String(format: "HOMO\u{2013}LUMO gap: %.4f Eh = %.3f eV", gap, gap * hartreeToEV))
                    .monospacedDigit().padding(.top, 6)
            }
            List(selection: Binding(get: { editor.activeOrbitalIndex }, set: { editor.activeOrbitalIndex = $0 })) {
                ForEach(shown.reversed(), id: \.index) { o in
                    HStack {
                        Text("\(o.index)").frame(width: 40, alignment: .trailing)
                        Text(o.occupied ? "occ" : "virt").frame(width: 40).foregroundStyle(.secondary)
                        Text(String(format: "%.5f Eh", o.energy)).frame(width: 110, alignment: .trailing)
                        Text(String(format: "%.3f eV", o.energy * hartreeToEV)).frame(width: 90, alignment: .trailing)
                        Text(label(o)).bold().foregroundStyle(.tint).frame(width: 50, alignment: .leading)
                        Spacer()
                    }.monospacedDigit().tag(o.index)
                }
            }
        }
    }

    private func label(_ o: OrbitalInfo) -> String {
        if o.index == homo?.index { return "HOMO" }
        if o.index == lumo?.index { return "LUMO" }
        if let h = homo, o.index == h.index - 1 { return "HOMO-1" }
        if let l = lumo, o.index == l.index + 1 { return "LUMO+1" }
        return ""
    }
}

// MARK: Excited states

struct ExcitedStatesTab: View {
    let result: CalculationResult
    var body: some View {
        VStack(spacing: 6) {
            Chart(Array(result.excitedStates.enumerated()), id: \.offset) { i, s in
                BarMark(x: .value("Wavelength (nm)", s.wavelengthNM), y: .value("f", s.oscillatorStrength), width: 3)
            }
            .chartXAxisLabel("Wavelength (nm)").chartYAxisLabel("Oscillator strength")
            .frame(height: 120).padding(.horizontal, 10).padding(.top, 8)
            List {
                HStack {
                    Text("#").frame(width: 30, alignment: .trailing)
                    Text("E (eV)").frame(width: 80, alignment: .trailing)
                    Text("\u{03BB} (nm)").frame(width: 80, alignment: .trailing)
                    Text("f").frame(width: 80, alignment: .trailing)
                    Spacer()
                }.font(.caption.bold()).foregroundStyle(.secondary)
                ForEach(Array(result.excitedStates.enumerated()), id: \.offset) { i, s in
                    HStack {
                        Text("\(i + 1)").frame(width: 30, alignment: .trailing)
                        Text(String(format: "%.4f", s.energyEV)).frame(width: 80, alignment: .trailing)
                        Text(String(format: "%.2f", s.wavelengthNM)).frame(width: 80, alignment: .trailing)
                        Text(String(format: "%.4f", s.oscillatorStrength)).frame(width: 80, alignment: .trailing)
                        Spacer()
                    }.monospacedDigit()
                }
            }
        }
    }
}
