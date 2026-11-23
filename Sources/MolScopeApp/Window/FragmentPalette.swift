import SwiftUI

struct FragmentPalette: View {
    @ObservedObject var editor: EditorModel
    @StateObject private var box = StateBox("")
    private var search: String { box.value }

    var body: some View {
        let cats = BuildOps.categories
        VStack(spacing: 0) {
            TextField("Search fragments", text: $box.value).textFieldStyle(.roundedBorder).padding(8)
            if cats.isEmpty {
                Spacer()
                Text("No fragments available").foregroundStyle(.secondary)
                Spacer()
            } else {
                List {
                    ForEach(cats) { cat in
                        let items = cat.fragments.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
                        if !items.isEmpty {
                            Section(cat.title) {
                                ForEach(items) { f in
                                    Button {
                                        editor.payload = .fragment(f.id); editor.tool = .build
                                    } label: {
                                        HStack {
                                            Text(f.name)
                                            Spacer()
                                            if editor.payload == .fragment(f.id) { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }
}
