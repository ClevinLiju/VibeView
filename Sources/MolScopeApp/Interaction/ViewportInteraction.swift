import Foundation
import AppKit
import MolCore

/// Maps viewport picks to editing actions according to the active tool.
@MainActor
struct ViewportInteraction {
    let editor: EditorModel

    func handle(_ pick: ViewportPick, modifiers: NSEvent.ModifierFlags) {
        switch editor.tool {
        case .rotate: break
        case .select: select(pick, extend: modifiers.contains(.shift) || modifiers.contains(.command))
        case .build: build(pick)
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

    private func build(_ pick: ViewportPick) {
        let m = editor.molecule
        let payload = editor.payload
        switch pick {
        case .empty(let p):
            editor.apply("Add Atom") { mol in if let r = BuildOps.place(payload, in: mol, at: p) { mol = r } }
        case .atom(let i):
            guard m.atoms.indices.contains(i) else { return }
            if BuildOps.isHydrogen(m, i) {
                editor.apply("Attach") { mol in if let r = BuildOps.attach(payload, to: mol, replacingHydrogen: i) { mol = r } }
            } else {
                editor.apply("Grow") { mol in if let r = BuildOps.grow(payload, from: i, in: mol) { mol = r } }
            }
        case .bond(let a, let b):
            guard let bond = m.bond(between: a, and: b) else { return }
            let next: BondOrder
            switch bond.order { case .single: next = .double; case .double: next = .triple; default: next = .single }
            editor.apply("Change Bond Order") { mol in BuildOps.setBondOrder(&mol, a, b, next) }
            editor.selectedBond = editor.molecule.bond(between: a, and: b)
        }
    }

    private func measure(_ pick: ViewportPick) {
        guard case .atom(let i) = pick else { return }
        if editor.measurePicks.count >= 4 { editor.measurePicks = [] }
        if editor.measurePicks.last == i { return }
        editor.measurePicks.append(i)
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
    func cleanGeometry() {
        if let r = BuildOps.clean(molecule) {
            apply("Clean Geometry") { $0 = r }
            statusMessage = "Geometry cleaned"
        } else { statusMessage = "Geometry cleanup unavailable" }
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
