import SwiftUI

/// All 118 elements in the 18-column layout, with the f-block rows below a small gap.
struct PeriodicTablePopover: View {
    @ObservedObject var editor: EditorModel
    @Binding var isPresented: Bool
    @StateObject private var hover = StateBox<Int?>(nil)
    /// The element whose atom / hybridized forms / functional groups are listed under the table.
    @State private var chosen: Int?

    init(editor: EditorModel, isPresented: Binding<Bool>, initialElement: Int? = nil) {
        self.editor = editor
        self._isPresented = isPresented
        self._chosen = State(initialValue: initialElement)
    }
    static let cell: CGFloat = 34
    /// Gap (in cells) between the main body (rows 0...6) and the lanthanide/actinide rows.
    static let fBlockGap: CGFloat = 0.4
    /// Total grid height in cells: 7 main rows + gap + 2 f-block rows.
    static var gridRows: CGFloat { 7 + fBlockGap + 2 }

    /// Vertical position (in cells) of a table row from `ElementInfo.gridPosition`.
    static func displayRow(_ row: Int) -> CGFloat { row < 7 ? CGFloat(row) : CGFloat(row - 8) + 7 + fBlockGap }

    var body: some View {
        let cell = Self.cell
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Element").font(.headline)
                Spacer()
                Text(hover.value.map { "\(ElementInfo.name($0)) · Z \($0)" } ?? (chosen == nil ? "Click an element to sketch with it" : "Pick the atom or a group below"))
                    .font(.callout).foregroundStyle(.secondary)
            }
            ZStack(alignment: .topLeading) {
                Color.clear
                ForEach(1...118, id: \.self) { z in
                    if let p = ElementInfo.gridPosition(z) {
                        button(z).offset(x: CGFloat(p.col) * cell, y: Self.displayRow(p.row) * cell)
                    }
                }
                // Markers showing where the f-block rows belong in the main table.
                Text("57–70").font(.system(size: 9)).foregroundStyle(.secondary)
                    .frame(width: 2 * cell - 4, alignment: .trailing).offset(x: 0, y: (Self.displayRow(8) + 0.35) * cell)
                Text("89–102").font(.system(size: 9)).foregroundStyle(.secondary)
                    .frame(width: 2 * cell - 4, alignment: .trailing).offset(x: 0, y: (Self.displayRow(9) + 0.35) * cell)
            }
            .frame(width: cell * 18, height: cell * Self.gridRows, alignment: .topLeading)
            if let z = chosen {
                Divider()
                ElementGroupPicker(editor: editor, z: z, onPick: { isPresented = false })
                    .frame(width: cell * 18, alignment: .leading)
            }
        }
        .padding(12)
        .fixedSize()
    }

    private func marker(_ s: String) -> some View { Text(s).font(.system(size: 8)) }

    private func button(_ z: Int) -> some View {
        let cell = Self.cell
        let selected = editor.payload == .element(z) || chosen == z
        let c = ElementInfo.rgb(z)
        let light = (0.299 * c.r + 0.587 * c.g + 0.114 * c.b) > 0.55
        return Button {
            editor.payload = .element(z); editor.tool = .build
            // Elements with hybridized forms or groups keep the popover open and list them below the table.
            if ElementGroupPicker.hasGroups(z) { chosen = z } else { isPresented = false }
        } label: {
            VStack(spacing: 0) {
                Text("\(z)").font(.system(size: 7))
                Text(ElementInfo.symbol(z)).font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(light ? Color.black : Color.white)
            .frame(width: cell - 2, height: cell - 2)
            .background(ElementInfo.color(z).opacity(0.9), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(selected ? Color.accentColor : .clear, lineWidth: 2.5))
        }
        .buttonStyle(.plain)
        .onHover { inside in if inside { hover.value = z } else if hover.value == z { hover.value = nil } }
        .help("\(ElementInfo.name(z)) (\(ElementInfo.symbol(z)), Z = \(z))")
    }
}
