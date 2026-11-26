import SwiftUI
import MolCore
import MolBuild

/// What can be sketched for one element: the atom alone (hydrogens added automatically), its hybridized forms and
/// the functional groups built on it (MolBuild `GroupLibrary`). Each entry has a 2-D thumbnail drawn from its own
/// template geometry. Picking one makes it the Sketch payload (click empty space / a hydrogen / a heavy atom).
struct ElementGroupPicker: View {
    @ObservedObject var editor: EditorModel
    let z: Int
    /// Called after an entry was picked (e.g. to close the popover).
    var onPick: () -> Void = {}
    var thumb: CGFloat = 40

    static func hasGroups(_ z: Int) -> Bool { !GroupLibrary.groups(forElement: z).isEmpty }

    private var atoms: [BuildGroup] { GroupLibrary.groups(forElement: z).filter { $0.kind == .atom } }
    private var groups: [BuildGroup] { GroupLibrary.groups(forElement: z).filter { $0.kind == .group } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("\(ElementInfo.name(z))").font(.headline)
                Text("Click empty space to place, a hydrogen to substitute it, a heavy atom to replace it")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            section("Atom") {
                tile(payload: .element(z), thumbID: atoms.first.map { FragmentThumbnails.groupPrefix + $0.id },
                     title: ElementInfo.symbol(z), subtitle: "alone, +H", help: "\(ElementInfo.name(z)) with hydrogens added automatically")
                ForEach(atoms) { g in
                    tile(payload: .group(g.id), thumbID: FragmentThumbnails.groupPrefix + g.id, title: g.label,
                         subtitle: g.hybridization.map { hybTitle($0) } ?? "", help: g.name)
                }
            }
            if !groups.isEmpty {
                section("Functional groups") {
                    ForEach(groups) { g in
                        tile(payload: .group(g.id), thumbID: FragmentThumbnails.groupPrefix + g.id, title: g.label,
                             subtitle: shortName(g.name), help: g.name)
                    }
                }
            }
        }
    }

    private func hybTitle(_ h: Hybridization) -> String {
        switch h { case .sp: "linear"; case .sp2: "trigonal"; case .sp3: "tetrahedral"; case .none: "" }
    }
    private func shortName(_ s: String) -> String {
        let t = s.components(separatedBy: " (").first ?? s
        return t.count <= 14 ? t : String(t.prefix(13)) + "…"
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(thumb + 34), spacing: 4), count: 7), alignment: .leading, spacing: 4) {
                content()
            }
        }
    }

    private func tile(payload: BuildPayload, thumbID: String?, title: String, subtitle: String, help: String) -> some View {
        let on = editor.payload == payload
        return Button {
            editor.payload = payload; editor.tool = .build; onPick()
        } label: {
            VStack(spacing: 1) {
                Group {
                    if let id = thumbID { FragmentThumbnail(id: id, side: thumb) }
                    else { Text(title).font(.system(size: 16, weight: .semibold)).frame(width: thumb, height: thumb) }
                }
                Text(title).font(.system(size: 10, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7)
                Text(subtitle).font(.system(size: 8)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
            }
            .frame(width: thumb + 32, height: thumb + 30)
            .background(RoundedRectangle(cornerRadius: 6).fill(on ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(on ? Color.accentColor : .clear, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
