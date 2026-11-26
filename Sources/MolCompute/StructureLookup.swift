import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import MolCore
import MolIO
import MolBuild

// Orchestration of the lookup sources in StructureSources.swift for the "Look up structure" dialog
// (engine methods lookup.suggest / lookup.structure / lookup.download).

/// What `StructureLookup.suggest` found.
public struct StructureLookupResult: Sendable {
    public var candidates: [LookupCandidate]
    /// The source that was searched (Auto resolves to one, plus PDB hits for names).
    public var source: LookupSource
    /// For Auto: the source the query was routed to.
    public var resolvedSource: LookupSource
    /// A note for the dialog ("DrugBank IDs come from PubChem's cross-references", …).
    public var notice: String?
    /// Why nothing was found (offline, timeout, not found), nil when there are candidates.
    public var error: ComputeError?

    public init(candidates: [LookupCandidate], source: LookupSource, resolvedSource: LookupSource? = nil,
                notice: String? = nil, error: ComputeError? = nil) {
        self.candidates = candidates; self.source = source; self.resolvedSource = resolvedSource ?? source
        self.notice = notice; self.error = error
    }
}

/// Structure lookup across PubChem, RCSB PDB, ChEMBL, DrugBank (through PubChem) and NCI CACTUS.
/// Candidates are cached by `LookupCandidate.id` ("pdb:1CRN"), which `structure(id:)` and `downloadPDB` take.
public actor StructureLookup {
    public let pubchem: NameLookup
    public let rcsb: RCSBClient
    public let chembl: ChEMBLClient
    public let cactus: CactusClient
    private var byID: [String: LookupCandidate] = [:]

    public static let drugBankNote = "DrugBank has no free API: DrugBank IDs are resolved through PubChem's cross-references, and the structure comes from PubChem."
    public static let sciFinderNote = "SciFinder (CAS) has no public API and needs an institutional CAS subscription. CAS registry numbers (e.g. 50-78-2) are resolved here through PubChem."
    public static let cactusNote = "NCI CACTUS (Chemical Identifier Resolver) resolves names, CAS numbers and SMILES. It is slower than PubChem and sometimes down."

    public init(pubchem: NameLookup = NameLookup(), rcsb: RCSBClient = RCSBClient(), chembl: ChEMBLClient = ChEMBLClient(),
                cactus: CactusClient = CactusClient()) {
        self.pubchem = pubchem; self.rcsb = rcsb; self.chembl = chembl; self.cactus = cactus
    }

    public func cached(_ id: String) -> LookupCandidate? { byID[id] }
    public func remember(_ cs: [LookupCandidate]) { for c in cs { byID[c.id] = c } }

    public func suggest(_ query: String, source: LookupSource = .auto, limit: Int = 8) async -> StructureLookupResult {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return StructureLookupResult(candidates: [], source: source) }
        var r: StructureLookupResult
        do {
            switch source {
            case .auto: r = try await auto(q, limit: limit)
            case .pubchem: r = await pubchemSearch(q, limit: limit)
            case .pdb: r = try await pdbSearch(q, limit: limit)
            case .chembl: r = try await chemblSearch(q, limit: limit)
            case .drugbank: r = await drugbankSearch(q, limit: limit)
            case .cactus: r = try await cactusSearch(q)
            }
        } catch {
            r = StructureLookupResult(candidates: [], source: source, error: LookupHTTP.mapError(error))
        }
        r.source = source
        if r.candidates.isEmpty, r.error == nil { r.error = .notFound(q) }
        if !r.candidates.isEmpty { r.error = nil }
        remember(r.candidates)
        return r
    }

    private func auto(_ q: String, limit: Int) async throws -> StructureLookupResult {
        let g = LookupSourceGuess.guess(q)
        switch g.source {
        case .pdb:
            // "1CRN" is a PDB ID, but a 4-character query can also be a name or a CID: fall back to PubChem.
            let r = try? await pdbSearch(g.query, limit: limit, textSearch: false)
            if let r, !r.candidates.isEmpty { return r }
            return await pubchemSearch(q, limit: limit)
        case .chembl: return try await chemblSearch(g.query, limit: limit)
        case .drugbank: return await drugbankSearch(g.query, limit: limit)
        default: break
        }
        // Names also search the PDB ("hemoglobin", "lysozyme"); CAS numbers, SMILES and CIDs only PubChem.
        let isName: Bool
        if case .name = LookupQueryKind.classify(q) { isName = true } else { isName = false }
        async let pdbHits: [LookupCandidate] = isName ? ((try? await pdbText(q, rows: limit)) ?? []) : []
        var p = await pubchemSearch(q, limit: limit)
        var cs = p.candidates
        if cs.isEmpty, isName, let c = try? await cactus.candidate(q) { cs.append(c) }
        let pdb = await pdbHits
        // Small-molecule hits first (at most 3 PDB entries after them); when PubChem has none (protein names), the
        // PDB entries are the list.
        cs += pdb.prefix(cs.isEmpty ? limit : 3)
        p.candidates = cs
        if !cs.isEmpty { p.error = nil }
        if pdb.count > 0, p.candidates.first?.source == .pdb { p.resolvedSource = .pdb }
        return p
    }

    private func pubchemSearch(_ q: String, limit: Int) async -> StructureLookupResult {
        let cs = await pubchem.suggest(q, limit: limit)
        let e = cs.isEmpty ? await pubchem.lastError : nil
        return StructureLookupResult(candidates: cs, source: .pubchem, notice: CASNumber.isValid(q) ? Self.sciFinderNote : nil, error: e)
    }

    // MARK: PDB

    private func pdbText(_ q: String, rows: Int) async throws -> [LookupCandidate] {
        let ids = try await rcsb.search(q, rows: rows)
        return try await pdbCandidates(ids, matched: q, kind: .ambiguous)
    }

    private func pdbCandidates(_ ids: [String], matched: String, kind: LookupMatchKind) async throws -> [LookupCandidate] {
        guard !ids.isEmpty else { return [] }
        let entries = try await rcsb.entries(ids)
        let byId = Dictionary(entries.map { ($0.id.uppercased(), $0) }, uniquingKeysWith: { a, _ in a })
        var out = ids.compactMap { byId[$0.uppercased()] }.map { RCSBClient.candidate($0, matched: matched, kind: kind) }
        let client = rcsb
        let thumbs: [String: Data] = await withTaskGroup(of: (String, Data?).self) { g in
            for c in out { let id = c.identifier; g.addTask { (id, await client.thumbnail(id)) } }
            var r: [String: Data] = [:]
            for await (id, d) in g { if let d { r[id] = d } }
            return r
        }
        for i in out.indices { out[i].thumbnail = thumbs[out[i].identifier] }
        return out
    }

    private func pdbSearch(_ q: String, limit: Int, textSearch: Bool = true) async throws -> StructureLookupResult {
        if let id = LookupSourceGuess.pdbID(q) {
            let cs = try await pdbCandidates([id], matched: q, kind: .exact)
            if !cs.isEmpty || !textSearch { return StructureLookupResult(candidates: cs, source: .pdb) }
        }
        return StructureLookupResult(candidates: try await pdbText(q, rows: limit), source: .pdb)
    }

    // MARK: ChEMBL

    private func chemblSearch(_ q: String, limit: Int) async throws -> StructureLookupResult {
        var ms: [ChEMBLMolecule] = []
        let compact = q.replacingOccurrences(of: " ", with: "")
        let byID = LookupSourceGuess.isChEMBLID(compact)
        if byID {
            if let m = try await chembl.molecule(compact) { ms = [m] }
        } else {
            ms = try await chembl.search(q, limit: limit)
            // An exact preferred-name or synonym match goes first.
            if let k = ms.firstIndex(where: { m in
                m.name?.caseInsensitiveCompare(q) == .orderedSame || m.synonyms.contains { $0.caseInsensitiveCompare(q) == .orderedSame } }) {
                let m = ms.remove(at: k); ms.insert(m, at: 0)
            }
        }
        var cs = ms.prefix(limit).enumerated().map { i, m in
            ChEMBLClient.candidate(m, matched: q, kind: byID || i == 0 ? .exact : .ambiguous)
        }
        let client = chembl
        let imgs: [String: Data] = await withTaskGroup(of: (String, Data?).self) { g in
            for c in cs where c.molfile != nil { let id = c.identifier; g.addTask { (id, await client.image(id)) } }
            var r: [String: Data] = [:]
            for await (id, d) in g { if let d { r[id] = d } }
            return r
        }
        for i in cs.indices { cs[i].thumbnail = imgs[cs[i].identifier] }
        // ChEMBL's image service fails now and then (HTTP 500): PubChem's depiction of the same InChIKey instead.
        let http = LookupHTTP(timeout: 10)
        let missing = cs.indices.filter { cs[$0].thumbnail == nil && cs[$0].inchiKey != nil }
        let pngs: [Int: Data] = await withTaskGroup(of: (Int, Data?).self) { g in
            for i in missing {
                guard let key = cs[i].inchiKey,
                      let u = URL(string: "https://pubchem.ncbi.nlm.nih.gov/rest/pug/compound/inchikey/\(key)/PNG?image_size=160x160") else { continue }
                g.addTask { (i, try? await http.get(u)) }
            }
            var r: [Int: Data] = [:]
            for await (i, d) in g { if let d, d.starts(with: [0x89, 0x50, 0x4E, 0x47]) { r[i] = d } }
            return r
        }
        for (i, d) in pngs { cs[i].thumbnail = d; cs[i].thumbnailMIME = "image/png" }
        return StructureLookupResult(candidates: cs, source: .chembl)
    }

    // MARK: DrugBank (through PubChem)

    private func drugbankSearch(_ q: String, limit: Int) async -> StructureLookupResult {
        let id = q.replacingOccurrences(of: " ", with: "").uppercased()
        let isID = LookupSourceGuess.isDrugBankID(id)
        var cs = await pubchem.suggest(isID ? id : q, limit: limit)
        let e = cs.isEmpty ? await pubchem.lastError : nil
        // PubChem's name index lists DrugBank IDs as synonyms: a hit for "DB00945" carries that ID.
        if isID { for i in cs.indices where cs[i].drugBankID == nil { cs[i].drugBankID = id } }
        var tagged = cs.compactMap(Self.drugBankCandidate)
        var notice = Self.drugBankNote
        if tagged.isEmpty, !cs.isEmpty {
            notice += " PubChem lists no DrugBank ID for these compounds, so they are shown as PubChem records."
            tagged = cs
        }
        return StructureLookupResult(candidates: tagged, source: .drugbank, notice: notice, error: e)
    }

    /// A PubChem candidate relabelled as its DrugBank record (nil when PubChem lists no DrugBank ID).
    public static func drugBankCandidate(_ p: LookupCandidate) -> LookupCandidate? {
        guard let db = p.drugBankID?.uppercased() else { return nil }
        var c = p
        c.source = .drugbank
        c.identifier = db
        c.webURL = URL(string: "https://go.drugbank.com/drugs/\(db)")
        c.sourceNote = "DrugBank ID resolved through PubChem; structure from PubChem CID \(p.cid)"
        c.details = ["\(db) · PubChem CID \(p.cid)"]
        return c
    }

    // MARK: CACTUS

    private func cactusSearch(_ q: String) async throws -> StructureLookupResult {
        let c = try await cactus.candidate(q)
        return StructureLookupResult(candidates: c.map { [$0] } ?? [], source: .cactus, notice: Self.cactusNote)
    }

    // MARK: Structures

    /// The 3D structure of a candidate: small molecules in 3D, a PDB entry's first model (for "insert").
    public func structure(id: String) async throws -> Molecule {
        guard let c = byID[id] ?? Self.bareCandidate(id) else { throw ComputeError.notFound(id) }
        switch c.source {
        case .pdb:
            let f = try await rcsb.download(c.identifier)
            var m = try Self.loadPDB(f.text, fileName: f.fileName)
            m.title = c.identifier
            return m
        case .chembl:
            return try await chemblStructure(c)
        case .cactus:
            guard let sdf = try await cactus.sdf(c.identifier) else { throw ComputeError.notFound(c.identifier) }
            var m = try PubChemClient.parseSDF(sdf, fallbackTitle: c.title).molecule
            if !m.atoms.contains(where: { $0.atomicNumber == 1 }) { Editing.addHydrogens(&m) }
            m.title = c.title
            return m
        case .pubchem, .drugbank, .auto:
            guard c.cid > 0 else { throw ComputeError.notFound(id) }
            return try await pubchem.structure(for: c)
        }
    }

    /// Candidate for an id that `suggest` didn't return ("pubchem:2244", "pdb:1crn", "chembl:CHEMBL25").
    public static func bareCandidate(_ id: String) -> LookupCandidate? {
        let parts = id.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let src = LookupSource(rawValue: parts[0].lowercased()), src != .auto, src != .drugbank,
              !parts[1].isEmpty else { return nil }
        let ident = src == .pdb || src == .chembl ? parts[1].uppercased() : parts[1]
        if src == .pubchem, Int(ident) == nil { return nil }
        var c = LookupCandidate(cid: src == .pubchem ? Int(ident) ?? 0 : 0, title: ident,
                                depictionURL: URL(string: "https://pubchem.ncbi.nlm.nih.gov/rest/pug/compound/cid/\(ident)/PNG")!,
                                matchKind: .exact, matchedQuery: ident, source: src, identifier: ident)
        c.isMacromolecule = src == .pdb
        return c
    }

    private func chemblStructure(_ c: LookupCandidate) async throws -> Molecule {
        var cand = c
        if cand.molfile == nil, let m = try await chembl.molecule(c.identifier) {
            cand = ChEMBLClient.candidate(m, matched: c.matchedQuery, kind: c.matchKind)
            if c.title != c.identifier { cand.title = c.title }
        }
        // PubChem's 3D conformer for the same InChIKey; otherwise ChEMBL's 2D molfile, with hydrogens, embedded in 3D.
        if let key = cand.inchiKey, let p = try? await PubChemClient(timeout: 15).fetch(inchiKey: key), p.is3D {
            var m = p.molecule
            m.title = cand.title
            return m
        }
        guard let mf = cand.molfile else {
            throw ComputeError.notFound("\(c.identifier) structure (ChEMBL has no small-molecule structure for biologics)")
        }
        var m = try Self.moleculeFromMolfile(mf)
        m.title = cand.title
        return m
    }

    /// A ChEMBL molfile (2D, usually without hydrogens) as a 3D molecule.
    public static func moleculeFromMolfile(_ mf: String) throws -> Molecule {
        let text = mf.hasSuffix("\n") ? mf + "$$$$\n" : mf + "\n$$$$\n"
        let records: [SDFRecord]
        do { records = try MDLMolFormat.parse(text) } catch { throw ComputeError.parse("\(error)") }
        guard var m = records.first?.molecule, !m.atoms.isEmpty else { throw ComputeError.parse("molfile has no atoms") }
        if !m.atoms.contains(where: { $0.atomicNumber == 1 }) { Editing.addHydrogens(&m) }
        return PubChemClient.embed2D(m)
    }

    /// PDB or PDBx/mmCIF text as a molecule (first model, like a document opened from the file).
    public static func loadPDB(_ text: String, fileName: String) throws -> Molecule {
        do { return try MolecularFileLoader.load(text: text, format: .pdb, fileName: fileName).molecules.first ?? Molecule() }
        catch { throw ComputeError.parse("\(fileName): \(error)") }
    }

    /// Downloads a PDB entry into `directory` and returns the file to open as a document: `<ID>.pdb`, or `<ID>.cif`
    /// for entries that only exist as PDBx/mmCIF (large structures such as most cryo-EM assemblies).
    public func downloadPDB(id: String, directory: URL) async throws -> (url: URL, format: String) {
        let ident = (byID[id] ?? Self.bareCandidate(id))?.identifier ?? LookupSourceGuess.pdbID(id) ?? id
        guard let up = LookupSourceGuess.pdbID(ident) else { throw ComputeError.notFound(id) }
        let f = try await rcsb.download(up)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let isCIF = f.fileName.lowercased().hasSuffix(".cif")
        let url = directory.appendingPathComponent(up + (isCIF ? ".cif" : ".pdb"))
        try Data(f.text.utf8).write(to: url, options: .atomic)
        return (url, isCIF ? "cif" : "pdb")
    }
}
