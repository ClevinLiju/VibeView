import Foundation
import MolCore
import MolIO

public enum LookupMatchKind: String, Sendable, Hashable { case exact, ambiguous, spellingSuggestion, cas, smiles, cid }

public struct LookupCandidate: Sendable, Identifiable, Hashable {
    public var cid: Int
    public var id: Int { cid }
    public var title: String
    public var iupacName: String?
    public var formula: String?
    public var molecularWeight: Double?
    public var canonicalSMILES: String?
    public var synonyms: [String]
    public var casNumber: String?
    public var depictionURL: URL
    public var thumbnail: Data?
    public var matchKind: LookupMatchKind
    public var matchedQuery: String

    public init(cid: Int, title: String, iupacName: String? = nil, formula: String? = nil, molecularWeight: Double? = nil,
                canonicalSMILES: String? = nil, synonyms: [String] = [], casNumber: String? = nil, depictionURL: URL,
                thumbnail: Data? = nil, matchKind: LookupMatchKind, matchedQuery: String) {
        self.cid = cid; self.title = title; self.iupacName = iupacName; self.formula = formula
        self.molecularWeight = molecularWeight; self.canonicalSMILES = canonicalSMILES; self.synonyms = synonyms
        self.casNumber = casNumber; self.depictionURL = depictionURL; self.thumbnail = thumbnail
        self.matchKind = matchKind; self.matchedQuery = matchedQuery
    }
}

public enum CASNumber {
    public static func isValid(_ s: String) -> Bool {
        let parts = s.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, (2...7).contains(parts[0].count), parts[1].count == 2, parts[2].count == 1,
              parts.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } }) else { return false }
        let digits = (String(parts[0]) + String(parts[1])).compactMap { $0.wholeNumberValue }
        var sum = 0
        for (i, d) in digits.reversed().enumerated() { sum += d * (i + 1) }
        return sum % 10 == Int(parts[2])!
    }
}

public enum LookupQueryKind: Equatable, Sendable {
    case cid(Int), cas(String), smiles(String), name(String)

    public static func classify(_ query: String) -> LookupQueryKind {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if let m = q.range(of: #"^cid\s*[:=]?\s*\d+$"#, options: [.regularExpression, .caseInsensitive]),
           let n = Int(q[m].filter { $0.isNumber }) { return .cid(n) }
        if !q.isEmpty, q.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(q) { return .cid(n) }
        if CASNumber.isValid(q) { return .cas(q) }
        // CAS-shaped but with a wrong check digit: a mistyped registry number, not SMILES. Search it as text.
        if q.range(of: #"^\d{2,7}-\d{2}-\d$"#, options: .regularExpression) != nil { return .name(q) }
        if !q.isEmpty, !q.contains(where: { $0.isWhitespace }), q.count > 2,
           q.range(of: #"^(\[[^\]]+\]|Br|Cl|[BCNOPSFIbcnops]|[=#$:/\\.\-+()@%]|\d)+$"#, options: .regularExpression) != nil {
            let special = q.contains { "=#()[]@/\\+%$:.".contains($0) } || q.contains { $0.isNumber }
            let allCaps = q.allSatisfy { $0.isUppercase }
            if special || allCaps { return .smiles(q) }
        }
        return .name(q)
    }
}

public final class PubChemThrottle: @unchecked Sendable {
    public static let shared = PubChemThrottle()
    private let lock = NSLock()
    private var next = Date.distantPast
    public let minInterval: TimeInterval
    public init(minInterval: TimeInterval = 0.2) { self.minInterval = minInterval }
    public func wait() async {
        lock.lock()
        let now = Date()
        let slot = max(now, next)
        next = slot.addingTimeInterval(minInterval)
        lock.unlock()
        let d = slot.timeIntervalSince(now)
        if d > 0 { try? await Task.sleep(nanoseconds: UInt64(d * 1_000_000_000)) }
    }
}

public struct LookupProperties: Sendable, Equatable {
    public var cid: Int
    public var title: String?
    public var iupacName: String?
    public var formula: String?
    public var molecularWeight: Double?
    public var smiles: String?
}

public actor NameLookup {
    /// Whether `term` contains `word` (lowercased) as a whole word ("m-xylene" contains "xylene").
    static func containsWord(_ term: String, _ word: String) -> Bool {
        term.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains { $0 == word }
    }

    /// Autocomplete terms with the simplest variants first: fewer words, then shorter (o-/m-/p-xylene before
    /// "2,5-Dichloro-p-xylene"); ties keep PubChem's order.
    static func rankedTerms(_ terms: [String], query: String) -> [String] {
        func words(_ t: String) -> Int { t.split(whereSeparator: { !$0.isLetter }).filter { $0.count > 1 }.count }
        return terms.enumerated().sorted { a, b in
            let (wa, wb) = (words(a.element), words(b.element))
            if wa != wb { return wa < wb }
            if a.element.count != b.element.count { return a.element.count < b.element.count }
            return a.offset < b.offset
        }.map(\.element)
    }


    public let timeout: TimeInterval
    public let thumbnailSize: Int
    public let useCactusFallback: Bool
    private let session: URLSession
    private let baseURL: URL
    private let throttle = PubChemThrottle.shared
    public private(set) var lastError: ComputeError?
    private var queryCache: [String: [LookupCandidate]] = [:]
    private var cidCache: [Int: LookupCandidate] = [:]

    public init(timeout: TimeInterval = 10, thumbnailSize: Int = 160, useCactusFallback: Bool = true,
                session: URLSession = .shared, baseURL: URL = URL(string: "https://pubchem.ncbi.nlm.nih.gov/rest")!) {
        self.timeout = timeout; self.thumbnailSize = thumbnailSize; self.useCactusFallback = useCactusFallback
        self.session = session; self.baseURL = baseURL
    }

    // MARK: Parsing helpers

    private static func json(_ data: Data) -> Any? { try? JSONSerialization.jsonObject(with: data) }

    public static func parseCIDs(_ data: Data) -> [Int] {
        guard let o = json(data) as? [String: Any], let l = o["IdentifierList"] as? [String: Any],
              let arr = l["CID"] as? [Any] else { return [] }
        return arr.compactMap { ($0 as? Int) ?? Int("\($0)") }.filter { $0 > 0 }
    }

    public static func parseProperties(_ data: Data) -> [LookupProperties] {
        guard let o = json(data) as? [String: Any], let t = o["PropertyTable"] as? [String: Any],
              let arr = t["Properties"] as? [[String: Any]] else { return [] }
        func str(_ d: [String: Any], _ k: String) -> String? {
            guard let v = d[k] else { return nil }
            let s = (v as? String) ?? "\(v)"
            return s.isEmpty ? nil : s
        }
        return arr.compactMap { d in
            guard let cid = (d["CID"] as? Int) ?? Int("\(d["CID"] ?? "")") else { return nil }
            let smiles = str(d, "ConnectivitySMILES") ?? str(d, "CanonicalSMILES") ?? str(d, "SMILES") ?? str(d, "IsomericSMILES")
            return LookupProperties(cid: cid, title: str(d, "Title"), iupacName: str(d, "IUPACName"), formula: str(d, "MolecularFormula"),
                                    molecularWeight: (d["MolecularWeight"] as? Double) ?? str(d, "MolecularWeight").flatMap { Double($0) },
                                    smiles: smiles)
        }
    }

    public static func parseSynonyms(_ data: Data) -> [Int: [String]] {
        guard let o = json(data) as? [String: Any], let l = o["InformationList"] as? [String: Any],
              let arr = l["Information"] as? [[String: Any]] else { return [:] }
        var out: [Int: [String]] = [:]
        for d in arr {
            guard let cid = (d["CID"] as? Int) ?? Int("\(d["CID"] ?? "")") else { continue }
            out[cid] = (d["Synonym"] as? [Any])?.compactMap { $0 as? String } ?? []
        }
        return out
    }

    public static func parseAutocomplete(_ data: Data) -> [String] {
        guard let o = json(data) as? [String: Any], let d = o["dictionary_terms"] as? [String: Any],
              let arr = d["compound"] as? [Any] else { return [] }
        return arr.compactMap { $0 as? String }
    }

    // MARK: HTTP

    private static var pathAllowed: CharacterSet {
        var a = CharacterSet.urlPathAllowed
        a.remove(charactersIn: "/?#[]@!$&'()*+,;=%")
        return a
    }
    private static func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: pathAllowed) ?? s }

    private static func mapError(_ e: Error) -> ComputeError {
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

    private func send(_ url: URL, form: String? = nil, retry: Bool = true) async throws -> Data {
        try Task.checkCancellation()
        await throttle.wait()
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        if let form {
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = form.data(using: .utf8)
        }
        do {
            let (data, resp) = try await session.data(for: req)
            if let h = resp as? HTTPURLResponse, h.statusCode != 200 {
                if h.statusCode == 503 && retry {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    return try await send(url, form: form, retry: false)
                }
                throw ComputeError.httpStatus(h.statusCode)
            }
            return data
        } catch { throw Self.mapError(error) }
    }

    private func pug(_ path: String) -> URL { URL(string: baseURL.absoluteString + "/pug/" + path)! }

    private func cids(forName name: String) async throws -> [Int] {
        guard let u = URL(string: baseURL.absoluteString + "/pug/compound/name/\(Self.enc(name))/cids/JSON") else { return [] }
        do { return Self.parseCIDs(try await send(u)) }
        catch ComputeError.httpStatus(let c) where c == 404 || c == 400 { return [] }
    }

    private func cids(forSMILES s: String) async throws -> [Int] {
        var form = CharacterSet.alphanumerics; form.insert(charactersIn: "-._~")
        let body = "smiles=" + (s.addingPercentEncoding(withAllowedCharacters: form) ?? s)
        do { return Self.parseCIDs(try await send(pug("compound/smiles/cids/JSON"), form: body)) }
        catch ComputeError.httpStatus(let c) where c == 404 || c == 400 { return [] }
    }

    private func autocompleteTerms(_ q: String, limit: Int) async throws -> [String] {
        guard let u = URL(string: baseURL.absoluteString + "/autocomplete/compound/\(Self.enc(q))/json?limit=\(limit)") else { return [] }
        do { return Self.parseAutocomplete(try await send(u)) }
        catch ComputeError.httpStatus { return [] }
    }

    // MARK: Public API

    public func autocomplete(_ prefix: String, limit: Int = 8) async -> [String] {
        let q = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        do { return Array(try await autocompleteTerms(q, limit: limit).prefix(limit)) }
        catch { lastError = Self.mapError(error); return [] }
    }

    public func suggest(_ query: String, limit: Int = 8) async -> [LookupCandidate] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        lastError = nil
        guard !q.isEmpty else { return [] }
        let key = q.lowercased()
        if let c = queryCache[key] { return Array(c.prefix(limit)) }
        do {
            var entries: [(cid: Int, kind: LookupMatchKind, matched: String)] = []
            func add(_ cid: Int, _ k: LookupMatchKind, _ m: String) {
                if !entries.contains(where: { $0.cid == cid }) { entries.append((cid, k, m)) }
            }
            switch LookupQueryKind.classify(q) {
            case .cid(let n):
                add(n, .cid, q)
            case .smiles(let s):
                for c in try await cids(forSMILES: s).prefix(limit) { add(c, .smiles, s) }
            case .cas(let s):
                for c in try await cids(forName: s).prefix(limit) { add(c, .cas, s) }
            case .name(let n):
                let found = try await cids(forName: n)
                if !found.isEmpty {
                    for (i, c) in found.enumerated() { add(c, (found.count > 1 && i > 0) ? .ambiguous : .exact, n) }
                    if found.count < 3 {
                        let terms = Self.rankedTerms(try await autocompleteTerms(n, limit: 20), query: n)
                        let ql = n.lowercased()
                        var resolved = 0
                        for t in terms where resolved < 4 {
                            guard t.lowercased() != ql, Self.containsWord(t, ql) else { continue }
                            if let c = try await cids(forName: t).first, !entries.contains(where: { $0.cid == c }) {
                                add(c, .ambiguous, t); resolved += 1
                            }
                        }
                    }
                } else {
                    // Not a PubChem name: either a class name ("xylene" -> o-/m-/p-xylene) or a typo ("cafeine").
                    let terms = Self.rankedTerms(try await autocompleteTerms(n, limit: 20), query: n)
                    let ql = n.lowercased()
                    let isomers = terms.filter { Self.containsWord($0, ql) }
                    let picks = isomers.isEmpty ? Array(terms.prefix(3)) : Array(isomers.prefix(5))
                    for t in picks {
                        if let c = try await cids(forName: t).first {
                            add(c, isomers.isEmpty ? .spellingSuggestion : .ambiguous, t)
                        }
                    }
                    if entries.isEmpty, useCactusFallback, let smi = try await cactusSMILES(n) {
                        for c in try await cids(forSMILES: smi).prefix(limit) { add(c, .exact, smi) }
                    }
                }
            }
            let capped = Array(entries.prefix(limit))
            let base = try await candidates(for: capped.map { $0.cid })
            var result: [LookupCandidate] = []
            for e in capped {
                if var c = base[e.cid] { c.matchKind = e.kind; c.matchedQuery = e.matched; result.append(c) }
            }
            if result.isEmpty { lastError = .notFound(q) }
            queryCache[key] = result
            return result
        } catch {
            lastError = Self.mapError(error)
            return []
        }
    }

    public func structure(for candidate: LookupCandidate) async throws -> Molecule {
        await throttle.wait()
        let client = PubChemClient(timeout: max(timeout, 15), session: session,
                                   baseURL: URL(string: baseURL.absoluteString + "/pug")!)
        var m = try await client.fetch(cid: candidate.cid).molecule
        m.title = candidate.title
        return m
    }

    // MARK: Internals

    private func cactusSMILES(_ name: String) async throws -> String? {
        guard let u = URL(string: "https://cactus.nci.nih.gov/chemical/structure/\(Self.enc(name))/smiles") else { return nil }
        do {
            let d = try await send(u)
            let s = String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return (s.isEmpty || s.contains("<") || s.contains(" ")) ? nil : s.components(separatedBy: .newlines).first
        } catch ComputeError.httpStatus { return nil }
    }

    private func depiction(_ cid: Int) -> URL {
        URL(string: baseURL.absoluteString + "/pug/compound/cid/\(cid)/PNG?image_size=\(thumbnailSize)x\(thumbnailSize)")!
    }

    private func candidates(for cidList: [Int]) async throws -> [Int: LookupCandidate] {
        var out: [Int: LookupCandidate] = [:]
        let missing = cidList.filter { cidCache[$0] == nil }
        if !missing.isEmpty {
            let list = missing.map(String.init).joined(separator: ",")
            let props = "Title,IUPACName,MolecularFormula,MolecularWeight,CanonicalSMILES,IsomericSMILES,ConnectivitySMILES,SMILES"
            var pmap: [Int: LookupProperties] = [:]
            do {
                let d = try await send(pug("compound/cid/\(list)/property/\(props)/JSON"))
                for p in Self.parseProperties(d) { pmap[p.cid] = p }
            } catch ComputeError.httpStatus { }
            var smap: [Int: [String]] = [:]
            do { smap = Self.parseSynonyms(try await send(pug("compound/cid/\(list)/synonyms/JSON"))) }
            catch ComputeError.httpStatus { }
            var built: [Int: LookupCandidate] = [:]
            for cid in missing {
                let p = pmap[cid]
                let syn = smap[cid] ?? []
                built[cid] = LookupCandidate(
                    cid: cid, title: p?.title ?? p?.iupacName ?? "CID \(cid)", iupacName: p?.iupacName, formula: p?.formula,
                    molecularWeight: p?.molecularWeight, canonicalSMILES: p?.smiles, synonyms: Array(syn.prefix(5)),
                    casNumber: syn.first(where: CASNumber.isValid), depictionURL: depiction(cid), thumbnail: nil,
                    matchKind: .exact, matchedQuery: "")
            }
            let thumbs: [Int: Data] = await withTaskGroup(of: (Int, Data?).self) { group in
                for cid in missing {
                    let u = depiction(cid)
                    group.addTask { [self] in (cid, try? await self.send(u)) }
                }
                var r: [Int: Data] = [:]
                for await (c, d) in group { if let d, !d.isEmpty { r[c] = d } }
                return r
            }
            for cid in missing { built[cid]?.thumbnail = thumbs[cid]; cidCache[cid] = built[cid] }
        }
        for c in cidList { out[c] = cidCache[c] }
        return out
    }
}
