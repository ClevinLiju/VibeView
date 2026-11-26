import Foundation
import MolCore
import MolIO
import MolBuild
import MolCompute
import MolCommand
import MolAnalysis

/// Protocol version reported by `engine.info` (bump on breaking changes).
let protocolVersion = 1
let engineVersion = "1.0.0"

var platformName: String {
    #if os(Windows)
    return "windows"
    #elseif os(macOS)
    return "macos"
    #elseif os(Linux)
    return "linux"
    #else
    return "unknown"
    #endif
}

/// An error sent back as `{"id":…, "error": {"code":…, "message":…}}`.
struct RPCError: Error, CustomStringConvertible {
    var code: String
    var message: String
    var description: String { "\(code): \(message)" }

    static func badRequest(_ m: String) -> RPCError { RPCError(code: "bad_request", message: m) }
    static func notFound(_ m: String) -> RPCError { RPCError(code: "not_found", message: m) }
    static func parse(_ m: String) -> RPCError { RPCError(code: "parse_error", message: m) }
    static func io(_ m: String) -> RPCError { RPCError(code: "io_error", message: m) }
    static func notInstalled(_ m: String) -> RPCError { RPCError(code: "not_installed", message: m) }
    static func internalError(_ m: String) -> RPCError { RPCError(code: "internal", message: m) }
    static let cancelled = RPCError(code: "cancelled", message: "the request was cancelled")

    /// Maps any error thrown by the core modules onto a protocol error code.
    static func from(_ error: Error) -> RPCError {
        if let e = error as? RPCError { return e }
        if error is CancellationError { return .cancelled }
        if let e = error as? ComputeError {
            let msg = e.errorDescription ?? "\(e)"
            switch e {
            case .notInstalled: return RPCError(code: "not_installed", message: msg)
            case .offline: return RPCError(code: "offline", message: msg)
            case .timeout: return RPCError(code: "timeout", message: msg)
            case .notFound: return RPCError(code: "not_found", message: msg)
            case .cancelled: return .cancelled
            case .parse: return RPCError(code: "parse_error", message: msg)
            case .httpStatus, .processFailed: return RPCError(code: "io_error", message: msg)
            }
        }
        if let e = error as? MolIOError {
            switch e {
            case .unreadable(let s): return .io("cannot read \(s)")
            case .parse: return .parse(e.description)
            case .unsupported: return .badRequest(e.description)
            }
        }
        if let e = error as? BuildError { return .badRequest(e.errorDescription ?? "\(e)") }
        if let e = error as? CommandError { return .badRequest(e.message) }
        if let e = error as? OrbitalSurfaceError { return .badRequest(e.description) }
        if let e = error as? JSONParseError { return .parse(e.description) }
        if error is DecodingError { return .badRequest("invalid parameters: \(error)") }
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain || ns.domain == NSPOSIXErrorDomain {
            return .io(ns.localizedDescription)
        }
        return .internalError("\(error)")
    }

    var json: JSON { ["code": .string(code), "message": .string(message)] }
}

/// Typed access to a request's `params` object.
struct Params {
    let raw: [String: JSON]
    init(_ j: JSON?) { raw = j?.objectValue ?? [:] }

    func has(_ k: String) -> Bool { if let v = raw[k], !v.isNull { return true }; return false }
    subscript(_ k: String) -> JSON? { raw[k].flatMap { $0.isNull ? nil : $0 } }

    func string(_ k: String) throws -> String {
        guard let s = self[k]?.stringValue else { throw RPCError.badRequest("missing string parameter '\(k)'") }
        return s
    }
    func optString(_ k: String) -> String? { self[k]?.stringValue }

    func int(_ k: String) throws -> Int {
        guard let v = self[k]?.intValue else { throw RPCError.badRequest("missing integer parameter '\(k)'") }
        return v
    }
    func optInt(_ k: String) -> Int? { self[k]?.intValue }

    func double(_ k: String) throws -> Double {
        guard let v = self[k]?.doubleValue, v.isFinite else { throw RPCError.badRequest("missing number parameter '\(k)'") }
        return v
    }
    func optDouble(_ k: String) -> Double? { self[k]?.doubleValue.flatMap { $0.isFinite ? $0 : nil } }

    func bool(_ k: String, default d: Bool) -> Bool { self[k]?.boolValue ?? d }
    func optBool(_ k: String) -> Bool? { self[k]?.boolValue }

    func ints(_ k: String) throws -> [Int] {
        guard let a = self[k]?.arrayValue else { throw RPCError.badRequest("missing integer array parameter '\(k)'") }
        return try a.map {
            guard let v = $0.intValue else { throw RPCError.badRequest("'\(k)' must contain integers") }
            return v
        }
    }
    func optInts(_ k: String) throws -> [Int]? { has(k) ? try ints(k) : nil }

    func vec3(_ k: String) throws -> Vec3 {
        guard let v = try optVec3(k) else { throw RPCError.badRequest("missing [x,y,z] parameter '\(k)'") }
        return v
    }
    func optVec3(_ k: String) throws -> Vec3? {
        guard let j = self[k] else { return nil }
        return try JSONShapes.vec3(j, name: k)
    }
    func object(_ k: String) throws -> Params {
        guard let o = self[k]?.objectValue else { throw RPCError.badRequest("missing object parameter '\(k)'") }
        return Params(.object(o))
    }
    func optObject(_ k: String) -> Params? { self[k]?.objectValue.map { Params(.object($0)) } }

    func docId() throws -> String {
        if let s = self["docId"]?.stringValue { return s }
        if let n = self["docId"]?.intValue { return String(n) }
        throw RPCError.badRequest("missing 'docId'")
    }
}

/// Conversions between core types and the protocol's shared JSON shapes.
enum JSONShapes {
    static func vec3(_ v: Vec3) -> JSON { .array([.number(v.x), .number(v.y), .number(v.z)]) }

    static func vec3(_ j: JSON, name: String) throws -> Vec3 {
        guard let a = j.arrayValue, a.count == 3, let x = a[0].doubleValue, let y = a[1].doubleValue, let z = a[2].doubleValue,
              x.isFinite, y.isFinite, z.isFinite else {
            throw RPCError.badRequest("'\(name)' must be [x, y, z]")
        }
        return Vec3(x, y, z)
    }

    static func bondOrder(_ j: JSON?) throws -> BondOrder {
        guard let j else { return .single }
        if let s = j.stringValue {
            switch s.lowercased() {
            case "single", "1": return .single
            case "double", "2": return .double
            case "triple", "3": return .triple
            case "aromatic", "1.5": return .aromatic
            default: throw RPCError.badRequest("unknown bond order '\(s)'")
            }
        }
        guard let d = j.doubleValue, let o = BondOrder(rawValue: d) else { throw RPCError.badRequest("bond order must be 1, 1.5, 2 or 3") }
        return o
    }

    static func molecule(_ m: Molecule) -> JSON {
        var atoms: [JSON] = []
        atoms.reserveCapacity(m.atoms.count)
        for a in m.atoms {
            atoms.append(.object([
                "z": .number(Double(a.atomicNumber)),
                "symbol": .string(Elements.symbol(a.atomicNumber)),
                "pos": vec3(a.position),
                "charge": .number(a.charge),
                "label": a.label.map { .string($0) } ?? .null,
            ]))
        }
        let bonds: [JSON] = m.bonds.map {
            .object(["a": .number(Double($0.a)), "b": .number(Double($0.b)), "order": .number($0.order.rawValue)])
        }
        return .object([
            "title": .string(m.title), "charge": .number(Double(m.charge)), "multiplicity": .number(Double(m.multiplicity)),
            "atoms": .array(atoms), "bonds": .array(bonds),
        ])
    }

    static func molecule(from j: JSON) throws -> Molecule {
        guard let o = j.objectValue else { throw RPCError.badRequest("'molecule' must be an object") }
        var m = Molecule()
        m.title = o["title"]?.stringValue ?? ""
        m.charge = o["charge"]?.intValue ?? 0
        m.multiplicity = max(1, o["multiplicity"]?.intValue ?? 1)
        for (i, aj) in (o["atoms"]?.arrayValue ?? []).enumerated() {
            guard let ao = aj.objectValue else { throw RPCError.badRequest("atom \(i) must be an object") }
            var z = ao["z"]?.intValue
            if z == nil, let s = ao["symbol"]?.stringValue { z = Elements.atomicNumber(symbol: s) }
            guard let zz = z, zz >= 0, zz < Elements.all.count else { throw RPCError.badRequest("atom \(i) has no valid 'z' or 'symbol'") }
            guard let pj = ao["pos"] else { throw RPCError.badRequest("atom \(i) has no 'pos'") }
            var a = Atom(id: i, atomicNumber: zz, position: try vec3(pj, name: "atoms[\(i)].pos"))
            a.charge = ao["charge"]?.doubleValue ?? 0
            a.label = ao["label"]?.stringValue
            m.atoms.append(a)
        }
        for (k, bj) in (o["bonds"]?.arrayValue ?? []).enumerated() {
            guard let a = bj["a"]?.intValue, let b = bj["b"]?.intValue, a != b,
                  m.atoms.indices.contains(a), m.atoms.indices.contains(b) else {
                throw RPCError.badRequest("bond \(k) has invalid atom indices")
            }
            m.bonds.append(Bond(a, b, order: try bondOrder(bj["order"])))
        }
        m.normalizeBonds()
        return m
    }

    static func mesh(_ m: IsoSurfaceMesh) -> JSON {
        var o: [String: JSON] = [
            "sign": .number(Double(m.sign.rawValue)),
            "isovalue": .number(m.isovalue),
            "vertexCount": .number(Double(m.vertices.count)),
            "triangleCount": .number(Double(m.indices.count / 3)),
            "positionsB64": .string(Binary.float32(Binary.flatten(m.vertices))),
            "normalsB64": .string(Binary.float32(Binary.flatten(m.normals))),
            "indicesB64": .string(Binary.uint32(m.indices)),
            "colorsB64": m.vertexColors.map { .string(Binary.float32(Binary.flatten($0))) } ?? .null,
        ]
        if let s = m.vertexScalars { o["scalarsB64"] = .string(Binary.float32(s)) }
        if let s = m.vertexScalars, let lo = s.min(), let hi = s.max() { o["scalarRange"] = [.number(Double(lo)), .number(Double(hi))] }
        return .object(o)
    }

    static func spectrum(_ s: Spectrum) -> JSON {
        .object([
            "xLabel": .string(s.xLabel), "yLabel": .string(s.yLabel), "xAxisReversed": .bool(s.xAxisReversed),
            "pointCount": .number(Double(s.points.count)),
            "xB64": .string(Binary.float32(s.points.map(\.x))),
            "yB64": .string(Binary.float32(s.points.map(\.y))),
            "sticks": .array(s.sticks.map {
                .object(["x": .number($0.x), "height": .number($0.height), "label": $0.label.map { .string($0) } ?? .null,
                         "sourceIndex": .number(Double($0.sourceIndex))])
            }),
        ])
    }
}
