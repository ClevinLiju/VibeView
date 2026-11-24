import SwiftUI
import MolCore

struct StatusBar: View {
    @ObservedObject var editor: EditorModel
    var body: some View {
        let m = editor.displayedMolecule
        HStack(spacing: 14) {
            Label(editor.tool.title, systemImage: editor.tool.symbol).labelStyle(.titleAndIcon)
            if !m.atoms.isEmpty {
                Text(hillFormula(m)).font(.system(.caption, design: .monospaced))
                Text("\(m.atoms.count) atoms · \(m.bonds.count) bonds")
                Text(String(format: "%.2f g/mol", m.molecularWeight))
                Text("charge \(m.charge) · mult. \(m.multiplicity)")
            }
            if !editor.selection.isEmpty { Text("\(editor.selection.count) selected").foregroundStyle(Color.accentColor) }
            Spacer()
            if let busy = editor.busyMessage {
                ProgressView().controlSize(.mini)
                Text(busy).lineLimit(1)
            } else {
                Text(editor.statusMessage).lineLimit(1)
            }
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}
