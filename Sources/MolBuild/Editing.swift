import Foundation
import simd
import MolCore

// Molecule editing operations (Worker A, Lead 4).

public enum Hybridization: String, Sendable { case sp, sp2, sp3, none }

@inline(__always) func bUnit(_ v: Vec3) -> Vec3 {
    let l = simd_length(v)
    return l < 1e-12 ? Vec3(0, 0, 1) : v / l
}

public enum Editing {
    // MARK: valence helpers

    static func allowedValences(_ z: Int) -> [Int] {
        switch z {
        case 1: return [1]
        case 5: return [3]
        case 6, 14, 32: return [4]
        case 7, 15, 33: return [3, 5]
        case 8: return [2]
        case 16, 34, 52: return [2, 4, 6]
        case 9, 17, 35, 53: return [1]
        default:
            let v = BuildElements.valence(z)
            return v > 0 ? [v] : []
        }
    }

    static func hasMultiple(_ m: Molecule, _ i: Int) -> Bool {
        m.bonds.contains { ($0.a == i || $0.b == i) && $0.order != .single }
    }

    /// Formal charge shifts implied by the molecule charge (loose heuristic).
    static func chargeShift(_ m: Molecule) -> [Int: Int] {
        var out = [Int: Int]()
        if m.charge > 0 {
            var left = m.charge
            for z in [7, 15, 8] {
                for i in m.atoms.indices where m.atoms[i].atomicNumber == z && left > 0 {
                    out[i] = 1; left -= 1
                }
            }
        } else if m.charge < 0 {
            var left = -m.charge
            for z in [8, 16, 7] {
                for i in m.atoms.indices where m.atoms[i].atomicNumber == z && left > 0 {
                    let hasDouble = m.bonds.contains { ($0.a == i || $0.b == i) && $0.order != .single }
                    if !hasDouble && m.buildBondOrderSum(i) <= 2 - (z == 7 ? -1 : 0) { out[i] = -1; left -= 1 }
                }
            }
        }
        return out
    }

    /// Number of hydrogens that should be added to atom i.
    static func openValence(_ m: Molecule, _ i: Int, shift: [Int: Int]) -> Int {
        let z = m.atoms[i].atomicNumber
        guard z > 1 else { return 0 }
        let allowed = allowedValences(z)
        guard !allowed.isEmpty else { return 0 }
        let bos = Int(floor(m.buildBondOrderSum(i) + 1e-6))
        let sh = shift[i] ?? 0
        let aromatic = m.bonds.contains { ($0.a == i || $0.b == i) && $0.order == .aromatic }
        var cands = allowed.map { $0 + sh }
        if aromatic && (z == 8 || z == 16 || z == 34) { cands = [2 + sh] }
        // Aromatic N: pyridine-type (two ring bonds) and pyrrole-type (two ring bonds + H/R) are both saturated;
        // the 1.5 bond-order bookkeeping would otherwise ask for a fifth bond on N-H.
        if aromatic && z == 7 && sh == 0 && bos >= 3 { return 0 }
        if sh != 0 && (z == 7 || z == 15) && sh > 0 { cands = [4] }
        guard let v = cands.filter({ $0 >= bos }).min() else { return 0 }
        return max(0, v - bos)
    }

    // MARK: hybridization

    public static func hybridization(_ m: Molecule, atom: Int) -> Hybridization {
        guard atom >= 0, atom < m.atoms.count else { return .none }
        let z = m.atoms[atom].atomicNumber
        if z == 1 { return .none }
        if [2, 10, 18, 36, 54, 86].contains(z) { return .none }
        let mine = m.bonds.filter { $0.a == atom || $0.b == atom }
        let triples = mine.filter { $0.order == .triple }.count
        let doubles = mine.filter { $0.order == .double }.count
        if triples > 0 { return .sp }
        if doubles >= 2 && (z == 6 || z == 14) { return .sp }
        if doubles > 0 || mine.contains(where: { $0.order == .aromatic }) { return .sp2 }
        if (z == 7 || z == 8) && !mine.isEmpty {
            // lone-pair donor conjugated with an unsaturated neighbour
            for n in m.buildNeighbors(of: atom) where hasMultiple(m, n) { return .sp2 }
        }
        return .sp3
    }

    // MARK: ideal directions

    /// Unit directions (from atom) for `n` new substituents.
    static func newDirections(_ m: Molecule, atom: Int, count n: Int, hyb: Hybridization) -> [Vec3] {
        guard n > 0 else { return [] }
        let p = m.atoms[atom].position
        let nbs = m.buildNeighbors(of: atom)
        let us = nbs.map { bUnit(m.atoms[$0].position - p) }
        let k = us.count
        let z = m.atoms[atom].atomicNumber
        let tetra = 109.4712206 * Double.pi / 180
        func perp(_ v: Vec3) -> Vec3 { buildPerpendicular(v) }

        // reference direction (perpendicular component) for k == 1
        func refQ(_ u: Vec3) -> Vec3? {
            let b = nbs[0]
            let cands = m.buildNeighbors(of: b).filter { $0 != atom }
            let pick = cands.first(where: { m.atoms[$0].atomicNumber > 1 }) ?? cands.first
            guard let c = pick else { return nil }
            let rv = bUnit(m.atoms[c].position - m.atoms[b].position)
            let q = rv - simd_dot(rv, u) * u
            return simd_length(q) < 1e-6 ? nil : simd_normalize(q)
        }

        switch hyb {
        case .sp:
            if k == 0 { let x = Vec3(1, 0, 0); return n == 1 ? [x] : [x, -x] }
            if k == 1 { return [-us[0]] }
            return []
        case .sp2:
            if k == 0 {
                let ds = (0..<3).map { j -> Vec3 in let a = Double(j) * 2 * .pi / 3; return Vec3(cos(a), sin(a), 0) }
                return Array(ds.prefix(n))
            }
            if k == 1 {
                let u = us[0]
                let q = refQ(u) ?? perp(u)
                let s3 = sin(2 * Double.pi / 3)
                let plus = -0.5 * u + s3 * q, minus = -0.5 * u - s3 * q
                if n >= 2 { return [plus, minus] }
                return (z == 8) ? [plus] : [minus]
            }
            if k == 2 {
                var d = -(us[0] + us[1])
                if simd_length(d) < 1e-6 { d = perp(us[0]) }
                return [simd_normalize(d)]
            }
            if k == 3 {
                var d = -(us[0] + us[1] + us[2])
                if simd_length(d) < 1e-6 { d = simd_cross(us[0] - us[1], us[0] - us[2]) }
                return [simd_normalize(d)]
            }
            return []
        default: // sp3
            if k == 0 {
                let s = 1 / 3.0.squareRoot()
                let t = [Vec3(1, 1, 1) * s, Vec3(1, -1, -1) * s, Vec3(-1, 1, -1) * s, Vec3(-1, -1, 1) * s]
                return Array(t.prefix(n))
            }
            if k == 1 {
                let u = us[0]
                let e1 = refQ(u) ?? perp(u)
                let e2 = simd_cross(u, e1)
                return (0..<min(n, 3)).map { j in
                    let phi = Double.pi + Double(j) * 2 * .pi / 3
                    return u * cos(tetra) + sin(tetra) * (cos(phi) * e1 + sin(phi) * e2)
                }
            }
            if k == 2 {
                var s = -(us[0] + us[1])
                var w = simd_cross(us[0], us[1])
                if simd_length(w) < 1e-6 { w = perp(us[0]); s = perp(w) }
                s = simd_normalize(s); w = simd_normalize(w)
                let a = tetra / 2
                if n >= 2 { return [s * cos(a) + w * sin(a), s * cos(a) - w * sin(a)] }
                return [s * cos(a) + w * sin(a)]
            }
            if k == 3 {
                var d = -(us[0] + us[1] + us[2])
                if simd_length(d) < 1e-6 { d = simd_cross(us[0] - us[1], us[0] - us[2]) }
                return [simd_normalize(d)]
            }
            return []
        }
    }

    /// Add `count` hydrogens to one atom using the given (or guessed) hybridization geometry.
    static func placeHydrogens(_ m: inout Molecule, atom: Int, count: Int, hyb: Hybridization? = nil) {
        guard count > 0 else { return }
        let h = hyb ?? hybridization(m, atom: atom)
        let dirs = newDirections(m, atom: atom, count: count, hyb: h == .none ? .sp3 : h)
        let z = m.atoms[atom].atomicNumber
        let len = BuildElements.bondLength(z, 1)
        for d in dirs.prefix(count) {
            let idx = m.buildAddAtom(1, at: m.atoms[atom].position + d * len)
            m.buildSetBond(atom, idx, .single)
        }
    }

    public static func addHydrogens(_ m: inout Molecule, atoms: [Int]? = nil) {
        let shift = chargeShift(m)
        let targets = atoms ?? Array(m.atoms.indices)
        for i in targets where i >= 0 && i < m.atoms.count {
            let n = openValence(m, i, shift: shift)
            if n > 0 { placeHydrogens(&m, atom: i, count: n) }
        }
    }

    public static func removeHydrogens(_ m: inout Molecule, atoms: [Int]? = nil) {
        var rem = Set<Int>()
        if let atoms {
            let set = Set(atoms)
            for a in atoms where a >= 0 && a < m.atoms.count && m.atoms[a].atomicNumber == 1 { rem.insert(a) }
            for b in m.bonds {
                if set.contains(b.a), m.atoms[b.b].atomicNumber == 1 { rem.insert(b.b) }
                if set.contains(b.b), m.atoms[b.a].atomicNumber == 1 { rem.insert(b.a) }
            }
        } else {
            for (i, a) in m.atoms.enumerated() where a.atomicNumber == 1 {
                // keep H2 style molecules where both atoms are hydrogen
                let nb = m.buildNeighbors(of: i)
                if nb.isEmpty || nb.contains(where: { m.atoms[$0].atomicNumber > 1 }) { rem.insert(i) }
            }
            if rem.count == m.atoms.count, !m.atoms.isEmpty { rem.removeAll() }
        }
        if !rem.isEmpty { m = m.buildRemovingAtoms(rem) }
    }

    public static func deleteAtoms(_ m: inout Molecule, _ s: Set<Int>) {
        let valid = s.filter { $0 >= 0 && $0 < m.atoms.count }
        if !valid.isEmpty { m = m.buildRemovingAtoms(valid) }
    }

    /// Remove terminal hydrogens of `atoms`; returns new indices of `atoms`.
    static func stripTerminalH(_ m: inout Molecule, from atoms: [Int]) -> [Int] {
        var rem = Set<Int>()
        for a in atoms {
            for n in m.buildNeighbors(of: a) where m.atoms[n].atomicNumber == 1 && m.buildNeighbors(of: n).count == 1 { rem.insert(n) }
        }
        let remap = atoms.map { a in a - rem.filter { $0 < a }.count }
        if !rem.isEmpty { m = m.buildRemovingAtoms(rem) }
        return remap
    }

    public static func setElement(_ m: inout Molecule, atom: Int, to z: Int, adjustHydrogens: Bool = true) {
        guard atom >= 0, atom < m.atoms.count, m.atoms[atom].atomicNumber != z else { return }
        var a = atom
        if adjustHydrogens { a = stripTerminalH(&m, from: [atom])[0] }
        m.atoms[a].atomicNumber = z
        guard adjustHydrogens else { return }
        // refit bond lengths of terminal neighbours (heavy chain stays put)
        addHydrogens(&m, atoms: [a])
    }

    static func reachable(_ m: Molecule, from s: Int, to t: Int, without e: (Int, Int)) -> Bool {
        var seen = Set([s]); var stack = [s]
        while let x = stack.popLast() {
            for n in m.buildNeighbors(of: x) {
                if (x == e.0 && n == e.1) || (x == e.1 && n == e.0) { continue }
                if n == t { return true }
                if seen.insert(n).inserted { stack.append(n) }
            }
        }
        return false
    }

    public static func setBondOrder(_ m: inout Molecule, _ a: Int, _ b: Int, _ order: BondOrder?, adjustHydrogens: Bool = true) {
        guard a != b, a >= 0, b >= 0, a < m.atoms.count, b < m.atoms.count else { return }
        // A bond to hydrogen can only be single (and stripping terminal H would delete an endpoint).
        if m.atoms[a].atomicNumber == 1 || m.atoms[b].atomicNumber == 1 {
            if order == nil { m.buildSetBond(a, b, nil) } else { m.buildSetBond(a, b, .single) }
            return
        }
        var a2 = a, b2 = b
        if adjustHydrogens {
            let r = stripTerminalH(&m, from: [a, b])
            a2 = r[0]; b2 = r[1]
        }
        m.buildSetBond(a2, b2, order)
        if adjustHydrogens {
            if let order, !reachable(m, from: b2, to: a2, without: (a2, b2)) {
                let ideal = BuildElements.bondLength(m.atoms[a2].atomicNumber, m.atoms[b2].atomicNumber, order: order)
                GeometryEdit.setDistance(&m, a2, b2, to: ideal)
            }
            addHydrogens(&m, atoms: [a2, b2])
        }
    }

    // MARK: rigid operations

    public static func centroid(_ m: Molecule) -> Vec3 {
        guard !m.atoms.isEmpty else { return .zero }
        return m.atoms.reduce(Vec3.zero) { $0 + $1.position } / Double(m.atoms.count)
    }

    public static func invert(_ m: inout Molecule, center: Vec3? = nil) {
        let c = center ?? centroid(m)
        for i in m.atoms.indices { m.atoms[i].position = 2 * c - m.atoms[i].position }
    }

    public static func mirror(_ m: inout Molecule, planeNormal: Vec3, through: Vec3? = nil) {
        let n = bUnit(planeNormal)
        let c = through ?? centroid(m)
        for i in m.atoms.indices {
            let p = m.atoms[i].position
            m.atoms[i].position = p - 2 * simd_dot(p - c, n) * n
        }
    }

    public static func perceiveBonds(_ m: inout Molecule, tolerance: Double = 0.45) {
        var out = [Bond]()
        let n = m.atoms.count
        for i in 0..<n {
            let zi = m.atoms[i].atomicNumber
            let ri = BuildElements.covalentRadius(zi)
            for j in (i + 1)..<max(n, i + 1) {
                let zj = m.atoms[j].atomicNumber
                let rsum = ri + BuildElements.covalentRadius(zj)
                let d = simd_distance(m.atoms[i].position, m.atoms[j].position)
                guard d > 0.4, d < rsum + tolerance else { continue }
                if zi == 1 && zj == 1 && n > 2 && d > 0.9 { continue }
                var order = BondOrder.single
                let ratio = d / rsum
                let heavy = zi > 1 && zj > 1
                let cno: Set<Int> = [6, 7, 8]
                if heavy && cno.contains(zi) && cno.contains(zj) {
                    if ratio < 0.82 { order = .triple }
                    else if ratio < 0.90 { order = .double }
                    else if ratio < 0.955 && zi != 8 && zj != 8 { order = .aromatic }
                }
                out.append(Bond(i, j, order: order))
            }
        }
        m.bonds = out
    }
}
