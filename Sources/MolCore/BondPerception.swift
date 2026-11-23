import Foundation
import simd

extension Molecule {
    /// Distance-based bond perception: bond if 0.4 < d < rCov(a) + rCov(b) + tolerance.
    /// Dummy atoms are ignored. H-H pairs are limited to d <= 0.9 and each hydrogen keeps only
    /// its shortest bond. Result is sorted by (a, b); all bonds are single.
    public func perceivedBonds(tolerance: Double = 0.45) -> [Bond] {
        let n = atoms.count
        if n < 2 { return [] }
        let pos = atoms.map(\.position)
        let rad = atoms.map { $0.atomicNumber > 0 ? $0.element.covalentRadius : 0 }
        let maxR = rad.max() ?? 0
        let cutoff = 2 * maxR + tolerance
        if cutoff <= 0 { return [] }
        let grid = NeighborGrid(positions: pos, cellSize: cutoff)
        var cand: [(Int, Int, Double)] = []
        for (i, j) in grid.pairs(within: cutoff) {
            let zi = atoms[i].atomicNumber, zj = atoms[j].atomicNumber
            if zi <= 0 || zj <= 0 { continue }
            let d = simd_length(pos[i] - pos[j])
            if d <= 0.4 || d >= rad[i] + rad[j] + tolerance { continue }
            if zi == 1 && zj == 1 && d > 0.9 { continue }
            cand.append((i, j, d))
        }
        // Hydrogens keep only their shortest bond.
        var best = [Double](repeating: .infinity, count: n)
        var bestPartner = [Int](repeating: -1, count: n)
        for (i, j, d) in cand {
            if atoms[i].atomicNumber == 1 && d < best[i] { best[i] = d; bestPartner[i] = j }
            if atoms[j].atomicNumber == 1 && d < best[j] { best[j] = d; bestPartner[j] = i }
        }
        var out: [Bond] = []
        out.reserveCapacity(cand.count)
        for (i, j, _) in cand {
            if atoms[i].atomicNumber == 1 && bestPartner[i] != j { continue }
            if atoms[j].atomicNumber == 1 && bestPartner[j] != i { continue }
            out.append(Bond(i, j))
        }
        out.sort { $0.a != $1.a ? $0.a < $1.a : $0.b < $1.b }
        return out
    }

    /// Replaces `bonds` with perceived bonds. With `keepExistingOrders`, bonds whose pair is
    /// still bonded retain their previous order.
    public mutating func perceiveBonds(tolerance: Double = 0.45, keepExistingOrders: Bool = true) {
        var fresh = perceivedBonds(tolerance: tolerance)
        if keepExistingOrders && !bonds.isEmpty {
            var old: [Int64: BondOrder] = [:]
            for b in bonds { old[Int64(b.a) << 32 | Int64(b.b)] = b.order }
            for k in fresh.indices {
                if let o = old[Int64(fresh[k].a) << 32 | Int64(fresh[k].b)] { fresh[k].order = o }
            }
        }
        bonds = fresh
    }
}
