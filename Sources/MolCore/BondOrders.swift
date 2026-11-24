import Foundation
import simd

// Bond-order perception, aromaticity, Kekulé structures and formal charges (heuristic, valence based).

private let organicZ: Set<Int> = [1, 5, 6, 7, 8, 9, 14, 15, 16, 17, 34, 35, 53]

private func valenceList(_ z: Int) -> [Int] {
    let v = Elements.element(z).valences
    if !v.isEmpty { return v }
    switch z {
    case 1, 9: return [1]
    case 5: return [3]
    case 6, 14: return [4]
    case 7, 15: return [3, 5]
    case 8: return [2]
    case 16, 34: return [2, 4, 6]
    case 17, 35, 53: return [1, 3, 5, 7]
    default: return []
    }
}

/// Number of additional bond-order units an atom with `d` explicit neighbors can still take
/// (smallest typical valence >= d, minus d). N with 4 neighbors is treated as ammonium (0).
private func baseRemaining(_ z: Int, _ d: Int) -> Int {
    if z == 7 && d >= 4 { return 0 }
    guard let t = valenceList(z).sorted().first(where: { $0 >= d }) else { return 0 }
    return min(t - d, 3)
}

/// Extra capacity granted to a hypervalent/cationic hub atom (nitro N+, sulfonyl S, phosphate P, perchlorate Cl ...).
private func expansion(_ z: Int, _ d: Int, _ currentTarget: Int) -> Int {
    if z == 7 { return d == 3 ? 1 : 0 }
    guard [14, 15, 16, 17, 34, 35, 53].contains(z) else { return 0 }
    if let nxt = valenceList(z).sorted().first(where: { $0 > currentTarget }) { return min(nxt - currentTarget, 4) }
    return 0
}

/// Edmonds' blossom algorithm for maximum cardinality matching on a general graph.
private struct BlossomMatcher {
    let n: Int
    let g: [[Int]]
    var match: [Int]
    private var p: [Int], base: [Int], used: [Bool], blossom: [Bool]

    init(n: Int, g: [[Int]], match: [Int]) {
        self.n = n; self.g = g; self.match = match
        p = [Int](repeating: -1, count: n); base = Array(0..<n)
        used = [Bool](repeating: false, count: n); blossom = [Bool](repeating: false, count: n)
    }

    private func lca(_ a0: Int, _ b0: Int) -> Int {
        var seen = [Bool](repeating: false, count: n)
        var a = a0, b = b0
        while true {
            a = base[a]; seen[a] = true
            if match[a] == -1 { break }
            a = p[match[a]]
        }
        while true {
            b = base[b]
            if seen[b] { return b }
            b = p[match[b]]
        }
    }

    private mutating func markPath(_ v0: Int, _ b: Int, _ child0: Int) {
        var v = v0, child = child0
        while base[v] != b {
            blossom[base[v]] = true; blossom[base[match[v]]] = true
            p[v] = child; child = match[v]; v = p[match[v]]
        }
    }

    private mutating func findPath(_ root: Int) -> Int {
        for i in 0..<n { used[i] = false; p[i] = -1; base[i] = i }
        used[root] = true
        var q = [root]; var qh = 0
        while qh < q.count {
            let v = q[qh]; qh += 1
            for to in g[v] {
                if base[v] == base[to] || match[v] == to { continue }
                if to == root || (match[to] != -1 && p[match[to]] != -1) {
                    let cb = lca(v, to)
                    for i in 0..<n { blossom[i] = false }
                    markPath(v, cb, to); markPath(to, cb, v)
                    for i in 0..<n where blossom[base[i]] {
                        base[i] = cb
                        if !used[i] { used[i] = true; q.append(i) }
                    }
                } else if p[to] == -1 {
                    p[to] = v
                    if match[to] == -1 { return to }
                    let t = match[to]; used[t] = true; q.append(t)
                }
            }
        }
        return -1
    }

    mutating func augmentAll() {
        for i in 0..<n where match[i] == -1 && !g[i].isEmpty {
            var v = findPath(i)
            while v != -1 {
                let pv = p[v], ppv = match[pv]
                match[v] = pv; match[pv] = v
                v = ppv
            }
        }
    }
}

extension Molecule {
    // MARK: bond orders

    /// Assigns single/double/triple orders from valence and geometry for organic main-group atoms
    /// (H,B,C,N,O,F,Si,P,S,Cl,Se,Br,I), then marks aromatic rings. Bonds to other elements (metals)
    /// are left single. Requires bonds to exist. Heuristic: shorter bonds (relative to covalent radii)
    /// are preferred as multiple bonds; a maximum matching on the "free valence" graph (Edmonds)
    /// guarantees every satisfiable atom is satisfied. Nitro/sulfonyl/phosphate/perchlorate-like
    /// hubs are allowed to expand their valence when terminal atoms would otherwise stay unsatisfied.
    public mutating func perceiveBondOrders() {
        guard !bonds.isEmpty else { return }
        let n = atoms.count
        var deg = [Int](repeating: 0, count: n)
        for b in bonds where b.a < n && b.b < n { deg[b.a] += 1; deg[b.b] += 1 }
        let eligible = atoms.map { organicZ.contains($0.atomicNumber) }
        var cand: [Int] = []
        for (k, b) in bonds.enumerated() {
            if b.a < n, b.b < n, eligible[b.a], eligible[b.b] { cand.append(k); bonds[k].order = .single }
        }
        var rem = [Int](repeating: 0, count: n)
        var target = [Int](repeating: 0, count: n)
        for i in 0..<n where eligible[i] {
            rem[i] = baseRemaining(atoms[i].atomicNumber, deg[i])
            target[i] = deg[i] + rem[i]
        }
        var (extra, matched) = solveMatching(rem: rem, cand: cand)
        var expanded = Set<Int>()
        let adjAll = adjacency()
        for _ in 0..<8 {
            var used = [Int](repeating: 0, count: n)
            for k in cand { used[bonds[k].a] += extra[k]; used[bonds[k].b] += extra[k] }
            var hubs: [Int] = []
            for i in 0..<n where eligible[i] && rem[i] - used[i] > 0 {
                for j in adjAll[i] where eligible[j] && !expanded.contains(j) && !hubs.contains(j) {
                    if expansion(atoms[j].atomicNumber, deg[j], target[j]) > 0 { hubs.append(j) }
                }
            }
            var improved = false
            for h in hubs {
                var r2 = rem
                r2[h] += expansion(atoms[h].atomicNumber, deg[h], target[h])
                let res = solveMatching(rem: r2, cand: cand)
                expanded.insert(h)
                if res.matched > matched {
                    rem = r2; extra = res.extra; matched = res.matched; improved = true
                    target[h] = deg[h] + rem[h]
                    break
                }
            }
            if !improved { break }
        }
        for k in cand {
            bonds[k].order = extra[k] >= 2 ? .triple : (extra[k] == 1 ? .double : .single)
        }
        markAromaticBonds()
    }

    private func solveMatching(rem: [Int], cand: [Int]) -> (extra: [Int], matched: Int) {
        let n = atoms.count
        var offset = [Int](repeating: 0, count: n + 1)
        for i in 0..<n { offset[i + 1] = offset[i] + rem[i] }
        let S = offset[n]
        var extra = [Int](repeating: 0, count: bonds.count)
        if S == 0 { return (extra, 0) }
        var atomOf = [Int](repeating: 0, count: S)
        for i in 0..<n { for s in offset[i]..<offset[i + 1] { atomOf[s] = i } }
        var g = [[Int]](repeating: [], count: S)
        for k in cand {
            let b = bonds[k]
            for sa in offset[b.a]..<offset[b.a + 1] {
                for sb in offset[b.b]..<offset[b.b + 1] { g[sa].append(sb); g[sb].append(sa) }
            }
        }
        // Greedy initialisation guided by bond length.
        var match = [Int](repeating: -1, count: S)
        var nextFree = offset
        func ratio(_ k: Int) -> Double {
            let b = bonds[k]
            let rs = Elements.element(atoms[b.a].atomicNumber).covalentRadius + Elements.element(atoms[b.b].atomicNumber).covalentRadius
            let d = VecMath.distance(atoms[b.a].position, atoms[b.b].position)
            return rs > 0 ? d / rs : 1
        }
        let sorted = cand.map { ($0, ratio($0)) }.sorted { $0.1 < $1.1 }
        for (limit, pass) in [(0.95, 0), (0.84, 1)] {
            _ = pass
            for (k, r) in sorted where r < limit {
                let b = bonds[k]
                if nextFree[b.a] < offset[b.a + 1] && nextFree[b.b] < offset[b.b + 1] {
                    let sa = nextFree[b.a], sb = nextFree[b.b]
                    match[sa] = sb; match[sb] = sa
                    nextFree[b.a] += 1; nextFree[b.b] += 1
                }
            }
        }
        var bm = BlossomMatcher(n: S, g: g, match: match)
        bm.augmentAll()
        var key: [Int: Int] = [:]
        for k in cand { key[bonds[k].a * n + bonds[k].b] = k }
        var matched = 0
        for s in 0..<S {
            let t = bm.match[s]
            if t > s {
                let a = min(atomOf[s], atomOf[t]), b = max(atomOf[s], atomOf[t])
                if let k = key[a * n + b] { extra[k] += 1 }
            }
            if t != -1 { matched += 1 }
        }
        for k in cand { extra[k] = min(extra[k], 2) }
        return (extra, matched)
    }

    // MARK: aromaticity

    /// SSSR rings of size 5-7 that are planar (best-fit plane deviation < 0.25 Å) and satisfy Hückel 4n+2
    /// with pi-electron counting from the CURRENT bond orders (double or aromatic bonds: 1 per atom;
    /// single-bonded N/O/S/Se/P: 2; carbonyl-like exocyclic double bonds: 0; sp3 atoms disqualify).
    /// Fused systems are evaluated ring by ring; atoms double-bonded into a neighbouring ring count 1.
    public func aromaticRings() -> [[Int]] {
        let n = atoms.count
        let rings = smallestSetOfSmallestRings().filter { (5...7).contains($0.count) }
        if rings.isEmpty { return [] }
        let adj = adjacency()
        var ringAtom = [Bool](repeating: false, count: n)
        for r in smallestSetOfSmallestRings() { for i in r { ringAtom[i] = true } }
        var orderOf: [Int: BondOrder] = [:]
        for b in bonds { orderOf[b.a * n + b.b] = b.order }
        func ord(_ i: Int, _ j: Int) -> BondOrder? { orderOf[min(i, j) * n + max(i, j)] }

        var result: [[Int]] = []
        for ring in rings {
            let inRing = Set(ring)
            // planarity
            var c = Vec3.zero
            for i in ring { c += atoms[i].position }
            c /= Double(ring.count)
            var cov = simd_double3x3()
            for i in ring {
                let d = atoms[i].position - c
                cov[0][0] += d.x * d.x; cov[1][1] += d.y * d.y; cov[2][2] += d.z * d.z
                cov[0][1] += d.x * d.y; cov[1][0] += d.x * d.y
                cov[0][2] += d.x * d.z; cov[2][0] += d.x * d.z
                cov[1][2] += d.y * d.z; cov[2][1] += d.y * d.z
            }
            let nrm = VecMath.symmetricEigen(cov).vectors.columns.0
            if ring.contains(where: { abs(simd_dot(atoms[$0].position - c, nrm)) > 0.25 }) { continue }

            var sum = 0
            var flex = 0
            var ok = true
            for i in ring {
                let z = atoms[i].atomicNumber
                let d = adj[i].count
                var pi = false      // has a pi bond into the ring or a fused neighbour ring
                var exoHet = false  // exocyclic pi bond to a non-ring atom
                for j in adj[i] {
                    guard let o = ord(i, j), o == .double || o == .aromatic || o == .triple else { continue }
                    if inRing.contains(j) { pi = true }
                    else if ringAtom[j] && o != .triple { pi = true }
                    else { exoHet = true }
                }
                if pi { sum += 1; continue }
                if exoHet { continue }               // contributes 0
                switch z {
                case 6, 14:
                    if d >= 4 { ok = false } else { flex += 1 }
                case 7, 15:
                    if d >= 4 { ok = false } else { sum += 2 }
                case 8, 16, 34:
                    if d >= 3 { ok = false } else { sum += 2 }
                case 5: break
                default: ok = false
                }
                if !ok { break }
            }
            guard ok, flex <= 1 else { continue }
            let options = flex == 1 ? [0, 2] : [0]
            if options.contains(where: { s in let t = sum + s; return t >= 2 && (t - 2) % 4 == 0 }) { result.append(ring) }
        }
        return result
    }

    /// Sets `.aromatic` on every bond of every ring from `aromaticRings()`.
    public mutating func markAromaticBonds() {
        for ring in aromaticRings() {
            for k in 0..<ring.count {
                if let bi = bondIndex(ring[k], ring[(k + 1) % ring.count]) { bonds[bi].order = .aromatic }
            }
        }
    }

    /// Converts `.aromatic` bonds to alternating single/double bonds (maximum matching over the
    /// aromatic sub-graph). Returns false (molecule unchanged) if no Kekulé structure exists.
    @discardableResult
    public mutating func kekulize() -> Bool {
        guard bonds.contains(where: { $0.order == .aromatic }) else { return true }
        guard let orders = kekuleAssignment(relaxPyrroleN: false, allowPartial: false) else { return false }
        for k in bonds.indices { bonds[k].order = orders[k] }
        return true
    }

    /// Bond orders for display (parallel to `bonds`), with every `.aromatic` bond shown as single or double
    /// in one alternating Kekulé structure. The molecule itself is not changed (stored aromatic orders stay).
    /// Non-aromatic bonds keep their order. Best effort: when no perfect structure exists (e.g. a pyrrole-type
    /// N without its explicit H), the ambiguous N is treated as the lone-pair donor; failing that, a maximum
    /// partial assignment is returned (unmatched bonds single). Deterministic for a given molecule.
    public func kekuleDisplayOrders() -> [BondOrder] {
        guard bonds.contains(where: { $0.order == .aromatic }) else { return bonds.map(\.order) }
        return kekuleAssignment(relaxPyrroleN: false, allowPartial: false)
            ?? kekuleAssignment(relaxPyrroleN: true, allowPartial: false)
            ?? kekuleAssignment(relaxPyrroleN: true, allowPartial: true)
            ?? bonds.map { $0.order == .aromatic ? .single : $0.order }
    }

    /// A copy of the molecule with `kekuleDisplayOrders()` applied (for exporters/renderers that cannot draw 1.5).
    public func kekuleDisplayMolecule() -> Molecule {
        var m = self
        let o = kekuleDisplayOrders()
        for k in m.bonds.indices { m.bonds[k].order = o[k] }
        return m
    }

    private func kekuleAssignment(relaxPyrroleN: Bool, allowPartial: Bool) -> [BondOrder]? {
        let n = atoms.count
        let arom = bonds.indices.filter { bonds[$0].order == .aromatic && bonds[$0].a < n && bonds[$0].b < n }
        var out = bonds.map(\.order)
        if arom.isEmpty { return out }
        var deg = [Int](repeating: 0, count: n)
        var hasExoDouble = [Bool](repeating: false, count: n)
        var inArom = [Bool](repeating: false, count: n)
        for b in bonds where b.a < n && b.b < n {
            deg[b.a] += 1; deg[b.b] += 1
            if b.order == .double || b.order == .triple { hasExoDouble[b.a] = true; hasExoDouble[b.b] = true }
        }
        for k in arom { inArom[bonds[k].a] = true; inArom[bonds[k].b] = true }
        var smallRingN = [Bool](repeating: false, count: n)
        if relaxPyrroleN {
            // deg-2 N/P whose aromatic rings are all five-membered: may be the pyrrole-type donor
            let rings = smallestSetOfSmallestRings()
            for i in 0..<n where inArom[i] && [7, 15].contains(atoms[i].atomicNumber) && deg[i] == 2 {
                let mine = rings.filter { $0.contains(i) }
                if !mine.isEmpty && mine.allSatisfy({ $0.count == 5 }) { smallRingN[i] = true }
            }
        }
        var need = [Bool](repeating: false, count: n)
        for i in 0..<n where inArom[i] {
            let z = atoms[i].atomicNumber
            if hasExoDouble[i] { continue }
            switch z {
            case 6, 14, 5: need[i] = true
            case 7, 15: need[i] = (deg[i] == 2 && !smallRingN[i]) || (deg[i] == 3 && atoms[i].charge > 0.5)
            default: need[i] = false
            }
        }
        var sid = [Int](repeating: -1, count: n)
        var cnt = 0
        for i in 0..<n where need[i] { sid[i] = cnt; cnt += 1 }
        var g = [[Int]](repeating: [], count: cnt)
        for k in arom {
            let b = bonds[k]
            if sid[b.a] >= 0 && sid[b.b] >= 0 { g[sid[b.a]].append(sid[b.b]); g[sid[b.b]].append(sid[b.a]) }
        }
        var bm = BlossomMatcher(n: cnt, g: g, match: [Int](repeating: -1, count: cnt))
        bm.augmentAll()
        if relaxPyrroleN && !allowPartial {
            // at most one relaxed donor per ring system is fine; require all other atoms matched
            if bm.match.contains(-1) { return nil }
        } else if !allowPartial && bm.match.contains(-1) { return nil }
        for k in arom {
            let b = bonds[k]
            out[k] = (sid[b.a] >= 0 && sid[b.b] >= 0 && bm.match[sid[b.a]] == sid[b.b]) ? .double : .single
        }
        return out
    }

    // MARK: formal charges

    /// Heuristic formal charges from bond-order sums (aromatic systems are kekulized first):
    /// N s=4 -> +1, N s=2 -> -1, O s=1 -> -1, O s=3 -> +1, S s=1 -> -1, S s=3 -> +1, P s=4 -> +1, B s=4 -> -1,
    /// halogen with no bonds -> -1, C s=3 -> sign of molecule charge (else 0), alkali ion +1, Mg/Ca ion +2.
    /// If the sum disagrees with `charge` because explicit hydrogens are missing (sum < charge), negative
    /// charges on terminal singly-bonded O/S/N are dropped until the sum matches.
    public func formalCharges() -> [Int] {
        var c = self
        var sums: [Int]
        if c.bonds.contains(where: { $0.order == .aromatic }) && !c.kekulize() {
            sums = atoms.indices.map { Int(bondOrderSum(of: $0).rounded(.up)) }
        } else {
            sums = atoms.indices.map { Int(c.bondOrderSum(of: $0).rounded()) }
        }
        let adj = adjacency()
        var out = [Int](repeating: 0, count: atoms.count)
        for i in atoms.indices {
            let s = sums[i], d = adj[i].count
            switch atoms[i].atomicNumber {
            case 3, 11, 19, 37, 55: if d == 0 { out[i] = 1 }
            case 12, 20: if d == 0 { out[i] = 2 }
            case 5: if s == 4 { out[i] = -1 }
            case 6: if s == 3 { out[i] = d == 1 && s == 3 && charge <= 0 ? -1 : (charge < 0 ? -1 : (charge > 0 ? 1 : 0)) }
            case 7: if s == 4 { out[i] = 1 } else if s == 2 { out[i] = -1 }
            case 8: if s == 1 { out[i] = -1 } else if s == 3 { out[i] = 1 }
            case 15: if s == 4 { out[i] = 1 }
            case 16, 34: if s == 1 { out[i] = -1 } else if s == 3 { out[i] = 1 }
            case 9, 17, 35, 53: if d == 0 { out[i] = -1 } else if s == 2 { out[i] = 1 }
            default: break
            }
        }
        var total = out.reduce(0, +)
        if total < charge {
            for i in atoms.indices where total < charge && out[i] == -1 && adj[i].count == 1 && [7, 8, 16].contains(atoms[i].atomicNumber) {
                out[i] = 0; total += 1
            }
        }
        return out
    }
}
