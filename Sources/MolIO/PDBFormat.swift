import Foundation
import MolCore

/// Crystallographic cell from a CRYST1 record (lengths in Angstrom, angles in degrees).
/// (Named PDBUnitCell to avoid clashing with MolRender.UnitCell.)
public struct PDBUnitCell: Sendable, Codable, Equatable, Hashable {
    public var a: Double, b: Double, c: Double
    public var alpha: Double, beta: Double, gamma: Double
    public var spaceGroup: String
    public init(a: Double, b: Double, c: Double, alpha: Double = 90, beta: Double = 90, gamma: Double = 90,
                spaceGroup: String = "P 1") {
        self.a = a; self.b = b; self.c = c
        self.alpha = alpha; self.beta = beta; self.gamma = gamma
        self.spaceGroup = spaceGroup
    }
}

/// Per-atom PDB metadata (one per atom of the matching model).
public struct PDBAtomRecord: Sendable, Codable, Equatable, Hashable {
    public var serial: Int
    public var name: String
    public var altLoc: String
    public var resName: String
    public var chainID: String
    public var resSeq: Int
    public var iCode: String
    public var occupancy: Double
    public var tempFactor: Double
    public var element: String
    public var formalCharge: Int
    public var isHetero: Bool
    public init(serial: Int, name: String, altLoc: String = "", resName: String = "UNL", chainID: String = "A",
                resSeq: Int = 1, iCode: String = "", occupancy: Double = 1.0, tempFactor: Double = 0.0,
                element: String = "", formalCharge: Int = 0, isHetero: Bool = false) {
        self.serial = serial; self.name = name; self.altLoc = altLoc; self.resName = resName
        self.chainID = chainID; self.resSeq = resSeq; self.iCode = iCode; self.occupancy = occupancy
        self.tempFactor = tempFactor; self.element = element; self.formalCharge = formalCharge
        self.isHetero = isHetero
    }
}

/// One biological assembly from REMARK 350 (or mmCIF pdbx_struct_assembly_gen): each part applies its operators to
/// its chains. Operators are row-major 3x4 matrices [r11 r12 r13 t1 r21 r22 r23 t2 r31 r32 r33 t3] in Angstrom.
public struct PDBAssembly: Sendable, Codable, Equatable, Hashable {
    public struct Part: Sendable, Codable, Equatable, Hashable {
        public var chains: [String]
        public var operators: [[Double]]
        public init(chains: [String], operators: [[Double]]) { self.chains = chains; self.operators = operators }
    }
    public var id: String
    public var parts: [Part]
    public init(id: String, parts: [Part]) { self.id = id; self.parts = parts }

    public static let identity: [Double] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0]
    public static func isIdentity(_ op: [Double]) -> Bool {
        op.count == 12 && zip(op, identity).allSatisfy { abs($0 - $1) < 1e-4 }
    }
    /// Chains used by any part (order of first mention).
    public var chains: [String] {
        var seen = Set<String>(), out: [String] = []
        for p in parts { for c in p.chains where seen.insert(c).inserted { out.append(c) } }
        return out
    }
}

public struct PDBFile: Sendable, Codable, Equatable {
    public var models: [Molecule]
    public var cell: PDBUnitCell?
    /// One array per model, parallel to `models[i].atoms`.
    public var atomRecords: [[PDBAtomRecord]]
    /// Biological assemblies (REMARK 350), in file order.
    public var assemblies: [PDBAssembly] = []
    /// Atoms dropped because they belong to a less occupied alternate location (see `PDBFormat.parse`).
    public var droppedAltLocAtoms = 0
    public init(models: [Molecule] = [], cell: PDBUnitCell? = nil, atomRecords: [[PDBAtomRecord]] = [],
                assemblies: [PDBAssembly] = []) {
        self.models = models; self.cell = cell; self.atomRecords = atomRecords; self.assemblies = assemblies
    }
}

/// PDB v3.3 reader/writer (ATOM/HETATM/CONECT/CRYST1/MODEL/ENDMDL/TER/END/TITLE).
///
/// CONECT handling: every listed pair becomes a bond. If a neighbour is listed N times in a record
/// (the common convention for double/triple bonds), the bond order is N (1 single, 2 double, >=3
/// triple); across the two directions of a pair the larger multiplicity wins. The writer emits the
/// neighbour once per unit of order (aromatic is written as single). Only 3 decimals of
/// coordinate precision are stored in the format.
///
/// Alternate locations: by default one conformer per residue is kept (the altLoc label with the highest summed
/// occupancy in that residue, ties to the label met first); atoms with a blank altLoc are always kept. Pass
/// `keepAltLocs: true` to read every record.
public enum PDBFormat {
    private static func fail(_ line: Int?, _ msg: String) -> MolIOError {
        .parse(format: "pdb", line: line, message: msg)
    }

    public static func read(url: URL, keepAltLocs: Bool = false) throws -> PDBFile {
        try parse(try readText(url), keepAltLocs: keepAltLocs)
    }

    // 1-based inclusive column slice, tolerant of short lines.
    private static func field(_ b: [UInt8], _ from: Int, _ to: Int) -> String {
        guard from <= b.count else { return "" }
        let hi = min(to, b.count)
        return String(decoding: b[(from - 1)..<hi], as: UTF8.self)
    }
    private static func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces) }

    private static func inferElement(name4: String, hetero: Bool) -> Int? {
        let chars = Array(name4)
        guard !chars.isEmpty else { return nil }
        var idx = 0
        let startsAtCol13 = chars[0] != " "
        while idx < chars.count, chars[idx] == " " || chars[idx].isNumber { idx += 1 }
        guard idx < chars.count, chars[idx].isLetter else { return nil }
        let rest = String(chars[idx...]).trimmingCharacters(in: .whitespaces)
        let first = String(chars[idx])
        if !startsAtCol13 { return IOElements.atomicNumber(exact: first) }
        if first == "H" || first == "h" {
            let r = Array(rest)
            if r.count <= 1 || !hetero || (r.count > 2 && r[2].isNumber) || (r.count > 1 && r[1].isNumber) {
                return 1
            }
        }
        if rest.count >= 2 {
            let two = String(rest.prefix(2))
            if two.allSatisfy({ $0.isLetter }), !(hetero == false && first == "H"),
               let z = IOElements.atomicNumber(exact: two), z > 0 { return z }
        }
        return IOElements.atomicNumber(exact: first)
    }

    private static func parseCharge(_ s: String) -> Int {
        let t = trim(s)
        guard !t.isEmpty else { return 0 }
        let digits = t.filter { $0.isNumber }
        let sign: Int = t.contains("-") ? -1 : 1
        return sign * (Int(digits) ?? (t.contains("+") || t.contains("-") ? 1 : 0))
    }

    /// Indices of the records to keep: blank altLoc always, else the residue's preferred altLoc label (highest summed
    /// occupancy, ties to the label met first).
    public static func preferredAltLocs(_ recs: [PDBAtomRecord]) -> [Int] {
        guard recs.contains(where: { !$0.altLoc.isEmpty }) else { return Array(recs.indices) }
        struct Key: Hashable { var chain: String, seq: Int, icode: String }
        var occ: [Key: [String: Double]] = [:], labels: [Key: [String]] = [:]
        for r in recs where !r.altLoc.isEmpty {
            let k = Key(chain: r.chainID, seq: r.resSeq, icode: r.iCode)
            if occ[k]?[r.altLoc] == nil { labels[k, default: []].append(r.altLoc) }
            occ[k, default: [:]][r.altLoc, default: 0] += r.occupancy
        }
        var best: [Key: String] = [:]
        for (k, ls) in labels {
            var b = ls[0]
            for l in ls.dropFirst() where (occ[k]?[l] ?? 0) > (occ[k]?[b] ?? 0) + 1e-6 { b = l }
            best[k] = b
        }
        return recs.indices.filter { i in
            let r = recs[i]
            return r.altLoc.isEmpty || best[Key(chain: r.chainID, seq: r.resSeq, icode: r.iCode)] == r.altLoc
        }
    }

    /// REMARK 350 biological assemblies (BIOMOLECULE / APPLY THE FOLLOWING TO CHAINS / BIOMT1-3).
    public static func parseAssemblies(_ text: String) -> [PDBAssembly] {
        var out: [PDBAssembly] = []
        var cur: PDBAssembly? = nil
        var chains: [String] = []
        var ops: [Int: [Double]] = [:], opOrder: [Int] = []
        var lastWasChains = false
        func flushPart() {
            defer { chains = []; ops = [:]; opOrder = [] }
            guard !chains.isEmpty else { return }
            let list = opOrder.compactMap { ops[$0] }.filter { $0.count == 12 }
            cur?.parts.append(.init(chains: chains, operators: list.isEmpty ? [PDBAssembly.identity] : list))
        }
        func flushAssembly() { flushPart(); if let c = cur, !c.parts.isEmpty { out.append(c) }; cur = nil }
        func chainList<S: StringProtocol>(_ s: S) -> [String] {
            s.split(whereSeparator: { $0 == "," || $0 == " " }).map { String($0) }.filter { !$0.isEmpty && $0 != "AND" }
        }
        var done = false
        text.enumerateLines { line, stop in
            if line.hasPrefix("ATOM  ") || line.hasPrefix("HETATM") { done = true; stop = true; return }
            guard line.hasPrefix("REMARK 350") else { return }
            let body = line.dropFirst(10).trimmingCharacters(in: .whitespaces)
            if body.hasPrefix("BIOMOLECULE:") {
                flushAssembly()
                cur = PDBAssembly(id: body.dropFirst(12).trimmingCharacters(in: .whitespaces), parts: [])
                lastWasChains = false
            } else if let r = body.range(of: "APPLY THE FOLLOWING TO CHAINS:") {
                if !lastWasChains { flushPart() }
                chains += chainList(body[r.upperBound...])
                lastWasChains = true
            } else if body.hasPrefix("AND CHAINS:") {
                chains += chainList(body.dropFirst(11))
                lastWasChains = true
            } else if body.hasPrefix("BIOMT"), body.count > 6,
                      let row = Int(String(body[body.index(body.startIndex, offsetBy: 5)])), (1...3).contains(row) {
                lastWasChains = false
                let f = body.dropFirst(6).split(separator: " ").compactMap { Double($0) }
                guard f.count >= 5 else { return }
                let serial = Int(f[0])
                if ops[serial] == nil { ops[serial] = []; opOrder.append(serial) }
                if ops[serial]!.count == (row - 1) * 4 { ops[serial]! += Array(f[1...4]) }
            }
        }
        _ = done
        flushAssembly()
        return out
    }

    public static func parse(_ text: String, keepAltLocs: Bool = false) throws -> PDBFile {
        let lines = splitLines(text)
        var dropped = 0
        var models: [Molecule] = [], records: [[PDBAtomRecord]] = []
        var curAtoms: [Atom] = [], curRecs: [PDBAtomRecord] = []
        var curCharge = 0
        var inModel = false
        var cell: PDBUnitCell? = nil
        var titleParts: [String] = []
        var conect: [(Int, [Int], Int)] = []   // (line, serials, ...) first = center

        func finish() {
            if !keepAltLocs && !curAtoms.isEmpty {
                let keep = preferredAltLocs(curRecs)
                if keep.count < curAtoms.count {
                    dropped += curAtoms.count - keep.count
                    curAtoms = keep.enumerated().map { (k, i) in var a = curAtoms[i]; a.id = k; return a }
                    curRecs = keep.map { curRecs[$0] }
                    curCharge = curRecs.reduce(0) { $0 + $1.formalCharge }
                }
            }
            if !curAtoms.isEmpty {
                var m = Molecule(atoms: curAtoms, charge: curCharge)
                m.title = titleParts.joined(separator: " ")
                models.append(m); records.append(curRecs)
            }
            curAtoms = []; curRecs = []; curCharge = 0
        }

        for (ln, raw) in lines.enumerated() {
            let b = Array(raw.utf8)
            guard b.count >= 3 else { continue }
            let rec = trim(field(b, 1, 6))
            switch rec {
            case "ATOM", "HETATM":
                guard b.count >= 54 else { throw fail(ln + 1, "\(rec) line too short (\(b.count) columns, need 54)") }
                guard let x = Double(trim(field(b, 31, 38))), let y = Double(trim(field(b, 39, 46))),
                      let z = Double(trim(field(b, 47, 54))), x.isFinite, y.isFinite, z.isFinite else {
                    throw fail(ln + 1, "bad coordinates")
                }
                let nameRaw = field(b, 13, 16)
                let name = trim(nameRaw)
                let hetero = rec == "HETATM"
                var zNum: Int? = nil
                let elemCol = trim(field(b, 77, 78))
                if !elemCol.isEmpty { zNum = IOElements.atomicNumber(exact: elemCol) }
                if zNum == nil { zNum = inferElement(name4: nameRaw, hetero: hetero) }
                guard let zz = zNum else { throw fail(ln + 1, "cannot determine element of atom '\(name)'") }
                let idx = curAtoms.count
                var a = Atom(id: idx, atomicNumber: zz, position: Vec3(x, y, z))
                a.label = name.isEmpty ? nil : name
                let fc = parseCharge(field(b, 79, 80))
                curCharge += fc
                curAtoms.append(a)
                curRecs.append(PDBAtomRecord(
                    serial: Int(trim(field(b, 7, 11))) ?? (idx + 1), name: name,
                    altLoc: trim(field(b, 17, 17)), resName: trim(field(b, 18, 20)),
                    chainID: trim(field(b, 22, 22)), resSeq: Int(trim(field(b, 23, 26))) ?? 0,
                    iCode: trim(field(b, 27, 27)),
                    occupancy: Double(trim(field(b, 55, 60))) ?? 1.0, tempFactor: Double(trim(field(b, 61, 66))) ?? 0.0,
                    element: IOElements.symbol(zz), formalCharge: fc, isHetero: hetero))
            case "MODEL":
                if inModel { throw fail(ln + 1, "MODEL inside an unterminated MODEL") }
                finish()
                inModel = true
            case "ENDMDL":
                guard inModel else { throw fail(ln + 1, "ENDMDL without MODEL") }
                finish(); inModel = false
            case "CONECT":
                var serials: [Int] = []
                var c = 7
                while c <= b.count {
                    let f = trim(field(b, c, c + 4))
                    if !f.isEmpty {
                        guard let v = Int(f) else { throw fail(ln + 1, "bad CONECT serial '\(f)'") }
                        serials.append(v)
                    }
                    c += 5
                }
                guard !serials.isEmpty else { throw fail(ln + 1, "empty CONECT record") }
                conect.append((ln + 1, serials, 0))
            case "CRYST1":
                guard b.count >= 54, let ca = Double(trim(field(b, 7, 15))), let cb = Double(trim(field(b, 16, 24))),
                      let cc = Double(trim(field(b, 25, 33))), let al = Double(trim(field(b, 34, 40))),
                      let be = Double(trim(field(b, 41, 47))), let ga = Double(trim(field(b, 48, 54))) else {
                    throw fail(ln + 1, "bad CRYST1 record")
                }
                cell = PDBUnitCell(a: ca, b: cb, c: cc, alpha: al, beta: be, gamma: ga,
                                   spaceGroup: trim(field(b, 56, 66)))
            case "TITLE":
                let t = trim(field(b, 11, 80))
                if !t.isEmpty { titleParts.append(t) }
            case "END":
                if inModel { throw fail(ln + 1, "END inside an unterminated MODEL") }
                finish()
                var f = try build(models: models, records: records, cell: cell, conect: conect)
                f.assemblies = parseAssemblies(text); f.droppedAltLocAtoms = dropped
                return f
            default: break
            }
        }
        if inModel { throw fail(lines.count, "unterminated MODEL (truncated file?)") }
        finish()
        var f = try build(models: models, records: records, cell: cell, conect: conect)
        f.assemblies = parseAssemblies(text); f.droppedAltLocAtoms = dropped
        return f
    }

    private static func build(models: [Molecule], records: [[PDBAtomRecord]], cell: PDBUnitCell?,
                              conect: [(Int, [Int], Int)]) throws -> PDBFile {
        guard !models.isEmpty else { throw fail(nil, "no ATOM/HETATM records found") }
        var models = models
        // bond multiplicities, keyed by serial pair (done per model through serial->index)
        var counts: [Int: [Int: Int]] = [:]  // center -> neighbour serial -> multiplicity
        for (_, s, _) in conect {
            let center = s[0]
            for n in s.dropFirst() { counts[center, default: [:]][n, default: 0] += 1 }
        }
        if !counts.isEmpty {
            for mi in models.indices {
                var map: [Int: Int] = [:]
                for (i, r) in records[mi].enumerated() { map[r.serial] = i }
                var best: [UInt64: Int] = [:]
                for (c, nb) in counts {
                    guard let ci = map[c] else { continue }
                    for (n, mult) in nb {
                        guard let ni = map[n], ni != ci else { continue }
                        let key = UInt64(min(ci, ni)) << 32 | UInt64(max(ci, ni))
                        best[key] = max(best[key] ?? 0, mult)
                    }
                }
                for key in best.keys.sorted() {
                    let order: BondOrder = best[key]! >= 3 ? .triple : (best[key]! == 2 ? .double : .single)
                    models[mi].bonds.append(Bond(Int(key >> 32), Int(key & 0xFFFF_FFFF), order: order))
                }
            }
        }
        return PDBFile(models: models, cell: cell, atomRecords: records)
    }

    // MARK: writing

    private static func padL(_ s: String, _ n: Int) -> String {
        s.count >= n ? String(s.suffix(n)) : String(repeating: " ", count: n - s.count) + s
    }
    private static func padR(_ s: String, _ n: Int) -> String {
        s.count >= n ? String(s.prefix(n)) : s + String(repeating: " ", count: n - s.count)
    }
    private static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
    }

    private static func defaultRecords(_ m: Molecule) -> [PDBAtomRecord] {
        m.atoms.enumerated().map { (i, a) in
            PDBAtomRecord(serial: i + 1, name: a.label ?? IOElements.symbol(a.atomicNumber), resName: "UNL",
                          chainID: "A", resSeq: 1, element: IOElements.symbol(a.atomicNumber), isHetero: true)
        }
    }

    private static func atomLines(_ m: Molecule, _ recs: [PDBAtomRecord], into out: inout String) {
        for (i, a) in m.atoms.enumerated() {
            let r = recs[i]
            let sym = r.element.isEmpty ? IOElements.symbol(a.atomicNumber) : r.element
            let name: String
            if r.name.count >= 4 { name = String(r.name.prefix(4)) }
            else if sym.count >= 2 { name = padR(r.name, 4) }
            else { name = padR(" " + r.name, 4) }
            var line = padR(r.isHetero ? "HETATM" : "ATOM", 6)
            line += padL(String(((r.serial % 100000) + 100000) % 100000), 5) + " " + name
            line += padR(String(r.altLoc.prefix(1)), 1) + padL(String(r.resName.prefix(3)), 3) + " "
            line += padR(String(r.chainID.prefix(1)), 1) + padL(String(r.resSeq % 10000), 4)
            line += padR(String(r.iCode.prefix(1)), 1) + "   "
            line += String(format: "%8.3f%8.3f%8.3f%6.2f%6.2f", a.position.x, a.position.y, a.position.z, r.occupancy, r.tempFactor)
            line += String(repeating: " ", count: 10) + padL(sym.uppercased(), 2)
            if r.formalCharge != 0 { line += "\(min(abs(r.formalCharge), 9))" + (r.formalCharge > 0 ? "+" : "-") }
            out += line + "\n"
        }
    }

    private static func conectLines(_ m: Molecule, _ recs: [PDBAtomRecord], into out: inout String) {
        guard m.atoms.count <= 99999, !m.bonds.isEmpty else { return }
        var nbrs = [[Int]](repeating: [], count: m.atoms.count)
        for b in m.bonds where b.a >= 0 && b.b < m.atoms.count && b.a != b.b {
            let k = b.order == .triple ? 3 : (b.order == .double ? 2 : 1)
            for _ in 0..<k { nbrs[b.a].append(b.b); nbrs[b.b].append(b.a) }
        }
        for i in 0..<nbrs.count where !nbrs[i].isEmpty {
            let list = nbrs[i]
            var p = 0
            while p < list.count {
                var line = "CONECT" + padL(String(recs[i].serial), 5)
                for q in p..<min(p + 4, list.count) { line += padL(String(recs[list[q]].serial), 5) }
                out += line + "\n"
                p += 4
            }
        }
    }

    private static func crystLine(_ c: PDBUnitCell) -> String {
        "CRYST1" + String(format: "%9.3f%9.3f%9.3f%7.2f%7.2f%7.2f", c.a, c.b, c.c, c.alpha, c.beta, c.gamma)
            + " " + padR(c.spaceGroup, 11) + padL("1", 4) + "\n"
    }

    public static func write(_ molecule: Molecule, records: [PDBAtomRecord]? = nil, cell: PDBUnitCell? = nil) -> String {
        let recs = (records?.count == molecule.atoms.count ? records : nil) ?? defaultRecords(molecule)
        var out = ""
        if !molecule.title.isEmpty { out += "TITLE     " + String(clean(molecule.title).prefix(70)) + "\n" }
        if let c = cell { out += crystLine(c) }
        atomLines(molecule, recs, into: &out)
        out += "TER\n"
        conectLines(molecule, recs, into: &out)
        out += "END\n"
        return out
    }

    public static func write(models: [Molecule]) -> String {
        var out = ""
        if let t = models.first?.title, !t.isEmpty { out += "TITLE     " + String(clean(t).prefix(70)) + "\n" }
        for (i, m) in models.enumerated() {
            out += "MODEL     " + padL(String(i + 1), 4) + "\n"
            atomLines(m, defaultRecords(m), into: &out)
            out += "ENDMDL\n"
        }
        if let m = models.first { conectLines(m, defaultRecords(m), into: &out) }
        out += "END\n"
        return out
    }
}
