import Foundation

/// Plain value-type document state: molecule + selection + snapshot-based undo/redo.
public struct MoleculeDocumentModel: Sendable {
    private struct Snapshot: Sendable {
        var name: String
        var molecule: Molecule
        var selection: AtomSelection
        var revision: Int
    }

    public private(set) var molecule: Molecule
    public var selection: AtomSelection {
        didSet { if selection != oldValue { changeCount += 1 } }
    }
    /// Increments on every change (edit, selection, undo, redo, replace) for UI refresh.
    public private(set) var changeCount: Int = 0
    public var undoLimit: Int = 100 { didSet { trim() } }

    private var undoStack: [Snapshot] = []   // states BEFORE each action
    private var redoStack: [Snapshot] = []   // states AFTER each undone action
    private var revision = 0
    private var nextRevision = 1
    private var savedRevision = 0
    private var groupDepth = 0
    private var groupStart: Snapshot? = nil

    public init(molecule: Molecule = Molecule()) {
        self.molecule = molecule
        self.selection = AtomSelection()
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var undoName: String? { undoStack.last?.name }
    public var redoName: String? { redoStack.last?.name }
    public var isDirty: Bool { revision != savedRevision }
    public var isGrouping: Bool { groupDepth > 0 }

    public mutating func markSaved() { savedRevision = revision }

    private mutating func trim() {
        let lim = max(undoLimit, 0)
        if undoStack.count > lim { undoStack.removeFirst(undoStack.count - lim) }
    }

    private func snapshot(_ name: String) -> Snapshot {
        Snapshot(name: name, molecule: molecule, selection: selection, revision: revision)
    }

    /// Runs `edit`; if it changes the molecule, records one undo step. Selection is clamped to valid indices.
    public mutating func perform(_ name: String, _ edit: (inout Molecule) -> Void) {
        performRemapping(name) { m in edit(&m); return nil }
    }

    /// Like `perform`, but `edit` may return an old->new index map (from `Molecule.removeAtoms`)
    /// which is applied to the selection.
    public mutating func performRemapping(_ name: String, _ edit: (inout Molecule) -> [Int?]?) {
        var m = molecule
        let before = snapshot(name)
        let map = edit(&m)
        guard m != molecule else { return }
        molecule = m
        if let map { selection.remap(map) }
        selection.clamp(count: molecule.atoms.count)
        changeCount += 1
        if groupDepth > 0 { return }
        undoStack.append(before)
        redoStack.removeAll()
        revision = nextRevision; nextRevision += 1
        trim()
    }

    public mutating func beginGroup(_ name: String) {
        if groupDepth == 0 { groupStart = snapshot(name) }
        groupDepth += 1
    }

    /// Ends a group; all edits made inside become one undo step (none if nothing changed).
    public mutating func endGroup() {
        guard groupDepth > 0 else { return }
        groupDepth -= 1
        guard groupDepth == 0, let start = groupStart else { return }
        groupStart = nil
        guard start.molecule != molecule else { return }
        undoStack.append(start)
        redoStack.removeAll()
        revision = nextRevision; nextRevision += 1
        trim()
    }

    public mutating func undo() {
        guard let s = undoStack.popLast() else { return }
        redoStack.append(Snapshot(name: s.name, molecule: molecule, selection: selection, revision: revision))
        restore(s)
    }

    public mutating func redo() {
        guard let s = redoStack.popLast() else { return }
        undoStack.append(Snapshot(name: s.name, molecule: molecule, selection: selection, revision: revision))
        restore(s)
    }

    private mutating func restore(_ s: Snapshot) {
        molecule = s.molecule
        var sel = s.selection
        sel.clamp(count: molecule.atoms.count)
        selection = sel
        revision = s.revision
        changeCount += 1
    }

    /// Replaces the molecule. `actionName == nil`: not undoable, clears history, marks clean (e.g. file load).
    /// Otherwise it is one undoable step.
    public mutating func replaceMolecule(_ m: Molecule, actionName: String?) {
        if let name = actionName {
            let before = snapshot(name)
            molecule = m
            selection.clamp(count: m.atoms.count)
            changeCount += 1
            if groupDepth > 0 { return }
            undoStack.append(before); redoStack.removeAll()
            revision = nextRevision; nextRevision += 1
            trim()
        } else {
            molecule = m
            selection = AtomSelection()
            undoStack.removeAll(); redoStack.removeAll()
            groupDepth = 0; groupStart = nil
            revision = nextRevision; nextRevision += 1
            savedRevision = revision
            changeCount += 1
        }
    }
}
