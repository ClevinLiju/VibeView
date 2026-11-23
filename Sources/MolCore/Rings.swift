import Foundation

// Ring perception: Horton-style candidate cycles + GF(2) independence test (SSSR).

extension Molecule {
    /// Smallest set of smallest rings. Each ring is a cycle of atom indices in traversal
    /// order (consecutive entries bonded, last bonded to first). Ring count = B - N + C.
    /// Sorted by ring size, then by minimum atom index.
    public func smallestSetOfSmallestRings() -> [[Int]] {
        let n = atoms.count
        // Valid unique edges.
        var edgeIndex: [Int: Int] = [:]
        var edges: [(Int, Int)] = []
        for b in bonds where b.a != b.b && b.a >= 0 && b.b < n {
            let key = b.a * n + b.b
            if edgeIndex[key] == nil { edgeIndex[key] = edges.count; edges.append((b.a, b.b)) }
        }
        if edges.count < 3 { return [] }
        // 2-core.
        var deg = [Int](repeating: 0, count: n)
        var adj = [[(Int, Int)]](repeating: [], count: n)
        for (ei, e) in edges.enumerated() {
            adj[e.0].append((e.1, ei)); adj[e.1].append((e.0, ei))
            deg[e.0] += 1; deg[e.1] += 1
        }
        var alive = [Bool](repeating: true, count: n)
        var stack: [Int] = []
        for i in 0..<n where deg[i] <= 1 { alive[i] = false; stack.append(i) }
        while let v = stack.popLast() {
            for (w, _) in adj[v] where alive[w] {
                deg[w] -= 1
                if deg[w] <= 1 { alive[w] = false; stack.append(w) }
            }
        }
        // Components of the 2-core.
        var comp = [Int](repeating: -1, count: n)
        var comps: [[Int]] = []
        for s in 0..<n where alive[s] && comp[s] < 0 {
            var members = [s]; comp[s] = comps.count
            var k = 0
            while k < members.count {
                let v = members[k]; k += 1
                for (w, _) in adj[v] where alive[w] && comp[w] < 0 { comp[w] = comps.count; members.append(w) }
            }
            comps.append(members)
        }
        var result: [[Int]] = []
        var depth = [Int](repeating: -1, count: n)
        var parent = [Int](repeating: -1, count: n)
        var branch = [Int](repeating: -1, count: n)
        for members in comps {
            // Local edge indexing.
            var localEdge: [Int: Int] = [:]
            var nLocalEdges = 0
            for v in members {
                for (w, ei) in adj[v] where alive[w] && v < w && localEdge[ei] == nil {
                    localEdge[ei] = nLocalEdges; nLocalEdges += 1
                }
            }
            let target = nLocalEdges - members.count + 1
            if target <= 0 { continue }
            let maxDepth = members.count > 400 ? 6 : Int.max
            // Candidates.
            var seen = Set<[Int]>()
            var cands: [[Int]] = []
            for v in members {
                var visited: [Int] = [v]
                depth[v] = 0; parent[v] = -1; branch[v] = -1
                var k = 0
                while k < visited.count {
                    let x = visited[k]; k += 1
                    if depth[x] >= maxDepth { continue }
                    for (w, _) in adj[x] where alive[w] && depth[w] < 0 {
                        depth[w] = depth[x] + 1; parent[w] = x
                        branch[w] = (x == v) ? w : branch[x]
                        visited.append(w)
                    }
                }
                for x in visited where x != v {
                    for (y, _) in adj[x] where alive[y] && x < y && depth[y] >= 0 && y != v
                        && parent[y] != x && parent[x] != y && branch[x] != branch[y] {
                        var px: [Int] = []
                        var t = x
                        while t != v { px.append(t); t = parent[t] }
                        var ring = [v] + px.reversed()
                        t = y
                        while t != v { ring.append(t); t = parent[t] }
                        var key = [Int](); key.reserveCapacity(ring.count)
                        for i in 0..<ring.count {
                            let a = ring[i], b = ring[(i + 1) % ring.count]
                            key.append(edgeIndex[min(a, b) * n + max(a, b)]!)
                        }
                        key.sort()
                        if seen.insert(key).inserted { cands.append(ring) }
                    }
                }
                for u in visited { depth[u] = -1; parent[u] = -1; branch[u] = -1 }
            }
            // Order by size (stable on discovery order for determinism).
            let order = cands.indices.sorted { (cands[$0].count, $0) < (cands[$1].count, $1) }
            let words = (nLocalEdges + 63) / 64
            var pivots: [Int: [UInt64]] = [:]
            var found = 0
            for ci in order {
                let ring = cands[ci]
                var vec = [UInt64](repeating: 0, count: words)
                for i in 0..<ring.count {
                    let a = ring[i], b = ring[(i + 1) % ring.count]
                    let le = localEdge[edgeIndex[min(a, b) * n + max(a, b)]!]!
                    vec[le >> 6] ^= 1 << UInt64(le & 63)
                }
                // Reduce.
                var independent = false
                var w = 0
                while w < words {
                    if vec[w] == 0 { w += 1; continue }
                    let bit = vec[w].trailingZeroBitCount
                    let p = w * 64 + bit
                    if let basis = pivots[p] {
                        for j in w..<words { vec[j] ^= basis[j] }
                    } else {
                        pivots[p] = vec; independent = true; break
                    }
                }
                if independent {
                    result.append(ring); found += 1
                    if found == target { break }
                }
            }
        }
        result.sort {
            if $0.count != $1.count { return $0.count < $1.count }
            return ($0.min() ?? 0) < ($1.min() ?? 0)
        }
        return result
    }

    /// Per-atom ring index lists into `smallestSetOfSmallestRings()`.
    public func ringMembership() -> [[Int]] {
        var out = [[Int]](repeating: [], count: atoms.count)
        for (ri, r) in smallestSetOfSmallestRings().enumerated() { for a in r { out[a].append(ri) } }
        return out
    }

    /// Per-bond (index into `bonds`) flag: true if the bond is a bridge (not in any ring).
    private func bridgeFlags() -> [Bool] {
        let n = atoms.count
        var adj = [[(Int, Int)]](repeating: [], count: n)
        for (bi, b) in bonds.enumerated() where b.a != b.b && b.a >= 0 && b.b < n {
            adj[b.a].append((b.b, bi)); adj[b.b].append((b.a, bi))
        }
        var isBridge = [Bool](repeating: false, count: bonds.count)
        var disc = [Int](repeating: -1, count: n)
        var low = [Int](repeating: 0, count: n)
        var timer = 0
        for s in 0..<n where disc[s] < 0 {
            // iterative DFS: (vertex, parentBond, next adjacency index)
            var st: [(Int, Int, Int)] = [(s, -1, 0)]
            disc[s] = timer; low[s] = timer; timer += 1
            while !st.isEmpty {
                let (v, pb, idx) = st[st.count - 1]
                if idx < adj[v].count {
                    st[st.count - 1].2 += 1
                    let (w, bi) = adj[v][idx]
                    if bi == pb { continue }
                    if disc[w] < 0 {
                        disc[w] = timer; low[w] = timer; timer += 1
                        st.append((w, bi, 0))
                    } else {
                        low[v] = min(low[v], disc[w])
                    }
                } else {
                    st.removeLast()
                    if let top = st.last {
                        low[top.0] = min(low[top.0], low[v])
                        if low[v] > disc[top.0] { isBridge[pb] = true }
                    }
                }
            }
        }
        return isBridge
    }

    /// Per-atom flag: true if the atom is in any ring.
    public func ringAtomMask() -> [Bool] {
        var mask = [Bool](repeating: false, count: atoms.count)
        let br = bridgeFlags()
        for (bi, b) in bonds.enumerated() where !br[bi] && b.a != b.b && b.a >= 0 && b.b < atoms.count {
            mask[b.a] = true; mask[b.b] = true
        }
        return mask
    }

    /// True if bond (i, j) is a ring bond (not a bridge). False if no such bond.
    public func isRingBond(_ i: Int, _ j: Int) -> Bool {
        guard bondIndex(i, j) != nil else { return false }
        // Search for an alternative path i -> j avoiding the direct bond.
        let adj = adjacency()
        var seen = Set<Int>([i])
        var queue = [i]
        var k = 0
        while k < queue.count {
            let v = queue[k]; k += 1
            for w in adj[v] {
                if v == i && w == j { continue }
                if w == j { return true }
                if seen.insert(w).inserted { queue.append(w) }
            }
        }
        return false
    }
}
