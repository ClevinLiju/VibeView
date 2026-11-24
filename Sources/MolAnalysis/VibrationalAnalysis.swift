import Foundation
import simd
import MolCore

/// Characterizes a normal mode by its internal-coordinate content (Wilson B-matrix projection of the
/// Cartesian displacement onto bond stretches, valence-angle bends and torsions).
public enum VibrationalModeAnalysis {
    public enum CoordinateKind: String, Sendable, Codable {
        case stretch, bend, torsion, outOfPlane = "out-of-plane bend"
    }

    public struct InternalContribution: Sendable, Equatable {
        public var kind: CoordinateKind
        public var atoms: [Int]          // 0-based: 2 (stretch), 3 (bend, apex in the middle), 4 (torsion)
        public var label: String         // e.g. "C=O", "H–C–H", "H–C–C–H"
        /// Signed first-order change of the coordinate per unit displacement (Å or rad·Å_ref).
        public var amplitude: Double
        public var percent: Double       // approximate PED share, k·amplitude² / Σ (0–100)
    }

    public struct ModeCharacter: Sendable, Equatable {
        /// Human label such as "C=O stretch", "C–H stretch (asym)", "H–C–H bend", or "mixed: C–O stretch + C–O–H bend".
        public var label: String
        /// Grouped contributions (same kind + label summed), largest first.
        public var groups: [(kind: CoordinateKind, label: String, percent: Double)]
        public var contributions: [InternalContribution]   // largest first
        public var dominant: InternalContribution? { contributions.first }

        public static func == (a: ModeCharacter, b: ModeCharacter) -> Bool {
            a.label == b.label && a.contributions == b.contributions
        }
    }

    /// Approximate potential-energy distribution: each coordinate's share is k_q·s_q² with typical diagonal
    /// force constants (mdyn/Å for stretches × bond order, mdyn·Å/rad² for bends/torsions). This keeps light-atom
    /// bends from swamping heavy-atom stretches the way a bare geometric projection would.
    static func forceConstant(_ kind: CoordinateKind, order: BondOrder? = nil) -> Double {
        switch kind {
        case .stretch: return 4.5 * (order?.rawValue ?? 1)
        case .bend: return 0.7
        case .torsion: return 0.07
        case .outOfPlane: return 0.3
        }
    }

    static func elementOrder(_ a: Atom, _ b: Atom) -> Bool {
        func rank(_ z: Int) -> Int { z == 6 ? 0 : (z == 1 ? 1000 : z) }
        return rank(a.atomicNumber) < rank(b.atomicNumber)
    }

    static func bondSymbol(_ o: BondOrder?) -> String {
        switch o { case .double?: "="; case .triple?: "≡"; case .aromatic?: "⋯"; default: "–" }
    }

    public static func analyze(mode: NormalMode, molecule: Molecule) -> ModeCharacter {
        let atoms = molecule.atoms
        let n = atoms.count
        guard n >= 2, mode.displacements.count == n else {
            return ModeCharacter(label: "unassigned", groups: [], contributions: [])
        }
        var topo = molecule
        if topo.bonds.isEmpty { topo.perceiveBonds() }
        if topo.bonds.allSatisfy({ $0.order == .single }) { topo.perceiveBondOrders() }
        let bonds = topo.bonds
        var adj = [[Int]](repeating: [], count: n)
        var order: [Int: BondOrder] = [:]
        for b in bonds where b.a < n && b.b < n {
            adj[b.a].append(b.b); adj[b.b].append(b.a); order[b.a * n + b.b] = b.order; order[b.b * n + b.a] = b.order
        }
        // Normalize the displacement.
        var d = mode.displacements
        let norm = sqrt(d.reduce(0) { $0 + simd_length_squared($1) })
        if norm > 0 { d = d.map { $0 / norm } }
        let x = atoms.map(\.position)
        var list: [InternalContribution] = []

        // Stretches: dr = e_ab · (d_b - d_a)
        for b in bonds where b.a < n && b.b < n {
            let e = simd_normalize(x[b.b] - x[b.a])
            let amp = simd_dot(e, d[b.b] - d[b.a])
            let (p, q) = elementOrder(atoms[b.a], atoms[b.b]) ? (b.a, b.b) : (b.b, b.a)
            list.append(.init(kind: .stretch, atoms: [p, q], label: atoms[p].symbol + bondSymbol(b.order) + atoms[q].symbol,
                              amplitude: amp, percent: 0))
        }
        // Bends i–j–k (apex j): Wilson s-vectors.
        for j in 0..<n where adj[j].count >= 2 {
            let nb = adj[j].sorted()
            for ii in 0..<nb.count { for kk in (ii + 1)..<nb.count {
                let i = nb[ii], k = nb[kk]
                let ri = x[i] - x[j], rk = x[k] - x[j]
                let li = simd_length(ri), lk = simd_length(rk)
                guard li > 1e-6, lk > 1e-6 else { continue }
                let ei = ri / li, ek = rk / lk
                let c = max(-1, min(1, simd_dot(ei, ek))), s = sqrt(max(1e-12, 1 - c * c))
                guard s > 1e-3 else { continue }   // linear angle: skip (needs a linear-bend pair)
                let si = (c * ei - ek) / (li * s), sk = (c * ek - ei) / (lk * s), sj = -(si + sk)
                let amp = simd_dot(si, d[i]) + simd_dot(sk, d[k]) + simd_dot(sj, d[j])
                let (p, q) = elementOrder(atoms[i], atoms[k]) ? (i, k) : (k, i)
                list.append(.init(kind: .bend, atoms: [p, j, q], label: "\(atoms[p].symbol)–\(atoms[j].symbol)–\(atoms[q].symbol)",
                                  amplitude: amp, percent: 0))
            } }
        }
        // Torsions about each bond j–k (one per bond: first neighbors), numeric derivative of the dihedral.
        for b in bonds where b.a < n && b.b < n {
            let j = b.a, k = b.b
            guard let i = adj[j].filter({ $0 != k }).min(), let l = adj[k].filter({ $0 != j && $0 != i }).min() else { continue }
            let h = 1e-4
            func dih(_ t: Double) -> Double {
                VecMath.dihedral(x[i] + t * d[i], x[j] + t * d[j], x[k] + t * d[k], x[l] + t * d[l])
            }
            var dphi = dih(h) - dih(-h)
            if dphi > 180 { dphi -= 360 } else if dphi < -180 { dphi += 360 }
            let amp = dphi / (2 * h) * .pi / 180
            list.append(.init(kind: .torsion, atoms: [i, j, k, l],
                              label: "\(atoms[i].symbol)–\(atoms[j].symbol)–\(atoms[k].symbol)–\(atoms[l].symbol)",
                              amplitude: amp, percent: 0))
        }
        // Out-of-plane: signed height of a 3-coordinate centre above the plane of its neighbours (Å).
        for j in 0..<n where adj[j].count == 3 {
            let nb = adj[j].sorted()
            let h = 1e-4
            func height(_ t: Double) -> Double {
                let p = nb.map { x[$0] + t * d[$0] }, c = x[j] + t * d[j]
                let nrm = simd_cross(p[1] - p[0], p[2] - p[0])
                let l = simd_length(nrm)
                return l > 1e-9 ? simd_dot(c - p[0], nrm / l) : 0
            }
            let amp = (height(h) - height(-h)) / (2 * h)
            list.append(.init(kind: .outOfPlane, atoms: [j] + nb, label: atoms[j].symbol, amplitude: amp, percent: 0))
        }
        func k(_ c: InternalContribution) -> Double {
            forceConstant(c.kind, order: c.kind == .stretch ? order[c.atoms[0] * n + c.atoms[1]] : nil)
        }
        let total = list.reduce(0) { $0 + k($1) * $1.amplitude * $1.amplitude }
        guard total > 1e-12 else { return ModeCharacter(label: "unassigned", groups: [], contributions: []) }
        for i in list.indices { list[i].percent = 100 * k(list[i]) * list[i].amplitude * list[i].amplitude / total }
        list.sort { $0.percent > $1.percent }

        // Group equivalent coordinates.
        var gOrder: [String] = []
        var gSum: [String: Double] = [:], gKind: [String: CoordinateKind] = [:], gLabel: [String: String] = [:]
        var gMembers: [String: [InternalContribution]] = [:]
        for c in list {
            let key = c.kind.rawValue + "|" + c.label
            if gSum[key] == nil { gOrder.append(key); gKind[key] = c.kind; gLabel[key] = c.label }
            gSum[key, default: 0] += c.percent
            gMembers[key, default: []].append(c)
        }
        let groups = gOrder.map { (kind: gKind[$0]!, label: gLabel[$0]!, percent: gSum[$0]!) }.sorted { $0.percent > $1.percent }
        func name(_ g: (kind: CoordinateKind, label: String, percent: Double)) -> String {
            var s = "\(g.label) \(g.kind.rawValue)"
            let key = g.kind.rawValue + "|" + g.label
            let sig = (gMembers[key] ?? []).filter { $0.percent > 0.15 * g.percent }
            if g.kind == .stretch && sig.count >= 2 {
                // Members sharing an atom (e.g. CH2, NH2) are sym when they stretch in phase.
                let pos = sig.filter { $0.amplitude > 0 }.count, neg = sig.count - pos
                s += (pos == 0 || neg == 0) ? " (sym)" : " (asym)"
            }
            return s
        }
        var label = name(groups[0])
        if groups[0].percent < 45, groups.count > 1, groups[1].percent > 20 {
            label = "mixed: " + name(groups[0]) + " + " + name(groups[1])
        }
        if mode.frequency < 0 { label += " (imaginary)" }
        return ModeCharacter(label: label, groups: groups, contributions: list)
    }

    public static func labels(for modes: [NormalMode], molecule: Molecule) -> [String] {
        modes.map { analyze(mode: $0, molecule: molecule).label }
    }
}
