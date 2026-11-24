import SwiftUI
import MolCore

struct OrbitalsView: View {
    @ObservedObject var editor: EditorModel
    let result: CalculationResult

    @State private var spin: OrbitalInfo.Spin = .alpha

    private var unrestricted: Bool { result.orbitals.contains { $0.spin == .beta } }

    /// Orbitals of the shown spin set, highest energy first.
    private var shown: [OrbitalInfo] {
        let list = unrestricted ? result.orbitals.filter { $0.spin == spin } : result.orbitals
        return list.sorted { $0.index > $1.index }
    }
    private var homo: OrbitalInfo? { shown.filter(\.occupied).max { $0.index < $1.index } }
    private var lumo: OrbitalInfo? { shown.filter { !$0.occupied }.min { $0.index < $1.index } }

    private func label(_ o: OrbitalInfo) -> String {
        guard let h = homo else { return "#\(o.index)" }
        let d = o.index - h.index
        if d == 0 { return "HOMO" }
        if d < 0 { return "HOMO\(d)" }
        return d == 1 ? "LUMO" : "LUMO+\(d - 1)"
    }

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 8) {
                if unrestricted {
                    Picker("", selection: $spin) {
                        Text("Alpha").tag(OrbitalInfo.Spin.alpha); Text("Beta").tag(OrbitalInfo.Spin.beta)
                    }.pickerStyle(.segmented).labelsHidden()
                }
                if let h = homo, let l = lumo {
                    let gap = (l.energy - h.energy) * SpectrumMath.hartreeToEV
                    Label(String(format: "HOMO–LUMO gap  %.3f eV", gap), systemImage: "arrow.up.and.down")
                        .font(.callout.weight(.medium)).monospacedDigit()
                }
                HStack {
                    Button("HOMO") { if let h = homo { editor.activeOrbitalIndex = h.index } }.disabled(homo == nil)
                    Button("LUMO") { if let l = lumo { editor.activeOrbitalIndex = l.index } }.disabled(lumo == nil)
                    Button("Hide") { editor.activeOrbitalIndex = nil }.disabled(editor.activeOrbitalIndex == nil)
                }
                .controlSize(.small)
                HStack {
                    Text("Isovalue").font(.caption).foregroundStyle(.secondary)
                    Slider(value: isoSlider, in: 0...1)
                    Text(String(format: "%.3f", editor.orbitalIsovalue)).monospacedDigit().font(.caption)
                        .frame(width: 40, alignment: .trailing)
                }
                OrbitalLookControls(editor: editor)
                if !editor.orbitalStatus.isEmpty {
                    Text(editor.orbitalStatus).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(10).frame(minWidth: 240, maxWidth: 340)
            orbitalList.frame(minWidth: 260)
        }
    }

    /// Log-scaled isovalue slider, 0.005 ... 0.1.
    private var isoSlider: Binding<Double> {
        Binding(get: { log(max(editor.orbitalIsovalue, 0.005) / 0.005) / log(20) },
                set: { editor.orbitalIsovalue = 0.005 * pow(20, $0) })
    }

    private var orbitalList: some View {
        ScrollViewReader { sp in
            List(shown, id: \.index, selection: Binding<Int?>(get: { editor.activeOrbitalIndex }, set: { editor.activeOrbitalIndex = $0 })) { o in
                HStack(spacing: 8) {
                    Image(systemName: o.occupied ? "circle.fill" : "circle")
                        .font(.system(size: 8)).foregroundStyle(o.occupied ? Color.accentColor : .secondary)
                    Text(label(o)).fontWeight(o.index == homo?.index || o.index == lumo?.index ? .semibold : .regular)
                        .frame(width: 64, alignment: .leading)
                    Text("#\(o.index)").foregroundStyle(.secondary).frame(width: 40, alignment: .leading)
                    Spacer()
                    Text(String(format: "%.3f eV", o.energy * SpectrumMath.hartreeToEV))
                    Text(String(format: "%.4f Ha", o.energy)).foregroundStyle(.secondary)
                }
                .monospacedDigit().font(.callout)
                .id(o.index)
            }
            .onAppear { if let l = lumo { sp.scrollTo(l.index, anchor: .center) } }
        }
    }
}
