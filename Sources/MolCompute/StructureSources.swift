import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import MolCore
import MolIO

// Structure sources beyond PubChem for the "Look up structure" dialog. All networking goes through
// `URLSession.portableData` (PortableNetworking.swift) with a per-request timeout; errors map to ComputeError
// (.offline, .timeout, .cancelled, .httpStatus, .notFound).
//
// - RCSB PDB: Search API (full text) + Data API (GraphQL metadata) + file download (.pdb, else .cif).
// - ChEMBL (EBI): REST API, molecule by ID or search by name; molfile structures.
// - DrugBank: its API needs a paid licence, so DrugBank IDs and names are resolved through PubChem, which lists
//   DrugBank IDs as synonyms / registry IDs. The candidates say so (`sourceNote`).
// - NCI CACTUS: name / CAS / SMILES resolver with 3D SD files.
// - SciFinder (CAS) has no public API and isn't queried; CAS numbers resolve through PubChem.

public enum LookupSource: String, CaseIterable, Sendable, Codable {
    case auto, pubchem, pdb, chembl, drugbank, cactus

    public var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .pubchem: return "PubChem"
        case .pdb: return "RCSB PDB"
        case .chembl: return "ChEMBL"
        case .drugbank: return "DrugBank (via PubChem)"
        case .cactus: return "NCI CACTUS"
        }
    }
}

public enum LookupSourceGuess {
    /// "DB00945".
    public static func isDrugBankID(_ s: String) -> Bool { s.range(of: #"^DB\d{5}$"#, options: [.regularExpression, .caseInsensitive]) != nil }
    /// "CHEMBL25".
    public static func isChEMBLID(_ s: String) -> Bool { s.range(of: #"^CHEMBL\d+$"#, options: [.regularExpression, .caseInsensitive]) != nil }
    /// "1CRN", "4hhb", "pdb:1crn", "pdb_00001crn": a digit, then three letters/digits with at least one letter.
    public static func pdbID(_ s: String) -> String? {
        var q = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.lowercased().hasPrefix("pdb:") || q.lowercased().hasPrefix("pdb ") { q = String(q.dropFirst(4)).trimmingCharacters(in: .whitespaces) }
        if q.range(of: #"^pdb_0000[0-9][A-Za-z0-9]{3}$"#, options: [.regularExpression, .caseInsensitive]) != nil { q = String(q.suffix(4)) }
        guard q.range(of: #"^[0-9][A-Za-z0-9]{3}$"#, options: .regularExpression) != nil, q.contains(where: \.isLetter) else { return nil }
        return q.uppercased()
    }

    /// The source Auto mode uses for a query, and the query as that source wants it.
    /// PDB IDs -> PDB, CHEMBL\d+ -> ChEMBL, DB\d{5} -> DrugBank (via PubChem); CAS numbers, SMILES, CIDs and names -> PubChem
    /// (Auto also adds PDB text-search hits for names, see `StructureLookup`).
    public static func guess(_ query: String) -> (source: LookupSource, query: String) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = pdbID(q) { return (.pdb, id) }
        let compact = q.replacingOccurrences(of: " ", with: "")
        if isChEMBLID(compact) { return (.chembl, compact.uppercased()) }
        if isDrugBankID(compact) { return (.drugbank, compact.uppercased()) }
        return (.pubchem, q)
    }
}

// MARK: - HTTP

/// GET/POST with a timeout and ComputeError mapping, for the lookup clients.
public struct LookupHTTP: Sendable {
    public var session: URLSession
    public var timeout: TimeInterval
    public init(session: URLSession = .shared, timeout: TimeInterval = 10) { self.session = session; self.timeout = timeout }

    public static func mapError(_ e: Error) -> ComputeError {
        if let c = e as? ComputeError { return c }
        if e is CancellationError { return .cancelled }
        if let u = e as? URLError {
            switch u.code {
            case .timedOut: return .timeout
            case .cancelled: return .cancelled
            default: return .offline
            }
        }
        return .offline
    }

    public func get(_ url: URL, accept: String? = nil, timeout t: TimeInterval? = nil) async throws -> Data {
        var req = URLRequest(url: url)
        req.timeoutInterval = t ?? timeout
        if let accept { req.setValue(accept, forHTTPHeaderField: "Accept") }
        return try await send(req)
    }

    public func postJSON(_ url: URL, body: Any) async throws -> Data {
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(req)
    }

    private func send(_ req: URLRequest, retry: Bool = true) async throws -> Data {
        try Task.checkCancellation()
        do {
            let (data, resp) = try await session.portableData(for: req)
            if let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) { throw ComputeError.httpStatus(h.statusCode) }
            return data
        } catch {
            let e = Self.mapError(error)
            // ChEMBL and RCSB answer 500/502/503 now and then under load: one retry after a second.
            if retry, case .httpStatus(let c) = e, [500, 502, 503, 504].contains(c) {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                return try await send(req, retry: false)
            }
            throw e
        }
    }

    /// `s` percent-encoded for one URL path segment.
    public static func pathSegment(_ s: String) -> String {
        var a = CharacterSet.urlPathAllowed
        a.remove(charactersIn: "/?#[]@!$&'()*+,;=%")
        return s.addingPercentEncoding(withAllowedCharacters: a) ?? s
    }

    public static func queryValue(_ s: String) -> String {
        var a = CharacterSet.alphanumerics
        a.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: a) ?? s
    }
}

// MARK: - RCSB PDB

public struct RCSBEntry: Sendable, Equatable {
    public var id: String
    public var title: String
    public var methods: [String] = []
    public var resolution: Double? = nil
    public var organisms: [String] = []
    public var atomCount: Int? = nil
    public var releaseDate: String? = nil
}

public struct RCSBClient: Sendable {
    public var http: LookupHTTP
    public var searchURL = URL(string: "https://search.rcsb.org/rcsbsearch/v2/query")!
    public var graphqlURL = URL(string: "https://data.rcsb.org/graphql")!
    public var filesBase = "https://files.rcsb.org/download"
    public init(http: LookupHTTP = LookupHTTP()) { self.http = http }

    /// Preview image URLs, tried in order (the CDN keeps them under /pdb/; the flat path is RCSB's documented form).
    public static func imageURLs(_ id: String) -> [URL] {
        let l = id.lowercased()
        return ["https://cdn.rcsb.org/images/structures/pdb/\(l)_assembly-1.jpeg",
                "https://cdn.rcsb.org/images/structures/\(l)_assembly-1.jpeg",
                "https://cdn.rcsb.org/images/structures/pdb/\(l)_model-1.jpeg"].compactMap(URL.init(string:))
    }

    public static func entryPage(_ id: String) -> URL { URL(string: "https://www.rcsb.org/structure/\(id.uppercased())")! }

    /// Search API request body for a full-text query.
    public static func searchBody(_ text: String, rows: Int) -> [String: Any] {
        ["query": ["type": "terminal", "service": "full_text", "parameters": ["value": text]],
         "return_type": "entry",
         "request_options": ["paginate": ["start": 0, "rows": rows], "results_content_type": ["experimental"],
                             "sort": [["sort_by": "score", "direction": "desc"]]]]
    }

    public static func parseSearch(_ data: Data) -> [String] {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rs = o["result_set"] as? [[String: Any]] else { return [] }
        return rs.compactMap { $0["identifier"] as? String }
    }

    public static func graphqlBody(_ ids: [String]) -> [String: Any] {
        let list = ids.map { "\"\($0)\"" }.joined(separator: ",")
        return ["query": "{ entries(entry_ids: [\(list)]) { rcsb_id struct { title } exptl { method } "
                + "rcsb_entry_info { resolution_combined deposited_atom_count } "
                + "polymer_entities { rcsb_entity_source_organism { ncbi_scientific_name } } "
                + "rcsb_accession_info { initial_release_date } } }"]
    }

    public static func parseEntries(_ data: Data) -> [RCSBEntry] {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let d = o["data"] as? [String: Any], let es = d["entries"] as? [Any] else { return [] }
        return es.compactMap { x in
            guard let e = x as? [String: Any], let id = e["rcsb_id"] as? String else { return nil }
            var r = RCSBEntry(id: id, title: ((e["struct"] as? [String: Any])?["title"] as? String) ?? id)
            r.methods = ((e["exptl"] as? [[String: Any]]) ?? []).compactMap { $0["method"] as? String }
            let info = e["rcsb_entry_info"] as? [String: Any]
            r.resolution = (info?["resolution_combined"] as? [Any])?.first.flatMap { ($0 as? Double) ?? ($0 as? NSNumber)?.doubleValue }
            r.atomCount = (info?["deposited_atom_count"] as? Int) ?? (info?["deposited_atom_count"] as? NSNumber)?.intValue
            var orgs: [String] = []
            for pe in (e["polymer_entities"] as? [[String: Any]]) ?? [] {
                for so in (pe["rcsb_entity_source_organism"] as? [[String: Any]]) ?? [] {
                    if let n = so["ncbi_scientific_name"] as? String, !orgs.contains(n) { orgs.append(n) }
                }
            }
            r.organisms = orgs
            r.releaseDate = ((e["rcsb_accession_info"] as? [String: Any])?["initial_release_date"] as? String).map { String($0.prefix(10)) }
            return r
        }
    }

    public func search(_ text: String, rows: Int) async throws -> [String] {
        do { return Self.parseSearch(try await http.postJSON(searchURL, body: Self.searchBody(text, rows: rows))) }
        catch ComputeError.httpStatus(let c) where c == 204 || c == 400 || c == 404 { return [] }   // 204: no hits
    }

    public func entries(_ ids: [String]) async throws -> [RCSBEntry] {
        guard !ids.isEmpty else { return [] }
        return Self.parseEntries(try await http.postJSON(graphqlURL, body: Self.graphqlBody(ids)))
    }

    public func thumbnail(_ id: String) async -> Data? {
        for u in Self.imageURLs(id) {
            if let d = try? await http.get(u), d.count > 100, d.first == 0xFF { return d }   // JPEG
        }
        return nil
    }

    /// The entry as a PDB file, or as mmCIF when no PDB-format file exists (large structures).
    public func download(_ id: String) async throws -> (text: String, fileName: String) {
        let up = id.uppercased()
        let t = max(http.timeout, 60)
        do {
            let d = try await http.get(URL(string: "\(filesBase)/\(up).pdb")!, timeout: t)
            return (String(decoding: d, as: UTF8.self), up + ".pdb")
        } catch ComputeError.httpStatus(let c) where c == 404 {
            do {
                let d = try await http.get(URL(string: "\(filesBase)/\(up).cif")!, timeout: max(t, 120))
                return (String(decoding: d, as: UTF8.self), up + ".cif")
            } catch ComputeError.httpStatus(let c) where c == 404 { throw ComputeError.notFound("PDB entry \(up)") }
        }
    }

    /// Candidate for an entry (thumbnail filled in by the caller).
    public static func candidate(_ e: RCSBEntry, matched: String, kind: LookupMatchKind) -> LookupCandidate {
        var c = LookupCandidate(cid: 0, title: e.title.capitalizedTitle, depictionURL: imageURLs(e.id)[0], matchKind: kind,
                                matchedQuery: matched, source: .pdb, identifier: e.id)
        var line1: [String] = []
        if let m = e.methods.first { line1.append(m.capitalized) }
        if let r = e.resolution { line1.append(String(format: "%.2f Å", r)) }
        if let n = e.atomCount { line1.append("\(n) atoms") }
        if let d = e.releaseDate { line1.append("released \(d)") }
        c.details = [line1.joined(separator: " · ")].filter { !$0.isEmpty }
        if !e.organisms.isEmpty { c.details.append(e.organisms.prefix(3).joined(separator: ", ")) }
        c.thumbnailMIME = "image/jpeg"
        c.webURL = entryPage(e.id)
        c.isMacromolecule = true
        return c
    }
}

extension String {
    /// "WATER STRUCTURE OF A PROTEIN" -> "Water structure of a protein" (RCSB titles are often all caps).
    var capitalizedTitle: String {
        guard self == uppercased(), contains(where: \.isLetter) else { return self }
        let l = lowercased()
        return l.prefix(1).uppercased() + l.dropFirst()
    }
}

// MARK: - ChEMBL

public struct ChEMBLMolecule: Sendable, Equatable {
    public var id: String
    public var name: String?
    public var formula: String?
    public var molecularWeight: Double?
    public var smiles: String?
    public var molfile: String?
    public var inchiKey: String?
    public var maxPhase: String?
    public var type: String?
    public var synonyms: [String] = []
}

public struct ChEMBLClient: Sendable {
    public var http: LookupHTTP
    public var base = "https://www.ebi.ac.uk/chembl/api/data"
    public init(http: LookupHTTP = LookupHTTP(timeout: 40)) { self.http = http }

    static let fields = "molecule_chembl_id,pref_name,molecule_properties,molecule_structures,max_phase,molecule_type,molecule_synonyms"

    static func parseOne(_ d: [String: Any]) -> ChEMBLMolecule? {
        guard let id = d["molecule_chembl_id"] as? String else { return nil }
        let props = d["molecule_properties"] as? [String: Any]
        let st = d["molecule_structures"] as? [String: Any]
        func num(_ x: Any?) -> Double? { (x as? Double) ?? (x as? String).flatMap(Double.init) ?? (x as? NSNumber)?.doubleValue }
        var m = ChEMBLMolecule(id: id, name: d["pref_name"] as? String, formula: props?["full_molformula"] as? String,
                               molecularWeight: num(props?["full_mwt"]), smiles: st?["canonical_smiles"] as? String,
                               molfile: st?["molfile"] as? String, inchiKey: st?["standard_inchi_key"] as? String)
        if let p = d["max_phase"] { m.maxPhase = (p as? String) ?? num(p).map { String(format: "%g", $0) } }
        m.type = d["molecule_type"] as? String
        var syn: [String] = []
        for s in (d["molecule_synonyms"] as? [[String: Any]]) ?? [] {
            if let n = s["molecule_synonym"] as? String, !syn.contains(where: { $0.caseInsensitiveCompare(n) == .orderedSame }) { syn.append(n) }
        }
        m.synonyms = syn
        return m
    }

    public static func parseMolecule(_ data: Data) -> ChEMBLMolecule? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any]).flatMap { parseOne($0) }
    }

    public static func parseSearch(_ data: Data) -> [ChEMBLMolecule] {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ms = o["molecules"] as? [[String: Any]] else { return [] }
        return ms.compactMap(parseOne)
    }

    public func molecule(_ id: String) async throws -> ChEMBLMolecule? {
        let u = URL(string: "\(base)/molecule/\(LookupHTTP.pathSegment(id.uppercased())).json")!
        do { return Self.parseMolecule(try await http.get(u, accept: "application/json")) }
        catch ComputeError.httpStatus(let c) where c == 404 || c == 400 { return nil }
    }

    public func search(_ q: String, limit: Int) async throws -> [ChEMBLMolecule] {
        let u = URL(string: "\(base)/molecule/search.json?q=\(LookupHTTP.queryValue(q))&limit=\(limit)&only=\(Self.fields)")!
        do { return Self.parseSearch(try await http.get(u, accept: "application/json")) }
        catch ComputeError.httpStatus(let c) where c == 404 || c == 400 { return [] }
    }

    public func image(_ id: String) async -> Data? {
        guard let u = URL(string: "\(base)/image/\(LookupHTTP.pathSegment(id)).svg") else { return nil }
        guard let d = try? await http.get(u), d.count > 50, String(decoding: d.prefix(2000), as: UTF8.self).contains("<svg") else { return nil }
        return d
    }

    public static func candidate(_ m: ChEMBLMolecule, matched: String, kind: LookupMatchKind) -> LookupCandidate {
        var c = LookupCandidate(cid: 0, title: (m.name?.capitalizedTitle).flatMap { $0.isEmpty ? nil : $0 } ?? m.id, formula: m.formula,
                                molecularWeight: m.molecularWeight, canonicalSMILES: m.smiles, synonyms: Array(m.synonyms.prefix(5)),
                                depictionURL: URL(string: "https://www.ebi.ac.uk/chembl/api/data/image/\(m.id).svg")!,
                                matchKind: kind, matchedQuery: matched, source: .chembl, identifier: m.id)
        c.chemblID = m.id
        c.thumbnailMIME = "image/svg+xml"
        var d: [String] = [m.id]
        if let t = m.type { d.append(t) }
        if let p = m.maxPhase, let v = Double(p) { d.append(v >= 4 ? "approved drug (phase 4)" : "max phase \(p)") }
        c.details = [d.joined(separator: " · ")]
        c.webURL = URL(string: "https://www.ebi.ac.uk/chembl/compound_report_card/\(m.id)/")
        c.molfile = m.molfile
        c.inchiKey = m.inchiKey
        c.isMacromolecule = m.molfile == nil && (m.type ?? "").lowercased() != "small molecule"
        return c
    }
}

// MARK: - NCI CACTUS

public struct CactusClient: Sendable {
    public var http: LookupHTTP
    public var base = "https://cactus.nci.nih.gov/chemical/structure"
    public init(http: LookupHTTP = LookupHTTP(timeout: 20)) { self.http = http }

    private func text(_ q: String, _ what: String) async throws -> String? {
        let u = URL(string: "\(base)/\(LookupHTTP.pathSegment(q))/\(what)")!
        do {
            let s = String(decoding: try await http.get(u), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return s.isEmpty || s.hasPrefix("<") ? nil : s
        } catch ComputeError.httpStatus(let c) where c == 404 || c == 400 || c == 500 { return nil }
    }

    /// 3D SD file for a name / CAS number / SMILES / InChIKey, nil when CACTUS can't resolve it.
    public func sdf(_ q: String) async throws -> String? {
        guard let s = try await text(q, "file?format=sdf&get3d=true"), s.contains("V2000") || s.contains("V3000") else { return nil }
        return s
    }

    public func candidate(_ q: String) async throws -> LookupCandidate? {
        guard let smiles = try await text(q, "smiles")?.components(separatedBy: .newlines).first else { return nil }
        let formula = try? await text(q, "formula")
        var c = LookupCandidate(cid: 0, title: q, formula: formula?.components(separatedBy: .newlines).first, canonicalSMILES: smiles,
                                depictionURL: URL(string: "\(base)/\(LookupHTTP.pathSegment(q))/image?format=png&width=160&height=160")!,
                                matchKind: .exact, matchedQuery: q, source: .cactus, identifier: q)
        if let d = try? await http.get(c.depictionURL), d.starts(with: [0x89, 0x50, 0x4E, 0x47]) { c.thumbnail = d }
        if CASNumber.isValid(q) { c.casNumber = q }
        c.details = ["resolved by the NCI/CADD Chemical Identifier Resolver"]
        c.webURL = URL(string: "\(base)/\(LookupHTTP.pathSegment(q))/smiles")
        return c
    }
}
