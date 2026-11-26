import Foundation
import MolSIMD

// Owned by Lead 1 (Core). Structural editing and internal-coordinate manipulation.

public enum MoveMode: Sendable {
    case second      // move the atom-j (last) side
    case first       // move the atom-i (first) side
    case both        // split motion half/half
    case atomsOnly   // move only the end atom
}

extension Molecule {
    // MARK: add / remove

    @discardableResult
    public mutating func addAtom(atomicNumber: Int, position: Vec3) -> Int {
        let idx = atoms.count
        atoms.append(Atom(id: idx, atomicNumber: atomicNumber, position: position))
        return idx
    }

    @discardableResult
    public mutating func removeAtoms(_ indices: some Sequence<Int>) -> [Int?] {
        let n = atoms.count
        var drop = Array(repeating: false, count: n)
        for i in indices where i >= 0 && i < n { drop[i] = true }
        var map = [Int?](repeating: nil, count: n)
        var next = 0
        var newAtoms: [Atom] = []
        newAtoms.reserveCapacity(n)
        for i in 0..<n where !drop[i] {
            map[i] = next; next += 1
            newAtoms.append(atoms[i])
        }
        var newBonds: [Bond] = []
        for b in bonds {
            guard b.a >= 0, b.b < n, let a = map[b.a], let c = map[b.b] else { continue }
            newBonds.append(Bond(a, c, order: b.order))
        }
        atoms = newAtoms
        bonds = newBonds
        renumberAtomIDs()
        return map
    }

    public mutating func removeAtom(_ i: Int) { removeAtoms([i]) }

    @discardableResult
    public mutating func addBond(_ i: Int, _ j: Int, order: BondOrder = .single) -> Bool {
        guard i != j, i >= 0, j >= 0, i < atoms.count, j < atoms.count else { return false }
        if bondIndex(i, j) != nil { return false }
        bonds.append(Bond(i, j, order: order))
        return true
    }

    @discardableResult
    public mutating func removeBond(_ i: Int, _ j: Int) -> Bool {
        guard let k = bondIndex(i, j) else { return false }
        bonds.remove(at: k)
        return true
    }

    public mutating func setBondOrder(_ i: Int, _ j: Int, _ order: BondOrder) {
        if let k = bondIndex(i, j) { bonds[k].order = order } else { addBond(i, j, order: order) }
    }

    // MARK: connectivity

    public func fragments() -> [[Int]] {
        let adj = adjacency()
        var seen = Array(repeating: false, count: atoms.count)
        var out: [[Int]] = []
        for s in atoms.indices where !seen[s] {
            var comp: [Int] = []
            var stack = [s]
            seen[s] = true
            while let u = stack.popLast() {
                comp.append(u)
                for v in adj[u] where !seen[v] { seen[v] = true; stack.append(v) }
            }
            out.append(comp.sorted())
        }
        return out
    }

    public func fragment(containing i: Int) -> [Int] {
        guard i >= 0, i < atoms.count else { return [] }
        return reach(from: i, blocking: nil, adj: adjacency()).sorted()
    }

    /// Atoms reachable from `j` without crossing bond i–j (includes j; includes `i` if i–j is in a ring).
    public func atomsOnSide(of j: Int, from i: Int) -> Set<Int> {
        guard j >= 0, j < atoms.count else { return [] }
        return reach(from: j, blocking: (i, j), adj: adjacency())
    }

    private func reach(from s: Int, blocking: (Int, Int)?, adj: [[Int]]) -> Set<Int> {
        var seen: Set<Int> = [s]
        var stack = [s]
        while let u = stack.popLast() {
            for v in adj[u] {
                if let (p, q) = blocking, (u == p && v == q) || (u == q && v == p) { continue }
                if seen.insert(v).inserted { stack.append(v) }
            }
        }
        return seen
    }

    // MARK: bulk transforms

    public mutating func rotate(atoms idx: some Sequence<Int>, about origin: Vec3, axis: Vec3, degrees: Double) {
        let n = atoms.count
        for i in idx where i >= 0 && i < n {
            atoms[i].position = VecMath.rotate(atoms[i].position, about: origin, axis: axis, degrees: degrees)
        }
    }

    public mutating func translate(atoms idx: some Sequence<Int>, by d: Vec3) {
        let n = atoms.count
        for i in idx where i >= 0 && i < n { atoms[i].position += d }
    }

    // MARK: internal-coordinate setters

    /// The pair of moving sets (first side, second side) for a connection a–b.
    private func sides(_ a: Int, _ b: Int) -> (first: Set<Int>, second: Set<Int>) {
        let adj = adjacency()
        let blocking: (Int, Int)? = bondIndex(a, b) != nil ? (a, b) : nil
        var sb = reach(from: b, blocking: blocking, adj: adj)
        var sa = reach(from: a, blocking: blocking, adj: adj)
        if sa.contains(b) || sb.contains(a) { sa = [a]; sb = [b] }
        return (sa, sb)
    }

    public mutating func setDistance(_ i: Int, _ j: Int, to value: Double, moving: MoveMode = .second) {
        guard i != j, i >= 0, j >= 0, i < atoms.count, j < atoms.count else { return }
        let pi = atoms[i].position, pj = atoms[j].position
        var u = pj - pi
        let len = simd_length(u)
        u = len > 1e-12 ? u / len : Vec3(0, 0, 1)
        let delta = value - len
        let s = sides(i, j)
        var sa = s.first, sb = s.second
        // If sides overlap (e.g. unbonded atoms in same fragment), fall back to atoms only.
        if !sa.isDisjoint(with: sb) { sa = [i]; sb = [j] }
        switch moving {
        case .second: translate(atoms: sb, by: u * delta)
        case .first: translate(atoms: sa, by: -u * delta)
        case .both:
            translate(atoms: sb, by: u * (delta / 2))
            translate(atoms: sa, by: -u * (delta / 2))
        case .atomsOnly: translate(atoms: [j], by: u * delta)
        }
    }

    public mutating func setAngle(_ i: Int, _ j: Int, _ k: Int, to degrees: Double, moving: MoveMode = .second) {
        let n = atoms.count
        guard i != j, j != k, i != k, i >= 0, j >= 0, k >= 0, i < n, j < n, k < n else { return }
        let pi = atoms[i].position, pj = atoms[j].position, pk = atoms[k].position
        let a = pi - pj, b = pk - pj
        var axis = simd_cross(a, b)
        if simd_length(axis) < 1e-9 * max(1, simd_length(a) * simd_length(b)) {
            axis = VecMath.perpendicular(simd_length(a) > 1e-12 ? a : b)
        }
        let delta = degrees - VecMath.angle(pi, pj, pk)
        var sk = atomsOnSide(of: k, from: j)
        var si = atomsOnSide(of: i, from: j)
        if sk.contains(j) || sk.contains(i) { sk = [k] }
        if si.contains(j) || si.contains(k) { si = [i] }
        if !sk.isDisjoint(with: si) { sk = [k]; si = [i] }
        switch moving {
        case .second: rotate(atoms: sk, about: pj, axis: axis, degrees: delta)
        case .first: rotate(atoms: si, about: pj, axis: axis, degrees: -delta)
        case .both:
            rotate(atoms: sk, about: pj, axis: axis, degrees: delta / 2)
            rotate(atoms: si, about: pj, axis: axis, degrees: -delta / 2)
        case .atomsOnly: rotate(atoms: [k], about: pj, axis: axis, degrees: delta)
        }
    }

    public mutating func setDihedral(_ i: Int, _ j: Int, _ k: Int, _ l: Int, to degrees: Double, moving: MoveMode = .second) {
        let n = atoms.count
        guard Set([i, j, k, l]).count == 4, [i, j, k, l].allSatisfy({ $0 >= 0 && $0 < n }) else { return }
        let pi = atoms[i].position, pj = atoms[j].position, pk = atoms[k].position, pl = atoms[l].position
        let axis = pk - pj
        guard simd_length(axis) > 1e-12 else { return }
        let delta = degrees - VecMath.dihedral(pi, pj, pk, pl)
        var sl = atomsOnSide(of: k, from: j)
        var si = atomsOnSide(of: j, from: k)
        if sl.contains(j) || sl.contains(i) { sl = [l] } else if !sl.contains(l) { sl = [l] }
        if si.contains(k) || si.contains(l) { si = [i] } else if !si.contains(i) { si = [i] }
        if !sl.isDisjoint(with: si) { sl = [l]; si = [i] }
        switch moving {
        case .second: rotate(atoms: sl, about: pj, axis: axis, degrees: delta)
        case .first: rotate(atoms: si, about: pj, axis: axis, degrees: -delta)
        case .both:
            rotate(atoms: sl, about: pj, axis: axis, degrees: delta / 2)
            rotate(atoms: si, about: pj, axis: axis, degrees: -delta / 2)
        case .atomsOnly: rotate(atoms: [l], about: pj, axis: axis, degrees: delta)
        }
    }

    // MARK: merge / sub

    @discardableResult
    public mutating func merge(_ other: Molecule) -> Range<Int> {
        let off = atoms.count
        for a in other.atoms {
            var b = a
            b.id = atoms.count
            atoms.append(b)
        }
        for b in other.bonds { bonds.append(Bond(b.a + off, b.b + off, order: b.order)) }
        return off..<atoms.count
    }

    public func subMolecule(_ indices: [Int]) -> Molecule {
        var map: [Int: Int] = [:]
        var m = Molecule()
        m.title = title
        for i in indices where i >= 0 && i < atoms.count && map[i] == nil {
            map[i] = m.atoms.count
            var a = atoms[i]
            a.id = m.atoms.count
            m.atoms.append(a)
        }
        for b in bonds {
            if let x = map[b.a], let y = map[b.b] { m.bonds.append(Bond(x, y, order: b.order)) }
        }
        return m
    }
}
