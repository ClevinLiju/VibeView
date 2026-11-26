import AppKit
import MolCore
import MolRender
import MolCommand

/// Delete / Backspace and a right-click menu for the 3-D view. The view itself belongs to MolRender, so
/// events are observed with a local monitor scoped to this window's scene view.
@MainActor
final class ViewportEventMonitor {
    private weak var editor: EditorModel?
    private var monitor: Any?
    private var rightDown: NSPoint?

    init(editor: EditorModel) {
        self.editor = editor
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .rightMouseDown, .rightMouseUp]) { [weak self] e in
            guard let self else { return e }
            return MainActor.assumeIsolated { self.handle(e) }
        }
    }

    deinit { if let m = monitor { NSEvent.removeMonitor(m) } }

    private func handle(_ e: NSEvent) -> NSEvent? {
        guard let ed = editor else { return e }
        let view = ed.viewport.renderer.view
        guard e.window === view.window, view.window != nil else { return e }
        switch e.type {
        case .keyDown:
            // Only when the 3-D view has keyboard focus (never while typing in a text field).
            guard view.window?.firstResponder === view else { return e }
            let deleteKeys: Set<UInt16> = [51, 117]   // Backspace, forward Delete
            let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
            guard deleteKeys.contains(e.keyCode), mods.isEmpty || mods == .command else { return e }
            guard !ed.selection.isEmpty, ed.frameIndex == nil else { NSSound.beep(); return nil }
            ed.deleteSelection()
            return nil
        case .rightMouseDown:
            let p = view.convert(e.locationInWindow, from: nil)
            rightDown = view.bounds.contains(p) ? e.locationInWindow : nil
            return e
        case .rightMouseUp:
            defer { rightDown = nil }
            guard let start = rightDown, hypot(e.locationInWindow.x - start.x, e.locationInWindow.y - start.y) < 4 else { return e }
            let p = view.convert(e.locationInWindow, from: nil)
            // Right-clicking an unselected atom makes it the selection first, like Finder.
            if case .atom(let i) = ed.viewport.renderer.pick(at: p), !ed.selection.contains(i) { ed.selection = [i] }
            let menu = ViewportContextMenu.make(editor: ed)
            DispatchQueue.main.async { menu.popUp(positioning: nil, at: p, in: view) }
            return e
        default:
            return e
        }
    }
}

@MainActor
enum ViewportContextMenu {
    static func make(editor ed: EditorModel) -> NSMenu {
        let m = NSMenu()
        let n = ed.selection.count
        let del = ClosureMenuItem(n == 1 ? "Delete Atom" : "Delete \(n) Atoms") { ed.deleteSelection() }
        del.isEnabled = n > 0 && ed.frameIndex == nil
        m.addItem(del)
        m.addItem(.separator())
        m.addItem(ClosureMenuItem("Select All") { ed.selectAll() })
        let clear = ClosureMenuItem("Deselect") { ed.selection = []; ed.selectedBond = nil }
        clear.isEnabled = n > 0
        m.addItem(clear)
        m.addItem(.separator())
        m.addItem(ClosureMenuItem("Add Hydrogens") { ed.addHydrogens() })
        m.addItem(ClosureMenuItem("Fit to Window") { ed.fitView() })
        return m
    }
}

/// NSMenuItem that runs a closure (keeps menus free of selector plumbing).
final class ClosureMenuItem: NSMenuItem {
    private let run: () -> Void
    init(_ title: String, _ run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("not used") }
    @objc private func fire() { run() }
}

/// Console `delete` command: `delete` removes the selection, `delete SPEC` the given atoms (undoable).
extension CommandRegistry {
    static func app() -> CommandRegistry {
        var r = CommandRegistry.standard
        if r.lookup("delete") == nil {
            r.register(CommandDefinition(name: "delete", aliases: ["del"], usage: "delete [atoms]",
                                         summary: "Delete atoms (default: the selection). Undo with “undo”.") { inv in
                let targets = inv.arguments.isEmpty ? inv.context.selection : try inv.atoms(inv.arguments)
                guard !targets.isEmpty else { throw CommandError("nothing selected; give atoms, e.g. delete H or delete 3-5") }
                var m = inv.context.molecule
                let n = m.atoms.count
                BuildOps.deleteAtoms(&m, targets)
                inv.context.selection = []
                inv.context.setMolecule(m, actionName: "Delete Atoms")
                return CommandOutput("deleted \(n - m.atoms.count) atom\(n - m.atoms.count == 1 ? "" : "s")")
            })
        }
        return r
    }
}
