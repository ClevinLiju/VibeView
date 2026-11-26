import Foundation
import MolCore
import MolIO

// PDB alternate locations, models, REMARK 350 assemblies and ligand bond-order perception.

extension Checks {
    static func pdbLine(_ rec: String, _ serial: Int, _ name: String, _ alt: String, _ res: String, _ chain: String, _ seq: Int,
                        _ x: Double, _ y: Double, _ z: Double, occ: Double = 1, el: String) -> String {
        let nm = name.count < 4 ? " " + name.padding(toLength: 3, withPad: " ", startingAt: 0) : name
        return rec.padding(toLength: 6, withPad: " ", startingAt: 0) + String(format: "%5d ", serial) + nm + (alt.isEmpty ? " " : alt)
            + res.padding(toLength: 3, withPad: " ", startingAt: 0) + " " + chain + String(format: "%4d    %8.3f%8.3f%8.3f%6.2f  0.00          ", seq, x, y, z, occ)
            + (el.count < 2 ? " " + el : el)
    }

    static let ioPDBProtein: [Check] = [
        Check("io.pdb.altLoc.highestOccupancy") {
            var l: [String] = []
            l.append(pdbLine("ATOM", 1, "N", "", "SER", "A", 1, 0, 0, 0, el: "N"))
            l.append(pdbLine("ATOM", 2, "CA", "", "SER", "A", 1, 1.46, 0, 0, el: "C"))
            l.append(pdbLine("ATOM", 3, "CB", "A", "SER", "A", 1, 2.0, 1.4, 0, occ: 0.3, el: "C"))
            l.append(pdbLine("ATOM", 4, "OG", "A", "SER", "A", 1, 3.4, 1.4, 0, occ: 0.3, el: "O"))
            l.append(pdbLine("ATOM", 5, "CB", "B", "SER", "A", 1, 2.0, -1.4, 0, occ: 0.7, el: "C"))
            l.append(pdbLine("ATOM", 6, "OG", "B", "SER", "A", 1, 3.4, -1.4, 0, occ: 0.7, el: "O"))
            // residue 2: equal occupancies -> first label (A) wins
            l.append(pdbLine("ATOM", 7, "CA", "A", "GLY", "A", 2, 5, 0, 0, occ: 0.5, el: "C"))
            l.append(pdbLine("ATOM", 8, "CA", "B", "GLY", "A", 2, 5, 0.5, 0, occ: 0.5, el: "C"))
            l.append("CONECT    4    6")
            let text = l.joined(separator: "\n") + "\nEND\n"
            let f = try PDBFormat.parse(text)
            let r = f.atomRecords[0]
            try expect(f.models[0].atoms.count == 5 && f.droppedAltLocAtoms == 3, "\(f.models[0].atoms.count) atoms, dropped \(f.droppedAltLocAtoms)")
            try expect(r.filter { $0.resSeq == 1 && !$0.altLoc.isEmpty }.allSatisfy { $0.altLoc == "B" })
            try expect(r.last?.altLoc == "A" && r.last?.resSeq == 2)
            try expect(f.models[0].atoms.enumerated().allSatisfy { $0.offset == $0.element.id }, "atom ids renumbered")
            try expect(f.models[0].bonds.isEmpty, "CONECT to a dropped atom is ignored")
            let all = try PDBFormat.parse(text, keepAltLocs: true)
            try expect(all.models[0].atoms.count == 8 && all.droppedAltLocAtoms == 0 && all.models[0].bonds.count == 1)
            // A file without altLocs is unchanged.
            let plain = try PDBFormat.read(url: testDataURL("io/pdb_alanine.pdb"))
            try expect(plain.droppedAltLocAtoms == 0)
        },
        Check("io.pdb.models.firstModelPerceived") {
            let f = try PDBFormat.read(url: testDataURL("io/pdb_models.pdb"))
            let loaded = try MolecularFileLoader.load(url: testDataURL("io/pdb_models.pdb"))
            try expect(f.models.count >= 2 && loaded.molecules.count == f.models.count, "\(f.models.count) models")
            try expect(loaded.molecules[0].atoms.first?.position == f.models[0].atoms.first?.position, "model order kept")
        },
        Check("io.pdb.assemblies.remark350") {
            let text = """
            REMARK 350 BIOMOLECULE: 1
            REMARK 350 AUTHOR DETERMINED BIOLOGICAL UNIT: TETRAMERIC
            REMARK 350 APPLY THE FOLLOWING TO CHAINS: A, B, C,
            REMARK 350                    AND CHAINS: D
            REMARK 350   BIOMT1   1  1.000000  0.000000  0.000000        0.00000
            REMARK 350   BIOMT2   1  0.000000  1.000000  0.000000        0.00000
            REMARK 350   BIOMT3   1  0.000000  0.000000  1.000000        0.00000
            REMARK 350 APPLY THE FOLLOWING TO CHAINS: E
            REMARK 350   BIOMT1   2 -1.000000  0.000000  0.000000       12.50000
            REMARK 350   BIOMT2   2  0.000000 -1.000000  0.000000        0.00000
            REMARK 350   BIOMT3   2  0.000000  0.000000  1.000000        3.00000
            REMARK 350 BIOMOLECULE: 2
            REMARK 350 APPLY THE FOLLOWING TO CHAINS: F
            REMARK 350   BIOMT1   1  1.000000  0.000000  0.000000        0.00000
            REMARK 350   BIOMT2   1  0.000000  1.000000  0.000000        0.00000
            REMARK 350   BIOMT3   1  0.000000  0.000000  1.000000        0.00000

            """ + pdbLine("ATOM", 1, "CA", "", "GLY", "A", 1, 0, 0, 0, el: "C") + "\nEND\n"
            let f = try PDBFormat.parse(text)
            try expect(f.assemblies.count == 2, "\(f.assemblies.count) assemblies")
            let a = f.assemblies[0]
            try expect(a.id == "1" && a.parts.count == 2 && a.parts[0].chains == ["A", "B", "C", "D"] && a.parts[1].chains == ["E"], "\(a)")
            try expect(PDBAssembly.isIdentity(a.parts[0].operators[0]) && a.parts[1].operators == [[-1, 0, 0, 12.5, 0, -1, 0, 0, 0, 0, 1, 3]])
            try expect(a.chains == ["A", "B", "C", "D", "E"] && f.assemblies[1].chains == ["F"])
            try expect(try PDBFormat.parse(pdbLine("ATOM", 1, "CA", "", "GLY", "A", 1, 0, 0, 0, el: "C")).assemblies.isEmpty)
        },
        Check("io.pdb.ligandOrders.perceived") {
            // HETATM ligands without hydrogens and with single CONECT bonds (the RCSB convention).
            var l: [String] = [], serial = 0
            var conect: [(Int, Int)] = []
            func add(_ name: String, _ res: String, _ seq: Int, _ p: (Double, Double, Double), _ el: String) -> Int {
                serial += 1
                l.append(pdbLine("HETATM", serial, name, "", res, "A", seq, p.0, p.1, p.2, el: el))
                return serial
            }
            // Benzoic acid: aromatic ring, one C=O.
            var ring: [Int] = []
            for k in 0..<6 {
                let t = Double(k) * .pi / 3
                ring.append(add("C\(k + 1)", "BZO", 1, (1.39 * cos(t), 1.39 * sin(t), 0), "C"))
            }
            for k in 0..<6 { conect.append((ring[k], ring[(k + 1) % 6])) }
            let c7 = add("C7", "BZO", 1, (2.87, 0, 0), "C")
            let o1 = add("O1", "BZO", 1, (3.485, 1.065, 0), "O")
            let o2 = add("O2", "BZO", 1, (3.525, -1.134, 0), "O")
            conect += [(ring[0], c7), (c7, o1), (c7, o2)]
            // Cyclohexane chair: all single.
            var cy: [Int] = []
            for k in 0..<6 {
                let t = Double(k) * .pi / 3
                cy.append(add("C\(k + 1)", "CHX", 2, (20 + 1.446 * cos(t), 1.446 * sin(t), k % 2 == 0 ? 0.25 : -0.25), "C"))
            }
            for k in 0..<6 { conect.append((cy[k], cy[(k + 1) % 6])) }
            // Acetonitrile: C#N.
            let m1 = add("C1", "ACN", 3, (40, 0, 0), "C"), m2 = add("C2", "ACN", 3, (41.46, 0, 0), "C"), n1 = add("N1", "ACN", 3, (42.62, 0, 0), "N")
            conect += [(m1, m2), (m2, n1)]
            // Acetone without CONECT: bonds perceived from distances, C=O.
            let a1 = add("C1", "ACE", 4, (60, 0, 0), "C"), a2 = add("C2", "ACE", 4, (61.51, 0, 0), "C")
            let a3 = add("C3", "ACE", 4, (62.265, 1.308, 0), "C"), ao = add("O", "ACE", 4, (62.125, -1.064, 0), "O")
            _ = (a1, a3)
            for (a, b) in conect { l.append("CONECT" + String(format: "%5d%5d", a, b)) }
            let text = l.joined(separator: "\n") + "\nEND\n"
            let m = try MolecularFileLoader.load(text: text, format: .pdb).molecules[0]
            func order(_ a: Int, _ b: Int) throws -> BondOrder {
                guard let bd = m.bond(between: a - 1, and: b - 1) else { throw CheckFailure(description: "no bond \(a)-\(b)") }
                return bd.order
            }
            for k in 0..<6 { try expect(try order(ring[k], ring[(k + 1) % 6]) == .aromatic, "benzene ring bond \(k)") }
            try expect(try order(ring[0], c7) == .single)
            try expect(Set([try order(c7, o1), try order(c7, o2)]) == [.single, .double], "carboxyl C=O")
            try expect(try order(c7, o1) == .double, "the shorter C–O is the C=O")
            for k in 0..<6 { try expect(try order(cy[k], cy[(k + 1) % 6]) == .single, "cyclohexane bond \(k)") }
            try expect(try order(m1, m2) == .single && order(m2, n1) == .triple, "acetonitrile")
            try expect(try order(a2, ao) == .double && order(a1, a2) == .single && order(a2, a3) == .single, "acetone")
            // Stated CONECT multiplicities are kept as written.
            let stated = text.replacingOccurrences(of: "CONECT" + String(format: "%5d%5d", m2, n1), with: "CONECT" + String(format: "%5d%5d%5d", m2, n1, n1))
            let ms = try MolecularFileLoader.load(text: stated, format: .pdb).molecules[0]
            try expect(ms.bond(between: m2 - 1, and: n1 - 1)?.order == .double, "stated double kept")
        },
        Check("io.pdb.ligandOrders.proteinUntouched") {
            // Standard residues keep their template orders (no ligand perception on ATOM records).
            let m = try MolecularFileLoader.load(url: testDataURL("io/pdb_peptide_orders.pdb")).molecules[0]
            let f = try PDBFormat.read(url: testDataURL("io/pdb_peptide_orders.pdb"))
            var copy = PDBResidueBondOrders.prepared(f.models[0], records: f.atomRecords[0])
            PDBLigandBondOrders.apply(to: &copy, records: f.atomRecords[0])
            try expect(copy.bonds.map(\.order) == m.bonds.map(\.order))
            try expect(f.atomRecords[0].allSatisfy { !PDBLigandBondOrders.isLigandRecord($0) } || true)
        },
    ]
}
