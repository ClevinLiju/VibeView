import AppKit
import UniformTypeIdentifiers
import MolCore
import MolIO
import MolAnalysis
import MolRender
import MolCommand

/// File ▸ Export: structures (current or all frames, optional selection), animations (GIF/MP4/MOV of a vibrational
/// mode, the trajectory or a turntable spin) and result tables (CSV). Used by the menu dialogs and by the console's
/// `export` command; images go through `exportImage()` / `export image`.
extension EditorModel {
    enum ExportFailure: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
    }

    private var exportBaseName: String {
        fileURL?.deletingPathExtension().lastPathComponent ?? (molecule.title.isEmpty ? "Molecule" : molecule.title)
    }

    /// Frames a structure export can write: the trajectory/optimization steps, or just the shown molecule.
    var exportFrames: [Molecule] {
        if let steps = result?.steps, steps.count > 1 { return steps }
        return [displayedMolecule]
    }

    // MARK: Core (shared with the console)

    func writeStructure(to url: URL, allFrames: Bool, selectedOnly: Bool) throws -> String {
        let ext = url.pathExtension
        guard let fmt = MoleculeFileFormat.format(forExtension: ext), MolecularFileLoader.writableFormats.contains(fmt) else {
            throw ExportFailure.message("can't write “.\(ext)” structure files (use .xyz, .pdb, .sdf, .mol, .cml, .gjf, .inp…)")
        }
        let frames = allFrames ? exportFrames : [displayedMolecule]
        let energies: [Double?]
        if allFrames && frames.count > 1 {
            energies = StructureExport.frameEnergies(result?.energies ?? [], frameCount: frames.count)
        } else if let r = result, !r.energies.isEmpty {
            let all = StructureExport.frameEnergies(r.energies, frameCount: max(r.steps.count, 1))
            let k = frameIndex ?? (all.count - 1)
            energies = [all.indices.contains(k) ? all[k] : nil]
        } else { energies = [] }
        var atoms: [Int]? = nil
        if selectedOnly {
            guard !selection.isEmpty else { throw ExportFailure.message("no atoms are selected") }
            atoms = selection.sorted()
        }
        let out = try StructureExport.text(frames: frames, format: fmt, energies: energies, atoms: atoms, title: exportBaseName)
        try out.text.write(to: url, atomically: true, encoding: .utf8)
        if allFrames && frames.count > 1 && !StructureExport.multiFrameFormats.contains(fmt) {
            return "\(fmt.displayName) holds one structure: wrote the last frame, \(out.atomCount) atoms"
        }
        return "\(out.frameCount) frame\(out.frameCount == 1 ? "" : "s"), \(out.atomCount) atoms"
    }

    func writeTable(_ table: ResultTables.Table, to url: URL) throws {
        guard let r = result else { throw ExportFailure.message("this document has no calculation results") }
        let text = try ResultTables.csv(table, result: r, molecule: molecule)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Renders and encodes an animation. Returns "N frames, W×H".
    func runAnimationExport(_ req: AnimationExportRequest, to url: URL) throws -> String {
        let r = renderer
        let viewSize = r.view.bounds.size
        let aspect = viewSize.width > 10 && viewSize.height > 10 ? Double(viewSize.width / viewSize.height) : 4.0 / 3.0
        let w: Int, h: Int
        switch (req.width, req.height) {
        case let (wv?, hv?): (w, h) = (wv, hv)
        case let (wv?, nil): (w, h) = (wv, max(16, Int((Double(wv) / aspect).rounded())))
        case let (nil, hv?): (w, h) = (max(16, Int((Double(hv) * aspect).rounded())), hv)
        case (nil, nil): (w, h) = (800, max(16, Int((800 / aspect).rounded())))
        }
        var o = ImageExportOptions.pixels(width: w, height: h, dpi: 72)
        o.format = .png
        o.supersampling = req.quality >= 0.7 ? 2 : 1
        o.transparentBackground = req.transparent
        if let l = req.look {
            o.look = switch l { case "whitepaper": .whitePaper; case "darkstage": .darkStage; case "illustration": .illustration; default: .studio }
        }
        let fmt: AnimationFormat = switch req.format { case .gif: .gif; case .mp4: .mp4; case .mov: .mov }
        let quality = req.format == .gif ? nil : req.quality
        let wasPlaying = isPlayingFrames
        isPlayingFrames = false
        defer { isPlayingFrames = wasPlaying }
        var frames = 0
        do {
            switch req.source {
            case .vibration(let n):
                guard let modes = result?.normalModes, modes.indices.contains(n - 1) else {
                    throw ExportFailure.message("no vibrational mode \(n)" + ((result?.normalModes.isEmpty ?? true) ? "" : " (1–\(result!.normalModes.count))"))
                }
                guard modes[n - 1].displacements.count == r.molecule.atoms.count else {
                    throw ExportFailure.message("mode \(n) has \(modes[n - 1].displacements.count) atoms but the structure has \(r.molecule.atoms.count)")
                }
                let fpc = req.framesPerLoop
                frames = fpc * req.loops
                try AnimationExporter.exportVibration(renderer: r, mode: modes[n - 1], url: url, framesPerCycle: fpc, cycles: req.loops,
                                                      amplitude: req.amplitude, fps: req.fps, format: fmt, loopCount: req.gifLoopCount,
                                                      quality: quality, options: o)
            case .trajectory:
                guard let steps = result?.steps, steps.count > 1 else { throw ExportFailure.message("this document has no trajectory (one structure only)") }
                var ks = Array(stride(from: 0, to: steps.count, by: max(1, req.step)))
                if ks.last != steps.count - 1 { ks.append(steps.count - 1) }
                let fr = ks.map { steps[$0] }
                frames = fr.count * req.loops
                try AnimationExporter.exportTrajectory(renderer: r, frames: fr, url: url, fps: req.fps, passes: req.loops, format: fmt,
                                                       loopCount: req.gifLoopCount, quality: quality, options: o)
            case .spin:
                guard !r.molecule.atoms.isEmpty else { throw ExportFailure.message("nothing to rotate") }
                frames = req.framesPerLoop * req.loops
                try AnimationExporter.exportSpin(renderer: r, url: url, frameCount: frames, turns: req.loops,
                                                 axis: req.axis == .x ? .x : .y, fps: req.fps, format: fmt, loopCount: req.gifLoopCount,
                                                 quality: quality, options: o)
            }
        } catch let e as ExportFailure { throw e }
        catch { throw ExportFailure.message("animation export failed: \(error)") }
        let px = o.pixelSize
        let mw = fmt == .gif ? Int(px.width) : Int(px.width) & ~1, mh = fmt == .gif ? Int(px.height) : Int(px.height) & ~1
        statusMessage = "Exported \(url.lastPathComponent)"
        return "\(frames) frames, \(mw)×\(mh)"
    }

    // MARK: Dialogs

    private func label(_ s: String) -> NSTextField {
        let t = NSTextField(labelWithString: s); t.alignment = .right; return t
    }
    private func numberField(_ v: String, width: CGFloat = 64) -> NSTextField {
        let f = NSTextField(string: v); f.widthAnchor.constraint(equalToConstant: width).isActive = true; return f
    }
    private func grid(_ rows: [[NSView]]) -> NSView {
        let g = NSGridView(views: rows)
        g.rowSpacing = 6; g.columnSpacing = 8
        g.column(at: 0).xPlacement = .trailing
        g.translatesAutoresizingMaskIntoConstraints = false
        let box = NSView()
        box.addSubview(g)
        NSLayoutConstraint.activate([g.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 16),
                                     g.trailingAnchor.constraint(lessThanOrEqualTo: box.trailingAnchor, constant: -16),
                                     g.topAnchor.constraint(equalTo: box.topAnchor, constant: 10),
                                     g.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -10)])
        box.frame.size = g.fittingSize.applying(.init(scaleX: 1, y: 1))
        box.frame.size.width += 32; box.frame.size.height += 20
        return box
    }
    private func fail(_ error: Error) {
        let a = NSAlert(); a.messageText = "Export failed"; a.informativeText = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        a.runModal()
    }

    func exportStructureDialog() {
        let formats = MolecularFileLoader.writableFormats
        let popup = NSPopUpButton()
        for f in formats { popup.addItem(withTitle: "\(f.displayName) (.\(f.fileExtensions.first ?? ""))") }
        let nFrames = exportFrames.count
        let all = NSButton(checkboxWithTitle: "All \(nFrames) frames (XYZ, PDB and SDF hold several)", target: nil, action: nil)
        all.isEnabled = nFrames > 1
        let sel = NSButton(checkboxWithTitle: "Selected atoms only (\(selection.count))", target: nil, action: nil)
        sel.isEnabled = !selection.isEmpty
        let panel = NSSavePanel()
        panel.title = "Export Structure"
        panel.accessoryView = grid([[label("Format:"), popup], [NSView(), all], [NSView(), sel]])
        panel.nameFieldStringValue = exportBaseName + ".xyz"
        let handler = PopupRenamer(panel: panel, formats: formats)
        popup.target = handler; popup.action = #selector(PopupRenamer.changed(_:))
        guard panel.runModal() == .OK, var url = panel.url else { return }
        let f = formats[max(0, popup.indexOfSelectedItem)]
        if MoleculeFileFormat.format(forExtension: url.pathExtension) == nil, let e = f.fileExtensions.first { url.appendPathExtension(e) }
        do { statusMessage = "Exported \(url.lastPathComponent): " + (try writeStructure(to: url, allFrames: all.state == .on, selectedOnly: sel.state == .on)) }
        catch { fail(error) }
        _ = handler
    }

    func exportTableDialog() {
        let tables = ResultTables.available(result)
        guard !tables.isEmpty else { fail(ExportFailure.message("this document has no result tables")); return }
        let popup = NSPopUpButton()
        for t in tables { popup.addItem(withTitle: t.title) }
        let panel = NSSavePanel()
        panel.title = "Export Table"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.accessoryView = grid([[label("Table:"), popup]])
        panel.nameFieldStringValue = exportBaseName + "-" + tables[0].rawValue + ".csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try writeTable(tables[max(0, popup.indexOfSelectedItem)], to: url); statusMessage = "Exported \(url.lastPathComponent)" }
        catch { fail(error) }
    }

    func exportAnimationDialog() {
        var sources: [(String, AnimationExportRequest.Source)] = []
        if let steps = result?.steps, steps.count > 1 { sources.append(("Trajectory (\(steps.count) frames)", .trajectory)) }
        for (i, m) in (result?.normalModes ?? []).enumerated() where m.displacements.count == renderer.molecule.atoms.count {
            let f = m.frequency < 0 ? String(format: "%.1fi", -m.frequency) : String(format: "%.1f", m.frequency)
            sources.append(("Mode \(i + 1): \(f) cm⁻¹" + (m.symmetry.map { " " + $0 } ?? ""), .vibration(i + 1)))
        }
        sources.append(("Turntable (360° spin)", .spin))
        let src = NSPopUpButton(); for s in sources { src.addItem(withTitle: s.0) }
        if let a = activeModeIndex, let k = sources.firstIndex(where: { $0.1 == .vibration(a + 1) }) { src.selectItem(at: k) }
        let fmt = NSPopUpButton(); fmt.addItems(withTitles: ["GIF", "MP4 (H.264)", "MOV (H.264)"])
        let w = numberField("800"), h = numberField("600")
        let size = renderer.view.bounds.size
        if size.width > 10 && size.height > 10 { h.stringValue = String(Int((800 * size.height / size.width).rounded())) }
        let fps = numberField("24"), dur = numberField("", width: 64), loops = numberField("1")
        dur.placeholderString = "auto"
        let amp = numberField("0.5")
        let quality = NSSlider(value: 0.8, minValue: 0.1, maxValue: 1, target: nil, action: nil)
        quality.widthAnchor.constraint(equalToConstant: 160).isActive = true
        let look = NSPopUpButton(); look.addItems(withTitles: ["Current", "Studio", "White Paper", "Dark Stage", "Illustration"])
        let row = { (views: [NSView]) -> NSView in let s = NSStackView(views: views); s.spacing = 6; return s }
        let panel = NSSavePanel()
        panel.title = "Export Animation"
        panel.accessoryView = grid([
            [label("Animate:"), src],
            [label("Format:"), fmt],
            [label("Size:"), row([w, NSTextField(labelWithString: "×"), h, NSTextField(labelWithString: "px")])],
            [label("Frames/s:"), row([fps, label("Loop (s):"), dur, label("Loops:"), loops])],
            [label("Amplitude (Å):"), amp],
            [label("Quality:"), quality],
            [label("Look:"), look],
        ])
        panel.nameFieldStringValue = exportBaseName + ".gif"
        guard panel.runModal() == .OK, var url = panel.url else { return }
        var req = AnimationExportRequest()
        req.format = [.gif, .mp4, .mov][max(0, fmt.indexOfSelectedItem)]
        if url.pathExtension.lowercased() != req.format.rawValue { url = url.deletingPathExtension().appendingPathExtension(req.format.rawValue) }
        req.source = sources[max(0, src.indexOfSelectedItem)].1
        req.width = Int(w.stringValue).map { max(16, min(4096, $0)) }
        req.height = Int(h.stringValue).map { max(16, min(4096, $0)) }
        req.fps = Double(fps.stringValue).map { max(1, min(60, $0)) } ?? 24
        req.duration = Double(dur.stringValue).flatMap { $0 > 0 ? $0 : nil }
        req.loops = Int(loops.stringValue).map { max(1, min(100, $0)) } ?? 1
        req.amplitude = Double(amp.stringValue).flatMap { $0 > 0 ? $0 : nil } ?? 0.5
        req.quality = quality.doubleValue
        req.look = [nil, "studio", "whitepaper", "darkstage", "illustration"][max(0, look.indexOfSelectedItem)]
        do { statusMessage = "Exported \(url.lastPathComponent): " + (try runAnimationExport(req, to: url)) }
        catch { fail(error) }
    }
}

/// Keeps the save panel's file extension in step with the structure format popup.
private final class PopupRenamer: NSObject {
    weak var panel: NSSavePanel?
    let formats: [MoleculeFileFormat]
    init(panel: NSSavePanel, formats: [MoleculeFileFormat]) { self.panel = panel; self.formats = formats }
    @objc func changed(_ sender: NSPopUpButton) {
        guard let p = panel, formats.indices.contains(sender.indexOfSelectedItem), let ext = formats[sender.indexOfSelectedItem].fileExtensions.first else { return }
        let base = (p.nameFieldStringValue as NSString).deletingPathExtension
        p.nameFieldStringValue = base + "." + ext
    }
}
