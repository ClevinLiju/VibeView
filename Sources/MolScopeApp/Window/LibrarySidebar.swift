import SwiftUI
import MolCore
import MolBuild

/// Left sidebar: quick element tiles, bond-order tools and the searchable fragment library.
struct LibrarySidebar: View {
    @ObservedObject var editor: EditorModel
    @State private var search = ""
    @State private var showTable = false

    private static let quickElements = [1, 6, 7, 8, 9, 15, 16, 17, 35, 53, 5, 14]

    var body: some View {
        List {
            Section("Elements") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                    ForEach(Self.quickElements, id: \.self) { z in ElementTile(editor: editor, z: z) }
                }
                .padding(.vertical, 4)
                Button { showTable = true } label: { Label("Periodic Table…", systemImage: "square.grid.3x3") }
                    .buttonStyle(.borderless)
                    .popover(isPresented: $showTable, arrowEdge: .trailing) { PeriodicTablePopover(editor: editor, isPresented: $showTable) }
            }
            ForEach(BuildOps.categories) { cat in
                let items = cat.fragments.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
                if !items.isEmpty {
                    Section(cat.title) {
                        ForEach(items) { f in
                            let on = editor.payload == .fragment(f.id)
                            Button {
                                editor.payload = .fragment(f.id); editor.tool = .build
                            } label: {
                                Label(f.name, systemImage: Self.symbol(for: cat.id))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(on ? Color.accentColor : Color.primary)
                            .fontWeight(on ? .semibold : .regular)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $search, placement: .sidebar, prompt: "Fragments")
        .safeAreaInset(edge: .bottom) { SketchHint(editor: editor) }
    }

    static func symbol(for category: String) -> String {
        switch category {
        case "rings": "hexagon"
        case "groups": "point.3.connected.trianglepath.dotted"
        case "aminoAcids": "link"
        case "nucleobases": "allergens"
        default: "atom"
        }
    }
}

private struct ElementTile: View {
    @ObservedObject var editor: EditorModel
    let z: Int
    var body: some View {
        let on = editor.payload == .element(z)
        let c = ElementInfo.rgb(z)
        Button {
            editor.payload = .element(z); editor.tool = .build
        } label: {
            Text(ElementInfo.symbol(z))
                .font(.system(.callout, design: .rounded).weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 30)
                .background(
                    RoundedRectangle(cornerRadius: 7).fill(Color(red: c.r, green: c.g, blue: c.b).opacity(0.28))
                )
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(on ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: on ? 2 : 0.5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(ElementInfo.name(z)) — click to sketch")
    }
}

private struct SketchHint: View {
    @ObservedObject var editor: EditorModel
    var body: some View {
        if editor.tool == .build {
            VStack(alignment: .leading, spacing: 3) {
                Text("Sketching").font(.caption.weight(.semibold))
                Text("Click empty space to place · click an atom to grow · click a hydrogen to replace it · click a bond to cycle its order")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
        }
    }
}
