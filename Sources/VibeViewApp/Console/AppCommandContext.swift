import Foundation
import AppKit
import MolCore
import MolIO
import MolRender
import MolCommand

/// `CommandContext` for one document window: commands act on its editor, renderer and file location.
/// Atom indices are 0-based on both sides.
@MainActor
final class AppCommandContext: @preconcurrency CommandContext {
    private weak var editor: EditorModel?
    /// Starts in the document's folder (or the home folder for unsaved documents); `cd` changes it.
    var currentDirectory: URL

    init(editor: EditorModel) {
        self.editor = editor
        currentDirectory = editor.fileURL?.deletingLastPathComponent() ?? FileManager.default.homeDirectoryForCurrentUser
    }

    private var ed: EditorModel {
        get throws {
            guard let e = editor else { throw CommandError("the window is closed") }
            return e
        }
    }

    var molecule: Molecule { editor?.molecule ?? Molecule() }
    var selection: Set<Int> {
        get { editor?.selection ?? [] }
        set { editor?.selection = newValue.filter { $0 < molecule.atoms.count } }
    }

    func open(urls: [URL]) throws {
        for u in urls {
            guard FileManager.default.fileExists(atPath: u.path) else { throw CommandError("no such file: \(u.path)") }
            DocumentOpener.open(u)
        }
    }

    func save(to url: URL, format: MoleculeFileFormat?) throws {
        let e = try ed
        let ext = format?.fileExtensions.first ?? url.pathExtension
        guard !ext.isEmpty else { throw CommandError("give the file an extension (.xyz, .pdb, .mol, .sdf, .cml, .gjf)") }
        do { try IOBridge.write(e.molecule, ext: ext).write(to: url) }
        catch { throw CommandError("could not save \(url.lastPathComponent): \(error.localizedDescription)") }
    }

    func close() { editor?.viewport.renderer.view.window?.performClose(nil) }

    func setMolecule(_ m: Molecule, actionName: String) { editor?.replaceMolecule(m, actionName: actionName) }
    func setHydrogensVisible(_ visible: Bool) { editor?.renderOptions.showHydrogens = visible }

    func setStyle(_ style: DisplayStyleName) {
        let s: RenderStyle = switch style { case .ball: .ballAndStick; case .stick: .tube; case .spacefill: .spaceFilling; case .wire: .wireframe }
        editor?.setStyle(s)
    }

    func setLabels(_ kind: LabelKind?) {
        let l: LabelMode = switch kind { case .none: .none; case .atoms?: .elementIndex; case .charges?: .charge }
        editor?.setLabels(l)
    }

    func addMeasurement(atoms: [Int]) { editor?.addMonitor(for: atoms) }

    func rotate(axis: Axis, degrees: Double) {
        guard let cam = editor?.viewport.renderer.camera else { return }
        let rad = degrees * .pi / 180
        switch axis {
        case .z: cam.roll(radians: rad)
        case .y: cam.orbit(dx: rad / cam.orbitSensitivity, dy: 0)
        case .x: cam.orbit(dx: 0, dy: rad / cam.orbitSensitivity)
        }
    }

    func fitView() { editor?.fitView() }
    func viewAlong(_ axis: Axis) {
        editor?.standardView(axis == .x ? .alongX : axis == .y ? .alongY : .alongZ)
    }

    func addHydrogens() throws { try ed.addHydrogens() }
    func runXTBOptimization(options: [String]) throws {
        let e = try ed
        guard !e.molecule.atoms.isEmpty else { throw CommandError("nothing to optimize") }
        e.optimizeWithXTB()
    }

    func showOrbital(_ which: OrbitalSelector) throws {
        let e = try ed
        guard let orbs = e.result?.orbitals, !orbs.isEmpty else { throw CommandError("this document has no orbitals") }
        let alpha = orbs.filter { $0.spin != .beta }
        guard let homo = alpha.filter(\.occupied).map(\.index).max() else { throw CommandError("no occupied orbitals") }
        let idx: Int = switch which { case .homo(let k): homo + k; case .lumo(let k): homo + 1 + k; case .index(let n): n }
        guard alpha.contains(where: { $0.index == idx }) else { throw CommandError("no orbital \(idx)") }
        e.activeOrbitalIndex = idx
        e.showResults = true
    }

    func showVibration(_ mode: Int?) throws {
        let e = try ed
        guard let m = mode, m > 0 else { e.activeModeIndex = nil; return }
        guard let modes = e.result?.normalModes, modes.indices.contains(m - 1) else {
            throw CommandError("no vibrational mode \(m)\(e.result?.normalModes.isEmpty == false ? " (1–\(e.result!.normalModes.count))" : "")")
        }
        e.activeModeIndex = m - 1
        e.showResults = true
    }

    func exportImage(to url: URL, width: Int?, height: Int?) throws {
        let e = try ed
        var o = ImageExportOptions()
        if let width { o.widthPoints = Double(width) }
        if let height { o.heightPoints = Double(height) }
        do { try e.viewport.renderer.exportImage(to: url, options: o) }
        catch { throw CommandError("image export failed: \(error.localizedDescription)") }
    }

    func exportImage(_ request: ImageExportRequest, to url: URL) throws {
        let e = try ed
        let renderer = e.viewport.renderer
        if request.fit { renderer.fitToView(animated: false) }
        // Missing dimensions follow the on-screen view, so the export frames exactly what is visible.
        let viewSize = renderer.view.bounds.size
        let aspect = viewSize.width > 0 && viewSize.height > 0 ? Double(viewSize.width / viewSize.height) : 4.0 / 3.0
        let w: Int, h: Int
        switch (request.width, request.height) {
        case let (wv?, hv?): (w, h) = (wv, hv)
        case let (wv?, nil): (w, h) = (wv, max(1, Int((Double(wv) / aspect).rounded())))
        case let (nil, hv?): (w, h) = (max(1, Int((Double(hv) * aspect).rounded())), hv)
        case (nil, nil):
            w = max(1, Int((Double(max(viewSize.width, 400)) * request.scale).rounded()))
            h = max(1, Int((Double(w) / aspect).rounded()))
        }
        guard w <= 16384, h <= 16384 else { throw CommandError("image would be \(w)×\(h); the limit is 16384 px per side") }
        var o = ImageExportOptions.pixels(width: w, height: h, dpi: request.dpi)
        o.format = switch request.format { case .png: .png; case .jpeg: .jpeg; case .tiff: .tiff; case .heic: .heic }
        o.transparentBackground = request.transparent && o.format.supportsAlpha
        o.supersampling = request.supersample
        o.compressionQuality = request.quality
        if let l = request.look {
            o.look = switch l { case "whitepaper": .whitePaper; case "darkstage": .darkStage; case "illustration": .illustration; default: .studio }
        }
        do { try renderer.exportImage(to: url, options: o) }
        catch { throw CommandError("image export failed: \(error.localizedDescription)") }
    }

    func undo() -> Bool { guard let e = editor, e.canUndo else { return false }; e.undo(); return true }
    func redo() -> Bool { guard let e = editor, e.canRedo else { return false }; e.redo(); return true }
}
