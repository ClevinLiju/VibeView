import SwiftUI

struct PeriodicTablePopover: View {
    @ObservedObject var editor: EditorModel
    @Binding var isPresented: Bool
    private let cell: CGFloat = 34

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Element").font(.headline)
            ZStack(alignment: .topLeading) {
                Color.clear.frame(width: cell * 18, height: cell * 9.6)
                ForEach(1...118, id: \.self) { z in
                    if let p = ElementInfo.gridPosition(z) {
                        button(z).offset(x: CGFloat(p.col) * cell, y: (CGFloat(p.row) + (p.row >= 8 ? 0.6 : 0)) * cell)
                    }
                }
            }
        }
        .padding(12)
    }

    private func button(_ z: Int) -> some View {
        let selected = editor.payload == .element(z)
        let c = ElementInfo.rgb(z)
        let light = (0.299 * c.r + 0.587 * c.g + 0.114 * c.b) > 0.55
        return Button {
            editor.payload = .element(z); editor.tool = .build; isPresented = false
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
        .help("\(ElementInfo.symbol(z)) (Z = \(z))")
    }
}
