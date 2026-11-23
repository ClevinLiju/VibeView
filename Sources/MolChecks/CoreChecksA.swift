import Foundation
import simd
import MolCore

// Core team checks, owned by Lead 1 Worker A. Names must start with "core.".

private func mol(_ zs: [Int], _ ps: [Vec3], bonds: [(Int, Int)] = []) -> Molecule {
    var m = Molecule()
    for (i, z) in zs.enumerated() { m.atoms.append(Atom(id: i, atomicNumber: z, position: ps[i])) }
    m.bonds = bonds.map { Bond($0.0, $0.1) }
    return m
}

/// Abstract graph (positions irrelevant) for ring tests.
private func graph(_ n: Int, _ edges: [(Int, Int)]) -> Molecule {
    mol(Array(repeating: 6, count: n), (0..<n).map { Vec3(Double($0), 0, 0) }, bonds: edges)
}

private func cycleEdges(_ n: Int) -> [(Int, Int)] { (0..<n).map { ($0, ($0 + 1) % n) } }

private func benzene() -> Molecule {
    var zs: [Int] = [], ps: [Vec3] = []
    for k in 0..<6 {
        let a = Double(k) * .pi / 3
        zs.append(6); ps.append(Vec3(1.4 * cos(a), 1.4 * sin(a), 0))
    }
    for k in 0..<6 {
        let a = Double(k) * .pi / 3
        zs.append(1); ps.append(Vec3(2.48 * cos(a), 2.48 * sin(a), 0))
    }
    return mol(zs, ps)
}

private func naphthalene() -> Molecule {
    var pts: [Vec3] = []
    for cx in [0.0, 2.4249] {
        for k in 0..<6 {
            let a = (30 + 60 * Double(k)) * .pi / 180
            let p = Vec3(cx + 1.4 * cos(a), 1.4 * sin(a), 0)
            if !pts.contains(where: { simd_length($0 - p) < 0.05 }) { pts.append(p) }
        }
    }
    return mol(Array(repeating: 6, count: pts.count), pts)
}

private func cubane() -> Molecule {
    var ps: [Vec3] = []
    for x in 0...1 { for y in 0...1 { for z in 0...1 { ps.append(Vec3(Double(x), Double(y), Double(z)) * 1.57) } } }
    return mol(Array(repeating: 6, count: 8), ps)
}

private func c60() -> Molecule {
    let phi = (1 + 5.0.squareRoot()) / 2
    let bases: [[Double]] = [[0, 1, 3 * phi], [1, 2 + phi, 2 * phi], [phi, 2, 2 * phi + 1]]
    var pts: [Vec3] = []
    for b in bases {
        for cyc in 0..<3 {
            let v = [b[cyc % 3], b[(cyc + 1) % 3], b[(cyc + 2) % 3]]
            for sx in [-1.0, 1.0] { for sy in [-1.0, 1.0] { for sz in [-1.0, 1.0] {
                let p = Vec3(v[0] * sx, v[1] * sy, v[2] * sz) * 0.7
                if !pts.contains(where: { simd_length($0 - p) < 0.01 }) { pts.append(p) }
            } } }
        }
    }
    return mol(Array(repeating: 6, count: pts.count), pts)
}

private func lattice(_ n: Int, spacing: Double) -> Molecule {
    var ps: [Vec3] = []
    ps.reserveCapacity(n * n * n)
    for x in 0..<n { for y in 0..<n { for z in 0..<n { ps.append(Vec3(Double(x), Double(y), Double(z)) * spacing) } } }
    return mol(Array(repeating: 6, count: ps.count), ps)
}

private func ringsAreValid(_ m: Molecule, _ rings: [[Int]]) -> Bool {
    for r in rings {
        if Set(r).count != r.count || r.count < 3 { return false }
        for i in 0..<r.count where !m.areBonded(r[i], r[(i + 1) % r.count]) { return false }
    }
    return true
}

private struct LCG {
    var s: UInt64
    mutating func next() -> Double {
        s = s &* 6364136223846793005 &+ 1442695040888963407
        return Double(s >> 11) / Double(1 << 53)
    }
}

extension Checks {
    static let coreA: [Check] = [
        // MARK: elements
        Check("core.elements.table_size") {
            try expect(Elements.maxAtomicNumber == 118)
            try expect(Elements.all.count == 119)
            try expect(Elements.all[0].symbol == "X")
            for (z, e) in Elements.all.enumerated() { try expect(e.atomicNumber == z, "z \(z)") }
        },
        Check("core.elements.symbol_roundtrip_118") {
            for z in 1...118 {
                let s = Elements.symbol(z)
                try expect(Elements.atomicNumber(symbol: s) == z, "\(z) \(s)")
                try expect(Elements.atomicNumber(symbol: s.lowercased()) == z)
                try expect(Elements.atomicNumber(symbol: s.uppercased()) == z)
                try expect(Elements.element(symbol: s)?.atomicNumber == z)
                try expect(Elements.element(z).symbol == s)
            }
        },
        Check("core.elements.symbols_unique_and_known") {
            var seen = Set<String>()
            for z in 1...118 { try expect(seen.insert(Elements.symbol(z)).inserted, "dup \(z)") }
            let ref = ["H", "He", "Li", "Be", "B", "C", "N", "O", "F", "Ne", "Na", "Mg", "Al", "Si", "P", "S", "Cl", "Ar",
                       "K", "Ca", "Fe", "Cu", "Zn", "Br", "Ag", "I", "Au", "Hg", "Pb", "U", "Og"]
            let zs = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 26, 29, 30, 35, 47, 53, 79, 80, 82, 92, 118]
            for (s, z) in zip(ref, zs) { try expect(Elements.symbol(z) == s, "\(z)") }
        },
        Check("core.elements.lookup_edge_cases") {
            try expect(Elements.atomicNumber(symbol: "Xx") == nil)
            try expect(Elements.atomicNumber(symbol: "") == nil)
            try expect(Elements.atomicNumber(symbol: " Cl ") == 17)
            try expect(Elements.atomicNumber(symbol: "x") == 0)
            try expect(Elements.atomicNumber(symbol: "Bq") == 0)
            try expect(Elements.atomicNumber(symbol: "Gh") == 0)
            try expect(Elements.element(symbol: "zz") == nil)
            try expect(Elements.element(-5).atomicNumber == 0)
            try expect(Elements.element(500).atomicNumber == 0)
            try expect(Elements.symbol(999) == "X")
        },
        Check("core.elements.reference_values") {
            try expectClose(Elements.element(6).mass, 12.011, tol: 1e-9)
            try expectClose(Elements.element(1).mass, 1.008, tol: 1e-9)
            try expectClose(Elements.element(8).mass, 15.999, tol: 1e-9)
            try expectClose(Elements.element(6).covalentRadius, 0.76, tol: 1e-9)
            try expectClose(Elements.element(1).vdwRadius, 1.20, tol: 1e-9)
            try expectClose(Elements.element(6).vdwRadius, 1.70, tol: 1e-9)
            try expectClose(Elements.element(8).electronegativity ?? 0, 3.44, tol: 1e-9)
            try expect(Elements.element(2).electronegativity == nil)
            try expect(Elements.element(7).valences == [3, 5])
            try expect(Elements.element(16).valences == [2, 4, 6])
            try expect(Elements.element(7).defaultValence == 3)
            try expect(Elements.element(0).defaultValence == 0)
            try expect(Elements.element(26).name == "Iron")
        },
        Check("core.elements.data_sanity_all") {
            for z in 1...118 {
                let e = Elements.element(z)
                try expect(e.mass > 0.9 && e.mass < 300, "mass \(z)")
                if z > 1 { try expect(e.mass > Elements.element(z - 1).mass - 20, "mass trend \(z)") }
                try expect(e.covalentRadius > 0.2 && e.covalentRadius < 3, "cov \(z)")
                try expect(e.vdwRadius > 1 && e.vdwRadius < 4, "vdw \(z)")
                try expect(e.vdwRadius > e.covalentRadius * 0.6, "vdw>cov \(z)")
                for c in [e.color, e.cpkColor] {
                    try expect(c.x >= 0 && c.x <= 1 && c.y >= 0 && c.y <= 1 && c.z >= 0 && c.z <= 1, "color \(z)")
                }
                try expect(!e.name.isEmpty)
                try expect(!e.valences.isEmpty, "valence \(z)")
                if let en = e.electronegativity { try expect(en > 0.5 && en < 4.1, "en \(z)") }
            }
        },
        Check("core.elements.atom_accessors") {
            let a = Atom(id: 0, atomicNumber: 17, position: .zero)
            try expect(a.element.symbol == "Cl")
            try expect(a.symbol == "Cl")
            let d = Atom(id: 0, atomicNumber: 0, position: .zero)
            try expect(d.symbol == "X")
        },
        Check("core.elements.period_and_metal") {
            try expect(Elements.element(1).period == 1)
            try expect(Elements.element(6).period == 2)
            try expect(Elements.element(26).period == 4)
            try expect(Elements.element(79).period == 6)
            try expect(Elements.element(118).period == 7)
            try expect(Elements.element(0).period == 0)
            try expect(Elements.element(26).isMetal && Elements.element(11).isMetal)
            try expect(!Elements.element(6).isMetal && !Elements.element(17).isMetal && !Elements.element(1).isMetal)
        },

        // MARK: grid
        Check("core.grid.empty_and_single") {
            let g0 = NeighborGrid(positions: [], cellSize: 3)
            try expect(g0.pairs(within: 3).isEmpty)
            try expect(g0.neighbors(of: .zero, within: 3).isEmpty)
            let g1 = NeighborGrid(positions: [Vec3(1, 2, 3)], cellSize: 3)
            try expect(g1.pairs(within: 3).isEmpty)
            try expect(g1.neighbors(of: Vec3(1, 2, 3), within: 0.1) == [0])
            try expect(g1.neighbors(of: Vec3(9, 9, 9), within: 1).isEmpty)
        },
        Check("core.grid.known_pairs_and_boundary") {
            let p = [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(2, 0, 0), Vec3(-5, -5, -5)]
            let g = NeighborGrid(positions: p, cellSize: 1.5)
            let pr = g.pairs(within: 1.0).map { "\($0.0)-\($0.1)" }
            try expect(pr == ["0-1", "1-2"], "\(pr)")
            try expect(g.pairs(within: 2.0).count == 3)
            try expect(g.neighbors(of: Vec3(1, 0, 0), within: 1.0) == [0, 1, 2])
            try expect(g.neighbors(of: Vec3(1, 0, 0), within: 0.5) == [1])
            try expect(g.pairs(within: -1).isEmpty)
        },
        Check("core.grid.matches_bruteforce_negative_coords") {
            var r = LCG(s: 42)
            let pts = (0..<1500).map { _ in Vec3(r.next() * 30 - 15, r.next() * 30 - 15, r.next() * 30 - 15) }
            // cellSize smaller and larger than the radius
            for cs in [1.0, 3.0, 7.0] {
                let g = NeighborGrid(positions: pts, cellSize: cs)
                let got = Set(g.pairs(within: 3.0).map { $0.0 * 10000 + $0.1 })
                var want = Set<Int>()
                for i in 0..<pts.count { for j in (i + 1)..<pts.count where simd_length(pts[i] - pts[j]) <= 3.0 { want.insert(i * 10000 + j) } }
                try expect(got == want, "cs \(cs): \(got.count) vs \(want.count)")
                let q = pts[17]
                let nb = g.neighbors(of: q, within: 3.0)
                let nbWant = (0..<pts.count).filter { simd_length(pts[$0] - q) <= 3.0 }
                try expect(nb == nbWant)
            }
        },
        Check("core.grid.pairs_unique_ordered") {
            var r = LCG(s: 7)
            let pts = (0..<500).map { _ in Vec3(r.next() * 8, r.next() * 8, r.next() * 8) }
            let pr = NeighborGrid(positions: pts, cellSize: 3).pairs(within: 3)
            var seen = Set<Int>()
            for (i, j) in pr { try expect(i < j); try expect(seen.insert(i * 1000 + j).inserted) }
        },
        Check("core.grid.degenerate_inputs") {
            let g = NeighborGrid(positions: [Vec3(0, 0, 0), Vec3(0.5, 0, 0), Vec3(.nan, 0, 0)], cellSize: 0)
            try expect(g.pairs(within: 1).count == 1)
            let same = NeighborGrid(positions: Array(repeating: Vec3(1, 1, 1), count: 5), cellSize: 2)
            try expect(same.pairs(within: 0.1).count == 10)
            try expect(g.neighbors(of: Vec3(.nan, 0, 0), within: 1).isEmpty)
        },
        Check("core.grid.timing_100k") {
            var r = LCG(s: 99)
            let pts = (0..<100_000).map { _ in Vec3(r.next() * 100, r.next() * 100, r.next() * 100) }
            let t0 = Date()
            let g = NeighborGrid(positions: pts, cellSize: 3)
            let n = g.pairs(within: 3).count
            let dt = Date().timeIntervalSince(t0)
            print("    [grid 100k pairs=\(n) t=\(String(format: "%.2f", dt))s]")
            try expect(n > 100_000)
            try expect(dt < 20, "too slow \(dt)")
        },

        // MARK: bonds
        Check("core.bonds.empty_single_dummy") {
            try expect(Molecule().perceivedBonds().isEmpty)
            try expect(mol([6], [.zero]).perceivedBonds().isEmpty)
            let d = mol([0, 6, 0], [Vec3(0, 0, 0), Vec3(1.2, 0, 0), Vec3(2.4, 0, 0)])
            try expect(d.perceivedBonds().isEmpty)
        },
        Check("core.bonds.water_and_hh") {
            let w = mol([8, 1, 1], [Vec3(0, 0, 0), Vec3(0.96, 0, 0), Vec3(-0.24, 0.93, 0)])
            let b = w.perceivedBonds()
            try expect(b.count == 2 && b[0] == Bond(0, 1) && b[1] == Bond(0, 2), "\(b)")
            try expect(mol([1, 1], [.zero, Vec3(0.74, 0, 0)]).perceivedBonds().count == 1)
            try expect(mol([1, 1], [.zero, Vec3(1.2, 0, 0)]).perceivedBonds().isEmpty)
        },
        Check("core.bonds.distance_thresholds") {
            // C-C: 0.4 < d < 1.97
            try expect(mol([6, 6], [.zero, Vec3(1.5, 0, 0)]).perceivedBonds().count == 1)
            try expect(mol([6, 6], [.zero, Vec3(2.0, 0, 0)]).perceivedBonds().isEmpty)
            try expect(mol([6, 6], [.zero, Vec3(2.0, 0, 0)]).perceivedBonds(tolerance: 0.6).count == 1)
            try expect(mol([6, 6], [.zero, Vec3(0.3, 0, 0)]).perceivedBonds().isEmpty)
            try expect(mol([6, 6], [.zero, Vec3(0.4, 0, 0)]).perceivedBonds().isEmpty)
        },
        Check("core.bonds.hydrogen_keeps_shortest") {
            let m = mol([6, 1, 6], [Vec3(0, 0, 0), Vec3(1.2, 0, 0), Vec3(2.0, 0, 0)])
            let b = m.perceivedBonds()
            try expect(b.contains(Bond(1, 2)) && !b.contains(Bond(0, 1)), "\(b)")
            try expect(b.contains(Bond(0, 1)) == false)
        },
        Check("core.bonds.linear_chain_sorted") {
            let m = mol(Array(repeating: 6, count: 50), (0..<50).map { Vec3(Double(49 - $0) * 1.5, 0, 0) })
            let b = m.perceivedBonds()
            try expect(b.count == 49)
            for i in 1..<b.count { try expect((b[i - 1].a, b[i - 1].b) < (b[i].a, b[i].b)) }
            for x in b { try expect(x.a < x.b) }
        },
        Check("core.bonds.benzene_naphthalene_cubane_c60_sf6") {
            try expect(naphthalene().perceivedBonds().count == 11)
            try expect(cubane().perceivedBonds().count == 12)
            try expect(c60().atoms.count == 60)
            try expect(c60().perceivedBonds().count == 90)
            var b = benzene()
            try expect(b.perceivedBonds().count == 12, "benzene \(b.perceivedBonds().count)")
            b.perceiveBonds()
            try expect(b.bonds.count == 12)
            var ps: [Vec3] = [.zero]
            for d in [Vec3(1, 0, 0), Vec3(-1, 0, 0), Vec3(0, 1, 0), Vec3(0, -1, 0), Vec3(0, 0, 1), Vec3(0, 0, -1)] { ps.append(d * 1.56) }
            let sf6 = mol([16, 9, 9, 9, 9, 9, 9], ps)
            try expect(sf6.perceivedBonds().count == 6)
        },
        Check("core.bonds.keep_existing_orders") {
            var m = mol([6, 6, 6], [.zero, Vec3(1.3, 0, 0), Vec3(2.6, 0, 0)])
            m.bonds = [Bond(0, 1, order: .double), Bond(0, 2, order: .triple)]
            m.perceiveBonds(keepExistingOrders: true)
            try expect(m.bonds.count == 2)
            try expect(m.bond(between: 0, and: 1)?.order == .double)
            try expect(m.bond(between: 1, and: 2)?.order == .single)
            m.bonds[0].order = .double
            m.perceiveBonds(keepExistingOrders: false)
            try expect(m.bonds.allSatisfy { $0.order == .single })
        },
        Check("core.bonds.lattice_20k_timing") {
            let m = lattice(27, spacing: 1.5)
            try expect(m.atoms.count == 19683)
            let t0 = Date()
            let b = m.perceivedBonds()
            let dt = Date().timeIntervalSince(t0)
            print("    [bonds 19683 atoms: \(b.count) bonds, t=\(String(format: "%.2f", dt))s]")
            try expect(b.count == 3 * 27 * 27 * 26, "\(b.count)")
            try expect(dt < 15, "too slow \(dt)")
        },

        // MARK: rings
        Check("core.rings.none") {
            try expect(Molecule().smallestSetOfSmallestRings().isEmpty)
            try expect(graph(1, []).smallestSetOfSmallestRings().isEmpty)
            let chain = graph(6, (0..<5).map { ($0, $0 + 1) })
            try expect(chain.smallestSetOfSmallestRings().isEmpty)
            try expect(!chain.ringAtomMask().contains(true))
            try expect(!chain.isRingBond(0, 1))
            try expect(chain.ringMembership().allSatisfy { $0.isEmpty })
            let star = graph(5, [(0, 1), (0, 2), (0, 3), (0, 4)])
            try expect(star.smallestSetOfSmallestRings().isEmpty)
        },
        Check("core.rings.simple_cycles") {
            for n in 3...12 {
                let g = graph(n, cycleEdges(n))
                let r = g.smallestSetOfSmallestRings()
                try expect(r.count == 1 && r[0].count == n, "n=\(n)")
                try expect(ringsAreValid(g, r))
                try expect(g.ringAtomMask().allSatisfy { $0 })
            }
        },
        Check("core.rings.benzene_with_hydrogens") {
            var b = benzene(); b.perceiveBonds()
            let r = b.smallestSetOfSmallestRings()
            try expect(r.count == 1 && r[0].count == 6, "\(r)")
            try expect(ringsAreValid(b, r))
            let mask = b.ringAtomMask()
            try expect(mask[0..<6].allSatisfy { $0 } && !mask[6...].contains(true))
            try expect(b.isRingBond(0, 1) && b.isRingBond(5, 0))
            try expect(!b.isRingBond(0, 6))
            try expect(!b.isRingBond(0, 3), "non-bonded pair")
            let mem = b.ringMembership()
            try expect(mem[0] == [0] && mem[6].isEmpty)
        },
        Check("core.rings.naphthalene") {
            var m = naphthalene(); m.perceiveBonds()
            let r = m.smallestSetOfSmallestRings()
            try expect(r.count == 2 && r.allSatisfy { $0.count == 6 }, "\(r)")
            try expect(ringsAreValid(m, r))
            let shared = m.ringMembership().filter { $0.count == 2 }.count
            try expect(shared == 2, "fusion atoms \(shared)")
        },
        Check("core.rings.cubane") {
            var m = cubane(); m.perceiveBonds()
            let r = m.smallestSetOfSmallestRings()
            try expect(r.count == 5 && r.allSatisfy { $0.count == 4 }, "\(r)")
            try expect(ringsAreValid(m, r))
        },
        Check("core.rings.c60") {
            var m = c60(); m.perceiveBonds()
            let r = m.smallestSetOfSmallestRings()
            try expect(r.count == 31, "count \(r.count)")
            try expect(ringsAreValid(m, r))
            let five = r.filter { $0.count == 5 }.count, six = r.filter { $0.count == 6 }.count
            try expect(five == 12 && six == 19, "\(five) \(six)")
        },
        Check("core.rings.bicyclic_and_bridged") {
            // norbornane skeleton: bridgeheads 0,3; bridges (1,2), (4,5), (6)
            let nb = graph(7, [(0, 1), (1, 2), (2, 3), (3, 4), (4, 5), (5, 0), (0, 6), (6, 3)])
            let r = nb.smallestSetOfSmallestRings()
            try expect(r.count == 2, "\(r)")
            try expect(r.map(\.count).sorted() == [5, 5], "\(r.map(\.count))")
            try expect(ringsAreValid(nb, r))
            // spiro: two triangles sharing atom 0
            let sp = graph(5, [(0, 1), (1, 2), (2, 0), (0, 3), (3, 4), (4, 0)])
            try expect(sp.smallestSetOfSmallestRings().count == 2)
            // two rings joined by a bridge bond
            let bb = graph(6, [(0, 1), (1, 2), (2, 0), (3, 4), (4, 5), (5, 3), (2, 3)])
            try expect(bb.smallestSetOfSmallestRings().count == 2)
            try expect(!bb.isRingBond(2, 3) && bb.isRingBond(0, 1) && bb.isRingBond(2, 1))
        },
        Check("core.rings.ordering_and_disconnected") {
            // 6-ring (atoms 0-5) + 3-ring (6-8) + isolated atom
            let g = graph(10, cycleEdges(6) + [(6, 7), (7, 8), (8, 6)])
            let r = g.smallestSetOfSmallestRings()
            try expect(r.count == 2 && r[0].count == 3 && r[1].count == 6, "\(r)")
            let m = g.ringAtomMask()
            try expect(m[0] && m[8] && !m[9])
        },
        Check("core.rings.ring_count_formula_large_grid") {
            // 8x8 square lattice graph: rings = B - N + 1 = 112 - 64 + 1 = 49 squares
            var e: [(Int, Int)] = []
            for x in 0..<8 { for y in 0..<8 {
                if x < 7 { e.append((x * 8 + y, (x + 1) * 8 + y)) }
                if y < 7 { e.append((x * 8 + y, x * 8 + y + 1)) }
            } }
            let g = graph(64, e)
            let r = g.smallestSetOfSmallestRings()
            try expect(r.count == 49 && r.allSatisfy { $0.count == 4 }, "\(r.count)")
        },

        // MARK: formula
        Check("core.formula.water") {
            let w = mol([8, 1, 1], [Vec3(0, 0, 0), Vec3(0.96, 0, 0), Vec3(-0.24, 0.93, 0)])
            try expect(w.formula == "H2O")
            try expectClose(w.molecularWeight, 18.015, tol: 1e-6)
            try expectClose(w.monoisotopicMass, 18.010565, tol: 1e-4)
            try expect(w.elementCounts == [1: 2, 8: 1])
            try expect(w.formula(withCharge: true) == "H2O")
        },
        Check("core.formula.hill_order") {
            try expect(benzene().formula == "C6H6")
            try expect(naphthalene().formula == "C10")
            let sf6 = mol([16, 9, 9, 9, 9, 9, 9], Array(repeating: .zero, count: 7))
            try expect(sf6.formula == "F6S")
            // ethanol C2H6O with a bromine: C, H, then alphabetical (Br, O)
            let zs = [6, 6, 8, 35] + Array(repeating: 1, count: 5)
            try expect(mol(zs, Array(repeating: .zero, count: zs.count)).formula == "C2H5BrO")
            // no carbon: all alphabetical, including H
            let nh3 = mol([7, 1, 1, 1], Array(repeating: .zero, count: 4))
            try expect(nh3.formula == "H3N")
            try expect(mol([17, 11], [.zero, .zero]).formula == "ClNa")
        },
        Check("core.formula.edge_cases") {
            let e = Molecule()
            try expect(e.formula == "" && e.molecularWeight == 0 && e.monoisotopicMass == 0 && e.elementCounts.isEmpty)
            let d = mol([0, 6, 0], Array(repeating: .zero, count: 3))
            try expect(d.formula == "C" && d.elementCounts == [6: 1])
            try expectClose(d.molecularWeight, 12.011, tol: 1e-9)
            try expectClose(d.monoisotopicMass, 12.0, tol: 1e-12)
            try expect(mol([1], [.zero]).formula == "H")
        },
        Check("core.formula.charge_suffix") {
            var m = mol([7, 1, 1, 1, 1], Array(repeating: .zero, count: 5))
            m.charge = 1
            try expect(m.formula(withCharge: true) == "H4N+")
            try expect(m.formula(withCharge: false) == "H4N")
            var s = mol([16, 8, 8, 8, 8], Array(repeating: .zero, count: 5))
            s.charge = -2
            try expect(s.formula(withCharge: true) == "O4S2-")
            s.charge = 3
            try expect(s.formula(withCharge: true) == "O4S3+")
            s.charge = 0
            try expect(s.formula(withCharge: true) == "O4S")
        },
        Check("core.formula.masses_heavy_and_fallback") {
            let br = mol([35], [.zero])
            try expectClose(br.monoisotopicMass, 78.9183371, tol: 1e-6)
            try expectClose(br.molecularWeight, 79.904, tol: 1e-9)
            let og = mol([118], [.zero])
            try expectClose(og.monoisotopicMass, og.molecularWeight, tol: 1e-12)
            let c60m = c60()
            try expectClose(c60m.monoisotopicMass, 720.0, tol: 1e-9)
            try expectClose(c60m.molecularWeight, 720.66, tol: 1e-6)
            for z in 1...36 { try expect(abs(mol([z], [.zero]).monoisotopicMass - Elements.element(z).mass) < 2.0, "z \(z)") }
        },
    ]
}
