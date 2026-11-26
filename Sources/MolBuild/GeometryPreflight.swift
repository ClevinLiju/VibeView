import Foundation
import simd
import MolCore

/// Problems in a structure that make a calculation likely to fail (an SCF that does not converge, a
/// meaningless optimization): an atom far from every other atom, a bond stretched far beyond its
/// covalent length, or several disconnected fragments. Checked before a job runs; the user decides.
public struct GeometryWarning: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// `atom` (0-based) has no other atom closer than `distance` Å.
        case isolatedAtom(atom: Int, distance: Double)
        /// Bonded atoms `a`, `b` are `distance` Å apart, `ratio` times the sum of their covalent radii.
        case stretchedBond(a: Int, b: Int, distance: Double, ratio: Double)
        /// The structure has `sizes.count` disconnected pieces (atom counts, largest first).
        case fragments(sizes: [Int])
    }
    public var kind: Kind
    public var message: String
}

public enum GeometryPreflight {
    /// Default limits: no neighbour within 3 Å, or a bond longer than 1.6 × (r_cov(a) + r_cov(b)).
    public static let isolationDistance = 3.0
    public static let bondStretchRatio = 1.6

    /// "O2" style label (element symbol + 1-based atom number).
    public static func label(_ m: Molecule, _ i: Int) -> String { Elements.symbol(m.atoms[i].atomicNumber) + "\(i + 1)" }

    public static func check(_ m: Molecule, isolationDistance: Double = isolationDistance,
                             bondStretchRatio: Double = bondStretchRatio) -> [GeometryWarning] {
        let n = m.atoms.count
        guard n > 1 else { return [] }
        var out: [GeometryWarning] = []
        let pos = m.atoms.map(\.position)

        // Isolated atoms: nearest neighbour farther than the limit.
        let grid = NeighborGrid(positions: pos, cellSize: max(isolationDistance, 1))
        for i in 0..<n {
            let near = grid.neighbors(of: pos[i], within: isolationDistance).filter { $0 != i }
            guard near.isEmpty else { continue }
            var best = Double.infinity
            for j in 0..<n where j != i { best = min(best, simd_distance(pos[i], pos[j])) }
            out.append(GeometryWarning(kind: .isolatedAtom(atom: i, distance: best),
                                       message: String(format: "Atom %@ is %.1f Å from its nearest neighbour.", label(m, i), best)))
        }

        // Stretched bonds (only bonds that are stored; perception would not create them).
        for b in m.bonds where b.a < n && b.b < n && b.a != b.b {
            let d = simd_distance(pos[b.a], pos[b.b])
            let ref = Elements.element(m.atoms[b.a].atomicNumber).covalentRadius + Elements.element(m.atoms[b.b].atomicNumber).covalentRadius
            guard ref > 0 else { continue }
            let r = d / ref
            if r > bondStretchRatio {
                out.append(GeometryWarning(kind: .stretchedBond(a: b.a, b: b.b, distance: d, ratio: r),
                                           message: String(format: "The bond %@–%@ is %.1f Å long (%.1f× a normal %@–%@ bond).",
                                                           label(m, b.a), label(m, b.b), d, r,
                                                           Elements.symbol(m.atoms[b.a].atomicNumber), Elements.symbol(m.atoms[b.b].atomicNumber))))
            }
        }

        // Disconnected fragments (bonds as stored; perceived from distances when there are none).
        var connected = m
        if connected.bonds.isEmpty { connected.bonds = m.perceivedBonds() }
        let sizes = connected.fragments().map(\.count).sorted(by: >)
        if sizes.count > 1 {
            let list = sizes.prefix(4).map(String.init).joined(separator: ", ") + (sizes.count > 4 ? ", …" : "")
            out.append(GeometryWarning(kind: .fragments(sizes: sizes),
                                       message: "The structure has \(sizes.count) disconnected fragments (\(list) atoms)."))
        }
        return out
    }

    /// One confirmation text for all warnings, or nil when the geometry looks fine.
    public static func confirmationText(_ warnings: [GeometryWarning]) -> String? {
        guard !warnings.isEmpty else { return nil }
        let shown = warnings.prefix(5).map(\.message)
        let more = warnings.count > 5 ? ["…and \(warnings.count - 5) more."] : []
        return (shown + more).joined(separator: "\n") + "\nRun anyway?"
    }
}
