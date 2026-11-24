import AppKit
import SceneKit
import MolCore
import MolBuild
import MolRender

/// Developer aid for headless UI review: with `VIBEVIEW_SNAPSHOT_DIR` (or the older `VIBEVIEW_SNAPSHOT_DIR`) set, every window is written to
/// `<dir>/window-<n>.png` a few seconds after launch (SceneKit views are composited via `snapshot()`).
@MainActor
enum WindowSnapshots {
    static func scheduleIfRequested() {
        guard let dir = AppEnv.value("SNAPSHOT_DIR") else { return }
        let delay = Double(AppEnv.value("SNAPSHOT_DELAY") ?? "") ?? 6
        let url = URL(fileURLWithPath: dir)
        if AppEnv.isSet("GALLERY") {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                if let ed = EditorRegistry.live.last { UIGallery.capture(to: url, editor: ed) }
            }
        }
        if AppEnv.isSet("SELFTEST") {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { SelfTest.run(dir: url) }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { capture(to: url) }
        }
    }

    static func capture(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (n, w) in NSApp.windows.enumerated() where w.isVisible {
            guard let root = w.contentView?.superview ?? w.contentView else { continue }
            let b = root.bounds
            guard let rep = root.bitmapImageRepForCachingDisplay(in: b) else { continue }
            root.cacheDisplay(in: b, to: rep)
            let img = NSImage(size: b.size)
            img.lockFocus()
            // 3-D views first, then the window drawing on top (the SCNView area is transparent in the cache,
            // so SwiftUI overlays such as the command palette stay visible).
            for (k, v) in allSubviews(root).compactMap({ $0 as? SCNView }).enumerated() {
                let shot = v.snapshot()
                shot.draw(in: v.convert(v.bounds, to: root))
                if let t = shot.tiffRepresentation, let b = NSBitmapImageRep(data: t), let png = b.representation(using: .png, properties: [:]) {
                    try? png.write(to: dir.appendingPathComponent("scene-\(n)-\(k).png"))
                }
            }
            NSImage(cgImage: rep.cgImage!, size: b.size).draw(in: NSRect(origin: .zero, size: b.size), from: .zero, operation: .sourceOver, fraction: 1)
            img.unlockFocus()
            if let tiff = img.tiffRepresentation, let bmp = NSBitmapImageRep(data: tiff),
               let png = bmp.representation(using: .png, properties: [:]) {
                try? png.write(to: dir.appendingPathComponent("window-\(n)-\(w.title.replacingOccurrences(of: "/", with: "-")).png"))
            }
        }
    }

    private static func allSubviews(_ v: NSView) -> [NSView] { v.subviews + v.subviews.flatMap(allSubviews) }
}

/// Scripted end-to-end exercise of the editor through the real renderer (clicks via `performClick`).
@MainActor
enum SelfTest {
    static func run(dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var log: [String] = []
        func say(_ s: String) { log.append(s) }
        guard let ed = EditorRegistry.live.last else { say("FAIL no editor"); write(log, dir); return }
        let r = ed.viewport.renderer
        if !ed.molecule.atoms.isEmpty {   // a document was opened: exercise the results side instead
            say("loaded \(ed.molecule.formula) steps=\(ed.result?.steps.count ?? 0) modes=\(ed.result?.normalModes.count ?? 0) orbitals=\(ed.result?.orbitals.count ?? 0) excited=\(ed.result?.excitedStates.count ?? 0) wavefunction=\(ed.wavefunction != nil)")
            if let homo = ed.result?.orbitals.filter({ $0.occupied && $0.spin != .beta }).map(\.index).max() { ed.activeOrbitalIndex = homo }
            if let modes = ed.result?.normalModes, !modes.isEmpty { ed.activeModeIndex = modes.count - 1 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                say("orbital status: \(ed.orbitalStatus); surfaces=\(r.isosurfaces.count) vib playing=\(r.vibration.isPlaying)")
                var o = ImageExportOptions(); o.widthPoints = 640; o.heightPoints = 480
                try? r.exportImage(to: dir.appendingPathComponent("results-view.png"), options: o)
                WindowSnapshots.capture(to: dir); write(log, dir)
            }
            return
        }
        let c = CGPoint(x: r.view.bounds.midX, y: r.view.bounds.midY)
        ed.tool = .build; ed.payload = .element(6)
        r.performClick(at: c)
        say("place C: \(ed.molecule.formula) atoms=\(ed.molecule.atoms.count)")
        // grow: click on the carbon (atom 0) — find its screen point
        func screen(_ i: Int) -> CGPoint {
            let p = ed.molecule.atoms[i].position
            let v = r.view.projectPoint(SCNVector3(p.x, p.y, p.z))
            return CGPoint(x: v.x, y: v.y)
        }
        r.performClick(at: screen(0))
        say("click C with C (replace in place = no change): \(ed.molecule.formula)")
        ed.payload = .element(8)
        if let c2 = ed.molecule.atoms.indices.last(where: { ed.molecule.atoms[$0].atomicNumber == 6 }) { r.performClick(at: screen(c2)) }
        say("click C with O (replace C by O): \(ed.molecule.formula)")
        ed.payload = .fragment("phenyl")
        if let h = ed.molecule.atoms.indices.first(where: { ed.molecule.atoms[$0].atomicNumber == 1 }) { r.performClick(at: screen(h)) }
        say("attach phenyl on H: \(ed.molecule.formula)")
        // change element via inspector path + bond order cycle
        if let o = ed.molecule.atoms.indices.first(where: { ed.molecule.atoms[$0].atomicNumber == 8 }) {
            ed.apply("Change Element") { BuildOps.setElement(&$0, atom: o, to: 7) }
            say("O→N: \(ed.molecule.formula)")
        }
        ed.addHydrogens(); say("add H: \(ed.molecule.formula)")
        let e0 = Cleanup.energyFacade(ed.molecule)
        ed.cleanGeometry(); say(String(format: "clean: E %.2f → %.2f", e0, Cleanup.energyFacade(ed.molecule)))
        let n = ed.molecule.atoms.count
        ed.undo(); say("undo: atoms \(ed.molecule.atoms.count) (was \(n)), canRedo=\(ed.canRedo)")
        ed.redo(); say("redo: atoms \(ed.molecule.atoms.count)")
        // measure tool
        ed.tool = .measure; ed.measurePicks = []
        r.performClick(at: screen(0)); r.performClick(at: screen(1))
        say("measure picks \(ed.measurePicks) distance \(ed.measurePicks.count == 2 ? String(format: "%.3f", ed.molecule.distance(ed.measurePicks[0], ed.measurePicks[1])) : "-")")
        // select tool
        ed.tool = .select; r.performClick(at: screen(0)); say("select: \(ed.selection.sorted())")
        // Delete key in the focused 3-D view (synthesized Backspace through NSApp.sendEvent → event monitor)
        let before = ed.molecule.atoms.count
        if let h = ed.molecule.atoms.indices.last(where: { ed.molecule.atoms[$0].atomicNumber == 1 }) { ed.selection = [h] }
        r.view.window?.makeFirstResponder(r.view)
        if let w = r.view.window, let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                             windowNumber: w.windowNumber, context: nil, characters: "\u{7F}",
                                                             charactersIgnoringModifiers: "\u{7F}", isARepeat: false, keyCode: 51) {
            NSApp.sendEvent(key)
        }
        say("delete key: atoms \(before) → \(ed.molecule.atoms.count), undo name \(ed.undoActionName ?? "-")")
        ed.undo(); say("undo delete: atoms \(ed.molecule.atoms.count)")
        // console delete
        let con = ed.console
        con.input = "select H"; con.submit()
        let nh = ed.selection.count
        con.input = "delete"; con.submit()
        say("console delete (\(nh) H selected): \(ed.molecule.formula); last line: \(con.lines.last?.text ?? "")")
        con.input = "undo"; con.submit(); say("console undo: \(ed.molecule.formula)")
        // context menu contents
        ed.selection = [0]
        say("context menu: " + ViewportContextMenu.make(editor: ed).items.map { $0.isSeparatorItem ? "|" : $0.title + ($0.isEnabled ? "" : "(off)") }.joined(separator: ", "))
        // save + export
        do {
            let gjf = dir.appendingPathComponent("selftest.gjf")
            try IOBridge.write(ed.molecule, ext: "gjf").write(to: gjf)
            let back = try IOBridge.read(url: gjf)
            say("save/reload gjf: \(back.molecule.formula)")
            var o = ImageExportOptions(); o.widthPoints = 640; o.heightPoints = 480
            try r.exportImage(to: dir.appendingPathComponent("selftest-export.png"), options: o)
            say("export image: ok")
        } catch { say("FAIL io \(error)") }
        ed.tool = .rotate
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            ed.showCommandPalette = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                WindowSnapshots.capture(to: dir)
                ed.showCommandPalette = false
                ed.showCalcSetup = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    WindowSnapshots.captureSheets(to: dir)
                    write(log, dir)
                }
            }
        }
    }
    static func write(_ log: [String], _ dir: URL) {
        try? log.joined(separator: "\n").write(to: dir.appendingPathComponent("selftest.txt"), atomically: true, encoding: .utf8)
    }
}

extension WindowSnapshots {
    static func captureSheets(to dir: URL) {
        for (n, w) in NSApp.windows.enumerated() {
            guard let s = w.attachedSheet, let v = s.contentView else { continue }
            let b = v.bounds
            guard let rep = v.bitmapImageRepForCachingDisplay(in: b) else { continue }
            v.cacheDisplay(in: b, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("sheet-\(n).png"))
        }
    }
}
