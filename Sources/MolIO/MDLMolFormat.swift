import Foundation
import MolCore

public struct SDFProperty: Sendable, Codable, Equatable, Hashable {
    public var name: String
    public var value: String
    public init(name: String, value: String) { self.name = name; self.value = value }
}

public struct SDFRecord: Sendable, Codable, Equatable {
    public var molecule: Molecule
    /// Data items ("> <NAME>") in file order.
    public var properties: [SDFProperty]
    public init(molecule: Molecule, properties: [SDFProperty] = []) {
        self.molecule = molecule; self.properties = properties
    }
    public func value(for name: String) -> String? { properties.first { $0.name == name }?.value }
}

/// MDL CTfile V2000 MOL / SDF reader and writer. V3000 is rejected with `MolIOError.unsupported`.
///
/// Charges: atom-block charge codes and `M  CHG` are summed into `Molecule.charge` (`M  CHG`
/// overrides the atom-block codes). Radicals (`M  RAD`, code 4) set `multiplicity`. The writer, which
/// only has a net charge, places `M  CHG` on a single heuristic atom (first N for cations, first O
/// for anions, else atom 1) so the net charge round-trips. Coordinates have 4 decimals.
public enum MDLMolFormat {
    private static func fail(_ line: Int?, _ msg: String) -> MolIOError {
        .parse(format: "mdl", line: line, message: msg)
    }

    public static func read(url: URL) throws -> [SDFRecord] { try parse(try readText(url)) }

    private static func slice(_ s: Substring, _ from: Int, _ to: Int) -> String {
        let u = Array(s.utf8)
        guard from < u.count else { return "" }
        return String(decoding: u[from..<min(to, u.count)], as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }

    public static func parse(_ text: String) throws -> [SDFRecord] {
        let lines = splitLines(text)
        var records: [SDFRecord] = []
        var i = 0
        while i < lines.count {
            if !records.isEmpty, lines[i...].allSatisfy({ $0.allSatisfy { $0 == " " || $0 == "\t" } }) { break }
            let rec: SDFRecord, next: Int
            do {
                (rec, next) = try parseRecord(lines, start: i)
            } catch let e as MolIOError {
                // Many SD writers emit blank separator lines after "$$$$". Strictly, the next record's
                // header starts right after the terminator (so a blank title line is legal). Only when
                // the strict reading fails do we retry from the first non-blank line.
                guard !records.isEmpty, case .parse = e else { throw e }
                var j = i
                while j < lines.count, lines[j].allSatisfy({ $0 == " " || $0 == "\t" }) { j += 1 }
                guard j > i, j < lines.count else { throw e }
                (rec, next) = try parseRecord(lines, start: j)
            }
            records.append(rec)
            i = next
        }
        if records.isEmpty { throw fail(nil, "no molecule records found") }
        return records
    }

    private static func parseRecord(_ lines: [Substring], start s: Int) throws -> (SDFRecord, Int) {
        guard s + 3 < lines.count else { throw fail(lines.count, "truncated header") }
        let title = lines[s].trimmingCharacters(in: .whitespaces)
        let counts = lines[s + 3]
        if counts.contains("V3000") { throw MolIOError.unsupported("MDL V3000 CTfile") }
        let cu = Array(counts.utf8)
        var nA: Int? = nil, nB: Int? = nil
        if cu.count >= 6 { nA = Int(slice(counts, 0, 3)); nB = Int(slice(counts, 3, 6)) }
        if nA == nil || nB == nil {
            let t = tokens(counts)
            if t.count >= 2 { nA = Int(t[0]); nB = Int(t[1]) }
        }
        guard let na = nA, let nb = nB, na >= 0, nb >= 0, na <= 999_999, nb <= 999_999 else {
            throw fail(s + 4, "bad counts line")
        }
        var p = s + 4
        guard p + na + nb <= lines.count else { throw fail(lines.count, "truncated atom/bond block") }
        var atoms: [Atom] = []
        atoms.reserveCapacity(na)
        var chargeSum = 0
        var radicals = 0
        var atomCharges = [Int](repeating: 0, count: na)
        for k in 0..<na {
            let l = lines[p + k]
            var x: Double?, y: Double?, z: Double?, sym = "", code = 0
            let u = l.utf8.count
            if u >= 34 {
                x = Double(slice(l, 0, 10)); y = Double(slice(l, 10, 20)); z = Double(slice(l, 20, 30))
                sym = slice(l, 31, 34)
                code = Int(slice(l, 36, 39)) ?? 0
            }
            if x == nil || y == nil || z == nil || sym.isEmpty {
                let t = tokens(l)
                guard t.count >= 4, let tx = Double(t[0]), let ty = Double(t[1]), let tz = Double(t[2]) else {
                    throw fail(p + k + 1, "bad atom line")
                }
                x = tx; y = ty; z = tz; sym = String(t[3])
                code = t.count > 5 ? (Int(t[5]) ?? 0) : 0
            }
            guard let xx = x, let yy = y, let zz = z, xx.isFinite, yy.isFinite, zz.isFinite else {
                throw fail(p + k + 1, "bad coordinates")
            }
            guard let zn = IOElements.atomicNumber(exact: sym) else {
                throw fail(p + k + 1, "unsupported atom symbol '\(sym)'")
            }
            let ch: Int
            switch code {
            case 1: ch = 3
            case 2: ch = 2
            case 3: ch = 1
            case 5: ch = -1
            case 6: ch = -2
            case 7: ch = -3
            default: ch = 0
            }
            if code == 4 { radicals += 1 }
            atomCharges[k] = ch
            atoms.append(Atom(id: k, atomicNumber: zn, position: Vec3(xx, yy, zz)))
        }
        p += na
        var bonds: [Bond] = []
        for k in 0..<nb {
            let l = lines[p + k]
            var a: Int?, b: Int?, t: Int?
            if l.utf8.count >= 9 { a = Int(slice(l, 0, 3)); b = Int(slice(l, 3, 6)); t = Int(slice(l, 6, 9)) }
            if a == nil || b == nil || t == nil {
                let tk = tokens(l)
                guard tk.count >= 3 else { throw fail(p + k + 1, "bad bond line") }
                a = Int(tk[0]); b = Int(tk[1]); t = Int(tk[2])
            }
            guard let ia = a, let ib = b, let ty = t else { throw fail(p + k + 1, "bad bond line") }
            guard ia >= 1, ib >= 1, ia <= na, ib <= na, ia != ib else {
                throw fail(p + k + 1, "bond references atom outside 1...\(na)")
            }
            let order: BondOrder
            switch ty {
            case 1: order = .single
            case 2: order = .double
            case 3: order = .triple
            case 4: order = .aromatic
            default: throw fail(p + k + 1, "unsupported bond type \(ty)")
            }
            bonds.append(Bond(ia - 1, ib - 1, order: order))
        }
        p += nb
        // properties block
        var sawEnd = false
        var chg: [Int: Int]? = nil
        var rad: [Int: Int] = [:]
        while p < lines.count {
            let l = lines[p]
            p += 1
            if l.hasPrefix("M  END") { sawEnd = true; break }
            if l.hasPrefix("M  CHG") || l.hasPrefix("M  RAD") || l.hasPrefix("M  ISO") {
                let t = tokens(l)
                guard t.count >= 3, let n = Int(t[2]), n >= 0, t.count >= 3 + 2 * n else {
                    throw fail(p, "bad \(l.prefix(6)) line")
                }
                if l.hasPrefix("M  ISO") { continue }
                for q in 0..<n {
                    guard let ai = Int(t[3 + 2 * q]), let v = Int(t[4 + 2 * q]), ai >= 1, ai <= na else {
                        throw fail(p, "bad atom entry in \(l.prefix(6))")
                    }
                    if l.hasPrefix("M  CHG") { chg = chg ?? [:]; chg![ai - 1] = v } else { rad[ai - 1] = v }
                }
            }
        }
        guard sawEnd else { throw fail(lines.count, "missing 'M  END' (truncated record?)") }
        if let c = chg { chargeSum = c.values.reduce(0, +) } else { chargeSum = atomCharges.reduce(0, +) }
        var unpaired = 0
        if !rad.isEmpty {
            for v in rad.values { if v == 2 { unpaired += 1 } else if v == 3 { unpaired += 2 } }
        } else { unpaired = radicals }
        // data items
        var props: [SDFProperty] = []
        var sawTerminator = false
        while p < lines.count {
            let l = lines[p]
            if l.hasPrefix("$$$$") { sawTerminator = true; p += 1; break }
            if l.hasPrefix(">") {
                guard let lt = l.firstIndex(of: "<"), let gt = l.lastIndex(of: ">"), lt < gt else {
                    // data header without a name: skip it
                    p += 1
                    while p < lines.count, !lines[p].allSatisfy({ $0 == " " }), !lines[p].isEmpty, !lines[p].hasPrefix("$$$$") { p += 1 }
                    continue
                }
                let name = String(l[l.index(after: lt)..<gt])
                p += 1
                var vals: [String] = []
                while p < lines.count, !lines[p].isEmpty, !lines[p].hasPrefix("$$$$") {
                    vals.append(String(lines[p])); p += 1
                }
                props.append(SDFProperty(name: name, value: vals.joined(separator: "\n")))
                continue
            }
            p += 1
        }
        _ = sawTerminator
        var mol = Molecule(atoms: atoms, bonds: bonds, charge: chargeSum, multiplicity: 1 + unpaired, title: title)
        mol.title = title
        return (SDFRecord(molecule: mol, properties: props), p)
    }

    // MARK: writing

    private static func padL(_ s: String, _ n: Int) -> String {
        s.count >= n ? s : String(repeating: " ", count: n - s.count) + s
    }

    private static func molBlock(_ m: Molecule) -> String {
        var out = m.title.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ") + "\n"
        out += "  MolScope\n\n"
        out += padL(String(m.atoms.count), 3) + padL(String(m.bonds.count), 3) + "  0  0  0  0  0  0  0  0999 V2000\n"
        for a in m.atoms {
            let sym = IOElements.symbol(a.atomicNumber)
            out += String(format: "%10.4f%10.4f%10.4f ", a.position.x, a.position.y, a.position.z)
            out += sym.padding(toLength: 3, withPad: " ", startingAt: 0) + " 0  0  0  0  0  0  0  0  0  0  0  0\n"
        }
        for b in m.bonds {
            let t: Int
            switch b.order { case .single: t = 1; case .double: t = 2; case .triple: t = 3; case .aromatic: t = 4 }
            out += padL(String(b.a + 1), 3) + padL(String(b.b + 1), 3) + padL(String(t), 3) + "  0\n"
        }
        if m.charge != 0, !m.atoms.isEmpty {
            let want = m.charge > 0 ? 7 : 8
            let idx = m.atoms.firstIndex { $0.atomicNumber == want } ?? 0
            out += "M  CHG  1 " + padL(String(idx + 1), 3) + " " + padL(String(m.charge), 3) + "\n"
        }
        let unpaired = m.multiplicity - 1
        if unpaired > 0 {
            var entries: [(Int, Int)] = []
            for k in 0..<min(unpaired, m.atoms.count) { entries.append((k + 1, 2)) }
            var q = 0
            while q < entries.count {
                let chunk = entries[q..<min(q + 8, entries.count)]
                out += "M  RAD" + padL(String(chunk.count), 3)
                for (ai, v) in chunk { out += " " + padL(String(ai), 3) + " " + padL(String(v), 3) }
                out += "\n"
                q += 8
            }
        }
        out += "M  END\n"
        return out
    }

    /// A single MOL block ending with `M  END`.
    public static func write(_ molecule: Molecule) -> String { molBlock(molecule) }

    public static func writeSDF(_ records: [SDFRecord]) -> String {
        var out = ""
        for r in records {
            out += molBlock(r.molecule)
            for p in r.properties {
                out += "> <\(p.name)>\n"
                let vals = p.value.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" })
                for v in vals { out += v + "\n" }
                out += "\n"
            }
            out += "$$$$\n"
        }
        return out
    }
}
