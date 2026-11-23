import Foundation
import simd

// Owned by Lead 1. SMILES writer and parser (OpenSMILES subset: organic subset, bracket atoms
// with H count / charge / isotope / class, bonds - = # $ :, branches, ring closures incl. %nn,
// dot-disconnected fragments). Stereo marks (@, /, \) are parsed and ignored.
// The writer is deterministic but NOT canonical.

public enum SMILESError: Error, CustomStringConvertible, Equatable {
    case unexpectedCharacter(Character, position: Int)
    case unknownElement(String, position: Int)
    case unclosedBracket(position: Int)
    case unbalancedParenthesis(position: Int)
    case unclosedRing(Int)
    case danglingBond(position: Int)

    public var description: String {
        switch self {
        case let .unexpectedCharacter(c, p): return "unexpected '\(c)' at \(p)"
        case let .unknownElement(s, p): return "unknown element '\(s)' at \(p)"
        case let .unclosedBracket(p): return "unclosed '[' at \(p)"
        case let .unbalancedParenthesis(p): return "unbalanced parenthesis at \(p)"
        case let .unclosedRing(n): return "ring closure \(n) never closed"
        case let .danglingBond(p): return "bond symbol without a following atom at \(p)"
        }
    }
}

public struct SMILESParseResult: Sendable {
    public var molecule: Molecule
    /// Formal charge per atom (index-aligned with `molecule.atoms`).
    public var formalCharges: [Int]
    /// Per atom: true if written as an aromatic (lowercase) atom.
    public var aromatic: [Bool]
}

public enum SMILES {
    /// Organic-subset normal valences (OpenSMILES).
    static let organicValences: [Int: [Int]] = [
        5: [3], 6: [4], 7: [3, 5], 8: [2], 15: [3, 5], 16: [2, 4, 6], 9: [1], 17: [1], 35: [1], 53: [1],
    ]

    static func implicitHydrogens(z: Int, bondSum: Int, aromatic: Bool) -> Int {
        guard let vals = organicValences[z] else { return 0 }
        let used = bondSum + (aromatic ? 1 : 0)
        for v in vals where v >= used { return v - used }
        return 0
    }

    // MARK: - Parser

    /// Parses a SMILES string. Implicit hydrogens become explicit H atoms when `addHydrogens`.
    /// Coordinates are a crude non-overlapping 2D/3D layout (z = 0 plane), intended to be cleaned
    /// up by a force field; bonds and orders are exact.
    public static func parse(_ text: String, addHydrogens: Bool = true) throws -> SMILESParseResult {
        let chars = Array(text.trimmingCharacters(in: .whitespacesAndNewlines))
        var atomsZ: [Int] = []
        var arom: [Bool] = []
        var charges: [Int] = []
        var explicitH: [Int?] = []  // nil = implicit (organic subset)
        var bonds: [(Int, Int, BondOrder, explicit: Bool)] = []
        var stack: [Int] = []
        var prev: Int? = nil
        var pendingBond: BondOrder? = nil
        var pendingPos = 0
        var rings: [Int: (atom: Int, order: BondOrder?)] = [:]
        var i = 0

        func addAtom(_ z: Int, aromatic: Bool, h: Int?, charge: Int) {
            let idx = atomsZ.count
            atomsZ.append(z); arom.append(aromatic); explicitH.append(h); charges.append(charge)
            if let p = prev {
                let order = pendingBond ?? ((aromatic && arom[p]) ? .aromatic : .single)
                bonds.append((p, idx, order, pendingBond != nil))
            }
            pendingBond = nil
            prev = idx
        }

        func elementZ(_ s: String) -> Int? {
            guard let z = Elements.atomicNumber(symbol: s), z > 0 else { return nil }
            return z
        }

        while i < chars.count {
            let c = chars[i]
            switch c {
            case "(":
                guard let p = prev else { throw SMILESError.unbalancedParenthesis(position: i) }
                stack.append(p); i += 1
            case ")":
                guard let p = stack.popLast() else { throw SMILESError.unbalancedParenthesis(position: i) }
                prev = p; i += 1
            case ".":
                prev = nil; pendingBond = nil; i += 1
            case "-": pendingBond = .single; pendingPos = i; i += 1
            case "=": pendingBond = .double; pendingPos = i; i += 1
            case "#": pendingBond = .triple; pendingPos = i; i += 1
            case "$": pendingBond = .triple; pendingPos = i; i += 1  // quadruple not representable
            case ":": pendingBond = .aromatic; pendingPos = i; i += 1
            case "/", "\\": pendingBond = pendingBond ?? .single; pendingPos = i; i += 1
            case "%", "0"..."9":
                var num: Int
                if c == "%" {
                    guard i + 2 < chars.count, let d1 = chars[i + 1].wholeNumberValue, let d2 = chars[i + 2].wholeNumberValue
                    else { throw SMILESError.unexpectedCharacter(c, position: i) }
                    num = d1 * 10 + d2; i += 3
                } else { num = c.wholeNumberValue!; i += 1 }
                guard let p = prev else { throw SMILESError.unexpectedCharacter(c, position: i - 1) }
                if let open = rings.removeValue(forKey: num) {
                    let order = pendingBond ?? open.order ?? ((arom[p] && arom[open.atom]) ? .aromatic : .single)
                    bonds.append((open.atom, p, order, pendingBond != nil || open.order != nil))
                } else {
                    rings[num] = (p, pendingBond)
                }
                pendingBond = nil
            case "[":
                guard let close = chars[i...].firstIndex(of: "]") else { throw SMILESError.unclosedBracket(position: i) }
                let body = Array(chars[(i + 1)..<close])
                var j = 0
                while j < body.count, body[j].isNumber { j += 1 }  // isotope (ignored)
                guard j < body.count else { throw SMILESError.unknownElement(String(body), position: i) }
                var sym = String(body[j]); j += 1
                var aromatic = false
                if j < body.count, body[j].isLowercase, body[j].isLetter {
                    let two = sym + String(body[j])
                    if elementZ(two) != nil, !(sym.first!.isLowercase) { sym = two; j += 1 }
                    else if sym.first!.isLowercase, ["se", "as", "te"].contains(two) { sym = two; j += 1 }
                }
                if sym.first!.isLowercase { aromatic = true }
                guard let z = elementZ(sym) else { throw SMILESError.unknownElement(sym, position: i) }
                while j < body.count, body[j] == "@" { j += 1 }
                var h = 0
                if j < body.count, body[j] == "H" {
                    j += 1; h = 1
                    var digits = ""
                    while j < body.count, body[j].isNumber { digits.append(body[j]); j += 1 }
                    if let n = Int(digits) { h = n }
                }
                var charge = 0
                while j < body.count, body[j] == "+" || body[j] == "-" {
                    let sign = body[j] == "+" ? 1 : -1
                    j += 1
                    var digits = ""
                    while j < body.count, body[j].isNumber { digits.append(body[j]); j += 1 }
                    charge += sign * (Int(digits) ?? 1)
                }
                // atom class ":n" ignored
                addAtom(z, aromatic: aromatic, h: h, charge: charge)
                i = close + 1
            case "*":
                addAtom(0, aromatic: false, h: 0, charge: 0); i += 1
            default:
                guard c.isLetter else { throw SMILESError.unexpectedCharacter(c, position: i) }
                var sym = String(c)
                if (c == "C" || c == "B"), i + 1 < chars.count, (chars[i + 1] == "l" && c == "C") || (chars[i + 1] == "r" && c == "B") {
                    sym.append(chars[i + 1]); i += 1
                }
                i += 1
                let aromatic = c.isLowercase
                let allowed: Set<String> = ["B", "C", "N", "O", "P", "S", "F", "Cl", "Br", "I", "b", "c", "n", "o", "p", "s"]
                guard allowed.contains(sym), let z = elementZ(sym) else {
                    throw SMILESError.unknownElement(sym, position: i - sym.count)
                }
                addAtom(z, aromatic: aromatic, h: nil, charge: 0)
            }
        }
        if pendingBond != nil { throw SMILESError.danglingBond(position: pendingPos) }
        if !stack.isEmpty { throw SMILESError.unbalancedParenthesis(position: chars.count) }
        if let open = rings.keys.min() { throw SMILESError.unclosedRing(open) }

        // Hydrogen counts.
        let heavyCount = atomsZ.count
        var hCounts = [Int](repeating: 0, count: heavyCount)
        for a in 0..<heavyCount {
            if let h = explicitH[a] { hCounts[a] = h; continue }
            var sum = 0
            for b in bonds where b.0 == a || b.1 == a { sum += b.2 == .aromatic ? 1 : Int(b.2.rawValue) }
            hCounts[a] = implicitHydrogens(z: atomsZ[a], bondSum: sum, aromatic: arom[a])
        }

        var mol = Molecule()
        for a in 0..<heavyCount {
            mol.atoms.append(Atom(id: a, atomicNumber: atomsZ[a], position: .zero))
        }
        var seen = Set<Int64>()
        for b in bonds where b.0 != b.1 {
            let bond = Bond(b.0, b.1, order: b.2)
            if seen.insert(Int64(bond.a) << 32 | Int64(bond.b)).inserted { mol.bonds.append(bond) }
        }
        var fc = charges, ar = arom
        if addHydrogens {
            for a in 0..<heavyCount {
                for _ in 0..<hCounts[a] {
                    let idx = mol.atoms.count
                    mol.atoms.append(Atom(id: idx, atomicNumber: 1, position: .zero))
                    mol.bonds.append(Bond(a, idx))
                    fc.append(0); ar.append(false)
                }
            }
        }
        mol.charge = charges.reduce(0, +)
        layout(&mol)
        return SMILESParseResult(molecule: mol, formalCharges: fc, aromatic: ar)
    }

    /// Simple BFS layout: each atom placed at bond length from its parent, children fanned out
    /// at 120° steps, components offset along x. Not a real 2D depiction.
    static func layout(_ mol: inout Molecule) {
        let n = mol.atoms.count
        guard n > 0 else { return }
        let adj = mol.adjacency()
        var placed = [Bool](repeating: false, count: n)
        var dir = [Vec3](repeating: Vec3(1, 0, 0), count: n)
        var xOffset = 0.0
        for start in 0..<n where !placed[start] {
            placed[start] = true
            mol.atoms[start].position = Vec3(xOffset, 0, 0)
            var queue = [start], head = 0
            var maxX = xOffset
            while head < queue.count {
                let u = queue[head]; head += 1
                let kids = adj[u].filter { !placed[$0] }
                let base = atan2(dir[u].y, dir[u].x)
                let spread = [0.0, 60, -60, 120, -120, 180, 30, -30, 90, -90, 150, -150]
                for (k, v) in kids.enumerated() {
                    let ang = degToRad(spread[k % spread.count]) + base + (k >= spread.count ? 0.2 : 0)
                    let d = Vec3(cos(ang), sin(ang), 0)
                    let len = max(0.7, mol.atoms[u].element.covalentRadius + mol.atoms[v].element.covalentRadius)
                    // small z jitter by depth keeps rings from collapsing exactly onto atoms
                    let p = mol.atoms[u].position + d * len + Vec3(0, 0, Double(head % 3) * 0.05)
                    mol.atoms[v].position = p
                    dir[v] = d
                    placed[v] = true
                    queue.append(v)
                    maxX = max(maxX, p.x)
                }
            }
            xOffset = maxX + 3.0
        }
    }

    // MARK: - Writer

    /// Writes a SMILES string. Hydrogens bonded to exactly one heavy atom are folded into
    /// implicit/bracket H counts. Bonds with `.aromatic` order are written with lowercase atoms.
    /// `formalCharges` (index-aligned) adds bracket charges; default all 0.
    public static func write(_ mol: Molecule, formalCharges: [Int]? = nil) -> String {
        let n = mol.atoms.count
        guard n > 0 else { return "" }
        let adj = mol.adjacency()
        var orderOf: [Int64: BondOrder] = [:]
        for b in mol.bonds { orderOf[Int64(b.a) << 32 | Int64(b.b)] = b.order }
        func order(_ i: Int, _ j: Int) -> BondOrder { orderOf[Int64(min(i, j)) << 32 | Int64(max(i, j))] ?? .single }

        // Fold hydrogens.
        var folded = [Bool](repeating: false, count: n)
        var hCount = [Int](repeating: 0, count: n)
        for i in 0..<n where mol.atoms[i].atomicNumber == 1 && adj[i].count == 1 {
            let h = adj[i][0]
            let charge = formalCharges?[i] ?? 0
            if mol.atoms[h].atomicNumber > 1, charge == 0 { folded[i] = true; hCount[h] += 1 }
        }
        var aromaticAtom = [Bool](repeating: false, count: n)
        for b in mol.bonds where b.order == .aromatic { aromaticAtom[b.a] = true; aromaticAtom[b.b] = true }

        // Spanning-tree DFS to find ring closures.
        var visited = [Bool](repeating: false, count: n)
        var children = [[Int]](repeating: [], count: n)
        var closures = [[(partner: Int, digit: Int)]](repeating: [], count: n)
        var treeEdge = Set<Int64>()
        var roots: [Int] = []
        var backEdges: [(Int, Int)] = []
        func key(_ i: Int, _ j: Int) -> Int64 { Int64(min(i, j)) << 32 | Int64(max(i, j)) }
        var visitOrder: [Int] = []
        for s in 0..<n where !visited[s] && !folded[s] {
            roots.append(s)
            var stack: [(Int, Int?)] = [(s, nil)]
            while let (u, parent) = stack.popLast() {
                if visited[u] { continue }
                visited[u] = true
                visitOrder.append(u)
                if let p = parent { children[p].append(u); treeEdge.insert(key(p, u)) }
                for v in adj[u].reversed() where !folded[v] && !visited[v] { stack.append((v, u)) }
            }
        }
        var rank = [Int](repeating: 0, count: n)
        for (r, a) in visitOrder.enumerated() { rank[a] = r }
        var seenBack = Set<Int64>()
        for u in 0..<n where !folded[u] {
            for v in adj[u] where !folded[v] && !treeEdge.contains(key(u, v)) {
                if seenBack.insert(key(u, v)).inserted { backEdges.append(rank[u] < rank[v] ? (u, v) : (v, u)) }
            }
        }
        // Assign ring digits in output order: opening at the earlier atom.
        backEdges.sort { (rank[$0.0], rank[$0.1]) < (rank[$1.0], rank[$1.1]) }
        var inUse = Set<Int>()
        var openAt = [[(Int, Int)]](repeating: [], count: n)  // (partner, digit)
        var closeEvents: [Int: [(Int, Int)]] = [:]
        // Simulate output order to reuse digits.
        var events: [(atom: Int, open: Bool, edge: Int)] = []
        for (e, (u, v)) in backEdges.enumerated() { events.append((u, true, e)); events.append((v, false, e)) }
        events.sort { rank[$0.atom] != rank[$1.atom] ? rank[$0.atom] < rank[$1.atom] : (!$0.open && $1.open) }
        var digitOf = [Int](repeating: 0, count: backEdges.count)
        for ev in events {
            if ev.open {
                var d = 1
                while inUse.contains(d) { d += 1 }
                inUse.insert(d); digitOf[ev.edge] = d
            } else { inUse.remove(digitOf[ev.edge]) }
        }
        for (e, (u, v)) in backEdges.enumerated() {
            openAt[u].append((v, digitOf[e]))
            closeEvents[v, default: []].append((u, digitOf[e]))
        }
        _ = closures

        func bondSymbol(_ i: Int, _ j: Int) -> String {
            switch order(i, j) {
            case .single: return (aromaticAtom[i] && aromaticAtom[j]) ? "-" : ""
            case .aromatic: return ""
            case .double: return "="
            case .triple: return "#"
            }
        }
        func digitString(_ d: Int) -> String { d < 10 ? String(d) : "%\(d)" }

        func atomString(_ i: Int) -> String {
            let z = mol.atoms[i].atomicNumber
            let sym = z == 0 ? "*" : Elements.symbol(z)
            let charge = formalCharges?[i] ?? 0
            let arom = aromaticAtom[i]
            var sum = 0
            for v in adj[i] where !folded[v] {
                let o = order(i, v)
                sum += o == .aromatic ? 1 : Int(o.rawValue)
            }
            let canArom = [5, 6, 7, 8, 15, 16].contains(z)
            let symText = (arom && (canArom || z == 34 || z == 33)) ? sym.lowercased() : sym
            if z != 0, charge == 0, SMILES.organicValences[z] != nil, (!arom || canArom),
               implicitHydrogens(z: z, bondSum: sum, aromatic: arom && canArom) == hCount[i] {
                return symText
            }
            var s = "[" + symText
            if hCount[i] == 1 { s += "H" } else if hCount[i] > 1 { s += "H\(hCount[i])" }
            if charge > 0 { s += charge == 1 ? "+" : "+\(charge)" }
            if charge < 0 { s += charge == -1 ? "-" : "-\(-charge)" }
            return s + "]"
        }

        var out = ""
        func emit(_ u: Int) {
            out += atomString(u)
            for (partner, d) in closeEvents[u] ?? [] { out += bondSymbol(u, partner) + digitString(d) }
            for (partner, d) in openAt[u] { out += bondSymbol(u, partner) + digitString(d) }
            let kids = children[u]
            for (k, v) in kids.enumerated() {
                let last = k == kids.count - 1
                if !last { out += "(" }
                out += bondSymbol(u, v)
                emit(v)
                if !last { out += ")" }
            }
        }
        for (k, r) in roots.enumerated() {
            if k > 0 { out += "." }
            emit(r)
        }
        return out
    }
}

extension Molecule {
    /// SMILES string (non-canonical). See `SMILES.write`.
    public func smiles(formalCharges: [Int]? = nil) -> String { SMILES.write(self, formalCharges: formalCharges) }

    /// Builds a molecule from SMILES with explicit hydrogens and a crude layout.
    public init(smiles: String, addHydrogens: Bool = true) throws {
        self = try SMILES.parse(smiles, addHydrogens: addHydrogens).molecule
    }
}
