import Foundation
import SwiftUI
import MolCore

// SHARED APP CORE (owned by Lead 4). Workers: do not change existing signatures; you may add
// extensions to EditorModel in your own files.

public enum EditorTool: String, CaseIterable, Identifiable, Sendable {
    case rotate, select, build, measure
    public var id: String { rawValue }
    public var title: String {
        switch self { case .rotate: "Orbit"; case .select: "Pick"; case .build: "Sketch"; case .measure: "Gauge" }
    }
    public var symbol: String {
        switch self { case .rotate: "rotate.3d"; case .select: "cursorarrow.rays"; case .build: "pencil.and.outline"; case .measure: "ruler" }
    }
}

/// What the Sketch (build) tool places when you click.
public enum BuildPayload: Equatable, Sendable {
    case element(Int)          // atomic number
    case fragment(String)      // MolBuild FragmentLibrary id
}

/// Per-window editing state. The document holds the persisted molecule; the editor mirrors it.
@MainActor
public final class EditorModel: ObservableObject {
    @Published public var molecule: Molecule
    @Published public var result: CalculationResult?
    @Published public var selection: Set<Int> = []          // atom indices
    @Published public var selectedBond: Bond? = nil
    @Published public var tool: EditorTool = .rotate
    @Published public var payload: BuildPayload = .element(6)
    @Published public var measurePicks: [Int] = []          // up to 4 atom indices
    @Published public var frameIndex: Int? = nil             // index into result.steps when browsing
    @Published public var activeModeIndex: Int? = nil        // normal mode being animated
    @Published public var vibrationAmplitude: Double = 0.5
    @Published public var activeOrbitalIndex: Int? = nil     // 1-based orbital index for display
    @Published public var statusMessage: String = ""
    @Published public var fileURL: URL? = nil

    /// Called after every committed edit so the document can sync (set by the window view).
    public var onCommit: ((Molecule) -> Void)?

    private var undoStack: [(String, Molecule)] = []
    private var redoStack: [(String, Molecule)] = []
    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var undoActionName: String? { undoStack.last?.0 }
    public var redoActionName: String? { redoStack.last?.0 }

    public init(molecule: Molecule = Molecule(), result: CalculationResult? = nil) {
        self.molecule = molecule
        self.result = result
    }

    /// The molecule to draw: a browsed frame of the result if one is chosen, else the editable molecule.
    public var displayedMolecule: Molecule {
        if let f = frameIndex, let steps = result?.steps, steps.indices.contains(f) { return steps[f] }
        return molecule
    }

    /// Apply an undoable edit. All mutations of `molecule` should go through here.
    public func apply(_ actionName: String, _ change: (inout Molecule) -> Void) {
        var m = molecule
        change(&m)
        guard m != molecule else { return }
        undoStack.append((actionName, molecule))
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
        molecule = m
        selection = selection.filter { $0 < m.atoms.count }
        measurePicks = measurePicks.filter { $0 < m.atoms.count }
        frameIndex = nil
        onCommit?(m)
    }

    /// Replace the whole molecule (e.g. adopt an optimization frame) as one undoable step.
    public func replaceMolecule(_ m: Molecule, actionName: String) { apply(actionName) { $0 = m } }

    public func undo() {
        guard let (name, prev) = undoStack.popLast() else { return }
        redoStack.append((name, molecule))
        molecule = prev
        selection = selection.filter { $0 < prev.atoms.count }
        measurePicks = []
        onCommit?(prev)
    }

    public func redo() {
        guard let (name, next) = redoStack.popLast() else { return }
        undoStack.append((name, molecule))
        molecule = next
        selection = selection.filter { $0 < next.atoms.count }
        measurePicks = []
        onCommit?(next)
    }
}

/// Lets menu commands reach the frontmost window's editor.
public struct FocusedEditorKey: FocusedValueKey { public typealias Value = EditorModel }
public extension FocusedValues {
    var editor: EditorModel? {
        get { self[FocusedEditorKey.self] }
        set { self[FocusedEditorKey.self] = newValue }
    }
}

/// App-wide notifications for actions that open sheets/windows from menus.
public extension Notification.Name {
    static let molscopeShowCalcSetup = Notification.Name("molscope.showCalcSetup")
    static let molscopeShowJobQueue = Notification.Name("molscope.showJobQueue")
    static let molscopeShowResults = Notification.Name("molscope.showResults")
    static let molscopeCleanGeometry = Notification.Name("molscope.cleanGeometry")
}
