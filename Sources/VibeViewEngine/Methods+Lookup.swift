import Foundation
import MolCore
import MolCompute

/// Candidates seen by `lookup.suggest`, so `lookup.structure {cid}` can reuse the title.
final class CandidateCache: @unchecked Sendable {
    private let lock = NSLock()
    private var byCID: [Int: LookupCandidate] = [:]
    func store(_ cs: [LookupCandidate]) { lock.lock(); for c in cs { byCID[c.cid] = c }; lock.unlock() }
    func get(_ cid: Int) -> LookupCandidate? { lock.lock(); defer { lock.unlock() }; return byCID[cid] }
}

extension Engine {
    static func errorCode(_ e: ComputeError) -> String { RPCError.from(e).code }

    func lookupSuggest(_ p: Params) async throws -> JSON {
        let q = try p.string("query").trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = max(1, min(p.optInt("limit") ?? 8, 25))
        guard !q.isEmpty else { return ["candidates": [], "error": .null] }
        let cs = await lookup.suggest(q, limit: limit)
        try Task.checkCancellation()
        candidateCache.store(cs)
        let err = await lookup.lastError
        let out: [JSON] = cs.map { c in
            obj(["cid": c.cid, "title": c.title, "iupacName": c.iupacName, "formula": c.formula,
                 "molecularWeight": c.molecularWeight, "canonicalSMILES": c.canonicalSMILES, "synonyms": c.synonyms,
                 "casNumber": c.casNumber, "matchKind": c.matchKind.rawValue, "matchedQuery": c.matchedQuery,
                 "depictionURL": c.depictionURL.absoluteString,
                 "thumbnailB64": c.thumbnail.map { $0.base64EncodedString() }])
        }
        var errText: String? = nil
        var errCode: String? = nil
        if cs.isEmpty, let e = err { errText = e.errorDescription ?? "\(e)"; errCode = Engine.errorCode(e) }
        return obj(["candidates": JSON.array(out), "error": errText, "errorCode": errCode])
    }

    func lookupStructure(_ p: Params) async throws -> JSON {
        let cid = try p.int("cid")
        guard cid > 0 else { throw RPCError.badRequest("cid must be positive") }
        let c = candidateCache.get(cid) ?? LookupCandidate(
            cid: cid, title: p.optString("title") ?? "CID \(cid)",
            depictionURL: URL(string: "https://pubchem.ncbi.nlm.nih.gov/rest/pug/compound/cid/\(cid)/PNG")!,
            matchKind: .cid, matchedQuery: String(cid))
        var m = try await lookup.structure(for: c)
        try Task.checkCancellation()
        m = Preparation.prepared(m)
        return JSONShapes.molecule(m)
    }
}
