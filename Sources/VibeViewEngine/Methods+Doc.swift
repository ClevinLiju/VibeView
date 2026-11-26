import Foundation
import MolCore
import MolIO
import MolBuild
import MolSIMD

func checkAtoms(_ idx: [Int], in m: Molecule, name: String = "atoms") throws {
    for i in idx where !m.atoms.indices.contains(i) {
        throw RPCError.badRequest("atom index \(i) in '\(name)' is out of range (0..<\(m.atoms.count))")
    }
}

extension Engine {
    // MARK: Opening / closing

    func docNew(_ p: Params) async throws -> JSON {
        var m = Molecule(title: p.optString("title") ?? "")
        if let mj = p["molecule"] { m = try JSONShapes.molecule(from: mj) }
        let id = await store.newId()
        let d = EngineDocument(id: id, molecule: m, title: p.optString("title") ?? (m.title.isEmpty ? "Untitled" : m.title))
        await store.insert(d)
        return d.summary()
    }

    /// Loads `url` into a new document (shared by doc.open, the console `open` command and session.load).
    func openDocument(url: URL, companions: Bool) async throws -> EngineDocument {
        guard FileManager.default.fileExists(atPath: url.path) else { throw RPCError.io("no such file: \(url.path)") }
        let file: LoadedMolecularFile
        do {
            file = companions ? try MolecularFileLoader.loadWithCompanions(url: url).file : try MolecularFileLoader.load(url: url)
        } catch let e as MolIOError {
            // Content sniffing can pick the wrong reader (an ORCA input whose first line is a "# comment" looks
            // like a Gaussian route). When it fails, retry with the format the extension names.
            if case .parse = e, let ext = MoleculeFileFormat.format(forExtension: url.pathExtension),
               let text = try? String(contentsOf: url, encoding: .utf8),
               let f = try? MolecularFileLoader.load(text: text, format: ext, fileName: url.lastPathComponent) {
                Log.info("\(url.lastPathComponent): sniffed format failed (\(e.description)); read as \(ext.rawValue)")
                file = f
            } else {
                if case .unsupported = e { throw RPCError.parse(e.description) }
                throw RPCError.from(e)
            }
        }
        try Task.checkCancellation()
        let id = await store.newId()
        var d = Preparation.document(id: id, file: file, path: url.path, fileName: url.lastPathComponent)
        await store.insert(d)
        // Gaussian log with a .chk but no up-to-date .fchk: convert in the background (event doc.wavefunction).
        if companions, file.format == .gaussianOutput {
            d = await scheduleFormchkIfNeeded(d)
        }
        Log.info("opened \(url.lastPathComponent) as \(id) (\(file.format.rawValue), \(d.molecule.atoms.count) atoms)")
        return d
    }

    func docOpen(_ p: Params) async throws -> JSON {
        let path = try p.string("path")
        return try await openDocument(url: URL(fileURLWithPath: path), companions: p.bool("companions", default: true)).summary()
    }

    func docOpenText(_ p: Params) async throws -> JSON {
        let text = try p.string("text")
        var format: MoleculeFileFormat?
        if let f = p.optString("format") {
            guard let ff = MoleculeFileFormat(rawValue: f) ?? MoleculeFileFormat.format(forExtension: f) else {
                throw RPCError.badRequest("unknown format '\(f)'")
            }
            format = ff
        }
        let fileName = p.optString("fileName")
        let file: LoadedMolecularFile
        do { file = try MolecularFileLoader.load(text: text, format: format, fileName: fileName) } catch let e as MolIOError {
            // Same fallback as doc.open: the sniffed reader failed, so try the format the file name's extension names.
            if case .parse = e, format == nil, let n = fileName,
               let ext = MoleculeFileFormat.format(forExtension: (n as NSString).pathExtension),
               let f = try? MolecularFileLoader.load(text: text, format: ext, fileName: n) {
                file = f
            } else {
                if case .unsupported = e { throw RPCError.parse(e.description) }
                throw RPCError.from(e)
            }
        }
        let id = await store.newId()
        let d = Preparation.document(id: id, file: file, path: nil, fileName: fileName)
        await store.insert(d)
        return d.summary()
    }

    func docClose(_ p: Params) async throws -> JSON {
        let id = try p.docId()
        try await store.remove(id)
        await jobs.cancel(kind: "formchk", docId: id)
        return [:]
    }

    func docList() async -> JSON {
        ["docs": .array(await store.all().map { $0.summary() })]
    }

    // MARK: Saving

    static func writableFormat(_ name: String?, path: String?) throws -> MoleculeFileFormat {
        var f: MoleculeFileFormat?
        if let n = name { f = MoleculeFileFormat(rawValue: n) ?? MoleculeFileFormat.format(forExtension: n) }
        else if let p = path { f = MoleculeFileFormat.format(forExtension: (p as NSString).pathExtension) }
        guard let fmt = f else {
            throw RPCError.badRequest("unknown format \(name ?? "(from extension)"); writable: " + MolecularFileLoader.writableFormats.map(\.rawValue).joined(separator: ", "))
        }
        guard MolecularFileLoader.writableFormats.contains(fmt) else {
            throw RPCError.badRequest("\(fmt.displayName) is read-only; save as one of " + MolecularFileLoader.writableFormats.map(\.rawValue).joined(separator: ", "))
        }
        return fmt
    }

    func docSave(_ p: Params) async throws -> JSON {
        let id = try p.docId()
        let path = try p.string("path")
        let fmt = try Engine.writableFormat(p.optString("format"), path: path)
        let d = try await store.get(id)
        let text = try MolecularFileLoader.write(d.molecule, format: fmt)
        do { try text.write(toFile: path, atomically: true, encoding: .utf8) } catch {
            throw RPCError.io("could not write \(path): \(error.localizedDescription)")
        }
        try await store.mutate(id) { doc in
            doc.model.markSaved()
            if !(doc.format?.isCalculationOutput ?? false) || doc.path == nil {
                doc.path = path; doc.format = fmt
                doc.displayTitle = (path as NSString).lastPathComponent
            }
        }
        return ["path": .string(path), "format": .string(fmt.rawValue)]
    }

    func docExport(_ p: Params) async throws -> JSON {
        let d = try await store.get(try p.docId())
        let fmt = try Engine.writableFormat(try p.string("format"), path: nil)
        return ["text": .string(try MolecularFileLoader.write(d.molecule, format: fmt)), "format": .string(fmt.rawValue)]
    }

    // MARK: Reading

    func docMolecule(_ p: Params) async throws -> JSON {
        let d = try await store.get(try p.docId())
        if let k = p.optInt("frame") {
            if d.frames.isEmpty, k == 0 { return JSONShapes.molecule(d.molecule) }
            guard let f = d.frame(k) else { throw RPCError.notFound("no frame \(k) (0..<\(max(d.frames.count, 1)))") }
            return JSONShapes.molecule(f)
        }
        return JSONShapes.molecule(d.molecule)
    }

    func docUndo(_ p: Params, redo: Bool) async throws -> JSON {
        let d = try await store.mutate(try p.docId()) { doc -> EngineDocument in
            if redo { doc.model.redo() } else { doc.model.undo() }
            return doc
        }
        return ["summary": d.summary(), "molecule": JSONShapes.molecule(d.molecule)]
    }

    func docSetSelection(_ p: Params) async throws -> JSON {
        let atoms = try p.ints("atoms")
        let d = try await store.mutate(try p.docId()) { doc -> EngineDocument in
            try checkAtoms(atoms, in: doc.molecule)
            doc.model.selection = AtomSelection(atoms)
            return doc
        }
        return ["selection": d.model.selection.sorted.json]
    }

    func docResult(_ p: Params) async throws -> JSON {
        let d = try await store.get(try p.docId())
        guard let r = d.result else {
            return obj(["energies": [Double](), "normalTermination": false, "dipole": JSON.null, "routeSection": "",
                        "info": obj(["levelOfTheory": JSON.null, "rows": [JSON]()]), "thermo": JSON.null,
                        "charges": JSON.object([:]), "hasResult": false])
        }
        var thermo: JSON = .null
        if let t = r.thermochemistry {
            thermo = obj(["temperature": t.temperature, "pressure": t.pressure, "electronicEnergy": t.electronicEnergy,
                          "zeroPointEnergy": t.zeroPointEnergy, "thermalEnergyCorrection": t.thermalEnergyCorrection,
                          "enthalpyCorrection": t.enthalpyCorrection, "gibbsCorrection": t.gibbsCorrection,
                          "totalEnthalpy": t.totalEnthalpy, "totalGibbs": t.totalGibbs, "entropy": t.entropy])
        }
        let x = r.extras
        return obj([
            "energies": r.energies, "normalTermination": r.normalTermination,
            "dipole": r.dipole.map { JSONShapes.vec3($0) } ?? JSON.null,
            "dipoleMagnitude": r.dipole.map { ($0.x * $0.x + $0.y * $0.y + $0.z * $0.z).squareRoot() },
            "routeSection": r.routeSection,
            "info": obj(["levelOfTheory": x?.info?.levelOfTheory,
                         "rows": JSON.array(InfoRows.rows(r).map { obj(["label": $0.0, "value": $0.1]) })]),
            "thermo": thermo,
            "charges": JSON.object(SchemeNames.normalized(r.chargesByScheme).mapValues { $0.json }),
            "spinDensities": JSON.object(SchemeNames.normalized(x?.spinDensities ?? [:]).mapValues { $0.json }),
            "program": x?.program, "programVersion": x?.programVersion, "finalEnergy": x?.finalEnergy,
            "homoLumoGapEV": x?.homoLumoGapEV, "optimizationConverged": x?.optimizationConverged,
            "messages": x?.messages ?? [], "hasResult": true,
            "excitedStates": JSON.array(r.excitedStates.enumerated().map { k, s in
                obj(["index": k, "energyEV": s.energyEV, "wavelengthNM": s.wavelengthNM, "oscillatorStrength": s.oscillatorStrength,
                     "multiplicity": s.multiplicity, "symmetry": s.symmetry])
            }),
        ])
    }

    func docFrames(_ p: Params) async throws -> JSON {
        let d = try await store.get(try p.docId())
        let count = max(d.frames.count, 1)
        let energies = d.result?.energies ?? []
        var profile: JSON = .null
        if energies.count >= 2 {
            let e = energies.count > count && count > 1 ? Array(energies.suffix(count)) : energies
            let first = e[0]
            profile = obj(["coordinates": (0..<e.count).map(Double.init), "relativeKcal": e.map { ($0 - first) * 627.509474 },
                           "xLabel": "Step"])
        }
        // Per-frame data for the Trajectory player: energies and optimizer convergence aligned to the frames.
        let fe = ExportWriter.frameEnergies(d)
        var steps: JSON = .null
        if let si = d.result?.extras?.stepInfo, !si.isEmpty, si.contains(where: { !$0.isEmpty }) {
            let off = si.count - count
            steps = .array((0..<count).map { k -> JSON in
                guard si.indices.contains(k + off) else { return .null }
                let s = si[k + off]
                return s.isEmpty ? .null : obj(["maxForce": s.maxForce, "rmsForce": s.rmsForce, "maxStep": s.maxStep,
                                                "rmsStep": s.rmsStep, "energyChange": s.energyChange,
                                                "gradientNorm": s.gradientNorm, "converged": s.converged])
            })
        }
        // xtbopt.log / xtbopt.xyz opened on their own: the comment lines carry "gnorm:".
        if steps == .null, d.format == .xyz, d.frames.count > 1 {
            let g = d.frames.map { XYZFormat.commentGradientNorm($0.title) }
            if g.contains(where: { $0 != nil }) { steps = .array(g.map { v in v.map { obj(["gradientNorm": $0]) } ?? .null }) }
        }
        let converged = d.result?.extras?.optimizationConverged
        let optimization = converged != nil || steps != .null
        let kind = d.format == .pdb ? "models" : optimization ? "optimization" : d.result != nil ? "steps" : "trajectory"
        return obj(["count": count, "energies": energies, "profile": profile, "frameEnergies": fe, "steps": steps,
                    "converged": converged, "kind": kind, "home": d.format == .pdb ? 0 : count - 1])
    }

    /// Every frame's coordinates in one reply, for smooth trajectory playback:
    /// `{count, atomCounts: [n], positionsB64: Float32 x,y,z of all frames back to back (Å),
    ///   sameTopology, sameElements: [bool], bondChanges: [int]}` — `sameTopology[k]`: frame k has the elements and bonds
    /// of frame k-1 (bond-perception noise in large structures aside; always false
    /// for k = 0), so the player may interpolate between them and keep the drawn bonds.
    func docFrameCoordinates(_ p: Params) async throws -> JSON {
        let d = try await store.get(try p.docId())
        let frames = d.frames.isEmpty ? [d.molecule] : d.frames
        let total = frames.reduce(0) { $0 + $1.atoms.count }
        guard total <= 50_000_000 else { throw RPCError.badRequest("trajectory too large to send at once (\(total) atom positions)") }
        let result = try await Offload.run(AsyncCapture(frames)) { input, _ -> JSON? in
            let frames = input.value
            var xyz = [Float]()
            xyz.reserveCapacity(total * 3)
            var counts: [Int] = [], same: [Bool] = [], sameElements: [Bool] = [], bondChanges: [Int] = []
            var prevBonds: Set<Int64>? = nil
            var prevZ: [Int] = []
            for (k, f) in frames.enumerated() {
                for a in f.atoms { xyz.append(Float(a.position.x)); xyz.append(Float(a.position.y)); xyz.append(Float(a.position.z)) }
                counts.append(f.atoms.count)
                let z = f.atoms.map(\.atomicNumber)
                // Bonds as the viewer gets them from doc.molecule {frame} (Preparation.prepared).
                let prepared = f.atoms.count > 1 && f.atoms.count < 200_000 ? Preparation.prepared(f, perceiveOrders: false) : f
                var bonds = Set<Int64>()
                bonds.reserveCapacity(prepared.bonds.count)
                for b in prepared.bonds { bonds.insert(Int64(min(b.a, b.b)) << 32 | Int64(max(b.a, b.b))) }
                // Distance-based bond perception flickers by a few bonds in large moving structures (PCA modes, MD):
                // ignore up to 1% changed bonds from 500 atoms up; any change in a smaller molecule is a real rebond.
                var changes = 0
                if k > 0, z == prevZ, let pb = prevBonds { changes = bonds.symmetricDifference(pb).count }
                sameElements.append(k > 0 && z == prevZ)
                bondChanges.append(changes)
                same.append(k > 0 && z == prevZ && (changes == 0 || (f.atoms.count >= 500 && changes * 100 <= max(bonds.count, 1))))
                prevBonds = bonds; prevZ = z
            }
            return obj(["count": frames.count, "atomCounts": counts, "positionsB64": Binary.float32(xyz), "sameTopology": same,
                        "sameElements": sameElements, "bondChanges": bondChanges])
        }
        return result
    }

    // MARK: Editing

    func editApply(_ p: Params) async throws -> JSON {
        let id = try p.docId()
        let op = try p.object("op")
        let snapshot = try await store.get(id)
        // Runs on a large-stack worker so a long clean-up on a big molecule stays cancellable.
        let (name, newMol) = try await Offload.run(AsyncCapture((op, snapshot.molecule))) { input, _ -> Result<(String, Molecule), Error>? in
            let (op, m) = input.value
            return Result { try EditOps.apply(op, to: m) }
        }.get()
        try Task.checkCancellation()
        let d = try await store.commit(id, name: name, molecule: newMol)
        return ["summary": d.summary(), "molecule": JSONShapes.molecule(d.molecule)]
    }

    func buildFragments() -> JSON {
        let frags: [JSON] = FragmentLibrary.all.map {
            obj(["id": $0.id, "name": $0.name, "category": $0.category.rawValue, "categoryTitle": $0.category.title,
                 "anchor": $0.anchor, "leaving": $0.leaving, "molecule": JSONShapes.molecule($0.molecule)])
        }
        let cats: [JSON] = FragmentCategory.allCases.map { obj(["id": $0.rawValue, "title": $0.title]) }
        return ["fragments": .array(frags), "categories": .array(cats)]
    }
}

/// `EditOp` implementations (MolBuild placement rules, MolCore geometry edits). Pure: molecule in, molecule out.
enum EditOps {
    static func apply(_ op: Params, to m0: Molecule) throws -> (String, Molecule) {
        var m = m0
        let type = try op.string("type")
        switch type {
        case "addAtom":
            let z = try op.int("z")
            guard z >= 0, z < Elements.all.count else { throw RPCError.badRequest("invalid atomic number \(z)") }
            let pos = try op.vec3("pos")
            if op.bool("addHydrogens", default: true) {
                m = Builder.placeElement(z, in: m, at: pos, addHydrogens: true)
            } else {
                _ = m.addAtom(atomicNumber: z, position: pos)
            }
            return ("Add Atom", m)
        case "deleteAtoms":
            let atoms = try op.ints("atoms")
            try checkAtoms(atoms, in: m)
            Editing.deleteAtoms(&m, Set(atoms))
            return ("Delete Atoms", m)
        case "setElement":
            let a = try op.int("atom"), z = try op.int("z")
            try checkAtoms([a], in: m, name: "atom")
            guard z >= 0, z < Elements.all.count else { throw RPCError.badRequest("invalid atomic number \(z)") }
            Editing.setElement(&m, atom: a, to: z, adjustHydrogens: op.bool("adjustHydrogens", default: true))
            return ("Change Element", m)
        case "addBond":
            let a = try op.int("a"), b = try op.int("b")
            try checkAtoms([a, b], in: m)
            return ("Add Bond", try Editing.connect(m, a, b, order: try JSONShapes.bondOrder(op["order"])))
        case "deleteBond":
            let a = try op.int("a"), b = try op.int("b")
            try checkAtoms([a, b], in: m)
            guard m.areBonded(a, b) else { throw RPCError.badRequest("atoms \(a) and \(b) are not bonded") }
            return ("Delete Bond", try Editing.disconnect(m, a, b))
        case "setBondOrder":
            let a = try op.int("a"), b = try op.int("b")
            try checkAtoms([a, b], in: m)
            guard m.areBonded(a, b) else { throw RPCError.badRequest("atoms \(a) and \(b) are not bonded") }
            Editing.setBondOrder(&m, a, b, try JSONShapes.bondOrder(op["order"]), adjustHydrogens: op.bool("adjustHydrogens", default: true))
            return ("Change Bond Order", m)
        case "placeFragment", "placeElement":
            let item: BuildItem
            if type == "placeFragment" {
                let fid = try op.string("fragmentId")
                guard FragmentLibrary.fragment(id: fid) != nil else { throw RPCError.notFound("unknown fragment '\(fid)'") }
                item = .fragment(fid)
            } else {
                let z = try op.int("z")
                guard z > 0, z < Elements.all.count else { throw RPCError.badRequest("invalid atomic number \(z)") }
                item = .element(z)
            }
            let target: BuildTarget
            if let at = op.optInt("at") {
                try checkAtoms([at], in: m, name: "at")
                target = .atom(at)
            } else {
                target = .empty(try op.optVec3("pos") ?? (m.atoms.isEmpty ? Vec3(0, 0, 0) : m.centroid + Vec3(4, 0, 0)))
            }
            return (type == "placeFragment" ? "Place Fragment" : "Place Atom", try Builder.click(item, on: target, in: m))
        case "growAtom":
            let from = try op.int("from"), z = try op.int("z")
            try checkAtoms([from], in: m, name: "from")
            guard z > 0, z < Elements.all.count else { throw RPCError.badRequest("invalid atomic number \(z)") }
            guard let r = Builder.bondElement(z, to: m, atom: from, addHydrogens: op.bool("addHydrogens", default: true)) else {
                throw RPCError.badRequest("cannot grow a new atom from atom \(from) (no free valence)")
            }
            return ("Grow Atom", r)
        case "setDistance":
            let a = try op.ints("atoms"), v = try op.double("value")
            guard a.count == 2 else { throw RPCError.badRequest("setDistance needs 2 atoms") }
            try checkAtoms(a, in: m)
            guard Set(a).count == a.count else { throw RPCError.badRequest("setDistance needs distinct atoms") }
            guard v > 0 else { throw RPCError.badRequest("distance must be positive") }
            GeometryEdit.setDistanceMovingSmaller(&m, a[0], a[1], to: v)
            return ("Set Distance", m)
        case "setAngle":
            let a = try op.ints("atoms"), v = try op.double("value")
            guard a.count == 3 else { throw RPCError.badRequest("setAngle needs 3 atoms") }
            try checkAtoms(a, in: m)
            guard Set(a).count == a.count else { throw RPCError.badRequest("setAngle needs distinct atoms") }
            GeometryEdit.setAngleMovingSmaller(&m, a[0], a[1], a[2], to: v)
            return ("Set Angle", m)
        case "setDihedral":
            let a = try op.ints("atoms"), v = try op.double("value")
            guard a.count == 4 else { throw RPCError.badRequest("setDihedral needs 4 atoms") }
            try checkAtoms(a, in: m)
            guard Set(a).count == a.count else { throw RPCError.badRequest("setDihedral needs distinct atoms") }
            GeometryEdit.setDihedralMovingSmaller(&m, a[0], a[1], a[2], a[3], to: v)
            return ("Set Dihedral", m)
        case "moveAtoms":
            let a = try op.ints("atoms")
            try checkAtoms(a, in: m)
            m.translate(atoms: a, by: try op.vec3("delta"))
            return ("Move Atoms", m)
        case "rotateAtoms":
            let a = try op.ints("atoms")
            try checkAtoms(a, in: m)
            let axis = try op.vec3("axis")
            guard (axis.x * axis.x + axis.y * axis.y + axis.z * axis.z) > 1e-20 else { throw RPCError.badRequest("rotation axis is zero") }
            let pivot = try op.optVec3("axisPoint") ?? Geometry.centroid(a.map { m.atoms[$0].position })
            m.rotate(atoms: a, about: pivot, axis: axis, degrees: try op.double("degrees"))
            return ("Rotate Atoms", m)
        case "setPositions":
            guard let arr = op["positions"]?.arrayValue, arr.count == m.atoms.count else {
                throw RPCError.badRequest("'positions' must have one [x,y,z] per atom (\(m.atoms.count))")
            }
            for (i, pj) in arr.enumerated() { m.atoms[i].position = try JSONShapes.vec3(pj, name: "positions[\(i)]") }
            return ("Move Atoms", m)
        case "addHydrogens":
            let atoms = try op.optInts("atoms")
            if let atoms { try checkAtoms(atoms, in: m) }
            Editing.addHydrogens(&m, atoms: atoms)
            return ("Add Hydrogens", m)
        case "removeHydrogens":
            let atoms = try op.optInts("atoms")
            if let atoms { try checkAtoms(atoms, in: m) }
            Editing.removeHydrogens(&m, atoms: atoms)
            return ("Remove Hydrogens", m)
        case "cleanUp":
            let steps = max(1, min(op.optInt("steps") ?? 200, 20_000))
            let frozen = Set(try op.optInts("frozen") ?? [])
            try checkAtoms(Array(frozen), in: m, name: "frozen")
            guard m.atoms.count > 1 else { return ("Clean Up", m) }
            return ("Clean Up", Cleanup.minimize(m, frozen: frozen, maxSteps: steps).molecule)
        case "symmetrize":
            return ("Symmetrize", Symmetry.symmetrize(m, tolerance: op.optDouble("tolerance") ?? 0.1))
        case "setCharge":
            if let c = op.optInt("charge") { m.charge = c }
            if let s = op.optInt("multiplicity") {
                guard s >= 1 else { throw RPCError.badRequest("multiplicity must be >= 1") }
                m.multiplicity = s
            }
            return ("Set Charge", m)
        case "setTitle":
            m.title = try op.string("title")
            return ("Rename", m)
        case "replaceMolecule":
            guard let mj = op["molecule"] else { throw RPCError.badRequest("missing 'molecule'") }
            var r = try JSONShapes.molecule(from: mj)
            if op.bool("perceiveBonds", default: false) { r = Preparation.prepared(r) }
            return (op.optString("name") ?? "Replace Structure", r)
        default:
            if let r = try applyGroupOp(type, op, to: m) { return r }   // Methods+Groups.swift
            throw RPCError.badRequest("unknown edit op '\(type)'")
        }
    }
}

/// Labelled calculation-setup rows (same wording as the macOS info card).
enum InfoRows {
    static func rows(_ result: CalculationResult) -> [(String, String)] {
        guard let i = result.extras?.info else { return [] }
        var r: [(String, String)] = []
        func add(_ k: String, _ v: String?) { if let v, !v.isEmpty { r.append((k, v)) } }
        if let p = result.extras?.program {
            let name = ["orca": "ORCA", "gaussian": "Gaussian", "qchem": "Q-Chem", "xtb": "xtb"][p] ?? p
            add("Program", [name, result.extras?.programVersion].compactMap { $0 }.joined(separator: " "))
        }
        add("Job", i.jobTypes.isEmpty ? nil : i.jobTypes.joined(separator: " → "))
        if let m = i.method {
            var s = m
            if i.methodFamily == "DFT", let x = i.exchangeFunctional {
                s += " (" + [x, i.correlationFunctional].compactMap { $0 }.joined(separator: " + ")
                if let h = i.exactExchange { s += String(format: ", %.0f%% HF exchange", h * 100) }
                s += ")"
            } else if let fam = i.methodFamily, fam != "HF", fam.lowercased() != m.lowercased() {
                s += " (\(fam))"
            }
            add("Method", s)
        }
        add("Basis set", i.methodFamily == "Composite" ? "built into \(i.method ?? "method")" : i.basisSet)
        add("Auxiliary basis", i.auxiliaryBasis)
        add("Dispersion", i.dispersion)
        add("Solvation", i.solvationLabel)
        add("Reference", i.reference)
        if let c = i.charge, let m = i.multiplicity {
            let names = ["singlet", "doublet", "triplet", "quartet", "quintet", "sextet"]
            add("Charge / mult.", "\(c) / \(m) (\(names.indices.contains(m - 1) ? names[m - 1] : "2S+1 = \(m)"))")
        }
        add("Electrons", i.electrons.map(String.init))
        add("Basis functions", i.basisFunctions.map(String.init))
        add("Approximations", i.approximations.isEmpty ? nil : i.approximations.joined(separator: ", "))
        add("Grid", i.integrationGrid)
        var res: [String] = []
        if let c = i.cores { res.append(c == 1 ? "1 core" : "\(c) cores") }
        if let mm = i.memoryPerCoreMB { res.append("\(mm) MB/core") }
        add("Resources", res.isEmpty ? nil : res.joined(separator: ", "))
        if let s = i.wallTimeSeconds {
            if s < 60 { add("Wall time", String(format: "%.1f s", s)) } else {
                let t = Int(s.rounded())
                add("Wall time", t >= 3600 ? "\(t / 3600) h \((t % 3600) / 60) min" : "\(t / 60) min \(t % 60) s")
            }
        }
        return r
    }
}

/// Population-analysis scheme names, one spelling per scheme. Parsers differ ("mulliken" from Q-Chem, "Mulliken"
/// from ORCA and MolCore's fallback), which would otherwise send the same charges twice under two keys.
enum SchemeNames {
    static let canonical: [String: String] = [
        "mulliken": "Mulliken", "loewdin": "Loewdin", "lowdin": "Loewdin", "löwdin": "Loewdin",
        "hirshfeld": "Hirshfeld", "chelpg": "CHELPG", "npa": "NPA", "nbo": "NPA", "esp": "ESP", "merz-kollman": "ESP",
        "cm5": "CM5", "xtb": "xtb",
    ]

    static func normalized(_ d: [String: [Double]]) -> [String: [Double]] {
        var out: [String: [Double]] = [:]
        // Sorted so the result doesn't depend on dictionary order; an exact canonical spelling wins a collision.
        for k in d.keys.sorted() {
            let name = canonical[k.lowercased()] ?? k
            if out[name] == nil || k == name { out[name] = d[k] }
        }
        return out
    }
}
