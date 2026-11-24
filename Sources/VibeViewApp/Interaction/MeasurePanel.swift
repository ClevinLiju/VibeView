import SwiftUI
import MolCore

/// Overlay for the Gauge tool: shows distance / angle / dihedral of the picked atoms and lets you type a new value.
struct MeasurePanel: View {
    @ObservedObject var editor: EditorModel
    @State private var text = ""

    private var picks: [Int] { editor.measurePicks.filter { editor.molecule.atoms.indices.contains($0) } }

    private var info: (name: String, unit: String, value: Double)? {
        let m = editor.molecule, p = picks
        switch p.count {
        case 2: return ("Distance", "Å", m.distance(p[0], p[1]))
        case 3: return ("Angle", "°", m.angle(p[0], p[1], p[2]))
        case 4: return ("Dihedral", "°", m.dihedral(p[0], p[1], p[2], p[3]))
        default: return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Gauge", systemImage: "ruler").font(.headline)
                Spacer()
                Button("Clear") { editor.measurePicks = [] }.disabled(editor.measurePicks.isEmpty)
            }
            if let i = info {
                Text(picks.map { "\(ElementInfo.symbol(editor.molecule.atoms[$0].atomicNumber))\($0 + 1)" }.joined(separator: " – "))
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text(i.name)
                    Spacer()
                    Text(String(format: "%.4f %@", i.value, i.unit)).monospacedDigit()
                }
                HStack {
                    TextField("New value", text: $text).textFieldStyle(.roundedBorder).frame(width: 90)
                        .onSubmit(applyValue)
                    Text(i.unit)
                    Button("Set", action: applyValue).disabled(Double(text) == nil)
                }
            } else {
                Text(picks.isEmpty ? "Click 2 atoms for distance, 3 for angle, 4 for dihedral." : "\(picks.count) atom\(picks.count == 1 ? "" : "s") picked…")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(width: 250)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(10)
        .onChange(of: editor.measurePicks) { text = "" }
    }

    private func applyValue() {
        guard let v = Double(text), info != nil else { return }
        let p = picks
        switch p.count {
        case 2: editor.apply("Set Distance") { $0.setDistance(p[0], p[1], to: v) }
        case 3: editor.apply("Set Angle") { $0.setAngle(p[0], p[1], p[2], to: v) }
        case 4: editor.apply("Set Dihedral") { $0.setDihedral(p[0], p[1], p[2], p[3], to: v) }
        default: break
        }
        text = ""
    }
}
