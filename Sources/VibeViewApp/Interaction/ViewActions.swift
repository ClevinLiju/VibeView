import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MolCore
import MolRender

/// View-related actions shared by the menu bar, toolbar and command palette.
extension EditorModel {
    var renderer: MoleculeRenderer { viewport.renderer }

    func setStyle(_ s: RenderStyle) {
        renderOptions.style = s
        UserDefaults.standard.set(s.rawValue, forKey: ViewKeys.style)
    }
    func setLabels(_ l: LabelMode) { renderOptions.labelMode = l }
    func setMaterial(_ m: MaterialPreset) {
        renderOptions.material = m
        UserDefaults.standard.set(m.rawValue, forKey: ViewKeys.material)
    }
    func toggleHydrogens() { renderOptions.showHydrogens.toggle() }
    func toggleProjection() { renderOptions.projection = renderOptions.projection == .perspective ? .orthographic : .perspective }
    func toggleAmbientOcclusion() {
        renderOptions.ambientOcclusion.toggle()
        UserDefaults.standard.set(renderOptions.ambientOcclusion, forKey: ViewKeys.ambientOcclusion)
    }
    func toggleDepthCue() {
        renderOptions.depthCueing.toggle()
        UserDefaults.standard.set(renderOptions.depthCueing, forKey: ViewKeys.depthCue)
    }
    func toggleChargeColors() {
        if case .charge = renderOptions.colorScheme { renderOptions.colorScheme = .element } else { renderOptions.colorScheme = .charge(range: nil) }
    }
    func fitView() { renderer.fitToView(animated: true) }
    func standardView(_ v: StandardView) { renderer.camera.setStandardView(v, animated: true) }

    func invertSelection() { selection = Set(molecule.atoms.indices).subtracting(selection) }
    func removeHydrogens() {
        let sel = selection.isEmpty ? nil : selection
        apply("Remove Hydrogens") { BuildOps.removeHydrogens(&$0, atoms: sel) }
        selection = []
    }

    /// Export the current view as a PNG/TIFF (2× the window size, optional transparent background).
    func exportImage() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .tiff]
        panel.nameFieldStringValue = (fileURL?.deletingPathExtension().lastPathComponent ?? (molecule.title.isEmpty ? "Molecule" : molecule.title)) + ".png"
        let transparent = NSButton(checkboxWithTitle: "Transparent background", target: nil, action: nil)
        panel.accessoryView = transparent
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var o = ImageExportOptions()
        let size = renderer.view.bounds.size
        o.widthPoints = max(400, Double(size.width))
        o.heightPoints = max(300, Double(size.height))
        o.dpi = 144
        o.transparentBackground = transparent.state == .on
        o.format = url.pathExtension.lowercased() == "tiff" || url.pathExtension.lowercased() == "tif" ? .tiff : .png
        do {
            try renderer.exportImage(to: url, options: o)
            statusMessage = "Exported \(url.lastPathComponent)"
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// Copy the view to the pasteboard as an image.
    func copyImage() {
        var o = ImageExportOptions()
        let size = renderer.view.bounds.size
        o.widthPoints = Double(size.width); o.heightPoints = Double(size.height); o.dpi = 144
        guard let cg = try? renderer.renderImage(o) else { return }
        let img = NSImage(cgImage: cg, size: size)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([img])
        statusMessage = "Image copied"
    }
}
