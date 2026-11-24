import Foundation
import MolCore
import MolIO

/// The application side of the command language. Atom indices crossing this boundary are 0-BASED.
/// Only `molecule`, `selection` and `currentDirectory` are required; everything else has a
/// default (no-op, or throws "not supported") so the app can adopt features incrementally.
public protocol CommandContext: AnyObject {
    var molecule: Molecule { get }
    var selection: Set<Int> { get set }
    var currentDirectory: URL { get set }

    func open(urls: [URL]) throws
    func save(to url: URL, format: MoleculeFileFormat?) throws
    func close()
    /// Replace the molecule as one undoable edit.
    func setMolecule(_ m: Molecule, actionName: String)
    func setHydrogensVisible(_ visible: Bool)
    func setHidden(_ atoms: Set<Int>, hidden: Bool)
    func setStyle(_ style: DisplayStyleName)
    func setColor(_ color: CommandColor, atoms: Set<Int>)
    /// nil turns labels off.
    func setLabels(_ kind: LabelKind?)
    func addMeasurement(atoms: [Int])
    func rotate(axis: Axis, degrees: Double)
    func fitView()
    func viewAlong(_ axis: Axis)
    func addHydrogens() throws
    func cleanGeometry() throws
    /// Synchronous entry point; the app may start its own Task.
    func runXTBOptimization(options: [String]) throws
    func showOrbital(_ which: OrbitalSelector) throws
    /// 1-based mode number; nil or 0 stops the animation.
    func showVibration(_ mode: Int?) throws
    func exportImage(to url: URL, width: Int?, height: Int?) throws
    /// Full-featured export used by `export image`; the default forwards to `exportImage(to:width:height:)`.
    func exportImage(_ request: ImageExportRequest, to url: URL) throws
    func undo() -> Bool
    func redo() -> Bool
}

public extension CommandContext {
    func open(urls: [URL]) throws { throw CommandError("open is not supported here") }
    func save(to url: URL, format: MoleculeFileFormat?) throws { throw CommandError("save is not supported here") }
    func close() {}
    func setMolecule(_ m: Molecule, actionName: String) {}
    func setHydrogensVisible(_ visible: Bool) {}
    func setHidden(_ atoms: Set<Int>, hidden: Bool) {}
    func setStyle(_ style: DisplayStyleName) {}
    func setColor(_ color: CommandColor, atoms: Set<Int>) {}
    func setLabels(_ kind: LabelKind?) {}
    func addMeasurement(atoms: [Int]) {}
    func rotate(axis: Axis, degrees: Double) {}
    func fitView() {}
    func viewAlong(_ axis: Axis) {}
    func addHydrogens() throws { throw CommandError("addh is not supported here") }
    func cleanGeometry() throws { throw CommandError("clean is not supported here") }
    func runXTBOptimization(options: [String]) throws { throw CommandError("xtb is not supported here") }
    func showOrbital(_ which: OrbitalSelector) throws { throw CommandError("orbital display is not supported here") }
    func showVibration(_ mode: Int?) throws { throw CommandError("vibration display is not supported here") }
    func exportImage(to url: URL, width: Int?, height: Int?) throws { throw CommandError("image export is not supported here") }
    func exportImage(_ request: ImageExportRequest, to url: URL) throws {
        try exportImage(to: url, width: request.width, height: request.height)
    }
    func undo() -> Bool { false }
    func redo() -> Bool { false }
}
