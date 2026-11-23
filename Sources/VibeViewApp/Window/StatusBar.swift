import SwiftUI

struct StatusBar: View {
    @ObservedObject var editor: EditorModel
    var body: some View {
        let m = editor.displayedMolecule
        HStack(spacing: 14) {
            Text("\(m.atoms.count) atoms")
            Text(hillFormula(m)).font(.system(.caption, design: .monospaced))
            Text("charge \(m.charge), mult. \(m.multiplicity)")
            if let f = editor.frameIndex { Text("frame \(f + 1)") }
            Spacer()
            Text(editor.statusMessage).lineLimit(1)
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(.bar)
    }
}
