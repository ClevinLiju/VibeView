import Foundation
import MolCore
import MolIO

// Residue-template bond orders for protein PDBs (PDBResidueBondOrders, applied by MolecularFileLoader).

extension Checks {
    static let ioPDBOrders: [Check] = [
        Check("io.pdb.residueOrders.peptideFixture") {
            let url = testDataURL("io/pdb_peptide_orders.pdb")
            let raw = try PDBFormat.read(url: url)
            let m = try MolecularFileLoader.load(url: url).molecules[0]
            let r = raw.atomRecords[0]
            try expect(m.bonds.count == raw.models[0].bonds.count, "no bonds added when CONECT covers everything")
            func order(_ res: Int, _ a: String, _ b: String) throws -> BondOrder {
                guard let i = r.firstIndex(where: { $0.resSeq == res && $0.name == a }),
                      let j = r.firstIndex(where: { $0.resSeq == res && $0.name == b }) else {
                    throw CheckFailure(description: "atoms \(a)/\(b) of residue \(res) missing")
                }
                guard let bd = m.bond(between: i, and: j) else { throw CheckFailure(description: "no bond \(a)-\(b) in \(res)") }
                return bd.order
            }
            // backbone C=O in every residue, OXT single
            for res in 1...10 { try expect(try order(res, "C", "O") == .double, "C=O residue \(res)") }
            try expect(try order(10, "C", "OXT") == .single)
            // Phe / Tyr Kekulé
            for res in [1, 2] {
                let dbl = [("CG", "CD1"), ("CE1", "CZ"), ("CD2", "CE2")], sgl = [("CD1", "CE1"), ("CZ", "CE2"), ("CD2", "CG"), ("CB", "CG")]
                for (a, b) in dbl { try expect(try order(res, a, b) == .double, "\(res) \(a)=\(b)") }
                for (a, b) in sgl { try expect(try order(res, a, b) == .single, "\(res) \(a)-\(b)") }
            }
            try expect(try order(2, "CZ", "OH") == .single)
            // Trp: 4 doubles, NE1 has none
            for (a, b) in [("CG", "CD1"), ("CD2", "CE3"), ("CZ3", "CH2"), ("CZ2", "CE2")] { try expect(try order(3, a, b) == .double, "Trp \(a)=\(b)") }
            for (a, b) in [("CD1", "NE1"), ("NE1", "CE2"), ("CE2", "CD2"), ("CD2", "CG"), ("CE3", "CZ3"), ("CH2", "CZ2")] {
                try expect(try order(3, a, b) == .single, "Trp \(a)-\(b)")
            }
            // His tautomers: HD1 → CE1=NE2, HE2 → ND1=CE1; CG=CD2 in both
            try expect(try order(4, "CG", "CD2") == .double && order(4, "CE1", "NE2") == .double && order(4, "ND1", "CE1") == .single)
            try expect(try order(5, "CG", "CD2") == .double && order(5, "ND1", "CE1") == .double && order(5, "CE1", "NE2") == .single)
            // one C=O in carboxylates / amides, one C=N in Arg
            try expect(try order(6, "CG", "OD1") == .double && order(6, "CG", "OD2") == .single)
            try expect(try order(7, "CD", "OE1") == .double && order(7, "CD", "OE2") == .single)
            try expect(try order(8, "CG", "OD1") == .double && order(8, "CG", "ND2") == .single)
            try expect(try order(9, "CD", "OE1") == .double && order(9, "CD", "NE2") == .single)
            try expect(try order(10, "CZ", "NH1") == .double && order(10, "CZ", "NH2") == .single && order(10, "NE", "CZ") == .single)
            // counts: 10 C=O + 3 + 3 + 4 + 2 + 2 + 1 + 1 + 1 + 1 + 1 = 29 doubles; peptide bonds single
            try expect(m.bonds.filter { $0.order == .double }.count == 29, "doubles \(m.bonds.filter { $0.order == .double }.count)")
            try expect(!m.bonds.contains { $0.order == .aromatic || $0.order == .triple })
            // every residue's Kekulé system is consistent: no atom carries two double bonds
            var dcount = [Int](repeating: 0, count: m.atoms.count)
            for b in m.bonds where b.order == .double { dcount[b.a] += 1; dcount[b.b] += 1 }
            try expect(dcount.allSatisfy { $0 <= 1 })
        },
        Check("io.pdb.residueOrders.perceivedAlanine") {
            // The alanine fixture without CONECT: bonds come from distances, the template restores C=O,
            // while the Zn ion and water (HETATM) are left as perception gives them.
            let text = try readText(testDataURL("io/pdb_alanine.pdb"))
            let noConect = text.components(separatedBy: "\n").filter { !$0.hasPrefix("CONECT") }.joined(separator: "\n")
            let m = try MolecularFileLoader.load(text: noConect, format: .pdb).molecules[0]
            try expect(m.bond(between: 2, and: 3)?.order == .double, "C=O")
            try expect(m.bond(between: 0, and: 1)?.order == .single && m.bond(between: 1, and: 2)?.order == .single && m.bond(between: 1, and: 4)?.order == .single)
            try expect(m.bond(between: 9, and: 10) != nil && m.bond(between: 9, and: 11) != nil, "water bonds perceived too")
            // with CONECT the loader keeps the file's 9 bonds
            let full = try MolecularFileLoader.load(url: testDataURL("io/pdb_alanine.pdb")).molecules[0]
            try expect(full.bonds.count == 9 && full.bond(between: 2, and: 3)?.order == .double)
        },
        Check("io.pdb.residueOrders.nonProteinUntouched") {
            let f = try PDBFormat.read(url: testDataURL("io/pdb_models.pdb"))
            try expect(f.withResidueBondOrders() == f, "water-only models unchanged")
            // template pairs are public for the app/renderer
            try expect(PDBResidueBondOrders.doubleBondPairs(residue: "GLY", atomNames: []).map { "\($0.0)=\($0.1)" } == ["C=O"])
            try expect(PDBResidueBondOrders.doubleBondPairs(residue: "HID", atomNames: []).contains { $0 == ("CE1", "NE2") })
        },
    ]
}
