import Foundation
import MolCore
import MolBuild

enum PaletteCatalog {
    /// One command per element and per fragment. The app adds menu/action commands separately.
    @MainActor static func elementAndFragmentCommands(editor: EditorModel) -> [PaletteCommand] {
        var cmds: [PaletteCommand] = []
        for el in Elements.all where el.atomicNumber > 0 {
            let z = el.atomicNumber
            cmds.append(PaletteCommand(
                id: "element.\(z)", title: "\(el.name) (\(el.symbol))", subtitle: "Atomic number \(z)",
                symbol: "atom", category: "Elements",
                keywords: [el.symbol, "\(z)", "element", "atom"],
                perform: { editor.payload = .element(z); editor.tool = .build }))
        }
        for f in FragmentLibrary.all {
            let fid = f.id
            cmds.append(PaletteCommand(
                id: "fragment.\(fid)", title: f.name, subtitle: f.category.title,
                symbol: "hexagon", category: "Fragments",
                keywords: [f.category.title, "fragment", "group"],
                perform: { editor.payload = .fragment(fid); editor.tool = .build }))
        }
        return cmds
    }
}
