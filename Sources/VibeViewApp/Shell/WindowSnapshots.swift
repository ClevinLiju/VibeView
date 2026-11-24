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
        if AppEnv.value("README_SHOTS") != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { _ = ReadmeShots.runIfRequested(dir: url) }
            return
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
            guard let rep = composite(w), let png = rep.representation(using: .png, properties: [:]) else { continue }
            try? png.write(to: dir.appendingPathComponent("window-\(n)-\(w.title.replacingOccurrences(of: "/", with: "-")).png"))
        }
    }

    private static func allSubviews(_ v: NSView) -> [NSView] { v.subviews + v.subviews.flatMap(allSubviews) }

    /// The whole window with its 3-D views filled in. `cacheDisplay` paints each SCNView's area as a flat
    /// placeholder colour, so every pixel there that still shows that colour is replaced by the scene's own
    /// snapshot, and pixels that differ (SwiftUI overlays such as the info card) are kept.
    static func composite(_ w: NSWindow) -> NSBitmapImageRep? {
        guard let root = w.contentView?.superview ?? w.contentView else { return nil }
        let b = root.bounds
        guard let rep = root.bitmapImageRepForCachingDisplay(in: b) else { return nil }
        root.cacheDisplay(in: b, to: rep)
        let scale = CGFloat(rep.pixelsWide) / max(b.width, 1)
        for v in allSubviews(root).compactMap({ $0 as? SCNView }) where !v.isHiddenOrHasHiddenAncestor {
            var r = v.convert(v.bounds, to: root)
            if !root.isFlipped { r.origin.y = b.height - r.maxY }      // bitmap rows run top-down
            let px = Int((r.minX * scale).rounded()), py = Int((r.minY * scale).rounded())
            let pw = Int((r.width * scale).rounded()), ph = Int((r.height * scale).rounded())
            guard pw > 8, ph > 8, let scene = bitmap(of: v.snapshot(), width: pw, height: ph) else { continue }
            func windowPixel(_ x: Int, _ y: Int) -> [Int] {
                var p = [Int](repeating: 0, count: 4); rep.getPixel(&p, atX: x, y: y); return p
            }
            // Placeholder colour: the most common value among a few interior samples.
            var counts: [[Int]: Int] = [:]
            for fx in stride(from: 0.1, through: 0.9, by: 0.2) {
                for fy in stride(from: 0.1, through: 0.9, by: 0.2) {
                    counts[windowPixel(px + Int(Double(pw) * fx), py + Int(Double(ph) * fy)), default: 0] += 1
                }
            }
            guard let key = counts.max(by: { $0.value < $1.value })?.key else { continue }
            var p = [Int](repeating: 0, count: 4), s = [Int](repeating: 0, count: 4)
            for y in 0..<ph where py + y < rep.pixelsHigh {
                for x in 0..<pw where px + x < rep.pixelsWide {
                    rep.getPixel(&p, atX: px + x, y: py + y)
                    guard abs(p[0] - key[0]) <= 2, abs(p[1] - key[1]) <= 2, abs(p[2] - key[2]) <= 2 else { continue }
                    scene.getPixel(&s, atX: x, y: y)
                    s[3] = 255
                    rep.setPixel(&s, atX: px + x, y: py + y)
                }
            }
        }
        return rep
    }

    /// `image` redrawn into an RGBA bitmap of exactly `width`×`height` pixels, in the window bitmap's layout.
    private static func bitmap(of image: NSImage, width: Int, height: Int) -> NSBitmapImageRep? {
        guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        return out
    }
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
