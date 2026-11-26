import Foundation
import MolCore
import MolSIMD

// Z-matrix view of a molecule (results-panel "Z-Matrix" tab, Build ▸ From Z-Matrix…):
// - `ZMatrixTable.make` lists the atoms in a connectivity-following order (`ZMatrix.connectivityOrder`), each row
//   with its bond / angle / dihedral reference atoms (document indices) and values measured from the geometry.
// - `gaussianText` / `orcaText` write it as a Gaussian Z-matrix (with or without variables) or an ORCA `* int` block.
// - `ZMatrixText.parse` reads what a user pastes: a bare Gaussian Z-matrix (optionally with a "charge mult" line and a
//   variables section), a whole Gaussian input, an ORCA input / `* int` block, or bare ORCA internal rows.
// - `ZMatrixText.apply` puts a parsed Z-matrix onto a document: when the atoms match the table order (same count and
//   elements) only positions change, superimposed on the old geometry, so atom indices and bonds are kept.

public struct ZMatrixTable: Sendable, Equatable {
    public struct Row: Sendable, Equatable {
        public var atom: Int                 // document atom index
        public var atomicNumber: Int
        public var bondAtom: Int?, angleAtom: Int?, dihedralAtom: Int?   // document atom indices
        public var bond: Double?, angle: Double?, dihedral: Double?
        /// The bond reference is a real bond in the document.
        public var bonded: Bool
        public var label: String { Elements.symbol(atomicNumber) }
        /// The atoms a row depends on (itself first).
        public var atoms: [Int] { [atom] + [bondAtom, angleAtom, dihedralAtom].compactMap { $0 } }
    }
    /// `order[row]` = document atom index of that row.
    public var order: [Int]
    public var zmatrix: ZMatrix
    public var rows: [Row]
    public var charge: Int
    public var multiplicity: Int

    /// `ZMatrix(molecule:)` is quadratic in the atom count; beyond this the table is not built.
    public static let maxAtoms = 4000

    public static func reordered(_ m: Molecule, _ order: [Int]) -> Molecule {
        var inv = [Int](repeating: -1, count: m.atoms.count)
        for (k, i) in order.enumerated() { inv[i] = k }
        var r = Molecule(title: m.title)
        r.charge = m.charge; r.multiplicity = m.multiplicity
        for i in order { _ = r.addAtom(atomicNumber: m.atoms[i].atomicNumber, position: m.atoms[i].position) }
        for b in m.bonds where inv[b.a] >= 0 && inv[b.b] >= 0 { r.addBond(inv[b.a], inv[b.b], order: b.order) }
        return r
    }

    static func isPermutation(_ o: [Int], _ n: Int) -> Bool {
        guard o.count == n else { return false }
        var seen = [Bool](repeating: false, count: n)
        for i in o { guard i >= 0, i < n, !seen[i] else { return false }; seen[i] = true }
        return true
    }

    /// The table for `m` (connectivity order unless `order` is a permutation of the atoms). Nil for no atoms or
    /// more than `maxAtoms`.
    public static func make(_ m: Molecule, order explicit: [Int]? = nil) -> ZMatrixTable? {
        let n = m.atoms.count
        guard n > 0, n <= maxAtoms else { return nil }
        let order = explicit.flatMap { isPermutation($0, n) ? $0 : nil } ?? ZMatrix.connectivityOrder(m)
        let zm = ZMatrix(molecule: reordered(m, order))
        func num(_ v: ZValue?) -> Double? { if case .number(let d)? = v { return d }; return nil }
        let rows: [Row] = zm.rows.enumerated().map { r, row in
            let atom = order[r]
            let b = row.bondAtom.map { order[$0] }
            return Row(atom: atom, atomicNumber: row.atomicNumber, bondAtom: b, angleAtom: row.angleAtom.map { order[$0] },
                       dihedralAtom: row.dihedralAtom.map { order[$0] }, bond: num(row.bond), angle: num(row.angle),
                       dihedral: num(row.dihedral), bonded: b.map { m.areBonded(atom, $0) } ?? false)
        }
        return ZMatrixTable(order: order, zmatrix: zm, rows: rows, charge: m.charge, multiplicity: m.multiplicity)
    }

    /// Row number (1-based) of a document atom, as references are written in the text.
    public func rowNumber(ofAtom i: Int) -> Int? { order.firstIndex(of: i).map { $0 + 1 } }

    // MARK: text

    public enum TextStyle: String, Sendable, CaseIterable, Identifiable {
        case gaussian, gaussianVariables, orca
        public var id: String { rawValue }
        public var title: String {
            switch self { case .gaussian: "Gaussian"; case .gaussianVariables: "Gaussian (variables)"; case .orca: "ORCA * int" }
        }
    }

    public func text(_ style: TextStyle) -> String {
        switch style {
        case .gaussian: gaussianText(variables: false)
        case .gaussianVariables: gaussianText(variables: true)
        case .orca: orcaText()
        }
    }

    public func gaussianText(variables: Bool) -> String {
        var lines = ["\(charge) \(multiplicity)"]
        var vars: [(String, Double, Bool)] = []
        let wr = String(rows.count).count
        func ref(_ i: Int) -> String { let s = String(rowNumber(ofAtom: i) ?? 0); return String(repeating: " ", count: max(0, wr - s.count)) + s }
        func val(_ d: Double, _ name: String, length: Bool) -> String {
            if variables { vars.append((name, d, length)); return name.padding(toLength: 7, withPad: " ", startingAt: 0) }
            return length ? String(format: "%10.6f", d) : String(format: "%11.4f", d)
        }
        for (r, row) in rows.enumerated() {
            var s = row.label.padding(toLength: 2, withPad: " ", startingAt: 0)
            if let a = row.bondAtom, let d = row.bond { s += "  " + ref(a) + "  " + val(d, "R\(r + 1)", length: true) }
            if let b = row.angleAtom, let d = row.angle { s += "  " + ref(b) + "  " + val(d, "A\(r + 1)", length: false) }
            if let c = row.dihedralAtom, let d = row.dihedral { s += "  " + ref(c) + "  " + val(d, "D\(r + 1)", length: false) }
            while s.hasSuffix(" ") { s.removeLast() }
            lines.append(s)
        }
        if variables && !vars.isEmpty {
            lines.append("")
            for (n, v, len) in vars {
                lines.append(n.padding(toLength: 6, withPad: " ", startingAt: 0) + "= " + (len ? String(format: "%10.6f", v) : String(format: "%11.4f", v)))
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public func orcaText() -> String {
        var lines = ["* int \(charge) \(multiplicity)"]
        for row in rows {
            let a = row.bondAtom.flatMap(rowNumber(ofAtom:)) ?? 0, b = row.angleAtom.flatMap(rowNumber(ofAtom:)) ?? 0
            let c = row.dihedralAtom.flatMap(rowNumber(ofAtom:)) ?? 0
            lines.append(row.label.padding(toLength: 3, withPad: " ", startingAt: 0)
                         + String(format: " %4d %4d %4d %11.6f %11.4f %11.4f", a, b, c, row.bond ?? 0, row.angle ?? 0, row.dihedral ?? 0))
        }
        lines.append("*")
        return lines.joined(separator: "\n") + "\n"
    }
}

public enum ZMatrixText {
    public struct Parsed: Sendable {
        public var molecule: Molecule
        /// The text gave a charge and multiplicity.
        public var chargeGiven: Bool
        public var dummyCount: Int
        /// "gaussian", "gaussianInput", "orcaInput", "orcaInternal".
        public var source: String
        /// Z-matrix rows read (dummy atoms included); the atom count for a Cartesian input.
        public var rowCount: Int = 0
        /// Variables and constants the text defined (name -> value).
        public var variables: [String: Double] = [:]

        public init(molecule: Molecule, chargeGiven: Bool, dummyCount: Int = 0, source: String, rowCount: Int = 0,
                    variables: [String: Double] = [:]) {
            self.molecule = molecule; self.chargeGiven = chargeGiven; self.dummyCount = dummyCount
            self.source = source; self.rowCount = rowCount; self.variables = variables
        }
    }

    public enum ApplyMode: String, Sendable { case positions, replace }

    private static func tokens(_ s: String) -> [String] {
        s.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "," || $0 == "\r" }).map(String.init)
    }

    /// Bonds from distances; bond orders below 2000 atoms (perception is slow beyond).
    private static func finish(_ m0: Molecule) -> Molecule {
        var m = m0
        m.bonds = []
        m.renumberAtomIDs()
        guard m.atoms.count > 1 else { return m }
        m.perceiveBonds()
        if m.atoms.count < 2000 { m.perceiveBondOrders() }
        return m
    }

    public static func parse(_ text: String) throws -> Parsed {
        let norm = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var lines = norm.components(separatedBy: "\n")
        while let f = lines.first, f.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        guard let first = lines.first?.trimmingCharacters(in: .whitespaces) else { throw MolIOError.unsupported("the Z-matrix is empty") }
        let lowerAll = norm.lowercased()

        func fromFile(_ fmt: MoleculeFileFormat, _ source: String) throws -> Parsed {
            let f = try MolecularFileLoader.load(text: norm, format: fmt, fileName: nil)
            guard !f.molecule.atoms.isEmpty else { throw MolIOError.unsupported("no atoms found") }
            return Parsed(molecule: finish(f.molecule), chargeGiven: true, dummyCount: 0, source: source, rowCount: f.molecule.atoms.count)
        }
        if first.hasPrefix("#") || first.hasPrefix("%") { return try fromFile(.gaussianInput, "gaussianInput") }

        var charge: Int?, mult: Int?
        var source = "gaussian"
        if let k = lines.firstIndex(where: { let t = tokens($0.lowercased().replacingOccurrences(of: "*", with: "* ")); return t.count >= 4 && t[0] == "*" && t[1] == "int" }) {
            let t = tokens(lines[k].replacingOccurrences(of: "*", with: "* "))
            guard let c = Int(t[2]), let s = Int(t[3]), s >= 1 else { throw MolIOError.unsupported("bad '* int' line: \(lines[k])") }
            charge = c; mult = s
            let body = lines[(k + 1)...].prefix { let x = $0.trimmingCharacters(in: .whitespaces).lowercased(); return x != "*" && x != "end" }
            lines = Array(body.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            source = "orcaInput"
        } else if first.hasPrefix("!") || lowerAll.contains("* xyz") || lowerAll.contains("*xyz") {
            return try fromFile(.orcaInput, "orcaInput")
        } else {
            let t0 = tokens(first)
            if t0.count == 2, let c = Int(t0[0]), let s = Int(t0[1]), s >= 1 { charge = c; mult = s; lines.removeFirst() }
        }
        var zm: ZMatrix
        let spec = lines.prefix { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("!") }
        let orcaRows = spec.map(tokens)
        if let f = orcaRows.first, f.count >= 7, f[1] == "0", f[2] == "0", f[3] == "0",
           orcaRows.allSatisfy({ $0.count >= 7 && Int($0[1]) != nil && Int($0[2]) != nil && Int($0[3]) != nil }) {
            if source == "gaussian" { source = "orcaInternal" }
            zm = ZMatrix()
            for (r, t) in orcaRows.enumerated() {
                let low = t[0].lowercased()
                let zz: Int?
                if low == "da" || low == "x" || low == "xx" { zz = 0 } else {
                    let letters = String(t[0].prefix { $0.isLetter })
                    zz = Elements.atomicNumber(symbol: letters.prefix(1).uppercased() + letters.dropFirst().lowercased())
                }
                guard let z = zz else { throw MolIOError.unsupported("unknown element '\(t[0])' in row \(r + 1)") }
                let a = Int(t[1])!, b = Int(t[2])!, c = Int(t[3])!
                guard let rv = Double(t[4]), let av = Double(t[5]), let dv = Double(t[6]) else { throw MolIOError.unsupported("bad number in row \(r + 1)") }
                for x in [a, b, c] where x < 0 || x > r { throw MolIOError.unsupported("bad reference in row \(r + 1)") }
                zm.rows.append(ZMatrixRow(atomicNumber: z, bondAtom: a > 0 ? a - 1 : nil, bond: a > 0 ? .number(rv) : nil,
                                          angleAtom: b > 0 ? b - 1 : nil, angle: b > 0 ? .number(av) : nil,
                                          dihedralAtom: c > 0 ? c - 1 : nil, dihedral: c > 0 ? .number(dv) : nil))
            }
        } else {
            do { zm = try ZMatrix.parse(lines.joined(separator: "\n")) } catch let e as ZMatrixError { throw MolIOError.unsupported(e.description) }
        }
        var m: Molecule
        do { m = try zm.molecule() } catch let e as ZMatrixError { throw MolIOError.unsupported(e.description) }
        guard !m.atoms.isEmpty else { throw MolIOError.unsupported("the Z-matrix has only dummy atoms") }
        for i in m.atoms.indices { m.atoms[i].label = nil }
        m = finish(m)
        if let c = charge { m.charge = c }
        if let s = mult { m.multiplicity = s }
        return Parsed(molecule: m, chargeGiven: charge != nil, dummyCount: zm.rows.filter { $0.atomicNumber == 0 }.count, source: source,
                      rowCount: zm.rows.count, variables: zm.constants.merging(zm.variables) { _, n in n })
    }

    /// Applies a parsed Z-matrix to `m`. With `order` (the table's row → atom map) and matching atoms only the
    /// positions change (superimposed on the old geometry); otherwise the structure is replaced.
    public static func apply(_ parsed: Parsed, onto m: Molecule, order: [Int]?) -> (Molecule, ApplyMode) {
        let p = parsed.molecule
        if let ord = order, ZMatrixTable.isPermutation(ord, m.atoms.count), p.atoms.count == ord.count,
           zip(ord, p.atoms).allSatisfy({ m.atoms[$0.0].atomicNumber == $0.1.atomicNumber }) {
            let k = Geometry.kabsch(moving: p.positions, target: ord.map { m.atoms[$0].position })
            var out = m
            for (r, i) in ord.enumerated() { out.atoms[i].position = k.rotation * p.atoms[r].position + k.translation }
            if parsed.chargeGiven { out.charge = p.charge; out.multiplicity = p.multiplicity }
            return (out, .positions)
        }
        var r = p
        r.title = m.title
        if !parsed.chargeGiven { r.charge = m.charge; r.multiplicity = m.multiplicity }
        return (r, .replace)
    }
}
