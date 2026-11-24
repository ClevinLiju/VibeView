import Foundation
import MolCore

/// Atom selection expression. In command text atom numbers and fragment numbers are 1-BASED;
/// `evaluate` returns 0-BASED indices (Set<Int>) suitable for `Molecule.atoms`.
///
/// Grammar (keywords case-insensitive):
/// ```
/// expr    := and ( ("|" | "or") and )*
/// and     := unary ( ("&" | "and") unary )*
/// unary   := ("~" | "not") unary | primary
/// primary := "(" expr ")" | all | none | sel | selection | fragment N
///          | within R of unary | list
/// list    := item ("," item)*      item := N | N-M | ElementSymbol
/// ```
public indirect enum AtomSpec: Sendable, Equatable {
    case all, none, selection
    /// Atomic numbers.
    case elements(Set<Int>)
    /// 0-based indices.
    case indices(Set<Int>)
    /// 1-based fragment number.
    case fragment(Int)
    case within(Double, AtomSpec)
    case union(AtomSpec, AtomSpec)
    case intersection(AtomSpec, AtomSpec)
    case not(AtomSpec)

    public static func parse(_ words: [String]) throws -> AtomSpec {
        var p = SpecParser(tokens: try SpecParser.lex(words.joined(separator: " ")))
        if p.tokens.isEmpty { throw CommandError("empty atom specification") }
        let e = try p.expr()
        if let t = p.peek { throw CommandError("unexpected '\(t)' in atom specification") }
        return e
    }

    public static func parse(_ text: String) throws -> AtomSpec { try parse([text]) }

    /// Evaluates against `m`; out-of-range explicit indices are ignored (use `evaluateChecked` to reject them).
    public func evaluate(in m: Molecule, selection sel: Set<Int>) -> Set<Int> {
        switch self {
        case .all: return Set(0..<m.atoms.count)
        case .none: return []
        case .selection: return sel.filter { $0 >= 0 && $0 < m.atoms.count }
        case .elements(let zs): return Set(m.atoms.indices.filter { zs.contains(m.atoms[$0].atomicNumber) })
        case .indices(let s): return s.filter { $0 >= 0 && $0 < m.atoms.count }
        case .fragment(let n):
            let f = m.fragments()
            return n >= 1 && n <= f.count ? Set(f[n - 1]) : []
        case .within(let r, let sub):
            let base = sub.evaluate(in: m, selection: sel)
            let r2 = r * r
            let bp = base.map { m.atoms[$0].position }
            var out = base
            for i in m.atoms.indices where !base.contains(i) {
                let p = m.atoms[i].position
                for q in bp {
                    let d = p - q
                    if (d * d).sum() <= r2 { out.insert(i); break }
                }
            }
            return out
        case .union(let a, let b): return a.evaluate(in: m, selection: sel).union(b.evaluate(in: m, selection: sel))
        case .intersection(let a, let b): return a.evaluate(in: m, selection: sel).intersection(b.evaluate(in: m, selection: sel))
        case .not(let a): return Set(0..<m.atoms.count).subtracting(a.evaluate(in: m, selection: sel))
        }
    }

    /// Like `evaluate` but throws when an explicit atom or fragment number does not exist (messages use 1-based numbers).
    public func evaluateChecked(in m: Molecule, selection sel: Set<Int>) throws -> Set<Int> {
        try validate(m)
        return evaluate(in: m, selection: sel)
    }

    private func validate(_ m: Molecule) throws {
        switch self {
        case .indices(let s):
            if let bad = s.filter({ $0 < 0 || $0 >= m.atoms.count }).min() {
                throw CommandError("atom \(bad + 1) does not exist (molecule has \(m.atoms.count) atoms)")
            }
        case .fragment(let n):
            let c = m.fragments().count
            if n < 1 || n > c { throw CommandError("fragment \(n) does not exist (molecule has \(c) fragments)") }
        case .within(_, let a), .not(let a): try a.validate(m)
        case .union(let a, let b), .intersection(let a, let b): try a.validate(m); try b.validate(m)
        default: break
        }
    }
}

struct SpecParser {
    var tokens: [String]
    var pos = 0
    init(tokens: [String]) { self.tokens = tokens }
    var peek: String? { pos < tokens.count ? tokens[pos] : nil }
    mutating func next() -> String? { defer { pos += 1 }; return peek }

    static func lex(_ s: String) throws -> [String] {
        var out: [String] = []
        var cur = ""
        for c in s {
            if c.isWhitespace { if !cur.isEmpty { out.append(cur); cur = "" } }
            else if "()|&~".contains(c) { if !cur.isEmpty { out.append(cur); cur = "" }; out.append(String(c)) }
            else { cur.append(c) }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    func isKeyword(_ t: String?, _ k: String...) -> Bool {
        guard let t = t?.lowercased() else { return false }
        return k.contains(t)
    }

    mutating func expr() throws -> AtomSpec {
        var l = try and()
        while isKeyword(peek, "|", "or") { pos += 1; l = .union(l, try and()) }
        return l
    }
    mutating func and() throws -> AtomSpec {
        var l = try unary()
        while isKeyword(peek, "&", "and") { pos += 1; l = .intersection(l, try unary()) }
        return l
    }
    mutating func unary() throws -> AtomSpec {
        if isKeyword(peek, "~", "not") { pos += 1; return .not(try unary()) }
        return try primary()
    }
    mutating func primary() throws -> AtomSpec {
        guard let t = next() else { throw CommandError("atom specification ended unexpectedly") }
        let l = t.lowercased()
        switch l {
        case "(":
            let e = try expr()
            guard next() == ")" else { throw CommandError("missing ')' in atom specification") }
            return e
        case "all": return .all
        case "none": return .none
        case "sel", "selection": return .selection
        case "fragment":
            guard let n = next(), let k = Int(n), k >= 1 else { throw CommandError("'fragment' needs a number starting at 1") }
            return .fragment(k)
        case "within":
            guard let r = next(), let d = Double(r), d >= 0 else { throw CommandError("'within' needs a distance in Å") }
            guard isKeyword(next(), "of") else { throw CommandError("expected 'of' after 'within \(r)'") }
            return .within(d, try unary())
        case ")", "|", "&", "of", "or", "and":
            throw CommandError("unexpected '\(t)' in atom specification")
        default:
            return try list(t)
        }
    }

    func list(_ word: String) throws -> AtomSpec {
        var idx = Set<Int>(), zs = Set<Int>()
        var parts: [AtomSpec] = []
        for item in word.split(separator: ",", omittingEmptySubsequences: true).map(String.init) {
            if let n = Int(item) {
                guard n >= 1 else { throw CommandError("atom numbers start at 1 (got \(n))") }
                idx.insert(n - 1)
            } else if let dash = item.firstIndex(of: "-"), dash != item.startIndex,
                      let a = Int(item[..<dash]), let b = Int(item[item.index(after: dash)...]) {
                guard a >= 1, b >= a else { throw CommandError("bad atom range '\(item)' (numbers start at 1, ranges ascend)") }
                idx.formUnion((a - 1)...(b - 1))
            } else if let z = Elements.atomicNumber(symbol: item), z > 0 {
                zs.insert(z)
            } else {
                throw CommandError("unknown atom specifier '\(item)'")
            }
        }
        if !idx.isEmpty { parts.append(.indices(idx)) }
        if !zs.isEmpty { parts.append(.elements(zs)) }
        guard var r = parts.first else { throw CommandError("empty atom list '\(word)'") }
        for p in parts.dropFirst() { r = .union(r, p) }
        return r
    }
}
