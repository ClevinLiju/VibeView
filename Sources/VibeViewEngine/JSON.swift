import Foundation

/// A small, self-contained JSON value with its own parser and serializer, so the wire format is identical
/// on macOS and Windows (no NSNumber bridging differences between Foundation implementations).
enum JSON: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    subscript(key: String) -> JSON? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    var isNull: Bool { if case .null = self { return true }; return false }
    var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    var doubleValue: Double? {
        switch self {
        case .number(let d): return d
        case .string(let s): return Double(s)
        default: return nil
        }
    }
    var intValue: Int? {
        guard let d = doubleValue, d.isFinite, d == d.rounded(), abs(d) < 9.0e15 else { return nil }
        return Int(d)
    }
    var boolValue: Bool? {
        switch self {
        case .bool(let b): return b
        case .number(let d): return d != 0
        default: return nil
        }
    }
    var arrayValue: [JSON]? { if case .array(let a) = self { return a }; return nil }
    var objectValue: [String: JSON]? { if case .object(let o) = self { return o }; return nil }
}

// MARK: - Building values

protocol JSONConvertible { var json: JSON { get } }

extension JSON: JSONConvertible { var json: JSON { self } }
extension String: JSONConvertible { var json: JSON { .string(self) } }
extension Substring: JSONConvertible { var json: JSON { .string(String(self)) } }
extension Bool: JSONConvertible { var json: JSON { .bool(self) } }
extension Int: JSONConvertible { var json: JSON { .number(Double(self)) } }
extension Int32: JSONConvertible { var json: JSON { .number(Double(self)) } }
extension Double: JSONConvertible { var json: JSON { .number(self) } }
extension Float: JSONConvertible { var json: JSON { .number(Double(self)) } }
extension Optional: JSONConvertible where Wrapped: JSONConvertible {
    var json: JSON { self?.json ?? .null }
}
extension Array: JSONConvertible where Element: JSONConvertible {
    var json: JSON { .array(map(\.json)) }
}
extension Dictionary: JSONConvertible where Key == String, Value: JSONConvertible {
    var json: JSON { .object(mapValues(\.json)) }
}

/// `obj(["a": 1, "b": someOptional])`: nil values become JSON null.
func obj(_ d: [String: (any JSONConvertible)?]) -> JSON {
    var o: [String: JSON] = [:]
    o.reserveCapacity(d.count)
    for (k, v) in d { o[k] = v?.json ?? .null }
    return .object(o)
}

extension JSON: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
                ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral,
                ExpressibleByDictionaryLiteral {
    init(nilLiteral: ()) { self = .null }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(integerLiteral value: Int) { self = .number(Double(value)) }
    init(floatLiteral value: Double) { self = .number(value) }
    init(stringLiteral value: String) { self = .string(value) }
    init(arrayLiteral elements: JSON...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, JSON)...) {
        var o: [String: JSON] = [:]
        for (k, v) in elements { o[k] = v }
        self = .object(o)
    }
}

// MARK: - Serialization (single line, UTF-8)

extension JSON {
    func serialized() -> String {
        var s = ""
        s.reserveCapacity(256)
        write(into: &s)
        return s
    }

    private func write(into s: inout String) {
        switch self {
        case .null: s += "null"
        case .bool(let b): s += b ? "true" : "false"
        case .number(let d): s += JSON.format(d)
        case .string(let str): JSON.writeString(str, into: &s)
        case .array(let a):
            s += "["
            var first = true
            for v in a {
                if !first { s += "," }
                first = false
                v.write(into: &s)
            }
            s += "]"
        case .object(let o):
            s += "{"
            var first = true
            for k in o.keys.sorted() {
                if !first { s += "," }
                first = false
                JSON.writeString(k, into: &s)
                s += ":"
                o[k]!.write(into: &s)
            }
            s += "}"
        }
    }

    static func format(_ d: Double) -> String {
        guard d.isFinite else { return "null" }
        if d == d.rounded(), abs(d) < 1e15 { return String(Int64(d)) }
        return "\(d)"
    }

    private static func writeString(_ str: String, into s: inout String) {
        s += "\""
        for u in str.unicodeScalars {
            switch u {
            case "\"": s += "\\\""
            case "\\": s += "\\\\"
            case "\n": s += "\\n"
            case "\r": s += "\\r"
            case "\t": s += "\\t"
            case "\u{2028}": s += "\\u2028"
            case "\u{2029}": s += "\\u2029"
            default:
                if u.value < 0x20 {
                    let h = String(u.value, radix: 16)
                    s += "\\u" + String(repeating: "0", count: 4 - h.count) + h
                } else {
                    s.unicodeScalars.append(u)
                }
            }
        }
        s += "\""
    }
}

// MARK: - Parsing

struct JSONParseError: Error, CustomStringConvertible {
    var message: String
    var offset: Int
    var description: String { "\(message) at byte \(offset)" }
}

extension JSON {
    static func parse(_ text: String) throws -> JSON {
        var p = JSONParser(bytes: Array(text.utf8))
        p.skipWhitespace()
        let v = try p.value(depth: 0)
        p.skipWhitespace()
        guard p.i == p.bytes.count else { throw JSONParseError(message: "trailing characters", offset: p.i) }
        return v
    }

    static func parse(data: Data) throws -> JSON {
        try parse(String(decoding: data, as: UTF8.self))
    }

    /// Bridge to Codable: encode a value with JSONEncoder and re-read it as `JSON`.
    static func encode<T: Encodable>(_ value: T) throws -> JSON {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        return try parse(data: enc.encode(value))
    }

    /// Bridge to Codable: decode this value with JSONDecoder.
    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try dec.decode(T.self, from: Data(serialized().utf8))
    }
}

private struct JSONParser {
    let bytes: [UInt8]
    var i = 0

    init(bytes: [UInt8]) { self.bytes = bytes }

    mutating func skipWhitespace() {
        while i < bytes.count, bytes[i] == 0x20 || bytes[i] == 0x0A || bytes[i] == 0x0D || bytes[i] == 0x09 { i += 1 }
    }

    func fail(_ m: String) -> JSONParseError { JSONParseError(message: m, offset: i) }

    mutating func value(depth: Int) throws -> JSON {
        guard depth < 512 else { throw fail("nesting too deep") }
        guard i < bytes.count else { throw fail("unexpected end of input") }
        switch bytes[i] {
        case UInt8(ascii: "{"):
            i += 1
            var o: [String: JSON] = [:]
            skipWhitespace()
            if i < bytes.count, bytes[i] == UInt8(ascii: "}") { i += 1; return .object(o) }
            while true {
                skipWhitespace()
                guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else { throw fail("expected object key") }
                let k = try string()
                skipWhitespace()
                guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { throw fail("expected ':'") }
                i += 1
                skipWhitespace()
                o[k] = try value(depth: depth + 1)
                skipWhitespace()
                guard i < bytes.count else { throw fail("unterminated object") }
                if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                if bytes[i] == UInt8(ascii: "}") { i += 1; return .object(o) }
                throw fail("expected ',' or '}'")
            }
        case UInt8(ascii: "["):
            i += 1
            var a: [JSON] = []
            skipWhitespace()
            if i < bytes.count, bytes[i] == UInt8(ascii: "]") { i += 1; return .array(a) }
            while true {
                skipWhitespace()
                a.append(try value(depth: depth + 1))
                skipWhitespace()
                guard i < bytes.count else { throw fail("unterminated array") }
                if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                if bytes[i] == UInt8(ascii: "]") { i += 1; return .array(a) }
                throw fail("expected ',' or ']'")
            }
        case UInt8(ascii: "\""):
            return .string(try string())
        case UInt8(ascii: "t"): try literal("true"); return .bool(true)
        case UInt8(ascii: "f"): try literal("false"); return .bool(false)
        case UInt8(ascii: "n"): try literal("null"); return .null
        default:
            return .number(try number())
        }
    }

    mutating func literal(_ s: String) throws {
        let u = Array(s.utf8)
        guard i + u.count <= bytes.count, Array(bytes[i..<(i + u.count)]) == u else { throw fail("invalid literal") }
        i += u.count
    }

    mutating func number() throws -> Double {
        let start = i
        while i < bytes.count {
            let c = bytes[i]
            if (c >= 0x30 && c <= 0x39) || c == UInt8(ascii: "-") || c == UInt8(ascii: "+") || c == UInt8(ascii: ".")
                || c == UInt8(ascii: "e") || c == UInt8(ascii: "E") { i += 1 } else { break }
        }
        guard i > start, let d = Double(String(decoding: bytes[start..<i], as: UTF8.self)) else {
            i = start
            throw fail("invalid number")
        }
        return d
    }

    mutating func hex4() throws -> UInt32 {
        guard i + 4 <= bytes.count, let v = UInt32(String(decoding: bytes[i..<(i + 4)], as: UTF8.self), radix: 16) else {
            throw fail("invalid \\u escape")
        }
        i += 4
        return v
    }

    mutating func string() throws -> String {
        i += 1 // opening quote
        var out = [UInt8]()
        while true {
            guard i < bytes.count else { throw fail("unterminated string") }
            let c = bytes[i]
            if c == UInt8(ascii: "\"") { i += 1; break }
            if c == UInt8(ascii: "\\") {
                i += 1
                guard i < bytes.count else { throw fail("unterminated escape") }
                let e = bytes[i]
                i += 1
                switch e {
                case UInt8(ascii: "\""): out.append(0x22)
                case UInt8(ascii: "\\"): out.append(0x5C)
                case UInt8(ascii: "/"): out.append(0x2F)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "u"):
                    var cp = try hex4()
                    if (0xD800...0xDBFF).contains(cp), i + 6 <= bytes.count, bytes[i] == UInt8(ascii: "\\"), bytes[i + 1] == UInt8(ascii: "u") {
                        i += 2
                        let lo = try hex4()
                        if (0xDC00...0xDFFF).contains(lo) { cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00) } else { cp = 0xFFFD }
                    }
                    let scalar = Unicode.Scalar(cp) ?? "\u{FFFD}"
                    out.append(contentsOf: Array(String(Character(scalar)).utf8))
                default: throw fail("invalid escape")
                }
            } else {
                out.append(c)
                i += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }
}

// MARK: - Binary arrays (base64, little-endian)

enum Binary {
    static func float32(_ values: [Float]) -> String {
        var v = values
        #if _endian(big)
        v = v.map { Float(bitPattern: $0.bitPattern.byteSwapped) }
        #endif
        return v.withUnsafeBufferPointer { Data(buffer: $0) }.base64EncodedString()
    }

    static func float32(_ values: [Double]) -> String { float32(values.map(Float.init)) }

    static func uint32(_ values: [UInt32]) -> String {
        var v = values
        #if _endian(big)
        v = v.map { $0.byteSwapped }
        #endif
        return v.withUnsafeBufferPointer { Data(buffer: $0) }.base64EncodedString()
    }

    static func flatten(_ v: [SIMD3<Float>]) -> [Float] {
        var out = [Float]()
        out.reserveCapacity(v.count * 3)
        for p in v { out.append(p.x); out.append(p.y); out.append(p.z) }
        return out
    }

    static func flatten(_ v: [SIMD4<Float>]) -> [Float] {
        var out = [Float]()
        out.reserveCapacity(v.count * 4)
        for p in v { out.append(p.x); out.append(p.y); out.append(p.z); out.append(p.w) }
        return out
    }

    static func decodeFloat32(_ b64: String) -> [Float]? {
        guard let d = Data(base64Encoded: b64), d.count % 4 == 0 else { return nil }
        return d.withUnsafeBytes { raw in
            (0..<(d.count / 4)).map { k in Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: k * 4, as: UInt32.self))) }
        }
    }
}
