import Foundation
import MolSIMD

/// A set of selected atom indices (value type). Indices refer to `Molecule.atoms`.
public struct AtomSelection: Sendable, Hashable, Codable {
    public var atoms: Set<Int>

    public init() { atoms = [] }
    public init(_ s: some Sequence<Int>) { atoms = Set(s) }

    public var isEmpty: Bool { atoms.isEmpty }
    public var count: Int { atoms.count }
    public func contains(_ i: Int) -> Bool { atoms.contains(i) }
    /// Selected indices in ascending order.
    public var sorted: [Int] { atoms.sorted() }

    public mutating func insert(_ i: Int) { atoms.insert(i) }
    public mutating func remove(_ i: Int) { atoms.remove(i) }
    public mutating func toggle(_ i: Int) { if atoms.contains(i) { atoms.remove(i) } else { atoms.insert(i) } }
    public mutating func selectAll(count: Int) { atoms = Set(0..<max(count, 0)) }
    public mutating func clear() { atoms.removeAll() }
    /// Selects every index in 0..<count that is not selected and deselects the rest.
    public mutating func invert(count: Int) {
        atoms = Set((0..<max(count, 0)).filter { !atoms.contains($0) })
    }

    /// Updates indices after `Molecule.removeAtoms` (old index -> new index, nil if removed).
    /// Indices outside the map are dropped.
    public mutating func remap(_ map: [Int?]) {
        var out = Set<Int>()
        for i in atoms where i >= 0 && i < map.count { if let j = map[i] { out.insert(j) } }
        atoms = out
    }

    /// Drops indices that are not valid for an `count`-atom molecule.
    public mutating func clamp(count: Int) { atoms = atoms.filter { $0 >= 0 && $0 < count } }

    /// Indices into `m.bonds` of bonds with both ends selected.
    public func bonds(in m: Molecule) -> [Int] {
        m.bonds.indices.filter { atoms.contains(m.bonds[$0].a) && atoms.contains(m.bonds[$0].b) }
    }

    /// The connected component (via bonds) containing atom `i`. Empty if `i` is out of range.
    public static func fragment(of i: Int, in m: Molecule) -> AtomSelection {
        guard i >= 0, i < m.atoms.count else { return AtomSelection() }
        let adj = m.adjacency()
        var seen: Set<Int> = [i]
        var queue = [i]
        var head = 0
        while head < queue.count {
            let v = queue[head]; head += 1
            for w in adj[v] where seen.insert(w).inserted { queue.append(w) }
        }
        return AtomSelection(seen)
    }

    public static func byElement(_ z: Int, in m: Molecule) -> AtomSelection {
        AtomSelection(m.atoms.indices.filter { m.atoms[$0].atomicNumber == z })
    }

    /// Atoms (excluding `i`) within `radius` Å of atom `i`. Empty if `i` is out of range.
    public static func within(radius: Double, of i: Int, in m: Molecule) -> AtomSelection {
        guard i >= 0, i < m.atoms.count else { return AtomSelection() }
        let c = m.atoms[i].position
        let r2 = radius * radius
        return AtomSelection(m.atoms.indices.filter { $0 != i && simd_length_squared(m.atoms[$0].position - c) <= r2 })
    }
}
