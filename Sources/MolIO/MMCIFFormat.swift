import Foundation
import MolCore

// Minimal PDBx/mmCIF reader. Large structures (cryo-EM assemblies, ribosomes, most entries with more than 62 chains or
// 99,999 atoms) exist at RCSB only in this format. It reads, from the first data block:
//   - _atom_site (every model; auth chain / residue numbers / atom and residue names, like the PDB format, falling
//     back to the label_* items), altLoc, occupancy, B factor, formal charge, type_symbol;
//   - _struct_conf (helices) and _struct_sheet_range (strands);
//   - _pdbx_struct_assembly_gen + _pdbx_struct_oper_list (biological assemblies, including "(1-60)" ranges and
//     "(X0)(1-60)" products);
//   - _struct.title, _cell and _symmetry.
// The result is the same `PDBFile` that `PDBFormat.parse` produces (one conformer per residue unless keepAltLocs),
// so documents, cartoons and assemblies behave the same for both formats. Small-molecule CIF (fractional
// coordinates, no _atom_site.Cartn_x) is not supported.

/// A helix or strand from _struct_conf / _struct_sheet_range (auth chain and residue numbers).
public struct MMCIFSecondaryRange: Sendable, Codable, Equatable, Hashable {
    public var chain: String
    public var startSeq: Int
    public var startICode: String
    public var endSeq: Int
    public var endICode: String
    /// "H" alpha helix, "G" 3-10 helix, "I" pi helix, "E" strand (the HELIX class / SHEET convention of PDB files).
    public var kind: String
}

public struct MMCIFFile: Sendable, Equatable {
    public var pdb: PDBFile
    public var secondary: [MMCIFSecondaryRange]
    public var title: String
    public var entryID: String
}

public enum MMCIFFormat {
    private static func fail(_ msg: String) -> MolIOError { .parse(format: "mmcif", line: nil, message: msg) }

    /// True when `text` starts (after blank lines and comments) with a `data_` block header.
    public static func looksLikeMMCIF(_ text: String) -> Bool {
        for line in text.prefix(4096).split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let t = line.drop { $0 == " " || $0 == "\t" || $0 == "\u{FEFF}" }
            if t.isEmpty || t.hasPrefix("#") { continue }
            return t.lowercased().hasPrefix("data_")
        }
        return false
    }

    public static func read(url: URL, keepAltLocs: Bool = false) throws -> MMCIFFile {
        try parse(try readText(url), keepAltLocs: keepAltLocs)
    }

    // MARK: Tokenizer

    private struct Tok { var start: Int; var end: Int; var quoted: Bool }

    private struct Lexer {
        let b: [UInt8]
        var i = 0
        var pending: Tok? = nil
        init(_ b: [UInt8]) { self.b = b }

        @inline(__always) static func ws(_ c: UInt8) -> Bool { c == 32 || c == 9 || c == 10 || c == 13 }

        mutating func scan() -> Tok? {
            let n = b.count
            while i < n {
                let c = b[i]
                if Self.ws(c) { i += 1; continue }
                if c == 35 {   // '#': comment to end of line
                    while i < n, b[i] != 10 { i += 1 }
                    continue
                }
                if c == 59, i == 0 || b[i - 1] == 10 || b[i - 1] == 13 {   // ';' text field at line start
                    let s = i + 1
                    var j = s
                    while j < n { if b[j] == 10, j + 1 < n, b[j + 1] == 59 { break }; j += 1 }
                    i = min(n, j + 2)
                    return Tok(start: s, end: j, quoted: true)
                }
                if c == 39 || c == 34 {   // quoted: ends at the same quote followed by whitespace
                    var j = i + 1
                    while j < n {
                        if b[j] == c, j + 1 == n || Self.ws(b[j + 1]) { break }
                        if b[j] == 10 { break }
                        j += 1
                    }
                    let t = Tok(start: i + 1, end: j, quoted: true)
                    i = min(n, j + 1)
                    return t
                }
                var j = i
                while j < n, !Self.ws(b[j]) { j += 1 }
                let t = Tok(start: i, end: j, quoted: false)
                i = j
                return t
            }
            return nil
        }

        mutating func peek() -> Tok? {
            if pending == nil { pending = scan() }
            return pending
        }
        mutating func take() -> Tok? {
            if let p = pending { pending = nil; return p }
            return scan()
        }

        func string(_ t: Tok) -> String {
            var s = t.start, e = t.end
            if t.quoted {   // text fields: trim surrounding whitespace
                while s < e, Self.ws(b[s]) { s += 1 }
                while e > s, Self.ws(b[e - 1]) { e -= 1 }
            }
            return String(decoding: b[s..<e], as: UTF8.self)
        }

        /// Lowercased keyword check for unquoted tokens: loop_, data_, save_, global_, stop_.
        func isKeyword(_ t: Tok, _ word: String) -> Bool {
            guard !t.quoted, t.end - t.start >= word.utf8.count else { return false }
            for (k, w) in word.utf8.enumerated() {
                var c = b[t.start + k]
                if c >= 65 && c <= 90 { c += 32 }
                if c != w { return false }
            }
            return true
        }
        func isTag(_ t: Tok) -> Bool { !t.quoted && t.end > t.start && b[t.start] == 95 }
        func endsLoop(_ t: Tok) -> Bool {
            isTag(t) || isKeyword(t, "loop_") || isKeyword(t, "data_") || isKeyword(t, "save_")
                || isKeyword(t, "global_") || isKeyword(t, "stop_")
        }
        /// '.' (inapplicable) and '?' (unknown) are null.
        func isNull(_ t: Tok) -> Bool { !t.quoted && t.end == t.start + 1 && (b[t.start] == 46 || b[t.start] == 63) }
    }

    // MARK: Parsing

    /// Columns of one category: item name ("beg_auth_seq_id") -> values (one per row; nil = '.' or '?').
    private typealias Category = [String: [String?]]

    private struct AtomSite {
        var col: [String: Int] = [:]
        var models: [String] = []
        var atoms: [String: [Atom]] = [:]
        var recs: [String: [PDBAtomRecord]] = [:]
        var charge: [String: Int] = [:]
        var labelToAuth: [String: String] = [:]
        var labelOrder: [String] = []
        var idx: [Int?] = []   // per needed field, the column index
    }

    private enum F: Int, CaseIterable {
        case group, id, symbol, authAtom, labelAtom, alt, authComp, labelComp, authAsym, labelAsym, authSeq, labelSeq,
             ins, x, y, z, occ, b, charge, model
        var names: [String] {
            switch self {
            case .group: return ["group_pdb"]
            case .id: return ["id"]
            case .symbol: return ["type_symbol"]
            case .authAtom: return ["auth_atom_id"]
            case .labelAtom: return ["label_atom_id"]
            case .alt: return ["label_alt_id"]
            case .authComp: return ["auth_comp_id"]
            case .labelComp: return ["label_comp_id"]
            case .authAsym: return ["auth_asym_id"]
            case .labelAsym: return ["label_asym_id"]
            case .authSeq: return ["auth_seq_id"]
            case .labelSeq: return ["label_seq_id"]
            case .ins: return ["pdbx_pdb_ins_code"]
            case .x: return ["cartn_x"]
            case .y: return ["cartn_y"]
            case .z: return ["cartn_z"]
            case .occ: return ["occupancy"]
            case .b: return ["b_iso_or_equiv"]
            case .charge: return ["pdbx_formal_charge"]
            case .model: return ["pdbx_pdb_model_num"]
            }
        }
    }

    public static func parse(_ text: String, keepAltLocs: Bool = false) throws -> MMCIFFile {
        var lx = Lexer(Array(text.utf8))
        var cats: [String: Category] = [:]
        var site = AtomSite()
        var seenData = false
        var entry = ""

        func split(_ tag: String) -> (String, String) {
            let l = tag.lowercased()
            guard let dot = l.firstIndex(of: ".") else { return (l, "") }
            return (String(l[..<dot]), String(l[l.index(after: dot)...]))
        }

        while let t = lx.take() {
            if lx.isKeyword(t, "data_") {
                if seenData { break }   // first data block only
                seenData = true
                entry = String(lx.string(t).dropFirst(5))
                continue
            }
            if lx.isKeyword(t, "loop_") {
                var tags: [String] = []
                while let u = lx.peek(), lx.isTag(u) { tags.append(lx.string(u)); _ = lx.take() }
                guard let first = tags.first else { continue }
                let cat = split(first).0
                let items = tags.map { split($0).1 }
                if cat == "_atom_site" {
                    try readAtomSite(&lx, items: items, into: &site)
                } else {
                    var cols = [[String?]](repeating: [], count: items.count)
                    var k = 0
                    while let u = lx.peek(), !lx.endsLoop(u) {
                        _ = lx.take()
                        cols[k % items.count].append(lx.isNull(u) ? nil : lx.string(u))
                        k += 1
                    }
                    var c = cats[cat] ?? [:]
                    for (n, item) in items.enumerated() { c[item] = cols[n] }
                    cats[cat] = c
                }
                continue
            }
            if lx.isTag(t) {
                let (cat, item) = split(lx.string(t))
                guard let v = lx.peek(), !lx.endsLoop(v) else { continue }
                _ = lx.take()
                cats[cat, default: [:]][item] = [lx.isNull(v) ? nil : lx.string(v)]
            }
        }
        guard !site.models.isEmpty else {
            throw fail(cats["_atom_site_fract"] != nil || text.contains("_atom_site_fract_x")
                       ? "small-molecule CIF with fractional coordinates is not supported (only PDBx/mmCIF)"
                       : "no _atom_site records with Cartesian coordinates")
        }

        let title = (cats["_struct"]?["title"]?.first ?? nil) ?? ""
        var models: [Molecule] = [], records: [[PDBAtomRecord]] = []
        var dropped = 0
        for key in site.models {
            var atoms = site.atoms[key] ?? [], recs = site.recs[key] ?? []
            if !keepAltLocs {
                let keep = PDBFormat.preferredAltLocs(recs)
                if keep.count < atoms.count {
                    dropped += atoms.count - keep.count
                    atoms = keep.enumerated().map { (k, i) in var a = atoms[i]; a.id = k; return a }
                    recs = keep.map { recs[$0] }
                }
            }
            var m = Molecule(atoms: atoms, charge: recs.reduce(0) { $0 + $1.formalCharge })
            m.title = title
            models.append(m); records.append(recs)
        }
        var f = PDBFile(models: models, cell: cell(cats), atomRecords: records,
                        assemblies: assemblies(cats, labelToAuth: site.labelToAuth, labelOrder: site.labelOrder))
        f.droppedAltLocAtoms = dropped
        return MMCIFFile(pdb: f, secondary: secondary(cats), title: title, entryID: entry)
    }

    private static func readAtomSite(_ lx: inout Lexer, items: [String], into s: inout AtomSite) throws {
        let ncol = items.count
        var col: [String: Int] = [:]
        for (k, n) in items.enumerated() { col[n] = k }
        let idx: [Int?] = F.allCases.map { f in f.names.lazy.compactMap { col[$0] }.first }
        guard idx[F.x.rawValue] != nil, idx[F.y.rawValue] != nil, idx[F.z.rawValue] != nil else {
            // Not Cartesian: skip the rows.
            while let u = lx.peek(), !lx.endsLoop(u) { _ = lx.take() }
            return
        }
        var row: [Tok] = []
        row.reserveCapacity(ncol)
        func val(_ f: F) -> String? {
            guard let c = idx[f.rawValue] else { return nil }
            let t = row[c]
            return lx.isNull(t) ? nil : lx.string(t)
        }
        var lastModel = "", lastKey = ""
        while let u = lx.peek(), !lx.endsLoop(u) {
            _ = lx.take()
            row.append(u)
            guard row.count == ncol else { continue }
            defer { row.removeAll(keepingCapacity: true) }
            guard let x = val(.x).flatMap(Double.init), let y = val(.y).flatMap(Double.init), let z = val(.z).flatMap(Double.init),
                  x.isFinite, y.isFinite, z.isFinite else { continue }
            let name = val(.authAtom) ?? val(.labelAtom) ?? ""
            let sym = val(.symbol) ?? ""
            guard let zn = IOElements.atomicNumber(exact: sym) ?? (sym.uppercased() == "D" ? 1 : nil)
                    ?? IOElements.atomicNumber(label: name) else { continue }
            let model = val(.model) ?? "1"
            if model != lastModel {
                lastModel = model
                if s.atoms[model] == nil { s.models.append(model); s.atoms[model] = []; s.recs[model] = [] }
            }
            let chain = val(.authAsym) ?? val(.labelAsym) ?? ""
            if let la = val(.labelAsym) {
                let key = la + "|" + chain
                if key != lastKey, s.labelToAuth[la] == nil { s.labelToAuth[la] = chain; s.labelOrder.append(la) }
                lastKey = key
            }
            let fc = val(.charge).flatMap { Int($0) } ?? 0
            let n = s.atoms[model]!.count
            var a = Atom(id: n, atomicNumber: zn, position: Vec3(x, y, z))
            a.label = name.isEmpty ? nil : name
            s.atoms[model]!.append(a)
            s.recs[model]!.append(PDBAtomRecord(
                serial: val(.id).flatMap { Int($0) } ?? (n + 1), name: name, altLoc: val(.alt) ?? "",
                resName: val(.authComp) ?? val(.labelComp) ?? "UNL", chainID: chain,
                resSeq: (val(.authSeq) ?? val(.labelSeq)).flatMap { Int($0) } ?? 0, iCode: val(.ins) ?? "",
                occupancy: val(.occ).flatMap(Double.init) ?? 1.0, tempFactor: val(.b).flatMap(Double.init) ?? 0,
                element: IOElements.symbol(zn), formalCharge: fc, isHetero: (val(.group) ?? "ATOM").uppercased() == "HETATM"))
        }
    }

    // MARK: Other categories

    private static func rows(_ c: Category?) -> Int { c?.values.map(\.count).max() ?? 0 }

    private static func value(_ c: Category, _ item: String, _ r: Int) -> String? {
        guard let col = c[item], r < col.count else { return nil }
        return col[r]
    }

    private static func cell(_ cats: [String: Category]) -> PDBUnitCell? {
        guard let c = cats["_cell"], let a = value(c, "length_a", 0).flatMap(Double.init),
              let b = value(c, "length_b", 0).flatMap(Double.init), let cc = value(c, "length_c", 0).flatMap(Double.init),
              a > 1.01 || b > 1.01 || cc > 1.01 else { return nil }   // cryo-EM entries carry a dummy 1 x 1 x 1 cell
        let sg = cats["_symmetry"].flatMap { value($0, "space_group_name_h-m", 0) } ?? "P 1"
        return PDBUnitCell(a: a, b: b, c: cc, alpha: value(c, "angle_alpha", 0).flatMap(Double.init) ?? 90,
                           beta: value(c, "angle_beta", 0).flatMap(Double.init) ?? 90,
                           gamma: value(c, "angle_gamma", 0).flatMap(Double.init) ?? 90, spaceGroup: sg)
    }

    private static func secondary(_ cats: [String: Category]) -> [MMCIFSecondaryRange] {
        var out: [MMCIFSecondaryRange] = []
        if let c = cats["_struct_conf"] {
            for r in 0..<rows(c) {
                let type = (value(c, "conf_type_id", r) ?? "").uppercased()
                guard type.hasPrefix("HELX"),
                      let chain = value(c, "beg_auth_asym_id", r) ?? value(c, "beg_label_asym_id", r),
                      let s = (value(c, "beg_auth_seq_id", r) ?? value(c, "beg_label_seq_id", r)).flatMap({ Int($0) }),
                      let e = (value(c, "end_auth_seq_id", r) ?? value(c, "end_label_seq_id", r)).flatMap({ Int($0) }) else { continue }
                let cls = value(c, "pdbx_pdb_helix_class", r).flatMap { Int($0) } ?? 1
                out.append(MMCIFSecondaryRange(chain: chain, startSeq: s, startICode: value(c, "pdbx_beg_pdb_ins_code", r) ?? "",
                                               endSeq: e, endICode: value(c, "pdbx_end_pdb_ins_code", r) ?? "",
                                               kind: cls == 5 ? "G" : (cls == 3 ? "I" : "H")))
            }
        }
        if let c = cats["_struct_sheet_range"] {
            for r in 0..<rows(c) {
                guard let chain = value(c, "beg_auth_asym_id", r) ?? value(c, "beg_label_asym_id", r),
                      let s = (value(c, "beg_auth_seq_id", r) ?? value(c, "beg_label_seq_id", r)).flatMap({ Int($0) }),
                      let e = (value(c, "end_auth_seq_id", r) ?? value(c, "end_label_seq_id", r)).flatMap({ Int($0) }) else { continue }
                out.append(MMCIFSecondaryRange(chain: chain, startSeq: s, startICode: value(c, "pdbx_beg_pdb_ins_code", r) ?? "",
                                               endSeq: e, endICode: value(c, "pdbx_end_pdb_ins_code", r) ?? "", kind: "E"))
            }
        }
        return out
    }

    /// "1", "1,2,5", "(1-60)", "(X0)(1-60)" -> operator id lists, one per parenthesised factor.
    public static func operatorFactors(_ expr: String) -> [[String]] {
        var groups: [String] = []
        if expr.contains("(") {
            var cur = "", depth = 0
            for ch in expr {
                if ch == "(" { depth += 1; cur = ""; continue }
                if ch == ")" { depth -= 1; groups.append(cur); continue }
                if depth > 0 { cur.append(ch) }
            }
        } else { groups = [expr] }
        return groups.map { g in
            g.split(separator: ",").flatMap { item -> [String] in
                let p = item.trimmingCharacters(in: .whitespaces)
                let ends = p.split(separator: "-", maxSplits: 1)
                if ends.count == 2, let a = Int(ends[0]), let b = Int(ends[1]), a <= b, b - a < 100_000 { return (a...b).map(String.init) }
                return p.isEmpty ? [] : [p]
            }
        }.filter { !$0.isEmpty }
    }

    /// 3x4 row-major [r11 r12 r13 t1 r21 ... t3]: a after b.
    public static func compose(_ a: [Double], _ b: [Double]) -> [Double] {
        var o = [Double](repeating: 0, count: 12)
        for i in 0..<3 {
            for j in 0..<3 { o[i * 4 + j] = (0..<3).reduce(0) { $0 + a[i * 4 + $1] * b[$1 * 4 + j] } }
            o[i * 4 + 3] = (0..<3).reduce(0) { $0 + a[i * 4 + $1] * b[$1 * 4 + 3] } + a[i * 4 + 3]
        }
        return o
    }

    private static func assemblies(_ cats: [String: Category], labelToAuth: [String: String], labelOrder: [String]) -> [PDBAssembly] {
        guard let gen = cats["_pdbx_struct_assembly_gen"] else { return [] }
        var ops: [String: [Double]] = [:]
        if let ol = cats["_pdbx_struct_oper_list"] {
            for r in 0..<rows(ol) {
                guard let id = value(ol, "id", r) else { continue }
                var m: [Double] = []
                for i in 1...3 {
                    for j in 1...3 { m.append(value(ol, "matrix[\(i)][\(j)]", r).flatMap(Double.init) ?? (i == j ? 1 : 0)) }
                    m.append(value(ol, "vector[\(i)]", r).flatMap(Double.init) ?? 0)
                }
                ops[id] = m
            }
        }
        var out: [PDBAssembly] = []
        for r in 0..<rows(gen) {
            guard let aid = value(gen, "assembly_id", r), let expr = value(gen, "oper_expression", r),
                  let list = value(gen, "asym_id_list", r) else { continue }
            var chains: [String] = []
            for la in list.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                if let auth = labelToAuth[la], !chains.contains(auth) { chains.append(auth) }
            }
            guard !chains.isEmpty else { continue }
            var mats: [[Double]] = [PDBAssembly.identity]
            for factor in operatorFactors(expr) {
                let fm = factor.compactMap { ops[$0] }
                guard !fm.isEmpty else { continue }
                mats = mats.flatMap { a in fm.map { compose(a, $0) } }
            }
            if let k = out.firstIndex(where: { $0.id == aid }) {
                out[k].parts.append(.init(chains: chains, operators: mats))
            } else {
                out.append(PDBAssembly(id: aid, parts: [.init(chains: chains, operators: mats)]))
            }
        }
        _ = labelOrder
        return out
    }
}
