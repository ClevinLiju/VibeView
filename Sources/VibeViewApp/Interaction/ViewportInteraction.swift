import Foundation
import AppKit
import MolCore
import MolBuild
import MolRender

/// Maps viewport picks to editing actions according to the active tool.
@MainActor
struct ViewportInteraction {
    let editor: EditorModel

    func handle(_ pick: ViewportPick, modifiers: NSEvent.ModifierFlags) {
        switch editor.tool {
        case .rotate: break
        case .select, .move: select(pick, extend: modifiers.contains(.shift) || modifiers.contains(.command))
        case .build: build(pick, grow: modifiers.contains(.option))
        case .bond: link(pick, delete: modifiers.contains(.option))
        case .measure: measure(pick)
        }
    }

    private func select(_ pick: ViewportPick, extend: Bool) {
        switch pick {
        case .atom(let i):
            editor.selectedBond = nil
            if extend {
                if editor.selection.contains(i) { editor.selection.remove(i) } else { editor.selection.insert(i) }
            } else { editor.selection = [i] }
        case .bond(let a, let b):
            if let bond = editor.displayedMolecule.bond(between: a, and: b) {
                editor.selectedBond = bond
                editor.selection = [a, b]
            }
        case .empty:
            if !extend { editor.selection = []; editor.selectedBond = nil }
        }
    }

    /// Sketch click: empty space places, a hydrogen is substituted, a heavy atom is replaced in place
    /// (MolBuild `Builder.click`). Option-click on a heavy atom grows a new bonded atom instead.
    private func build(_ pick: ViewportPick, grow: Bool) {
        let m = editor.molecule
        let payload = editor.payload
        let item: BuildItem
        switch payload { case .element(let z): item = .element(z); case .fragment(let id): item = .fragment(id) }
        switch pick {
        case .empty(let p):
            run("Add \(payloadName)") { try Builder.click(item, on: .empty(p), in: $0) }
        case .atom(let i):
            guard m.atoms.indices.contains(i) else { return }
            if grow && !BuildOps.isHydrogen(m, i) {
                editor.apply("Grow") { mol in if let r = BuildOps.grow(payload, from: i, in: mol) { mol = r } }
                return
            }
            let action = BuildOps.isHydrogen(m, i) ? "Attach \(payloadName)" : "Replace with \(payloadName)"
            run(action) { try Builder.click(item, on: .atom(i), in: $0) }
        case .bond(let a, let b):
            guard let bond = m.bond(between: a, and: b) else { return }
            let next: BondOrder
            switch bond.order { case .single: next = .double; case .double: next = .triple; default: next = .single }
            editor.apply("Change Bond Order") { mol in BuildOps.setBondOrder(&mol, a, b, next) }
            editor.selectedBond = editor.molecule.bond(between: a, and: b)
        }
    }

    private var payloadName: String {
        switch editor.payload { case .element(let z): ElementInfo.symbol(z); case .fragment(let id): BuildOps.fragmentName(id) }
    }

    /// Run a throwing MolBuild edit as one undo step; refusals go to the status bar.
    private func run(_ action: String, _ body: (Molecule) throws -> Molecule) {
        do {
            let r = try body(editor.molecule)
            editor.apply(action) { $0 = r }
            editor.statusMessage = ""
        } catch {
            editor.statusMessage = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            NSSound.beep()
        }
    }

    /// Gauge: collect as many atoms as the mode needs; the finished measurement becomes a monitor.
    private func measure(_ pick: ViewportPick) {
        guard case .atom(let i) = pick else { return }
        let need = editor.measureMode.atomCount
        if editor.measurePicks.count >= need { editor.measurePicks = [] }
        if editor.measurePicks.contains(i) { return }
        editor.measurePicks.append(i)
        if editor.measurePicks.count == need { editor.addMonitor(for: editor.measurePicks) }
    }

    /// Link: click two atoms to bond them (any fragments) with `editor.bondOrder`; click a bond to give it that
    /// order; Option-click a bond (or the second atom of a bonded pair) to delete it.
    private func link(_ pick: ViewportPick, delete: Bool) {
        switch pick {
        case .empty:
            editor.bondPick = nil
        case .bond(let a, let b):
            editor.bondPick = nil
            if delete { run("Delete Bond") { try Editing.disconnect($0, a, b) } }
            else { let o = editor.bondOrder; run("Set Bond Order") { try Editing.connect($0, a, b, order: o) } }
        case .atom(let i):
            guard let first = editor.bondPick else { editor.bondPick = i; editor.statusMessage = "Now click the atom to bond to"; return }
            editor.bondPick = nil
            if first == i { return }
            if delete { run("Delete Bond") { try Editing.disconnect($0, first, i) } }
            else { let o = editor.bondOrder; run("Add Bond") { try Editing.connect($0, first, i, order: o) } }
        }
    }
}

extension EditorModel {
    func addMonitor(for picks: [Int]) {
        let m: Monitor
        switch picks.count {
        case 2: m = .distance(picks[0], picks[1])
        case 3: m = .angle(picks[0], picks[1], picks[2])
        case 4: m = .dihedral(picks[0], picks[1], picks[2], picks[3])
        default: return
        }
        if !monitors.contains(m) { monitors.append(m) }
    }
}

extension EditorModel {
    func deleteSelection() {
        let sel = selection
        guard !sel.isEmpty else { return }
        apply("Delete") { BuildOps.deleteAtoms(&$0, sel) }
        selection = []; selectedBond = nil
    }
    func selectAll() { selection = Set(molecule.atoms.indices) }
    func addHydrogens() {
        let sel = selection.isEmpty ? nil : selection
        apply("Add Hydrogens") { BuildOps.addHydrogens(&$0, atoms: sel) }
    }
    func centerAtOrigin() {
        apply("Center at Origin") { m in let c = m.centroid; for i in m.atoms.indices { m.atoms[i].position -= c } }
    }
    func rebuildBonds() {
        apply("Rebuild Bonds") { m in m.bonds = []; m.perceiveBonds(); m.perceiveBondOrders() }
    }
    func invertStructure() { apply("Invert") { BuildOps.invert(&$0) } }
    func mirrorStructure() { apply("Mirror") { BuildOps.mirror(&$0) } }
}
