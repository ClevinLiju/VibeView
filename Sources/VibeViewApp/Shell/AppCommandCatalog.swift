import SwiftUI
import AppKit
import MolRender

/// Every action reachable from the command palette (menus mirror these).
@MainActor
enum AppCommandCatalog {
    static func commands(editor e: EditorModel, openWindow: OpenWindowAction) -> [PaletteCommand] {
        let has = !e.molecule.atoms.isEmpty
        func c(_ id: String, _ title: String, _ sym: String, _ cat: String, _ sc: String? = nil, kw: [String] = [],
               enabled: Bool = true, _ run: @escaping @MainActor () -> Void) -> PaletteCommand {
            PaletteCommand(id: "action." + id, title: title, symbol: sym, category: cat, keywords: kw, shortcut: sc, isEnabled: enabled, perform: run)
        }
        var out: [PaletteCommand] = [
            c("open", "Open…", "folder", "File", "⌘O") { NSDocumentController.shared.openDocument(nil) },
            c("new", "New Structure", "doc.badge.plus", "File", "⌘N") { NSDocumentController.shared.newDocument(nil) },
            c("save", "Save", "square.and.arrow.down", "File", "⌘S") { NSApp.sendAction(#selector(NSDocument.save(_:)), to: nil, from: nil) },
            c("pubchem", "Open from PubChem…", "globe", "File", "⇧⌘O", kw: ["download", "smiles", "cid", "name", "search"]) { e.showPubChem = true },
            c("export", "Export Image…", "photo", "File", "⇧⌘E", kw: ["png", "tiff", "picture", "render"]) { e.exportImage() },
            c("copyimage", "Copy Image", "doc.on.clipboard", "Edit", "⇧⌘C") { e.copyImage() },
            c("undo", "Undo" + (e.undoActionName.map { " " + $0 } ?? ""), "arrow.uturn.backward", "Edit", "⌘Z", enabled: e.canUndo) { e.undo() },
            c("redo", "Redo" + (e.redoActionName.map { " " + $0 } ?? ""), "arrow.uturn.forward", "Edit", "⇧⌘Z", enabled: e.canRedo) { e.redo() },
            c("selectall", "Select All Atoms", "checkmark.circle", "Edit", "⌥⌘A", enabled: has) { e.selectAll() },
            c("invertsel", "Invert Selection", "circle.lefthalf.filled", "Edit", "⇧⌘I", enabled: has) { e.invertSelection() },
            c("delete", "Delete Selected Atoms", "trash", "Edit", "⌘⌫", enabled: !e.selection.isEmpty) { e.deleteSelection() },
            c("addh", "Add Hydrogens", "h.circle", "Structure", "⇧⌘H", kw: ["valence", "protonate"], enabled: has) { e.addHydrogens() },
            c("removeh", "Remove Hydrogens", "h.circle.fill", "Structure", "⌥⇧⌘H", enabled: has) { e.removeHydrogens() },
            c("clean", "Clean Up Geometry", "wand.and.stars", "Structure", "⇧⌘K", kw: ["force field", "minimize", "relax", "uff"], enabled: has) { e.cleanGeometry() },
            c("xtb", "Optimize with xtb", "bolt", "Structure", "⌥⌘K", kw: ["gfn2", "semiempirical", "tight binding"], enabled: has) { e.optimizeWithXTB() },
            c("invert", "Invert Through Center", "arrow.triangle.swap", "Structure", enabled: has) { e.invertStructure() },
            c("mirror", "Mirror Through XY Plane", "arrow.left.and.right.righttriangle.left.righttriangle.right", "Structure", enabled: has) { e.mirrorStructure() },
            c("center", "Center at Origin", "scope", "Structure", enabled: has) { e.centerAtOrigin() },
            c("rebond", "Rebuild Bonds", "link", "Structure", kw: ["connectivity", "perceive"], enabled: has) { e.rebuildBonds() },
            c("calc", "New Calculation…", "function", "Calculate", "⌥⌘C", kw: ["gaussian", "orca", "qchem", "q-chem", "xtb", "dft", "input"], enabled: has) { e.showCalcSetup = true },
            c("jobs", "Show Job Queue", "tray.full", "Calculate", "⌥⌘J", kw: ["running", "log"]) { openWindow(id: "job-queue") },
            c("fit", "Fit to Window", "arrow.up.left.and.arrow.down.right", "View", "⌘0", kw: ["zoom", "reset"]) { e.fitView() },
            c("hydrogens", e.renderOptions.showHydrogens ? "Hide Hydrogens" : "Show Hydrogens", "eye", "View", "⌃⌘H") { e.toggleHydrogens() },
            c("charges", "Toggle Color by Charge", "plusminus", "View", kw: ["mulliken", "partial"]) { e.toggleChargeColors() },
            c("ao", "Toggle Ambient Occlusion", "circle.dotted", "View", kw: ["ssao", "shadow"]) { e.toggleAmbientOcclusion() },
            c("depth", "Toggle Depth Cueing", "aqi.medium", "View", kw: ["fog"]) { e.toggleDepthCue() },
            c("ortho", "Toggle Orthographic Projection", "cube", "View", kw: ["perspective"]) { e.toggleProjection() },
            c("inspector", e.showInspector ? "Hide Inspector" : "Show Inspector", "sidebar.right", "View", "⌥⌘I") { e.showInspector.toggle() },
            c("library", e.showLibrary ? "Hide Library" : "Show Library", "sidebar.left", "View", "⌥⌘L") { e.showLibrary.toggle() },
            c("results", e.showResults ? "Hide Results" : "Show Results", "chart.xyaxis.line", "View", "⌥⌘R", enabled: e.result != nil) { e.showResults.toggle() },
            c("settings", "Settings…", "gearshape", "App", "⌘,", kw: ["preferences", "paths"]) { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) },
        ]
        for t in EditorTool.allCases {
            out.append(c("tool." + t.rawValue, t.title + " Tool", t.symbol, "Tools", "⌘\(t.shortcutDigit)") { e.tool = t })
        }
        for s in RenderStyle.allCases {
            out.append(c("style." + s.rawValue, "Style: " + s.title, s.symbol, "View", kw: ["render", "display"]) { e.setStyle(s) })
        }
        for l in LabelMode.menuCases {
            out.append(c("labels." + l.rawValue, "Labels: " + l.title, "textformat", "View") { e.setLabels(l) })
        }
        for v in StandardView.allCases {
            out.append(c("view." + v.rawValue, "Look Along " + v.rawValue.replacingOccurrences(of: "along", with: "").capitalized, "camera.viewfinder", "View", kw: ["orient", "camera"]) { e.standardView(v) })
        }
        return out + PaletteCatalog.elementAndFragmentCommands(editor: e)
    }
}
