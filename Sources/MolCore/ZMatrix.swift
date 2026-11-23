import Foundation
import simd

// Owned by Lead 1 (Core). Z-matrix model, parser (public Gaussian input conventions), builder and writer.

public enum ZMatrixError: Error, CustomStringConvertible, Equatable {
    case unknownVariable(String)
    case badReference(row: Int)
    case unknownElement(String)
    case geometry(row: Int, String)
    case parse(line: Int, String)

    public var description: String {
        switch self {
        case .unknownVariable(let v): return "unknown Z-matrix variable '\(v)'"
        case .badReference(let r): return "bad atom reference in Z-matrix row \(r + 1)"
        case .unknownElement(let e): return "unknown element '\(e)'"
        case .geometry(let r, let m): return "cannot place Z-matrix row \(r + 1): \(m)"
        case .parse(let l, let m): return "Z-matrix parse error at line \(l): \(m)"
        }
    }
}

public enum ZValue: Sendable, Hashable, Codable {
    case number(Double)
    case variable(String, negated: Bool)

    public func resolve(_ vars: [String: Double]) throws -> Double {
        switch self {
        case .number(let d): return d
        case .variable(let n, let neg):
            guard let v = vars[n] else { throw ZMatrixError.unknownVariable(n) }
            return neg ? -v : v
        }
    }
}

public struct ZMatrixRow: Sendable, Hashable, Codable {
    public var atomicNumber: Int            // 0 = dummy
    public var label: String
    public var bondAtom: Int?               // 0-based row indices
    public var bond: ZValue?
    public var angleAtom: Int?
    public var angle: ZValue?
    public var dihedralAtom: Int?
    public var dihedral: ZValue?            // dihedral, or second bond angle if dihedralIsSecondAngle != 0
    public var dihedralIsSecondAngle: Int   // 0 normal; +-1 alternate form (sign picks the side)
    public var cartesian: Vec3?
    public var frozen: Bool

    public init(atomicNumber: Int, label: String? = nil, bondAtom: Int? = nil, bond: ZValue? = nil,
                angleAtom: Int? = nil, angle: ZValue? = nil, dihedralAtom: Int? = nil, dihedral: ZValue? = nil,
                dihedralIsSecondAngle: Int = 0, cartesian: Vec3? = nil, frozen: Bool = false) {
        self.atomicNumber = atomicNumber
        self.label = label ?? (atomicNumber == 0 ? "X" : Elements.symbol(atomicNumber))
        self.bondAtom = bondAtom; self.bond = bond
        self.angleAtom = angleAtom; self.angle = angle
        self.dihedralAtom = dihedralAtom; self.dihedral = dihedral
        self.dihedralIsSecondAngle = dihedralIsSecondAngle
        self.cartesian = cartesian
        self.frozen = frozen
    }
}

public struct ZMatrix: Sendable, Hashable, Codable {
    public var rows: [ZMatrixRow]
    public var variables: [String: Double]
    public var constants: [String: Double]

    public init(rows: [ZMatrixRow] = [], variables: [String: Double] = [:], constants: [String: Double] = [:]) {
        self.rows = rows; self.variables = variables; self.constants = constants
    }

    // MARK: parsing

    private static func tokens(_ s: String) -> [String] {
        s.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "," || $0 == "\r" }).map(String.init)
    }

    private static func stripParens(_ s: String) -> String {
        var out = "", depth = 0
        for ch in s {
            if ch == "(" { depth += 1 } else if ch == ")" { depth = max(0, depth - 1) } else if depth == 0 { out.append(ch) }
        }
        return out
    }

    private static func isNumber(_ t: String) -> Bool {
        guard let f = t.first else { return false }
        if f.isNumber || f == "." { return Double(t) != nil }
        if f == "-" || f == "+" {
            let r = t.dropFirst()
            if let c = r.first, c.isNumber || c == "." { return Double(t) != nil }
        }
        return false
    }

    private static func value(_ t: String) -> ZValue {
        if isNumber(t) { return .number(Double(t)!) }
        if t.hasPrefix("-") { return .variable(String(t.dropFirst()), negated: true) }
        if t.hasPrefix("+") { return .variable(String(t.dropFirst()), negated: false) }
        return .variable(t, negated: false)
    }

    private static func element(_ tok: String) -> (z: Int, label: String)? {
        if let z = Int(tok) {
            guard z >= 0, z <= Elements.maxAtomicNumber else { return nil }
            return (z, z == 0 ? "X" : Elements.symbol(z))
        }
        let letters = String(tok.prefix(while: { $0.isLetter }))
        guard !letters.isEmpty else { return nil }
        let low = letters.lowercased()
        if low == "x" || low == "bq" || low == "du" || low == "xx" { return (0, tok) }
        func cap(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst().lowercased() }
        if letters.count >= 2, let z = Elements.atomicNumber(symbol: cap(String(letters.prefix(2)))) { return (z, tok) }
        if let z = Elements.atomicNumber(symbol: cap(String(letters.prefix(1)))) { return (z, tok) }
        return nil
    }

    public static func parse(_ text: String) throws -> ZMatrix {
        var zm = ZMatrix()
        enum State { case spec, vars, consts }
        var state = State.spec
        var lineNo = 0
        for raw in text.components(separatedBy: "\n") {
            lineNo += 1
            var line = raw
            if let bang = line.firstIndex(of: "!") { line = String(line[..<bang]) }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                if state == .spec && !zm.rows.isEmpty { state = .vars }
                continue
            }
            let low = trimmed.lowercased()
            if low.hasPrefix("variables") && low.dropFirst(9).trimmingCharacters(in: .whitespaces).isEmpty
                || low == "variables:" { state = .vars; continue }
            if low.hasPrefix("constants") && low.dropFirst(9).trimmingCharacters(in: .whitespaces).isEmpty
                || low == "constants:" { state = .consts; continue }
            if low.hasPrefix("variables:") || low.hasPrefix("constants:") {
                state = low.hasPrefix("v") ? .vars : .consts
                line = String(trimmed.dropFirst(10))
                if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            }
            switch state {
            case .spec:
                zm.rows.append(try parseRow(stripParens(line), index: zm.rows.count, line: lineNo, existing: zm.rows))
            case .vars, .consts:
                let t = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "," || $0 == "=" || $0 == "\r" }).map(String.init)
                guard t.count >= 2, let v = Double(t[1]) else {
                    throw ZMatrixError.parse(line: lineNo, "expected 'name value' in variable section")
                }
                if state == .vars { zm.variables[t[0]] = v } else { zm.constants[t[0]] = v }
            }
        }
        if zm.rows.isEmpty { throw ZMatrixError.parse(line: 1, "no atoms found") }
        return zm
    }

    private static func parseRow(_ line: String, index r: Int, line lineNo: Int, existing: [ZMatrixRow]) throws -> ZMatrixRow {
        let t = tokens(line)
        guard let first = t.first else { throw ZMatrixError.parse(line: lineNo, "empty line") }
        guard let el = element(first) else { throw ZMatrixError.unknownElement(first) }
        var row = ZMatrixRow(atomicNumber: el.z, label: el.z == 0 ? first : first)
        if Int(first) != nil { row.label = el.label }
        let rest = Array(t.dropFirst())

        func ref(_ s: String) throws -> Int {
            if let n = Int(s) {
                guard n >= 1, n - 1 < r else { throw ZMatrixError.badReference(row: r) }
                return n - 1
            }
            if let i = existing.firstIndex(where: { $0.label == s }) ?? existing.firstIndex(where: { $0.label.lowercased() == s.lowercased() }) {
                return i
            }
            throw ZMatrixError.badReference(row: r)
        }
        func coord(_ s: String) throws -> Double {
            guard isNumber(s), let d = Double(s) else { throw ZMatrixError.parse(line: lineNo, "bad Cartesian coordinate '\(s)'") }
            return d
        }
        switch rest.count {
        case 0:
            if r != 0 { throw ZMatrixError.badReference(row: r) }
        case 2:
            row.bondAtom = try ref(rest[0]); row.bond = value(rest[1])
        case 3:
            row.cartesian = Vec3(try coord(rest[0]), try coord(rest[1]), try coord(rest[2]))
        case 4:
            if rest[0] == "0" {
                row.cartesian = Vec3(try coord(rest[1]), try coord(rest[2]), try coord(rest[3]))
            } else {
                row.bondAtom = try ref(rest[0]); row.bond = value(rest[1])
                row.angleAtom = try ref(rest[2]); row.angle = value(rest[3])
            }
        case 6, 7:
            row.bondAtom = try ref(rest[0]); row.bond = value(rest[1])
            row.angleAtom = try ref(rest[2]); row.angle = value(rest[3])
            row.dihedralAtom = try ref(rest[4]); row.dihedral = value(rest[5])
            if rest.count == 7 {
                guard let f = Int(rest[6]), (-1...1).contains(f) else {
                    throw ZMatrixError.parse(line: lineNo, "bad alternate-form flag '\(rest[6])'")
                }
                row.dihedralIsSecondAngle = f
            }
        default:
            throw ZMatrixError.parse(line: lineNo, "unexpected number of fields (\(t.count))")
        }
        if let a = row.bondAtom, let b = row.angleAtom, a == b { throw ZMatrixError.badReference(row: r) }
        if let a = row.bondAtom, let c = row.dihedralAtom, a == c { throw ZMatrixError.badReference(row: r) }
        if let b = row.angleAtom, let c = row.dihedralAtom, b == c { throw ZMatrixError.badReference(row: r) }
        return row
    }

    // MARK: Cartesian generation

    private func allVariables() -> [String: Double] {
        constants.merging(variables) { _, new in new }
    }

    public func cartesian() throws -> [Vec3] {
        let vars = allVariables()
        var pos: [Vec3] = []
        pos.reserveCapacity(rows.count)
        for (r, row) in rows.enumerated() {
            if let c = row.cartesian { pos.append(c); continue }
            guard let a = row.bondAtom, let bv = row.bond else {
                if r == 0 { pos.append(.zero); continue }
                throw ZMatrixError.badReference(row: r)
            }
            guard a >= 0, a < r else { throw ZMatrixError.badReference(row: r) }
            let dist = try bv.resolve(vars)
            let A = pos[a]
            guard let b = row.angleAtom, let av = row.angle else {
                pos.append(A + Vec3(0, 0, dist)); continue
            }
            guard b >= 0, b < r, b != a else { throw ZMatrixError.badReference(row: r) }
            let theta = try av.resolve(vars)
            let B = pos[b]
            guard let c = row.dihedralAtom, let dv = row.dihedral else {
                // Two references: place in the xz-plane (positive x) relative to the A->B direction.
                let u = B - A
                guard simd_length(u) > 1e-12 else { throw ZMatrixError.geometry(row: r, "coincident reference atoms") }
                let un = simd_normalize(u)
                var w = Vec3(1, 0, 0) - simd_dot(Vec3(1, 0, 0), un) * un
                if simd_length(w) < 1e-9 { w = Vec3(0, 1, 0) - simd_dot(Vec3(0, 1, 0), un) * un }
                w = simd_normalize(w)
                let t = degToRad(theta)
                pos.append(A + dist * (cos(t) * un + sin(t) * w))
                continue
            }
            guard c >= 0, c < r, c != a, c != b else { throw ZMatrixError.badReference(row: r) }
            let C = pos[c]
            let third = try dv.resolve(vars)
            if row.dihedralIsSecondAngle != 0 {
                let u = B - A, v = C - A
                guard simd_length(u) > 1e-12, simd_length(v) > 1e-12 else {
                    throw ZMatrixError.geometry(row: r, "coincident reference atoms")
                }
                let un = simd_normalize(u), vn = simd_normalize(v)
                let k = simd_dot(un, vn)
                let denom = 1 - k * k
                guard denom > 1e-12 else { throw ZMatrixError.geometry(row: r, "collinear reference atoms") }
                let c1 = cos(degToRad(theta)), c2 = cos(degToRad(third))
                let alpha = (c1 - k * c2) / denom, beta = (c2 - k * c1) / denom
                let inPlane = alpha * un + beta * vn
                let g2 = (1 - simd_dot(inPlane, inPlane)) / denom
                guard g2 > -1e-9 else { throw ZMatrixError.geometry(row: r, "impossible angle combination") }
                let g = g2.squareRoot() * (row.dihedralIsSecondAngle < 0 ? -1.0 : 1.0)
                pos.append(A + dist * (inPlane + g * simd_cross(un, vn)))
            } else {
                pos.append(ZMatrix.place(dist: dist, angle: theta, dihedral: third, a: A, b: B, c: C))
            }
        }
        return pos
    }

    /// NeRF placement: new atom P at distance `dist` from `a`, angle P-a-b = `angle`, dihedral P-a-b-c = `dihedral`.
    static func place(dist: Double, angle: Double, dihedral: Double, a A: Vec3, b B: Vec3, c C: Vec3) -> Vec3 {
        let ab = A - B
        let bc = simd_length(ab) > 1e-12 ? simd_normalize(ab) : Vec3(0, 0, 1)
        var n = simd_cross(B - C, bc)
        if simd_length(n) < 1e-9 { n = VecMath.perpendicular(bc) } else { n = simd_normalize(n) }
        let m = simd_cross(n, bc)
        let t = degToRad(angle), p = degToRad(dihedral)
        return A + (-dist * cos(t)) * bc + (dist * sin(t) * cos(p)) * m + (dist * sin(t) * sin(p)) * n
    }

    public func molecule(includeDummies: Bool = false, perceiveBonds: Bool = false) throws -> Molecule {
        let pos = try cartesian()
        var mol = Molecule()
        for (i, row) in rows.enumerated() where includeDummies || row.atomicNumber != 0 {
            let idx = mol.addAtom(atomicNumber: row.atomicNumber, position: pos[i])
            mol.atoms[idx].label = row.label
        }
        if perceiveBonds { mol.perceiveBonds() }
        return mol
    }

    // MARK: building from Cartesians

    public init(molecule: Molecule, useVariables: Bool = false) {
        self.init()
        let p = molecule.positions
        let n = p.count
        let adj = molecule.adjacency()
        func sinAngle(_ a: Int, _ b: Int, _ c: Int) -> Double {
            sin(degToRad(VecMath.angle(p[a], p[b], p[c])))
        }
        for i in 0..<n {
            let z = molecule.atoms[i].atomicNumber
            var row = ZMatrixRow(atomicNumber: z)
            if i >= 1 {
                // bond atom: nearest earlier bonded atom, else nearest earlier atom
                let earlier = Array(0..<i)
                func nearest(_ s: [Int], to x: Int) -> Int? { s.min { VecMath.distance(p[$0], p[x]) < VecMath.distance(p[$1], p[x]) } }
                let a = nearest(earlier.filter { adj[i].contains($0) }, to: i) ?? nearest(earlier, to: i)!
                row.bondAtom = a
                row.bond = .number(VecMath.distance(p[i], p[a]))
                if i >= 2 {
                    let cand = earlier.filter { $0 != a }
                    let bonded = cand.filter { adj[a].contains($0) }
                    let ordered = bonded.sorted { VecMath.distance(p[$0], p[a]) < VecMath.distance(p[$1], p[a]) }
                        + cand.filter { !adj[a].contains($0) }.sorted { VecMath.distance(p[$0], p[a]) < VecMath.distance(p[$1], p[a]) }
                    let b = ordered[0]
                    row.angleAtom = b
                    row.angle = .number(VecMath.angle(p[i], p[a], p[b]))
                    if i >= 3 {
                        let cs = earlier.filter { $0 != a && $0 != b }
                        let pref = cs.filter { adj[b].contains($0) } + cs.filter { !adj[b].contains($0) && adj[a].contains($0) }
                            + cs.filter { !adj[b].contains($0) && !adj[a].contains($0) }
                        var chosen = pref[0], best = -1.0
                        for c in pref {
                            let s = sinAngle(a, b, c)
                            if s > 0.1 { chosen = c; best = 2; break }
                            if s > best { best = s; chosen = c }
                        }
                        row.dihedralAtom = chosen
                        row.dihedral = .number(VecMath.dihedral(p[i], p[a], p[b], p[chosen]))
                    }
                }
            }
            rows.append(row)
        }
        if useVariables { convertToVariables() }
    }

    private mutating func convertToVariables() {
        for i in rows.indices {
            if case .number(let v)? = rows[i].bond { rows[i].bond = .variable("R\(i + 1)", negated: false); variables["R\(i + 1)"] = v }
            if case .number(let v)? = rows[i].angle { rows[i].angle = .variable("A\(i + 1)", negated: false); variables["A\(i + 1)"] = v }
            if case .number(let v)? = rows[i].dihedral {
                rows[i].dihedral = .variable("D\(i + 1)", negated: false); variables["D\(i + 1)"] = v
            }
        }
    }

    // MARK: output

    public func formatted(useVariables: Bool? = nil) -> String {
        var zm = self
        if useVariables == true {
            zm.convertToVariables()
        } else if useVariables == false {
            let vars = allVariables()
            for i in zm.rows.indices {
                for kp in [\ZMatrixRow.bond, \ZMatrixRow.angle, \ZMatrixRow.dihedral] {
                    if let v = zm.rows[i][keyPath: kp], let d = try? v.resolve(vars) { zm.rows[i][keyPath: kp] = .number(d) }
                }
            }
            zm.variables = [:]; zm.constants = [:]
        }
        func f(_ v: ZValue?) -> String {
            switch v {
            case .number(let d)?: return String(format: "%.6f", d)
            case .variable(let n, let neg)?: return (neg ? "-" : "") + n
            case nil: return ""
            }
        }
        var out: [String] = []
        for row in zm.rows {
            var parts = [row.label]
            if let c = row.cartesian {
                parts += ["0", String(format: "%.6f", c.x), String(format: "%.6f", c.y), String(format: "%.6f", c.z)]
            } else {
                if let a = row.bondAtom { parts += ["\(a + 1)", f(row.bond)] }
                if let b = row.angleAtom { parts += ["\(b + 1)", f(row.angle)] }
                if let c = row.dihedralAtom {
                    parts += ["\(c + 1)", f(row.dihedral)]
                    if row.dihedralIsSecondAngle != 0 { parts.append("\(row.dihedralIsSecondAngle)") }
                }
            }
            out.append(parts.joined(separator: " "))
        }
        func natural(_ d: [String: Double], _ header: String?) {
            guard !d.isEmpty else { return }
            out.append(header ?? "")
            let keys = d.keys.sorted { a, b in
                let na = Int(a.drop(while: { !$0.isNumber })) ?? Int.max
                let nb = Int(b.drop(while: { !$0.isNumber })) ?? Int.max
                return na != nb ? na < nb : a < b
            }
            for k in keys { out.append("\(k)=" + String(format: "%.6f", d[k]!)) }
        }
        natural(zm.variables, nil)
        if !zm.constants.isEmpty {
            if zm.variables.isEmpty { out.append("") }
            out.append("Constants:")
            let saved = out.count
            natural(zm.constants, "")
            out.remove(at: saved)
        }
        return out.joined(separator: "\n") + "\n"
    }
}
