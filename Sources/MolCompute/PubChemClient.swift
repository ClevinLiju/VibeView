import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import MolCore
import MolIO
import MolBuild

public struct PubChemCompound: Sendable {
    public var cid: Int?
    public var title: String
    public var molecule: Molecule
    public var is3D: Bool
    public var sdf: String
}

public struct PubChemClient: Sendable {
    public var timeout: TimeInterval
    public var session: URLSession
    public var baseURL: URL

    public init(timeout: TimeInterval = 15, session: URLSession = .shared,
                baseURL: URL = URL(string: "https://pubchem.ncbi.nlm.nih.gov/rest/pug")!) {
        self.timeout = timeout; self.session = session; self.baseURL = baseURL
    }

    public func fetch(name: String) async throws -> PubChemCompound {
        try await fetch(domain: "name", value: name, query: name, post: false)
    }
    public func fetch(cid: Int) async throws -> PubChemCompound {
        try await fetch(domain: "cid", value: String(cid), query: "CID \(cid)", post: false)
    }
    public func fetch(smiles: String) async throws -> PubChemCompound {
        try await fetch(domain: "smiles", value: smiles, query: smiles, post: true)
    }

    private func fetch(domain: String, value: String, query: String, post: Bool) async throws -> PubChemCompound {
        for (i, type) in ["3d", "2d"].enumerated() {
            do {
                let text = try await request(domain: domain, value: value, recordType: type, post: post)
                return try Self.parseSDF(text, fallbackTitle: domain == "name" ? value : nil, is3D: type == "3d")
            } catch ComputeError.httpStatus(let c) where (c == 404 || c == 400) && i == 0 {
                continue
            } catch ComputeError.httpStatus(let c) where c == 404 || c == 400 {
                throw ComputeError.notFound(query)
            }
        }
        throw ComputeError.notFound(query)
    }

    private func request(domain: String, value: String, recordType: String, post: Bool) async throws -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#[]@!$&'()*+,;=%")
        var req: URLRequest
        if post {
            let u = URL(string: baseURL.absoluteString + "/compound/\(domain)/SDF?record_type=\(recordType)")!
            req = URLRequest(url: u)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            var form = CharacterSet.alphanumerics; form.insert(charactersIn: "-._~")
            req.httpBody = "\(domain)=\(value.addingPercentEncoding(withAllowedCharacters: form) ?? value)".data(using: .utf8)
        } else {
            let enc = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            guard let u = URL(string: baseURL.absoluteString + "/compound/\(domain)/\(enc)/SDF?record_type=\(recordType)") else {
                throw ComputeError.notFound(value)
            }
            req = URLRequest(url: u)
        }
        req.timeoutInterval = timeout
        do {
            let (data, resp) = try await session.portableData(for: req)
            if let h = resp as? HTTPURLResponse, h.statusCode != 200 { throw ComputeError.httpStatus(h.statusCode) }
            return String(decoding: data, as: UTF8.self)
        } catch let e as ComputeError { throw e
        } catch let e as URLError {
            switch e.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost, .dataNotAllowed:
                throw ComputeError.offline
            case .timedOut: throw ComputeError.timeout
            case .cancelled: throw ComputeError.cancelled
            default: throw ComputeError.offline
            }
        } catch is CancellationError { throw ComputeError.cancelled }
    }

    /// Parse a PubChem SDF. 2D records are embedded (z-perturbation + UFF) and flagged is3D = false.
    public static func parseSDF(_ text: String, fallbackTitle: String? = nil, is3D: Bool? = nil) throws -> PubChemCompound {
        let records: [SDFRecord]
        do { records = try MDLMolFormat.parse(text) } catch { throw ComputeError.parse("\(error)") }
        guard let rec = records.first, !rec.molecule.atoms.isEmpty else { throw ComputeError.parse("SDF has no atoms") }
        var mol = rec.molecule
        let flat = Set(mol.atoms.map { Int(($0.position.z * 1000).rounded()) }).count <= 1
        let threeD = is3D ?? !flat
        if !threeD { mol = embed2D(mol) }
        let cid = (rec.value(for: "PUBCHEM_COMPOUND_CID") ?? rec.value(for: "PUBCHEM_CID")).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let iupac = rec.value(for: "PUBCHEM_IUPAC_NAME")?.trimmingCharacters(in: .whitespacesAndNewlines)
        var title = fallbackTitle ?? (iupac?.isEmpty == false ? iupac! : mol.title)
        if title.isEmpty, let c = cid { title = "CID \(c)" }
        mol.title = title
        return PubChemCompound(cid: cid, title: title, molecule: mol, is3D: threeD, sdf: text)
    }

    /// Deterministic z-perturbation followed by UFF minimization, so planar 2D coordinates can pucker.
    public static func embed2D(_ m: Molecule) -> Molecule {
        var p = m
        for i in 0..<p.atoms.count {
            let s = sin(Double(i) * 12.9898 + 1.0) * 43758.5453
            p.atoms[i].position.z += (s - s.rounded(.down) - 0.5) * 0.3
        }
        return Cleanup.minimize(p, maxSteps: 1000).molecule
    }
}
