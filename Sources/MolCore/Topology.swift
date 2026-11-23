import Foundation
import simd

// Owned by Lead 1. Basic connectivity queries on Molecule.
// INVARIANT used across MolCore: atoms[i].id == i (editing ops renumber ids).

extension Molecule {
    /// Neighbor lists indexed by atom index (built from `bonds`). O(N + B).
    public func adjacency() -> [[Int]] {
        var adj = Array(repeating: [Int](), count: atoms.count)
        for b in bonds where b.a < atoms.count && b.b < atoms.count && b.a != b.b {
            adj[b.a].append(b.b)
            adj[b.b].append(b.a)
        }
        return adj
    }

    /// Indices of atoms bonded to atom `i`. O(B); use `adjacency()` in loops.
    public func neighbors(of i: Int) -> [Int] {
        var out: [Int] = []
        for b in bonds {
            if b.a == i { out.append(b.b) } else if b.b == i { out.append(b.a) }
        }
        return out
    }

    /// Index into `bonds` of the bond between `i` and `j`, if any.
    public func bondIndex(_ i: Int, _ j: Int) -> Int? {
        let lo = min(i, j), hi = max(i, j)
        return bonds.firstIndex { $0.a == lo && $0.b == hi }
    }

    /// The bond between `i` and `j`, if any.
    public func bond(between i: Int, and j: Int) -> Bond? {
        bondIndex(i, j).map { bonds[$0] }
    }

    public func areBonded(_ i: Int, _ j: Int) -> Bool { bondIndex(i, j) != nil }

    /// Number of explicit bonds to atom `i`.
    public func degree(of i: Int) -> Int { neighbors(of: i).count }

    /// Sum of bond orders at atom `i` (aromatic counts 1.5).
    public func bondOrderSum(of i: Int) -> Double {
        bonds.reduce(0) { $1.a == i || $1.b == i ? $0 + $1.order.rawValue : $0 }
    }

    /// Positions of all atoms in index order.
    public var positions: [Vec3] {
        get { atoms.map(\.position) }
        set { for i in 0..<min(newValue.count, atoms.count) { atoms[i].position = newValue[i] } }
    }

    /// Re-assigns `atoms[i].id = i` (restores the MolCore invariant).
    public mutating func renumberAtomIDs() {
        for i in atoms.indices { atoms[i].id = i }
    }

    /// Removes duplicate / self / out-of-range bonds, keeping the first occurrence.
    public mutating func normalizeBonds() {
        var seen = Set<Int64>()
        let n = atoms.count
        bonds = bonds.filter { b in
            guard b.a != b.b, b.a >= 0, b.b < n else { return false }
            return seen.insert(Int64(b.a) << 32 | Int64(b.b)).inserted
        }
    }

    // Convenience measurements by atom index (degrees for angles).
    public func distance(_ i: Int, _ j: Int) -> Double {
        VecMath.distance(atoms[i].position, atoms[j].position)
    }
    public func angle(_ i: Int, _ j: Int, _ k: Int) -> Double {
        VecMath.angle(atoms[i].position, atoms[j].position, atoms[k].position)
    }
    public func dihedral(_ i: Int, _ j: Int, _ k: Int, _ l: Int) -> Double {
        VecMath.dihedral(atoms[i].position, atoms[j].position, atoms[k].position, atoms[l].position)
    }
}
