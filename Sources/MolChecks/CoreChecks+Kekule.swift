import Foundation
import MolCore

// Lead A, round 3: Kekulé display orders for aromatic systems (renderer draws alternating bonds).

/// Validates a Kekulé assignment: no aromatic orders left; every aromatic C/B/Si and pyridine-type N
/// carries exactly one double bond; pyrrole-type N, O, S carry none. Returns the number of double bonds.
private func validateKekule(_ m: Molecule, _ orders: [BondOrder], name: String) throws -> Int {
    try expect(orders.count == m.bonds.count, "\(name): orders parallel to bonds")
    try expect(!orders.contains(.aromatic), "\(name): no aromatic orders in display")
    var aromaticAtom = Set<Int>()
    var deg = [Int](repeating: 0, count: m.atoms.count)
    for b in m.bonds { deg[b.a] += 1; deg[b.b] += 1 }
    for b in m.bonds where b.order == .aromatic { aromaticAtom.insert(b.a); aromaticAtom.insert(b.b) }
    var doubles = [Int](repeating: 0, count: m.atoms.count)
    for (k, b) in m.bonds.enumerated() where orders[k] == .double || orders[k] == .triple {
        doubles[b.a] += 1; doubles[b.b] += 1
    }
    for i in aromaticAtom {
        let z = m.atoms[i].atomicNumber
        try expect(doubles[i] <= 1, "\(name): atom \(i + 1) has \(doubles[i]) double bonds")
        switch z {
        case 6: try expect(doubles[i] == 1, "\(name): aromatic C \(i + 1) needs one double bond")
        case 7 where deg[i] == 2: try expect(doubles[i] == 1, "\(name): pyridine-type N \(i + 1) needs one double bond")
        case 7 where deg[i] == 3: try expect(doubles[i] == 0, "\(name): pyrrole-type N \(i + 1) has no double bond")
        case 8, 16: try expect(doubles[i] == 0, "\(name): O/S \(i + 1) has no double bond")
        default: break
        }
    }
    // alternation: no two ring-adjacent double bonds share an atom (implied by doubles <= 1)
    return orders.filter { $0 == .double }.count
}

extension Checks {
    static let coreKekule: [Check] = [
        Check("core.kekule.aromaticSystems") {
            // (SMILES, total double bonds in the display structure)
            let cases: [(String, String, Int)] = [
                ("benzene", "c1ccccc1", 3),
                ("naphthalene", "c1ccc2ccccc2c1", 5),
                ("anthracene", "c1ccc2cc3ccccc3cc2c1", 7),
                ("phenanthrene", "c1ccc2c(c1)ccc1ccccc12", 7),
                ("pyrene", "c1cc2ccc3cccc4ccc(c1)c2c34", 8),
                ("pyridine", "c1ccncc1", 3),
                ("pyrrole", "c1cc[nH]c1", 2),
                ("furan", "c1ccoc1", 2),
                ("thiophene", "c1ccsc1", 2),
                ("indole", "c1ccc2[nH]ccc2c1", 4),
                ("imidazole", "c1c[nH]cn1", 2),
                ("caffeine", "Cn1cnc2c1c(=O)n(C)c(=O)n2C", 4),
                ("toluene", "Cc1ccccc1", 3),
            ]
            for (name, smi, nDouble) in cases {
                let m = try Molecule(smiles: smi)
                try expect(m.bonds.contains { $0.order == .aromatic }, "\(name): SMILES gives aromatic bonds")
                let before = m
                let orders = m.kekuleDisplayOrders()
                try expect(m == before, "\(name): display orders do not mutate")
                let d = try validateKekule(m, orders, name: name)
                try expect(d == nDouble, "\(name): \(d) double bonds, expected \(nDouble)")
                // kekulize() agrees in count and validity
                var k = m
                try expect(k.kekulize(), "\(name): kekulize succeeds")
                _ = try validateKekule(m, k.bonds.map(\.order), name: name + " (kekulize)")
            }
        },
        Check("core.kekule.perRingDoubleCount") {
            // every six-membered carbocycle of benzenoid PAHs shows 2 or 3 double bonds; benzene exactly 3
            for (name, smi) in [("naphthalene", "c1ccc2ccccc2c1"), ("anthracene", "c1ccc2cc3ccccc3cc2c1"), ("pyrene", "c1cc2ccc3cccc4ccc(c1)c2c34")] {
                let m = try Molecule(smiles: smi)
                let o = m.kekuleDisplayOrders()
                for ring in m.smallestSetOfSmallestRings() where ring.count == 6 && ring.allSatisfy({ m.atoms[$0].atomicNumber == 6 }) {
                    var d = 0
                    for k in 0..<6 { if let bi = m.bondIndex(ring[k], ring[(k + 1) % 6]), o[bi] == .double { d += 1 } }
                    try expect((1...3).contains(d), "\(name): ring with \(d) double bonds")
                }
                let total = m.smallestSetOfSmallestRings().count
                try expect(total == (name == "pyrene" ? 4 : (name == "anthracene" ? 3 : 2)), "\(name): ring count \(total)")
            }
            let b = try Molecule(smiles: "c1ccccc1")
            let o = b.kekuleDisplayOrders()
            let ring = b.smallestSetOfSmallestRings()[0]
            var pattern: [BondOrder] = []
            for k in 0..<6 { pattern.append(o[b.bondIndex(ring[k], ring[(k + 1) % 6])!]) }
            for k in 0..<6 { try expect(pattern[k] != pattern[(k + 1) % 6], "benzene alternates") }
        },
        Check("core.kekule.perceivedFrom3D") {
            // 3D route: bonds perceived from geometry, orders perceived (marks aromatic), then displayed
            var m = try Molecule(smiles: "c1ccc2ccccc2c1")
            for k in m.bonds.indices { m.bonds[k].order = .single }
            m.perceiveBondOrders()
            let o = m.kekuleDisplayOrders()
            try expect(!o.contains(.aromatic))
            try expect(o.filter { $0 == .double }.count == 5, "naphthalene 3D: 5 doubles")
        },
        Check("core.kekule.bestEffort") {
            // pyrrole that lost its N-H: no perfect matching with N as pi-bond acceptor; display still alternates
            var p = try Molecule(smiles: "c1cc[nH]c1")
            let nh = p.atoms.indices.first { i in p.atoms[i].atomicNumber == 1 && p.neighbors(of: i).contains { p.atoms[$0].atomicNumber == 7 } }!
            _ = p.removeAtoms([nh])
            var strict = p
            try expect(!strict.kekulize(), "strict kekulize refuses N-H-less pyrrole")
            let o = p.kekuleDisplayOrders()
            try expect(!o.contains(.aromatic))
            try expect(o.filter { $0 == .double }.count == 2, "best effort gives 2 doubles")
            // non-aromatic molecules pass through unchanged
            let e = try Molecule(smiles: "C=CC#N")
            try expect(e.kekuleDisplayOrders() == e.bonds.map(\.order))
            try expect(Molecule().kekuleDisplayOrders().isEmpty)
            let km = try Molecule(smiles: "c1ccccc1").kekuleDisplayMolecule()
            try expect(!km.bonds.contains { $0.order == .aromatic })
        },
    ]
}
