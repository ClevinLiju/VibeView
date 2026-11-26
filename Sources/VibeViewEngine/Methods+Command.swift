import Foundation
import MolCore
import MolIO
import MolBuild
import MolCompute
import MolCommand
import MolSIMD

/// `CommandContext` over a snapshot of one document. Molecule edits go into the copied undo model (and are
/// committed back after the line runs); display changes are collected into a `ViewChange` for the front end.
final class EngineCommandContext: CommandContext {
    var model: MoleculeDocumentModel
    var currentDirectory: URL
    let doc: EngineDocument
    let xtbAvailable: Bool

    // collected view changes
    var style: String?
    var labels: String?
    var fit = false
    var viewAxis: String?
    var orbital: JSON = .null
    var vibration: JSON?
    var hydrogens: Bool?
    var hidden: [JSON] = []
    var colors: [JSON] = []
    var measurements: [[Int]] = []
    var rotations: [JSON] = []
    var exportRequest: JSON = .null
    var closeRequested = false
    var selectionChanged = false
    // follow-up work for the engine
    var openURLs: [URL] = []
    var xtbOptions: [String]?

    init(doc: EngineDocument, xtbAvailable: Bool) {
        self.doc = doc
        model = doc.model
        currentDirectory = doc.cwd
        self.xtbAvailable = xtbAvailable
    }

    var molecule: Molecule { model.molecule }
    var selection: Set<Int> {
        get { model.selection.atoms }
        set { model.selection = AtomSelection(newValue.filter { $0 >= 0 && $0 < model.molecule.atoms.count }); selectionChanged = true }
    }

    func open(urls: [URL]) throws {
        for u in urls where !FileManager.default.fileExists(atPath: u.path) { throw CommandError("no such file: \(u.path)") }
        openURLs += urls
    }

    func save(to url: URL, format: MoleculeFileFormat?) throws {
        let fmt: MoleculeFileFormat
        do { fmt = try Engine.writableFormat(format?.rawValue, path: url.path) } catch let e as RPCError { throw CommandError(e.message) }
        do { try MolecularFileLoader.write(model.molecule, format: fmt).write(to: url, atomically: true, encoding: .utf8) } catch {
            throw CommandError("could not save \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    func close() { closeRequested = true }

    func setMolecule(_ m: Molecule, actionName: String) { model.perform(actionName) { $0 = m } }
    func setHydrogensVisible(_ visible: Bool) { hydrogens = visible }
    func setHidden(_ atoms: Set<Int>, hidden h: Bool) { hidden.append(obj(["atoms": atoms.sorted(), "hidden": h])) }
    func setStyle(_ s: DisplayStyleName) { style = s.rawValue }
    func setColor(_ c: CommandColor, atoms: Set<Int>) {
        colors.append(obj(["atoms": atoms.sorted(), "rgba": [c.r, c.g, c.b, c.a]]))
    }
    func setLabels(_ kind: LabelKind?) { labels = kind?.rawValue ?? "none" }
    func addMeasurement(atoms: [Int]) { measurements.append(atoms) }
    func rotate(axis: Axis, degrees: Double) { rotations.append(obj(["axis": axis.rawValue, "degrees": degrees])) }
    func fitView() { fit = true }
    func viewAlong(_ axis: Axis) { viewAxis = axis.rawValue }

    func addHydrogens() throws {
        model.perform("Add Hydrogens") { Editing.addHydrogens(&$0, atoms: nil) }
    }

    func cleanGeometry() throws {
        let m = model.molecule
        guard m.atoms.count > 1 else { throw CommandError("nothing to clean") }
        let r = Cleanup.minimize(m, frozen: [], maxSteps: 500).molecule
        model.perform("Clean Up") { $0 = r }
    }

    func runXTBOptimization(options: [String]) throws {
        guard !model.molecule.atoms.isEmpty else { throw CommandError("nothing to optimize") }
        guard xtbAvailable else { throw CommandError("xtb is not installed (conda install -c conda-forge xtb), or set its path in Settings") }
        xtbOptions = options
    }

    func showOrbital(_ which: OrbitalSelector) throws {
        // Orbital list in 1-based numbering (alpha / restricted set).
        var occupied: [Int] = []
        var all: [Int] = []
        if let wf = doc.wavefunction {
            all = Array(1...max(1, wf.alpha.orbitalCount))
            occupied = wf.alpha.occupiedCount > 0 ? Array(1...wf.alpha.occupiedCount) : []
        } else if let orbs = doc.result?.orbitals.filter({ $0.spin != .beta }), !orbs.isEmpty {
            all = orbs.map(\.index)
            occupied = orbs.filter(\.occupied).map(\.index)
        } else {
            throw CommandError("this document has no orbitals")
        }
        guard let homo = occupied.max() else { throw CommandError("no occupied orbitals") }
        let idx: Int
        let label: String
        switch which {
        case .homo(let k): idx = homo + k; label = k == 0 ? "HOMO" : "HOMO\(k > 0 ? "+" : "−")\(abs(k))"
        case .lumo(let k): idx = homo + 1 + k; label = k == 0 ? "LUMO" : "LUMO\(k > 0 ? "+" : "−")\(abs(k))"
        case .index(let n): idx = n; label = "MO \(n)"
        }
        guard all.contains(idx) else { throw CommandError("no orbital \(idx)") }
        orbital = obj(["index": idx - 1, "number": idx, "spin": "alpha", "label": label])
    }

    func showVibration(_ mode: Int?) throws {
        guard let m = mode, m > 0 else { vibration = obj(["mode": JSON.null]); return }
        let modes = doc.result?.normalModes ?? []
        guard modes.indices.contains(m - 1) else {
            throw CommandError("no vibrational mode \(m)\(modes.isEmpty ? "" : " (1–\(modes.count))")")
        }
        vibration = obj(["mode": m - 1, "frequency": modes[m - 1].frequency])
    }

    func exportImage(to url: URL, width: Int?, height: Int?) throws {
        exportRequest = obj(["path": url.path, "width": width, "height": height])
    }

    func undo() -> Bool { guard model.canUndo else { return false }; model.undo(); return true }
    func redo() -> Bool { guard model.canRedo else { return false }; model.redo(); return true }

    var viewChange: JSON {
        var o: [String: JSON] = [
            "style": style.json, "labels": labels.json, "fit": .bool(fit), "view": viewAxis.json,
            "orbital": orbital, "background": .null, "exportImage": exportRequest, "close": .bool(closeRequested),
        ]
        if let v = vibration { o["vibration"] = v }
        if let h = hydrogens { o["hydrogens"] = .bool(h) }
        if !hidden.isEmpty { o["hidden"] = .array(hidden) }
        if !colors.isEmpty { o["colors"] = .array(colors) }
        if !measurements.isEmpty { o["measurements"] = measurements.json }
        if !rotations.isEmpty { o["rotate"] = .array(rotations) }
        if selectionChanged { o["selection"] = model.selection.sorted.json }
        return .object(o)
    }

    var hasViewChange: Bool {
        style != nil || labels != nil || fit || viewAxis != nil || !orbital.isNull || vibration != nil || hydrogens != nil
            || !hidden.isEmpty || !colors.isEmpty || !measurements.isEmpty || !rotations.isEmpty || !exportRequest.isNull
            || closeRequested || selectionChanged
    }
}

extension Engine {
    /// `xtb opt` console options: gfn0|gfn1|gfn2|gfnff, crude…extreme, alpb=<solvent>|gbsa=<solvent>, chrg=N, uhf=N, cycles=N.
    static func xtbSettings(fromConsole options: [String], molecule: Molecule) throws -> XTBSettings {
        var s = XTBSettings(task: .optimize)
        for o in options.map({ $0.lowercased() }) {
            let parts = o.split(separator: "=", maxSplits: 1).map(String.init)
            if let m = MolCompute.XTBMethod(rawValue: o) { s.method = m; continue }
            if let l = XTBOptLevel(rawValue: o) { s.optLevel = l; continue }
            if o == "sp" || o == "singlepoint" { s.task = .singlePoint; continue }
            if o == "hess" || o == "hessian" { s.task = .hessian; continue }
            guard parts.count == 2 else { throw CommandError("unknown xtb option '\(o)'") }
            switch parts[0] {
            case "alpb": s.solvationModel = .alpb; s.solvent = parts[1]
            case "gbsa": s.solvationModel = .gbsa; s.solvent = parts[1]
            case "chrg", "charge": s.charge = Int(parts[1])
            case "uhf": s.uhf = Int(parts[1])
            case "cycles": s.maxCycles = Int(parts[1])
            case "threads": s.threads = Int(parts[1]) ?? s.threads
            default: throw CommandError("unknown xtb option '\(o)'")
            }
        }
        return s
    }

    func commandExecute(_ p: Params) async throws -> JSON {
        let id = try p.docId()
        let line = try p.string("line")
        let snap = try await store.get(id)
        let ctx = EngineCommandContext(doc: snap, xtbAvailable: programs.locate(.xtb) != nil)
        // The console runs on a large-stack worker (clean, addh, select on big molecules), so the request stays
        // cancellable; a cancelled line commits nothing.
        let results = try await Offload.run(AsyncCapture(Unchecked((ctx, line)))) { input, _ -> [CommandResult]? in
            let (ctx, line) = input.value.value
            return CommandExecutor(context: ctx).execute(line)
        }
        // Commit molecule/selection/cwd changes back (the console ran on a snapshot).
        let changed = ctx.model.changeCount != snap.model.changeCount
        let moleculeChanged = ctx.model.molecule != snap.molecule
        let cwd = ctx.currentDirectory
        let newModel = ctx.model
        let d = try await store.mutate(id) { doc -> EngineDocument in
            if changed { doc.model = newModel }
            doc.cwd = cwd
            return doc
        }
        var extra: [JSON] = []
        // Follow-up actions: open files as new documents, start xtb.
        var opened: [JSON] = []
        for u in ctx.openURLs {
            do { opened.append(try await openDocument(url: u, companions: true).summary()) } catch {
                extra.append(obj(["command": "open", "success": false,
                                  "messages": [obj(["level": "error", "text": "\(u.lastPathComponent): \(RPCError.from(error).message)"])]]))
            }
        }
        var jobIds: [String] = []
        if let opts = ctx.xtbOptions {
            do {
                let s = try Engine.xtbSettings(fromConsole: opts, molecule: d.molecule)
                let (jid, dir) = try await startXTB(docId: id, settings: s, directory: nil)
                jobIds.append(jid)
                extra.append(obj(["command": "xtb", "success": true,
                                  "messages": [obj(["level": "info", "text": "xtb job \(jid) started in \(dir.path)"])]]))
            } catch {
                let msg = (error as? CommandError)?.message ?? RPCError.from(error).message
                extra.append(obj(["command": "xtb", "success": false, "messages": [obj(["level": "error", "text": msg])]]))
            }
        }
        let rs: [JSON] = results.map { r in
            var o: [String: JSON] = [
                "command": .string(r.command), "success": .bool(r.success),
                "messages": .array(r.messages.map { obj(["level": $0.level.rawValue, "text": $0.text]) }),
            ]
            switch r.value {
            case .number(let v, let unit)?: o["value"] = obj(["number": v, "unit": unit])
            case .text(let t)?: o["value"] = obj(["text": t])
            case .atoms(let a)?: o["value"] = obj(["atoms": a.sorted()])
            case nil: break
            }
            return .object(o)
        }
        return obj([
            "results": JSON.array(rs + extra),
            "molecule": moleculeChanged ? JSONShapes.molecule(d.molecule) : JSON.null,
            "view": ctx.hasViewChange ? ctx.viewChange : JSON.null,
            "summary": d.summary(), "cwd": cwd.path,
            "opened": JSON.array(opened), "jobs": jobIds,
        ])
    }

    func commandComplete(_ p: Params) async throws -> JSON {
        let d = try await store.get(try p.docId())
        let line = try p.string("line")
        let utf16 = Array(line.utf16)
        let cursorU16 = max(0, min(p.optInt("cursor") ?? utf16.count, utf16.count))
        // Cursor arrives as a UTF-16 offset (JavaScript string index); convert to a Character offset.
        let prefix = String(decoding: utf16.prefix(cursorU16), as: UTF16.self)
        let cursorChars = prefix.count
        let completions = CommandCompleter.candidates(for: line, cursor: cursorChars, cwd: d.cwd, molecule: d.molecule)
        // The word being completed starts after the last separator before the cursor.
        var from = prefix.utf16.count
        for (k, u) in prefix.utf16.enumerated().reversed() {
            if u == 0x20 || u == 0x09 || u == 0x3B || u == 0x0A { from = k + 1; break }
            if k == 0 { from = 0 }
        }
        return obj(["completions": completions, "replaceFrom": from, "cwd": d.cwd.path])
    }
}
