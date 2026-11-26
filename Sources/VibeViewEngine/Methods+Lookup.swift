import Foundation
import MolCore
import MolCompute

// Structure lookup: PubChem, RCSB PDB, ChEMBL, DrugBank (resolved through PubChem) and NCI CACTUS.
// SciFinder (CAS) has no public API; `lookup.sources` says so and CAS numbers resolve through PubChem.

extension Engine {
    static func errorCode(_ e: ComputeError) -> String { RPCError.from(e).code }

    static func candidateJSON(_ c: LookupCandidate) -> JSON {
        obj(["id": c.id, "source": c.source.rawValue, "sourceName": c.source.displayName, "identifier": c.identifier,
             "cid": c.cid, "title": c.title, "iupacName": c.iupacName, "formula": c.formula,
             "molecularWeight": c.molecularWeight, "canonicalSMILES": c.canonicalSMILES, "synonyms": c.synonyms,
             "casNumber": c.casNumber, "matchKind": c.matchKind.rawValue, "matchedQuery": c.matchedQuery,
             "depictionURL": c.depictionURL.absoluteString,
             "thumbnailB64": c.thumbnail.map { $0.base64EncodedString() }, "thumbnailMIME": c.thumbnailMIME,
             "details": c.details, "webURL": c.webURL?.absoluteString, "drugBankID": c.drugBankID, "chemblID": c.chemblID,
             "sourceNote": c.sourceNote, "isMacromolecule": c.isMacromolecule])
    }

    /// `lookup.sources`: the selectable sources, plus SciFinder (listed as unavailable, with the reason).
    func lookupSources() -> JSON {
        let hints: [LookupSource: String] = [
            .auto: "Guesses the source: PDB ID (1CRN), ChEMBL ID (CHEMBL25), DrugBank ID (DB00945), CAS number, SMILES, CID or name (names also search the PDB).",
            .pubchem: "Names, CAS numbers, SMILES and CIDs. 3D conformers.",
            .pdb: "Proteins and nucleic acids: a 4-character PDB ID or free text. Opens as a PDB document.",
            .chembl: "Bioactive molecules: CHEMBL ID or name.",
            .drugbank: StructureLookup.drugBankNote,
            .cactus: StructureLookup.cactusNote,
        ]
        var out: [JSON] = LookupSource.allCases.map { s in
            obj(["id": s.rawValue, "name": s.displayName, "available": true, "hint": hints[s]])
        }
        out.append(obj(["id": "scifinder", "name": "SciFinder (CAS)", "available": false, "hint": StructureLookup.sciFinderNote]))
        return .array(out)
    }

    func lookupSuggest(_ p: Params) async throws -> JSON {
        let q = try p.string("query").trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = max(1, min(p.optInt("limit") ?? 8, 25))
        let srcName = p.optString("source") ?? "auto"
        if srcName == "scifinder" {
            return obj(["candidates": JSON.array([]), "source": srcName, "resolvedSource": srcName,
                        "error": StructureLookup.sciFinderNote, "errorCode": "unavailable", "notice": StructureLookup.sciFinderNote])
        }
        guard let source = LookupSource(rawValue: srcName) else { throw RPCError.badRequest("unknown source '\(srcName)'") }
        guard !q.isEmpty else { return obj(["candidates": JSON.array([]), "error": JSON.null, "source": srcName]) }
        let r = await sources.suggest(q, source: source, limit: limit)
        try Task.checkCancellation()
        var errText: String? = nil
        var errCode: String? = nil
        if r.candidates.isEmpty, let e = r.error { errText = e.errorDescription ?? "\(e)"; errCode = Engine.errorCode(e) }
        return obj(["candidates": JSON.array(r.candidates.map(Engine.candidateJSON)), "source": r.source.rawValue,
                    "resolvedSource": r.resolvedSource.rawValue, "notice": r.notice, "error": errText, "errorCode": errCode])
    }

    /// Candidate id from `{id}` or the older `{cid}`.
    private static func candidateID(_ p: Params) throws -> String {
        if let id = p.optString("id"), !id.isEmpty { return id }
        let cid = try p.int("cid")
        guard cid > 0 else { throw RPCError.badRequest("cid must be positive") }
        return "pubchem:\(cid)"
    }

    func lookupStructure(_ p: Params) async throws -> JSON {
        let id = try Engine.candidateID(p)
        if id.hasPrefix("pubchem:"), await sources.cached(id) == nil, let t = p.optString("title"), let cid = Int(id.dropFirst(8)) {
            await sources.remember([LookupCandidate(cid: cid, title: t,
                depictionURL: URL(string: "https://pubchem.ncbi.nlm.nih.gov/rest/pug/compound/cid/\(cid)/PNG")!,
                matchKind: .cid, matchedQuery: String(cid))])
        }
        var m = try await sources.structure(id: id)
        try Task.checkCancellation()
        m = Preparation.prepared(m, perceiveOrders: m.atoms.count < 2000)
        return JSONShapes.molecule(m)
    }

    /// Where `lookup.download` saves PDB entries: %LOCALAPPDATA%\VibeView\Downloads (~/.cache/vibeview/downloads elsewhere).
    static func downloadDirectory() -> URL {
        let env = ProcessInfo.processInfo.environment
        #if os(Windows)
        if let l = env["LOCALAPPDATA"], !l.isEmpty {
            return URL(fileURLWithPath: l).appendingPathComponent("VibeView").appendingPathComponent("Downloads")
        }
        #endif
        if let x = env["XDG_CACHE_HOME"], !x.isEmpty { return URL(fileURLWithPath: x).appendingPathComponent("vibeview/downloads") }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/vibeview/downloads")
    }

    /// `lookup.download {id, directory?}`: saves a PDB entry (`pdb:1CRN`) and returns its path, to open with doc.open.
    func lookupDownload(_ p: Params) async throws -> JSON {
        let id = try Engine.candidateID(p)
        let dir = p.optString("directory").map { URL(fileURLWithPath: $0) } ?? Engine.downloadDirectory()
        let r = try await sources.downloadPDB(id: id, directory: dir)
        try Task.checkCancellation()
        return obj(["path": ProgramPaths.nativePath(r.url), "fileName": r.url.lastPathComponent, "downloadedFormat": r.format])
    }
}
