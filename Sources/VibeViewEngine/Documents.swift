import Foundation
import MolCore
import MolIO
import MolAnalysis

/// One open document: the editable molecule (with undo/redo) plus whatever the source file carried.
struct EngineDocument {
    let id: String
    var model: MoleculeDocumentModel
    /// Geometry frames from the file (opt/scan/IRC steps, trajectory frames). Prepared lazily by `frame(_:)`.
    var frames: [Molecule]
    var result: CalculationResult?
    var wavefunction: Wavefunction?
    /// Named volume grids (cube files and companion cubes).
    var volumes: [(name: String, grid: VolumeGrid)]
    var path: String?
    var format: MoleculeFileFormat?
    var program: QCProgram?
    var companions: [CompanionFile]
    /// One orbital-surface service per wavefunction (caches evaluated grids).
    var surfaces: OrbitalSurfaceService?
    /// Console working directory (`cd`).
    var cwd: URL
    var displayTitle: String
    /// A background formchk conversion is running for this document's `.chk` companion (see Formchk.swift).
    var formchkPending = false

    var molecule: Molecule { model.molecule }

    init(id: String, molecule: Molecule, title: String) {
        self.id = id
        model = MoleculeDocumentModel(molecule: molecule)
        frames = []
        volumes = []
        companions = []
        cwd = FileManager.default.homeDirectoryForCurrentUser
        displayTitle = title
    }

    /// Frame `k` with connectivity (same topology rules as the macOS app's IOBridge).
    func frame(_ k: Int) -> Molecule? {
        guard frames.indices.contains(k) else { return nil }
        return Preparation.prepared(frames[k], perceiveOrders: false)
    }

    var orbitalCount: Int {
        if let wf = wavefunction { return wf.alpha.orbitalCount }
        return result?.orbitals.filter { $0.spin != .beta }.count ?? 0
    }

    /// The geometry the result's modes refer to (the final structure when its atom count matches).
    var resultGeometry: Molecule {
        if let f = result?.steps.last, f.atoms.count == molecule.atoms.count { return Preparation.prepared(f, perceiveOrders: false) }
        return molecule
    }

    func summary() -> JSON {
        let m = model.molecule
        return obj([
            "docId": id, "title": displayTitle, "path": path, "format": format?.rawValue, "program": program?.rawValue,
            "formula": m.atoms.isEmpty ? "" : m.formula, "atomCount": m.atoms.count, "bondCount": m.bonds.count,
            "frameCount": max(frames.count, 1),
            "canUndo": model.canUndo, "canRedo": model.canRedo, "undoName": model.undoName, "redoName": model.redoName,
            "isDirty": model.isDirty,
            "charge": m.charge, "multiplicity": m.multiplicity,
            "hasWavefunction": wavefunction != nil, "isUnrestricted": wavefunction?.isUnrestricted ?? false,
            "volumeNames": volumes.map { $0.name },
            "modeCount": result?.normalModes.count ?? 0, "orbitalCount": orbitalCount,
            "excitedStateCount": result?.excitedStates.count ?? 0,
            "hasResult": result != nil, "formchkPending": formchkPending,
            "levelOfTheory": result?.extras?.info?.levelOfTheory,
            "selection": model.selection.sorted,
            "companions": JSON.array(companions.map {
                obj(["fileName": $0.fileName, "role": $0.role.rawValue, "used": $0.used, "note": $0.note, "path": $0.url.path])
            }),
        ])
    }
}

/// Molecule preparation shared with the macOS app (IOBridge.prepared): make sure connectivity exists.
enum Preparation {
    static func prepared(_ m: Molecule, perceiveOrders: Bool = true) -> Molecule {
        var m = m
        m.renumberAtomIDs()
        guard m.atoms.count > 1 && m.atoms.count < 200_000 else { return m }
        if m.bonds.isEmpty {
            m.perceiveBonds()
            if perceiveOrders && m.atoms.count < 2000 { m.perceiveBondOrders() }
        } else if hasUnbondedHeavyAtoms(m) {
            var stated = Set(m.bonds.map { Int64($0.a) << 32 | Int64($0.b) })
            for b in m.perceivedBonds() where stated.insert(Int64(b.a) << 32 | Int64(b.b)).inserted {
                m.bonds.append(b)
            }
        }
        return m
    }

    static func hasUnbondedHeavyAtoms(_ m: Molecule) -> Bool {
        var bonded = [Bool](repeating: false, count: m.atoms.count)
        for b in m.bonds where b.a < bonded.count && b.b < bonded.count { bonded[b.a] = true; bonded[b.b] = true }
        return m.atoms.indices.contains { !bonded[$0] && m.atoms[$0].atomicNumber > 1 }
    }

    /// Builds a document from a loaded file (no store access; pure).
    /// Formats whose bonds come with orders written in the file (CONECT multiplicity, MDL/CML bond types, Gaussian
    /// connectivity). Their bonds are kept as written.
    static let formatsWithBondOrders: Set<MoleculeFileFormat> = [.pdb, .mol, .sdf, .cml, .gaussianInput]

    static func document(id: String, file: LoadedMolecularFile, path: String?, fileName: String?) -> EngineDocument {
        // PDB models (NMR ensembles) open on the first model, like RCSB/Mol*; the others stay available as frames.
        var shown = prepared(file.format == .pdb ? (file.molecules.first ?? file.molecule) : file.molecule)
        // Calculation outputs (ORCA, Q-Chem, …) arrive with connectivity perceived by the parser but every bond
        // single, so `prepared` would skip order perception. Perceive orders for formats that never state them.
        if !formatsWithBondOrders.contains(file.format), shown.atoms.count > 1, shown.atoms.count < 2000,
           !shown.bonds.isEmpty, shown.bonds.allSatisfy({ $0.order == .single }) {
            shown.perceiveBondOrders()
        }
        var title = fileName.map { ($0 as NSString).lastPathComponent } ?? ""
        if title.isEmpty { title = shown.title.isEmpty ? "Untitled" : shown.title }
        var d = EngineDocument(id: id, molecule: shown, title: title)
        d.frames = file.molecules.count > 1 ? file.molecules : []
        if let r = file.result {
            if d.frames.isEmpty, r.steps.count > 1 { d.frames = r.steps }
            d.result = r
        }
        d.wavefunction = file.wavefunction
        if let wf = file.wavefunction { d.surfaces = OrbitalSurfaceService(wavefunction: wf) }
        var vols: [(String, VolumeGrid)] = []
        if let rv = file.result?.volumes, !rv.isEmpty {
            vols = rv.keys.sorted().map { ($0, rv[$0]!) }
        } else {
            for (k, g) in file.volumes.enumerated() { vols.append((file.volumes.count == 1 ? "cube" : "cube \(k + 1)", g)) }
        }
        d.volumes = vols.map { (name: $0.0, grid: $0.1) }
        d.path = path
        d.format = file.format
        d.program = file.program
        d.companions = file.companions
        if let p = path { d.cwd = URL(fileURLWithPath: p).deletingLastPathComponent() }
        return d
    }
}

/// All open documents. Heavy work is done by callers on snapshots; the actor only stores and commits.
actor DocumentStore {
    private var docs: [String: EngineDocument] = [:]
    private var order: [String] = []
    private var next = 1

    func newId() -> String {
        defer { next += 1 }
        return "d\(next)"
    }

    func insert(_ d: EngineDocument) {
        docs[d.id] = d
        order.append(d.id)
    }

    func get(_ id: String) throws -> EngineDocument {
        guard let d = docs[id] else { throw RPCError.notFound("no document '\(id)'") }
        return d
    }

    func all() -> [EngineDocument] { order.compactMap { docs[$0] } }

    func remove(_ id: String) throws {
        guard docs.removeValue(forKey: id) != nil else { throw RPCError.notFound("no document '\(id)'") }
        order.removeAll { $0 == id }
    }

    /// Mutates a document in place (synchronously, inside the actor).
    func mutate<T>(_ id: String, _ body: (inout EngineDocument) throws -> T) throws -> T {
        guard var d = docs[id] else { throw RPCError.notFound("no document '\(id)'") }
        let r = try body(&d)
        docs[id] = d
        return r
    }

    func summary(_ id: String) throws -> JSON { try get(id).summary() }

    /// Commits a molecule computed outside the actor as one undo step.
    func commit(_ id: String, name: String, molecule m: Molecule) throws -> EngineDocument {
        try mutate(id) { d in
            d.model.perform(name) { $0 = m }
            return d
        }
    }
}

/// Per-document FIFO ordering. `handleLine` draws a ticket synchronously, in arrival order, for every request
/// that reads or changes one document's editable state (edit.apply, command.execute, undo/redo, …). The request
/// task waits for its turn, so edits sent back to back apply in the order sent and never overwrite each other
/// (they compute on a snapshot and commit). Different documents don't block each other.
final class DocumentQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var next: [String: Int] = [:]
    private var serving: [String: Int] = [:]
    private var waiters: [String: [Int: CheckedContinuation<Void, Never>]] = [:]

    /// Methods that are ordered per document.
    static let orderedMethods: Set<String> = [
        "doc.close", "doc.save", "doc.export", "doc.molecule", "doc.summary", "doc.undo", "doc.redo",
        "doc.setSelection", "edit.apply", "command.execute",
        "doc.exportAs",
        "zmatrix.get", "zmatrix.edit", "zmatrix.apply", "zmatrix.addAtom",
    ]

    func ticket(_ id: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        let t = next[id, default: 0]
        next[id] = t + 1
        return t
    }

    func wait(_ id: String, _ t: Int) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if serving[id, default: 0] == t { lock.unlock(); c.resume(); return }
            waiters[id, default: [:]][t] = c
            lock.unlock()
        }
    }

    /// Must be called exactly once per ticket, after the request finished (or failed).
    func done(_ id: String) {
        lock.lock()
        let s = serving[id, default: 0] + 1
        serving[id] = s
        let c = waiters[id]?.removeValue(forKey: s)
        if waiters[id]?.isEmpty == true { waiters[id] = nil }
        lock.unlock()
        c?.resume()
    }
}
