import Foundation
import MolCore
import MolIO
import MolBuild
import MolSIMD

// Z-matrix methods (agent "zmatrix"): view the current molecule as a Z-matrix, edit one internal coordinate
// (Molden's Z-matrix editor), type or paste a whole Z-matrix, and add atoms by element + reference atoms +
// distance/angle/dihedral. All edits are one undo step through the document model (`DocumentStore.commit`).
//
//   zmatrix.get     {docId, ordering?, order?, refs?, variables?}            -> ZMatrixJSON
//   zmatrix.edit    {docId, ordering?, order?, refs?, row, field, value | changes: [{row, field, value}]}
//                                                                            -> {summary, molecule, zmatrix}
//   zmatrix.parse   {text}                                                   -> {molecule, rowCount, dummyCount, variables, source}
//   zmatrix.apply   {docId?, text, newDocument?, order?, title?}             -> {summary, molecule, mode, docId}
//   zmatrix.addAtom {docId, z, bondAtom?, angleAtom?, dihedralAtom?, bond?, angle?, dihedral?, bondOrder?,
//                    addHydrogens?, dryRun?}                                 -> {defaults, position, [summary, molecule, atom]}
//
// Row numbers (`row`, `refs`) are 0-based Z-matrix rows; `order[row]` is the document atom index of that row.

extension Engine {
    func zmatrixGet(_ p: Params) async throws -> JSON {
        let d = try await store.get(try p.docId())
        let o = try ZMatrixTools.Options(p)
        return try await Offload.run(AsyncCapture((d.molecule, o))) { box, _ -> Result<JSON, Error>? in
            let (m, o) = box.value
            return Result { try ZMatrixTools.describe(m, o) }
        }.get()
    }

    func zmatrixEdit(_ p: Params) async throws -> JSON {
        let id = try p.docId()
        let o = try ZMatrixTools.Options(p)
        let changes = try ZMatrixTools.changes(p)
        let snapshot = try await store.get(id)
        let (newMol, zjson) = try await Offload.run(AsyncCapture((snapshot.molecule, o, changes))) { box, _ -> Result<(Molecule, JSON), Error>? in
            let (m, o, ch) = box.value
            return Result { try ZMatrixTools.edit(m, o, ch) }
        }.get()
        try Task.checkCancellation()
        let d = try await store.commit(id, name: "Edit Z-Matrix", molecule: newMol)
        return ["summary": d.summary(), "molecule": JSONShapes.molecule(d.molecule), "zmatrix": zjson]
    }

    func zmatrixParse(_ p: Params) async throws -> JSON {
        let text = try p.string("text")
        let (m, info) = try ZMatrixTools.parseText(text)
        var r = info
        if case .object(var o) = r { o["molecule"] = JSONShapes.molecule(m); r = .object(o) }
        return r
    }

    func zmatrixApply(_ p: Params) async throws -> JSON {
        let text = try p.string("text")
        let (parsed, info) = try ZMatrixTools.parseText(text)
        let title = p.optString("title")
        let docId = p.has("docId") ? try p.docId() : nil
        if docId == nil || p.bool("newDocument", default: false) {
            var m = parsed
            if let t = title { m.title = t } else if m.title.isEmpty { m.title = "Z-Matrix" }
            let id = await store.newId()
            let d = EngineDocument(id: id, molecule: m, title: m.title)
            await store.insert(d)
            return ["summary": d.summary(), "molecule": JSONShapes.molecule(d.molecule), "mode": "new", "docId": .string(id),
                    "source": info["source"] ?? .null]
        }
        let id = docId!
        let snapshot = try await store.get(id)
        let order = try p.optInts("order")
        let (newMol, mode) = try ZMatrixTools.applyParsed(parsed, onto: snapshot.molecule, order: order,
                                                          chargeGiven: info["chargeGiven"]?.boolValue ?? false)
        let d = try await store.commit(id, name: mode == "positions" ? "Edit Z-Matrix" : "Z-Matrix", molecule: newMol)
        return ["summary": d.summary(), "molecule": JSONShapes.molecule(d.molecule), "mode": .string(mode), "docId": .string(id),
                "source": info["source"] ?? .null]
    }

    func zmatrixAddAtom(_ p: Params) async throws -> JSON {
        let id = try p.docId()
        let snapshot = try await store.get(id)
        let req = try ZMatrixTools.AddRequest(p)
        let selection = snapshot.model.selection.sorted
        let (newMol, out) = try await Offload.run(AsyncCapture((snapshot.molecule, req, selection))) { box, _ -> Result<(Molecule?, JSON), Error>? in
            let (m, r, sel) = box.value
            return Result { try ZMatrixTools.addAtom(m, r, selection: sel) }
        }.get()
        guard let nm = newMol else { return out }
        try Task.checkCancellation()
        let d = try await store.commit(id, name: "Add Atom (Z-Matrix)", molecule: nm)
        var o = out.objectValue ?? [:]
        o["summary"] = d.summary()
        o["molecule"] = JSONShapes.molecule(d.molecule)
        return .object(o)
    }
}

/// Pure Z-matrix helpers (molecule in, molecule/JSON out).
enum ZMatrixTools {
    /// `ZMatrix(molecule:)` is quadratic in the atom count; beyond this a Z-matrix table is not useful anyway.
    static let maxAtoms = 4000

    struct Options: Sendable {
        var ordering = "connectivity"       // "connectivity" | "input"
        var order: [Int]?                    // explicit row -> atom map (wins when it is a permutation of the atoms)
        var refs: [[Int?]]?                  // explicit [bond, angle, dihedral] reference rows per row
        var variables = false

        init() {}
        init(_ p: Params) throws {
            if let s = p.optString("ordering") {
                guard ["connectivity", "input"].contains(s) else { throw RPCError.badRequest("ordering must be 'connectivity' or 'input'") }
                ordering = s
            }
            order = try p.optInts("order")
            if let arr = p["refs"]?.arrayValue {
                refs = try arr.enumerated().map { k, r in
                    guard let a = r.arrayValue else { throw RPCError.badRequest("refs[\(k)] must be an array") }
                    return a.prefix(3).map { $0.intValue } + Array(repeating: nil, count: max(0, 3 - a.count))
                }
            }
            variables = p.bool("variables", default: false)
        }
    }

    struct Change: Sendable { var row: Int; var field: String; var value: Double }

    static func changes(_ p: Params) throws -> [Change] {
        func one(_ q: Params) throws -> Change {
            let f = try q.string("field")
            guard ["bond", "angle", "dihedral"].contains(f) else { throw RPCError.badRequest("field must be bond, angle or dihedral") }
            return Change(row: try q.int("row"), field: f, value: try q.double("value"))
        }
        if let arr = p["changes"]?.arrayValue {
            guard !arr.isEmpty else { throw RPCError.badRequest("'changes' is empty") }
            return try arr.map { try one(Params($0)) }
        }
        return [try one(p)]
    }

    // MARK: building

    static func reordered(_ m: Molecule, _ order: [Int]) -> Molecule {
        var inv = [Int](repeating: -1, count: order.count)
        for (k, i) in order.enumerated() { inv[i] = k }
        var r = Molecule(title: m.title)
        r.charge = m.charge; r.multiplicity = m.multiplicity
        for i in order { r.addAtom(atomicNumber: m.atoms[i].atomicNumber, position: m.atoms[i].position) }
        for b in m.bonds where b.a < inv.count && b.b < inv.count { r.addBond(inv[b.a], inv[b.b], order: b.order) }
        return r
    }

    static func isPermutation(_ o: [Int], _ n: Int) -> Bool {
        guard o.count == n else { return false }
        var seen = [Bool](repeating: false, count: n)
        for i in o { guard i >= 0, i < n, !seen[i] else { return false }; seen[i] = true }
        return true
    }

    /// Z-matrix rows with the given references; values measured from the geometry.
    static func manual(_ rm: Molecule, _ refs: [[Int?]]) throws -> ZMatrix {
        let p = rm.positions
        var zm = ZMatrix()
        for (r, ref) in refs.enumerated() {
            var row = ZMatrixRow(atomicNumber: rm.atoms[r].atomicNumber)
            let need = min(r, 3)
            let given = ref.prefix(need)
            guard given.count == need, given.allSatisfy({ $0 != nil }) else {
                throw RPCError.badRequest("Z-matrix row \(r + 1) needs \(need) reference atom\(need == 1 ? "" : "s")")
            }
            let rs = given.map { $0! }
            guard rs.allSatisfy({ $0 >= 0 && $0 < r }), Set(rs).count == rs.count else {
                throw RPCError.badRequest("Z-matrix row \(r + 1): references must be distinct earlier rows")
            }
            if need >= 1 { row.bondAtom = rs[0]; row.bond = .number(VecMath.distance(p[r], p[rs[0]])) }
            if need >= 2 { row.angleAtom = rs[1]; row.angle = .number(VecMath.angle(p[r], p[rs[0]], p[rs[1]])) }
            if need >= 3 { row.dihedralAtom = rs[2]; row.dihedral = .number(VecMath.dihedral(p[r], p[rs[0]], p[rs[1]], p[rs[2]])) }
            zm.rows.append(row)
        }
        return zm
    }

    static func build(_ m: Molecule, _ o: Options) throws -> (order: [Int], zm: ZMatrix, refsUsed: Bool) {
        let n = m.atoms.count
        guard n <= maxAtoms else { throw RPCError.badRequest("the Z-matrix view is limited to \(maxAtoms) atoms (this molecule has \(n))") }
        let order: [Int]
        if let ex = o.order, isPermutation(ex, n) { order = ex }
        else if o.ordering == "input" { order = Array(0..<n) }
        else { order = ZMatrix.connectivityOrder(m) }
        let rm = reordered(m, order)
        if let refs = o.refs, refs.count == n, o.order.map({ isPermutation($0, n) }) ?? false {
            return (order, try manual(rm, refs), true)
        }
        return (order, ZMatrix(molecule: rm), false)
    }

    // MARK: output

    static func number(_ v: ZValue?) -> Double? {
        if case .number(let d)? = v { return d }
        return nil
    }

    static func rowLabel(_ z: Int, _ r: Int) -> String { (z == 0 ? "X" : Elements.symbol(z)) + "\(r + 1)" }

    static func gaussianText(_ zm: ZMatrix, variables: Bool) -> String {
        var lines: [String] = []
        var vars: [(String, Double, Bool)] = []    // name, value, isLength
        let wl = max(2, zm.rows.map { $0.label.count }.max() ?? 2)
        let wr = String(zm.rows.count).count
        func ref(_ i: Int) -> String { String(repeating: " ", count: max(0, wr - String(i + 1).count)) + String(i + 1) }
        func val(_ d: Double, _ name: String, length: Bool) -> String {
            if variables { vars.append((name, d, length)); return name.padding(toLength: 7, withPad: " ", startingAt: 0) }
            return length ? String(format: "%10.6f", d) : String(format: "%11.4f", d)
        }
        for (r, row) in zm.rows.enumerated() {
            let sym = row.atomicNumber == 0 ? "X" : Elements.symbol(row.atomicNumber)
            var s = sym.padding(toLength: wl, withPad: " ", startingAt: 0)
            if let a = row.bondAtom, let d = number(row.bond) { s += "  " + ref(a) + "  " + val(d, "R\(r + 1)", length: true) }
            if let b = row.angleAtom, let d = number(row.angle) { s += "  " + ref(b) + "  " + val(d, "A\(r + 1)", length: false) }
            if let c = row.dihedralAtom, let d = number(row.dihedral) { s += "  " + ref(c) + "  " + val(d, "D\(r + 1)", length: false) }
            while s.hasSuffix(" ") { s.removeLast() }
            lines.append(s)
        }
        if variables && !vars.isEmpty {
            lines.append("")
            for (n, v, len) in vars { lines.append(n.padding(toLength: 6, withPad: " ", startingAt: 0) + "= " + (len ? String(format: "%10.6f", v) : String(format: "%11.4f", v))) }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func orcaText(_ zm: ZMatrix, charge: Int, multiplicity: Int) -> String {
        var lines = ["* int \(charge) \(multiplicity)"]
        for row in zm.rows {
            let sym = row.atomicNumber == 0 ? "DA" : Elements.symbol(row.atomicNumber)
            let a = row.bondAtom.map { $0 + 1 } ?? 0, b = row.angleAtom.map { $0 + 1 } ?? 0, c = row.dihedralAtom.map { $0 + 1 } ?? 0
            lines.append(sym.padding(toLength: 3, withPad: " ", startingAt: 0)
                         + String(format: " %4d %4d %4d %11.6f %11.4f %11.4f", a, b, c, number(row.bond) ?? 0, number(row.angle) ?? 0, number(row.dihedral) ?? 0))
        }
        lines.append("*")
        return lines.joined(separator: "\n") + "\n"
    }

    static func json(_ m: Molecule, order: [Int], zm: ZMatrix, o: Options, refsUsed: Bool) -> JSON {
        var rows: [JSON] = []
        rows.reserveCapacity(zm.rows.count)
        for (r, row) in zm.rows.enumerated() {
            let atom = order[r]
            func refAtom(_ x: Int?) -> JSON { x.map { .number(Double(order[$0])) } ?? .null }
            rows.append(obj([
                "row": r, "atom": atom, "z": row.atomicNumber, "symbol": Elements.symbol(row.atomicNumber),
                "label": rowLabel(row.atomicNumber, r),
                "bondRow": row.bondAtom, "bondAtom": refAtom(row.bondAtom), "bond": number(row.bond),
                "bonded": row.bondAtom.map { m.areBonded(atom, order[$0]) } ?? false,
                "angleRow": row.angleAtom, "angleAtom": refAtom(row.angleAtom), "angle": number(row.angle),
                "dihedralRow": row.dihedralAtom, "dihedralAtom": refAtom(row.dihedralAtom), "dihedral": number(row.dihedral),
            ]))
        }
        let refs: [JSON] = zm.rows.map { [$0.bondAtom.json, $0.angleAtom.json, $0.dihedralAtom.json] }
        return obj([
            "atomCount": m.atoms.count, "ordering": o.ordering, "order": order, "refs": JSON.array(refs), "refsUsed": refsUsed,
            "rows": JSON.array(rows),
            "gaussian": gaussianText(zm, variables: o.variables),
            "gaussianVariables": gaussianText(zm, variables: true),
            "orca": orcaText(zm, charge: m.charge, multiplicity: m.multiplicity),
            "charge": m.charge, "multiplicity": m.multiplicity,
        ])
    }

    static func describe(_ m: Molecule, _ o: Options) throws -> JSON {
        let (order, zm, used) = try build(m, o)
        return json(m, order: order, zm: zm, o: o, refsUsed: used)
    }

    // MARK: editing one value

    static func edit(_ m: Molecule, _ o: Options, _ changes: [Change]) throws -> (Molecule, JSON) {
        let (order, zm, _) = try build(m, o)
        var zm2 = zm
        for c in changes {
            guard zm.rows.indices.contains(c.row) else { throw RPCError.badRequest("row \(c.row) is out of range (0..<\(zm.rows.count))") }
            guard c.value.isFinite else { throw RPCError.badRequest("value must be a finite number") }
            switch c.field {
            case "bond":
                guard c.row >= 1 else { throw RPCError.badRequest("row 1 has no distance") }
                guard c.value > 0.01 else { throw RPCError.badRequest("a distance must be positive") }
                zm2.rows[c.row].bond = .number(c.value)
            case "angle":
                guard c.row >= 2 else { throw RPCError.badRequest("row \(c.row + 1) has no angle") }
                guard c.value > 0, c.value <= 180 else { throw RPCError.badRequest("an angle must be in (0, 180] degrees") }
                zm2.rows[c.row].angle = .number(c.value)
            default:
                guard c.row >= 3 else { throw RPCError.badRequest("row \(c.row + 1) has no dihedral") }
                var v = c.value.truncatingRemainder(dividingBy: 360)
                if v > 180 { v -= 360 } else if v <= -180 { v += 360 }
                zm2.rows[c.row].dihedral = .number(v)
            }
        }
        let old: [Vec3], new: [Vec3]
        do { old = try zm.cartesian(); new = try zm2.cartesian() } catch let e as ZMatrixError { throw RPCError.badRequest(e.description) }
        let actual = order.map { m.atoms[$0].position }
        // Rigid transform from the Z-matrix frame to the document frame (exact up to rounding), applied to the new
        // internal-coordinate geometry: atoms that don't depend on the edited rows stay exactly where they were.
        let k = Geometry.kabsch(moving: old, target: actual)
        var out = m
        for (r, i) in order.enumerated() {
            let q = k.rotation * new[r] + k.translation
            guard q.x.isFinite, q.y.isFinite, q.z.isFinite else { throw RPCError.badRequest("the new value gives an invalid geometry") }
            out.atoms[i].position = q
        }
        // Report the table with the same order and references, measured on the new geometry.
        var o2 = o
        o2.order = order
        o2.refs = zm2.rows.map { [$0.bondAtom, $0.angleAtom, $0.dihedralAtom] }
        let (ord2, zm3, used) = try build(out, o2)
        return (out, json(out, order: ord2, zm: zm3, o: o2, refsUsed: used))
    }

    // MARK: parsing text

    private static func tokens(_ s: String) -> [String] {
        s.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "," || $0 == "\r" }).map(String.init)
    }

    /// Parses a Z-matrix typed or pasted by the user. Accepts a bare Gaussian Z-matrix (with or without a variables
    /// section, optionally preceded by a "charge multiplicity" line), a whole Gaussian input (route line), an ORCA
    /// input or `* int` block, and bare ORCA internal-coordinate rows ("C 0 0 0 0.0 0.0 0.0").
    static func parseText(_ text: String) throws -> (Molecule, JSON) {
        let norm = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var lines = norm.components(separatedBy: "\n")
        while let f = lines.first, f.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        guard let first = lines.first?.trimmingCharacters(in: .whitespaces) else { throw RPCError.parse("the Z-matrix is empty") }
        let lowerAll = norm.lowercased()

        func fromFile(_ fmt: MoleculeFileFormat, _ source: String) throws -> (Molecule, JSON) {
            let f: LoadedMolecularFile
            do { f = try MolecularFileLoader.load(text: norm, format: fmt, fileName: nil) } catch let e as MolIOError {
                throw RPCError.parse(e.description)
            }
            var m = f.molecule
            guard !m.atoms.isEmpty else { throw RPCError.parse("no atoms found") }
            m.bonds = []
            m = Preparation.prepared(m)
            return (m, obj(["rowCount": m.atoms.count, "dummyCount": 0, "variables": JSON.object([:]), "source": source,
                            "chargeGiven": true, "atomCount": m.atoms.count]))
        }
        if first.hasPrefix("#") || first.hasPrefix("%") { return try fromFile(.gaussianInput, "gaussianInput") }

        var charge: Int?, mult: Int?
        var source = "gaussian"
        // ORCA `* int c m … *` block (with or without the rest of an ORCA input): its rows, charge and multiplicity.
        if let k = lines.firstIndex(where: { let t = tokens($0.lowercased().replacingOccurrences(of: "*", with: "* ")); return t.count >= 4 && t[0] == "*" && t[1] == "int" }) {
            let t = tokens(lines[k].replacingOccurrences(of: "*", with: "* "))
            guard let c = Int(t[2]), let s = Int(t[3]), s >= 1 else { throw RPCError.parse("bad '* int' line: \(lines[k])") }
            charge = c; mult = s
            let body = lines[(k + 1)...].prefix(while: { let x = $0.trimmingCharacters(in: .whitespaces).lowercased(); return x != "*" && x != "end" })
            lines = Array(body.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            source = "orcaInput"
        } else if first.hasPrefix("!") || lowerAll.contains("* xyz") || lowerAll.contains("*xyz") {
            return try fromFile(.orcaInput, "orcaInput")
        } else {
            let t0 = tokens(first)
            if t0.count == 2, let c = Int(t0[0]), let s = Int(t0[1]), s >= 1 { charge = c; mult = s; lines.removeFirst() }
        }
        var zm: ZMatrix
        let specLines = lines.prefix(while: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("!") }
        let orcaRows = specLines.map(tokens)
        if let f = orcaRows.first, f.count >= 7, f[1] == "0", f[2] == "0", f[3] == "0",
           orcaRows.allSatisfy({ $0.count >= 7 && Int($0[1]) != nil && Int($0[2]) != nil && Int($0[3]) != nil }) {
            if source == "gaussian" { source = "orcaInternal" }
            zm = ZMatrix()
            for (r, t) in orcaRows.enumerated() {
                let low = t[0].lowercased()
                let zz: Int?
                if low == "da" || low == "x" || low == "xx" { zz = 0 } else {
                    let letters = String(t[0].prefix(while: { $0.isLetter }))
                    zz = Elements.atomicNumber(symbol: letters.prefix(1).uppercased() + letters.dropFirst().lowercased())
                }
                guard let z = zz else { throw RPCError.parse("unknown element '\(t[0])' in row \(r + 1)") }
                let a = Int(t[1])!, b = Int(t[2])!, c = Int(t[3])!
                guard let rv = Double(t[4]), let av = Double(t[5]), let dv = Double(t[6]) else {
                    throw RPCError.parse("bad number in row \(r + 1)")
                }
                for x in [a, b, c] where x < 0 || x > r { throw RPCError.parse("bad reference in row \(r + 1)") }
                zm.rows.append(ZMatrixRow(atomicNumber: z, bondAtom: a > 0 ? a - 1 : nil, bond: a > 0 ? .number(rv) : nil,
                                          angleAtom: b > 0 ? b - 1 : nil, angle: b > 0 ? .number(av) : nil,
                                          dihedralAtom: c > 0 ? c - 1 : nil, dihedral: c > 0 ? .number(dv) : nil))
            }
        } else {
            do { zm = try ZMatrix.parse(lines.joined(separator: "\n")) } catch let e as ZMatrixError { throw RPCError.parse(e.description) }
        }
        var m: Molecule
        do { m = try zm.molecule() } catch let e as ZMatrixError { throw RPCError.parse(e.description) }
        guard !m.atoms.isEmpty else { throw RPCError.parse("the Z-matrix has only dummy atoms") }
        for i in m.atoms.indices { m.atoms[i].label = nil }
        m = Preparation.prepared(m)
        if let c = charge { m.charge = c }
        if let s = mult { m.multiplicity = s }
        let vars = zm.constants.merging(zm.variables) { _, n in n }
        return (m, obj(["rowCount": zm.rows.count, "dummyCount": zm.rows.filter { $0.atomicNumber == 0 }.count,
                        "variables": JSON.object(vars.mapValues { .number($0) }), "source": source,
                        "chargeGiven": charge != nil, "atomCount": m.atoms.count]))
    }

    /// Applies a parsed Z-matrix to a document molecule. When `order` is given and the parsed atoms match the
    /// document's atoms in that row order (same count and elements), only the positions change (bonds, labels
    /// and atom indices are kept; the result is superimposed on the old geometry). Otherwise the structure is replaced.
    static func applyParsed(_ parsed: Molecule, onto m: Molecule, order: [Int]?, chargeGiven: Bool) throws -> (Molecule, String) {
        if let ord = order, isPermutation(ord, m.atoms.count), parsed.atoms.count == ord.count,
           zip(ord, parsed.atoms).allSatisfy({ m.atoms[$0.0].atomicNumber == $0.1.atomicNumber }) {
            let actual = ord.map { m.atoms[$0].position }
            let k = Geometry.kabsch(moving: parsed.positions, target: actual)
            var out = m
            for (r, i) in ord.enumerated() { out.atoms[i].position = k.rotation * parsed.atoms[r].position + k.translation }
            if chargeGiven { out.charge = parsed.charge; out.multiplicity = parsed.multiplicity }
            return (out, "positions")
        }
        var r = parsed
        r.title = m.title
        if !chargeGiven { r.charge = m.charge; r.multiplicity = m.multiplicity }
        return (r, "replace")
    }

    // MARK: incremental builder

    struct AddRequest: Sendable {
        var z: Int
        var bondAtom: Int?, angleAtom: Int?, dihedralAtom: Int?
        var bond: Double?, angle: Double?, dihedral: Double?
        var order: BondOrder
        var addHydrogens: Bool
        var dryRun: Bool

        init(_ p: Params) throws {
            z = try p.int("z")
            guard z >= 1, z < Elements.all.count else { throw RPCError.badRequest("invalid atomic number \(z)") }
            bondAtom = p.optInt("bondAtom"); angleAtom = p.optInt("angleAtom"); dihedralAtom = p.optInt("dihedralAtom")
            bond = p.optDouble("bond"); angle = p.optDouble("angle"); dihedral = p.optDouble("dihedral")
            order = p.has("bondOrder") ? try JSONShapes.bondOrder(p["bondOrder"]) : .single
            addHydrogens = p.bool("addHydrogens", default: false)
            dryRun = p.bool("dryRun", default: false)
        }
    }

    static func hybridizationAngle(_ m: Molecule, _ a: Int) -> (Double, Hybridization) {
        let h = Editing.hybridization(m, atom: a)
        switch h {
        case .sp: return (180, h)
        case .sp2: return (120, h)
        default: return (109.4712, h)
        }
    }

    /// Placement of P from references (a, b, c) and values, using the Z-matrix placement rules.
    static func place(_ m: Molecule, _ a: Int?, _ b: Int?, _ c: Int?, _ r: Double, _ ang: Double, _ dih: Double) throws -> Vec3 {
        guard let a else { return m.atoms.isEmpty ? .zero : m.centroid + Vec3(4, 0, 0) }
        var zm = ZMatrix()
        let refs = [a, b, c].compactMap { $0 }
        for i in refs { zm.rows.append(ZMatrixRow(atomicNumber: 6, cartesian: m.atoms[i].position)) }
        zm.rows.append(ZMatrixRow(atomicNumber: 6, bondAtom: 0, bond: .number(r),
                                  angleAtom: refs.count > 1 ? 1 : nil, angle: refs.count > 1 ? .number(ang) : nil,
                                  dihedralAtom: refs.count > 2 ? 2 : nil, dihedral: refs.count > 2 ? .number(dih) : nil))
        do { return try zm.cartesian().last! } catch let e as ZMatrixError { throw RPCError.badRequest(e.description) }
    }

    static func addAtom(_ m0: Molecule, _ q: AddRequest, selection: [Int]) throws -> (Molecule?, JSON) {
        let m = m0
        let n = m.atoms.count
        for (name, v) in [("bondAtom", q.bondAtom), ("angleAtom", q.angleAtom), ("dihedralAtom", q.dihedralAtom)] {
            if let i = v, !(0..<n).contains(i) { throw RPCError.badRequest("\(name) \(i) is out of range (0..<\(n))") }
        }
        let p = m.positions
        func nearest(to x: Int, excluding ex: Set<Int>) -> Int? {
            (0..<n).filter { !ex.contains($0) }.min { VecMath.distance(p[$0], p[x]) < VecMath.distance(p[$1], p[x]) }
        }
        func preferred(_ cands: [Int]) -> Int? {
            // heavy atoms first, then the most recently added
            cands.sorted { (m.atoms[$0].atomicNumber > 1 ? 1 : 0, $0) > (m.atoms[$1].atomicNumber > 1 ? 1 : 0, $1) }.first
        }
        // references: given, else the last selected atom / last atom, then bonded neighbours along the chain
        var a = q.bondAtom
        if a == nil, n > 0 { a = selection.last ?? (n - 1) }
        var b = q.angleAtom
        if let a, b == nil, n >= 2 {
            b = preferred(m.neighbors(of: a)) ?? nearest(to: a, excluding: [a])
        }
        var c = q.dihedralAtom
        if let a, let b, c == nil, n >= 3 {
            func ok(_ x: Int) -> Bool { sin(degToRad(VecMath.angle(p[a], p[b], p[x]))) > 0.1 }
            let byB = m.neighbors(of: b).filter { $0 != a && ok($0) }
            let byA = m.neighbors(of: a).filter { $0 != b && ok($0) }
            c = preferred(byB) ?? preferred(byA)
                ?? (0..<n).filter { $0 != a && $0 != b && ok($0) }.min { VecMath.distance(p[$0], p[b]) < VecMath.distance(p[$1], p[b]) }
        }
        for (x, y) in [(a, b), (a, c), (b, c)] { if let x, let y, x == y { throw RPCError.badRequest("reference atoms must be distinct") } }
        var hyb = Hybridization.none
        var bond = q.bond ?? 0, angle = q.angle ?? 0, dihedral = q.dihedral ?? 180
        if let a {
            if q.bond == nil { bond = BuildElements.bondLength(q.z, m.atoms[a].atomicNumber, order: q.order) }
            let (ang, h) = hybridizationAngle(m, a)
            hyb = h
            if q.angle == nil { angle = ang }
        }
        guard a == nil || bond > 0.01 else { throw RPCError.badRequest("a distance must be positive") }
        guard b == nil || (angle > 0 && angle <= 180) else { throw RPCError.badRequest("an angle must be in (0, 180] degrees") }
        if let a, let b, let c, q.dihedral == nil {
            // staggered / in-plane candidates relative to the existing substituents of `a`; pick the roomiest one
            var cands: [Double] = []
            for x in m.neighbors(of: a) where x != b {
                let d = VecMath.dihedral(p[x], p[a], p[b], p[c])
                if hyb == .sp2 { cands.append(d + 180) } else { cands += [d + 120, d - 120] }
            }
            cands += hyb == .sp2 ? [180, 0] : [180, 60, -60, 120, -120, 0]
            var best = 180.0, bestScore = -Double.infinity
            for raw in cands {
                var v = raw.truncatingRemainder(dividingBy: 360)
                if v > 180 { v -= 360 } else if v <= -180 { v += 360 }
                let pos = try place(m, a, b, c, bond, angle, v)
                let score = (0..<n).filter { $0 != a }.map { VecMath.distance(pos, p[$0]) }.min() ?? 0
                if score > bestScore + 1e-3 { bestScore = score; best = v }
            }
            dihedral = best
        }
        let pos = try place(m, a, b, c, bond, angle, dihedral)
        let defaults = obj([
            "bondAtom": a, "angleAtom": b, "dihedralAtom": c,
            "bond": a != nil ? bond : nil, "angle": b != nil ? angle : nil, "dihedral": c != nil ? dihedral : nil,
            "hybridization": hyb.rawValue, "position": JSONShapes.vec3(pos),
        ])
        if q.dryRun { return (nil, ["defaults": defaults, "position": JSONShapes.vec3(pos)]) }
        var out = m
        let k = out.addAtom(atomicNumber: q.z, position: pos)
        if let a { out.addBond(a, k, order: q.order) }
        if q.addHydrogens { Editing.addHydrogens(&out, atoms: [k]) }
        return (out, ["defaults": defaults, "position": JSONShapes.vec3(pos), "atom": .number(Double(k))])
    }
}
