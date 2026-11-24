import SwiftUI
import MolCore
import MolBuild
import MolRender

/// Gauge panel: choose distance / angle / dihedral, click 2–4 atoms, and the result is kept as a monitor.
/// Every monitor's value can be typed in; the edit moves the smaller of the two sides.
struct MeasurePanel: View {
    @ObservedObject var editor: EditorModel
    @StateObject private var drafts = StateBox<[Int: String]>([:])

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Gauge", systemImage: "ruler").font(.headline)
                Spacer()
                Button("Clear All") { editor.monitors = []; editor.measurePicks = [] }
                    .disabled(editor.monitors.isEmpty && editor.measurePicks.isEmpty)
                    .controlSize(.small)
            }
            Picker("Measure", selection: $editor.measureMode) {
                ForEach(MeasureMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .onChange(of: editor.measureMode) { editor.measurePicks = [] }
            if editor.tool == .measure {
                let need = editor.measureMode.atomCount
                let have = editor.measurePicks.count % (need + 1)
                Text(have == 0 || have == need ? "Click \(need) atoms." : "\(have) of \(need) atoms picked…")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !editor.monitors.isEmpty {
                Divider()
                ForEach(Array(editor.monitors.enumerated()), id: \.offset) { idx, mon in row(idx, mon) }
            }
        }
        .padding(10)
        .frame(width: 290)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(10)
    }

    private func label(_ mon: Monitor) -> String {
        mon.atoms.filter { editor.molecule.atoms.indices.contains($0) }
            .map { "\(ElementInfo.symbol(editor.molecule.atoms[$0].atomicNumber))\($0 + 1)" }.joined(separator: "–")
    }

    private func value(_ mon: Monitor) -> (Double, String)? {
        let m = editor.displayedMolecule
        guard mon.atoms.allSatisfy({ m.atoms.indices.contains($0) }) else { return nil }
        switch mon {
        case .distance(let a, let b): return (GeometryEdit.distance(m, a, b), "Å")
        case .angle(let a, let b, let c): return (GeometryEdit.angle(m, a, b, c), "°")
        case .dihedral(let a, let b, let c, let d): return (GeometryEdit.dihedral(m, a, b, c, d), "°")
        }
    }

    @ViewBuilder private func row(_ idx: Int, _ mon: Monitor) -> some View {
        if let (v, unit) = value(mon) {
            HStack(spacing: 6) {
                Text(label(mon)).font(.caption.monospaced()).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                TextField("", text: Binding(get: { drafts.value[idx] ?? String(format: unit == "Å" ? "%.3f" : "%.1f", v) },
                                            set: { drafts.value[idx] = $0 }))
                    .textFieldStyle(.roundedBorder).frame(width: 70).multilineTextAlignment(.trailing)
                    .onSubmit { commit(idx, mon) }
                    .help("Type a new value and press Return; the smaller side of the structure moves.")
                Text(unit).frame(width: 14, alignment: .leading)
                Button { editor.monitors.remove(at: idx); drafts.value = [:] } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Remove this monitor")
            }
        }
    }

    private func commit(_ idx: Int, _ mon: Monitor) {
        defer { drafts.value[idx] = nil }
        guard let s = drafts.value[idx], let v = Double(s.trimmingCharacters(in: .whitespaces)) else { return }
        editor.setMonitor(mon, to: v)
    }
}

extension EditorModel {
    /// Change a measured value, moving the smaller side (MolBuild `GeometryEdit.set*MovingSmaller`).
    func setMonitor(_ mon: Monitor, to v: Double) {
        guard mon.atoms.allSatisfy({ molecule.atoms.indices.contains($0) }) else { return }
        switch mon {
        case .distance(let a, let b):
            guard v > 0.3 else { statusMessage = "Distance must be above 0.3 Å"; return }
            apply("Set Distance") { GeometryEdit.setDistanceMovingSmaller(&$0, a, b, to: v) }
        case .angle(let a, let b, let c):
            guard v > 0, v < 180 else { statusMessage = "Angle must be between 0° and 180°"; return }
            apply("Set Angle") { GeometryEdit.setAngleMovingSmaller(&$0, a, b, c, to: v) }
        case .dihedral(let a, let b, let c, let d):
            apply("Set Dihedral") { GeometryEdit.setDihedralMovingSmaller(&$0, a, b, c, d, to: v) }
        }
    }
}

/// Link tool panel: bond order for new bonds and a reminder of the gestures.
struct LinkPanel: View {
    @ObservedObject var editor: EditorModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Link", systemImage: "link").font(.headline)
            Picker("Order", selection: $editor.bondOrder) {
                Text("Single").tag(BondOrder.single)
                Text("Double").tag(BondOrder.double)
                Text("Triple").tag(BondOrder.triple)
            }
            .pickerStyle(.segmented).labelsHidden()
            Text(editor.bondPick.map { "Atom \($0 + 1) picked: click the second atom." }
                 ?? "Click two atoms to bond them, even across fragments. Click a bond to set its order; ⌥-click a bond to delete it.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(width: 260)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(10)
    }
}
