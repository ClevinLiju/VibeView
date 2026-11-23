import Foundation
import simd
import MolCore

// Core team (Lead 1) checks. Worker files CoreChecksA/B/C.swift add coreA/coreB/coreC.
extension Checks {
    static let core: [Check] = coreLead + coreA + coreB + coreC

    private static func counts(_ m: Molecule) -> [Int: Int] {
        var d: [Int: Int] = [:]
        for a in m.atoms { d[a.atomicNumber, default: 0] += 1 }
        return d
    }

    private static func orderCounts(_ m: Molecule) -> [BondOrder: Int] {
        var d: [BondOrder: Int] = [:]
        for b in m.bonds { d[b.order, default: 0] += 1 }
        return d
    }

    /// Parse, write, re-parse: element counts and bond-order histogram must survive.
    private static func roundTrip(_ s: String) throws {
        let m1 = try Molecule(smiles: s)
        let w = m1.smiles()
        let m2 = try Molecule(smiles: w)
        try expect(counts(m1) == counts(m2), "\(s) -> \(w): atom counts \(counts(m1)) vs \(counts(m2))")
        try expect(orderCounts(m1) == orderCounts(m2), "\(s) -> \(w): bond orders differ")
        try expect(m1.bonds.count == m2.bonds.count, "\(s) -> \(w): bond count")
    }

    static let coreLead: [Check] = [
        Check("core.smiles.parse.ethanol") {
            let m = try Molecule(smiles: "CCO")
            try expect(m.atoms.count == 9, "atoms \(m.atoms.count)")
            try expect(m.bonds.count == 8, "bonds \(m.bonds.count)")
            try expect(counts(m) == [6: 2, 8: 1, 1: 6])
            try expect(m.atoms.indices.allSatisfy { m.atoms[$0].id == $0 }, "id invariant")
        },
        Check("core.smiles.parse.benzene.aromatic") {
            let m = try Molecule(smiles: "c1ccccc1")
            try expect(counts(m) == [6: 6, 1: 6])
            try expect(orderCounts(m)[.aromatic] == 6, "aromatic bonds \(orderCounts(m))")
        },
        Check("core.smiles.parse.orders") {
            let co2 = try Molecule(smiles: "O=C=O")
            try expect(orderCounts(co2) == [.double: 2])
            let hcn = try Molecule(smiles: "C#N")
            try expect(counts(hcn) == [6: 1, 7: 1, 1: 1])
            try expect(orderCounts(hcn) == [.triple: 1, .single: 1])
        },
        Check("core.smiles.parse.brackets") {
            let r = try SMILES.parse("[NH4+]")
            try expect(r.molecule.atoms.count == 5 && r.molecule.charge == 1)
            try expect(r.formalCharges[0] == 1)
            let salt = try SMILES.parse("[Na+].[Cl-]")
            try expect(salt.molecule.atoms.count == 2 && salt.molecule.charge == 0 && salt.molecule.bonds.isEmpty)
            let iso = try Molecule(smiles: "[13CH4]")
            try expect(counts(iso) == [6: 1, 1: 4])
            let sulfate = try SMILES.parse("[O-]S(=O)(=O)[O-]")
            try expect(sulfate.molecule.charge == -2 && sulfate.molecule.atoms.count == 5)
            let fe = try Molecule(smiles: "[Fe+2]")
            try expect(fe.charge == 2 && fe.atoms.first?.atomicNumber == 26)
            let ch2 = try SMILES.parse("[CH2-2]")
            try expect(ch2.formalCharges[0] == -2 && ch2.molecule.atoms.count == 3)
        },
        Check("core.smiles.parse.halogens.branches") {
            let m = try Molecule(smiles: "ClC(Br)(F)I")
            try expect(counts(m) == [17: 1, 6: 1, 35: 1, 9: 1, 53: 1], "\(counts(m))")
            let tbu = try Molecule(smiles: "CC(C)(C)C")
            try expect(counts(tbu) == [6: 5, 1: 12] && tbu.bonds.count == 16)
        },
        Check("core.smiles.parse.ringClosures") {
            let cyclohexane = try Molecule(smiles: "C1CCCCC1")
            try expect(counts(cyclohexane) == [6: 6, 1: 12] && cyclohexane.bonds.count == 18)
            let pct = try Molecule(smiles: "C%10CCCC%10")
            try expect(counts(pct) == [6: 5, 1: 10])
            let naph = try Molecule(smiles: "c1ccc2ccccc2c1")
            try expect(counts(naph) == [6: 10, 1: 8] && orderCounts(naph)[.aromatic] == 11)
            let pyrrole = try Molecule(smiles: "c1cc[nH]c1")
            try expect(counts(pyrrole) == [6: 4, 7: 1, 1: 5])
            let ringDouble = try Molecule(smiles: "C=1CCCCC=1")
            try expect(orderCounts(ringDouble)[.double] == 1, "\(orderCounts(ringDouble))")
        },
        Check("core.smiles.parse.noHydrogens") {
            let m = try Molecule(smiles: "CCO", addHydrogens: false)
            try expect(m.atoms.count == 3 && m.bonds.count == 2)
        },
        Check("core.smiles.parse.edgeCases") {
            let empty = try Molecule(smiles: "")
            try expect(empty.atoms.isEmpty && empty.bonds.isEmpty)
            let single = try Molecule(smiles: "[He]")
            try expect(single.atoms.count == 1 && single.bonds.isEmpty)
            let h2 = try Molecule(smiles: "[H][H]")
            try expect(h2.atoms.count == 2 && h2.bonds.count == 1)
        },
        Check("core.smiles.parse.errors") {
            func fails(_ s: String) -> Bool { (try? SMILES.parse(s)) == nil }
            try expect(fails("C1CC"), "unclosed ring")
            try expect(fails("C(C"), "unbalanced (")
            try expect(fails("CC)"), "unbalanced )")
            try expect(fails("[Xx]"), "unknown element")
            try expect(fails("C="), "dangling bond")
            try expect(fails("[CH4"), "unclosed bracket")
            try expect(fails("Q"), "bad organic atom")
            try expect(fails("1CC"), "ring digit before atom")
        },
        Check("core.smiles.parse.layoutNoOverlap") {
            let m = try Molecule(smiles: "CC(C)(C)CCO")
            for i in m.atoms.indices { for j in (i + 1)..<m.atoms.count {
                try expect(m.distance(i, j) > 0.3, "atoms \(i),\(j) overlap")
            } }
            for b in m.bonds { try expect(m.distance(b.a, b.b) < 2.0, "bond too long") }
        },
        Check("core.smiles.write.simple") {
            try expect(Molecule().smiles() == "")
            let ch4 = try Molecule(smiles: "C")
            try expect(ch4.smiles() == "C", ch4.smiles())
            let water = try Molecule(smiles: "O")
            try expect(water.smiles() == "O", water.smiles())
            for s in ["[H][H]", "O=C=O", "CCO"] {
                let w = try Molecule(smiles: s).smiles()
                try expect(w == s, "\(s) wrote \(w)")
            }
            let single = Molecule(atoms: [Atom(id: 0, atomicNumber: 26, position: .zero)])
            try expect(single.smiles() == "[Fe]", single.smiles())
            let bareC = Molecule(atoms: [Atom(id: 0, atomicNumber: 6, position: .zero)])
            try expect(bareC.smiles() == "[C]", bareC.smiles())
        },
        Check("core.smiles.write.chargesAndRings") {
            let r = try SMILES.parse("[NH4+]")
            try expect(r.molecule.smiles(formalCharges: r.formalCharges) == "[NH4+]")
            let bz = try Molecule(smiles: "c1ccccc1")
            try expect(bz.smiles() == "c1ccccc1", bz.smiles())
            let ring = try Molecule(smiles: "C1CCCCC1")
            try expect(ring.smiles() == "C1CCCCC1", ring.smiles())
            let pyrrole = try Molecule(smiles: "c1cc[nH]c1")
            try expect(pyrrole.smiles().contains("[nH]"), pyrrole.smiles())
        },
        Check("core.smiles.roundTrip") {
            for s in ["CCO", "c1ccccc1", "c1ccc2ccccc2c1", "C1CCC2(CC1)CCCC2", "OC(=O)C(N)Cc1ccccc1",
                      "C#CC=CC", "c1ccncc1", "c1cc[nH]c1", "c1ccoc1", "c1ccsc1", "ClC(Cl)(Cl)Cl",
                      "C12C3C4C1C5C2C3C45", "[Na+].[Cl-]", "CC(C)(C)C", "FS(F)(F)(F)(F)F",
                      "c1ccc(cc1)-c1ccccc1", "C1CC2CCC1C2", "O=S(=O)(O)O"] {
                try roundTrip(s)
            }
        },
        Check("core.smiles.large") {
            let chain = String(repeating: "C", count: 1500)
            let m = try Molecule(smiles: chain)
            try expect(m.atoms.count == 1500 + 3002, "\(m.atoms.count)")
            try expect(m.smiles() == chain)
            // Many ring closures with digit reuse: 300 fused-free cyclopropanes in a chain.
            let rings = String(repeating: "C1CC1", count: 300)
            try roundTrip(rings)
        },
        Check("core.vector.basics") {
            try expectClose(VecMath.distance(Vec3(0, 0, 0), Vec3(3, 4, 0)), 5)
            try expectClose(VecMath.angle(Vec3(1, 0, 0), .zero, Vec3(0, 1, 0)), 90)
            try expectClose(VecMath.angle(Vec3(1, 0, 0), .zero, Vec3(-1, 0, 0)), 180)
            try expectClose(VecMath.angle(.zero, .zero, Vec3(1, 0, 0)), 0)
            // IUPAC: looking down b->c, a at +x, d rotated +90° clockwise = +90.
            try expectClose(VecMath.dihedral(Vec3(1, 0, 0), .zero, Vec3(0, 0, 1), Vec3(0, 1, 1)), 90)
            try expectClose(VecMath.dihedral(Vec3(1, 0, 0), .zero, Vec3(0, 0, 1), Vec3(0, -1, 1)), -90)
            try expectClose(abs(VecMath.dihedral(Vec3(1, 0, 0), .zero, Vec3(0, 0, 1), Vec3(-1, 0, 1))), 180)
            let r = VecMath.rotate(Vec3(1, 0, 0), about: .zero, axis: Vec3(0, 0, 1), degrees: 90)
            try expect(simd_length(r - Vec3(0, 1, 0)) < 1e-12)
            let m = VecMath.rotationMatrix(axis: Vec3(0, 0, 2), degrees: 90)
            try expect(simd_length(m * Vec3(1, 0, 0) - Vec3(0, 1, 0)) < 1e-12)
            try expect(VecMath.rotationMatrix(axis: .zero, degrees: 30) == matrix_identity_double3x3)
            for v in [Vec3(1, 0, 0), Vec3(0, 0, 5), Vec3(1, 2, 3)] {
                let p = VecMath.perpendicular(v)
                try expect(abs(simd_dot(p, v)) < 1e-12 && abs(simd_length(p) - 1) < 1e-12)
            }
            try expectClose(radToDeg(degToRad(37)), 37)
        },
        Check("core.vector.symmetricEigen") {
            let rot = VecMath.rotationMatrix(axis: Vec3(1, 2, 3), degrees: 33)
            let d = simd_double3x3(diagonal: Vec3(5, 1, 3))
            let a = rot * d * rot.transpose
            let (vals, vecs) = VecMath.symmetricEigen(a)
            try expectClose(vals.x, 1, tol: 1e-9); try expectClose(vals.y, 3, tol: 1e-9); try expectClose(vals.z, 5, tol: 1e-9)
            try expectClose(vecs.determinant, 1, tol: 1e-9)
            for k in 0..<3 {
                let v = vecs[k]
                try expect(simd_length(a * v - vals[k] * v) < 1e-9, "eigvec \(k)")
            }
            let (dv, _) = VecMath.symmetricEigen(simd_double3x3(diagonal: Vec3(2, 2, 2)))
            try expect(dv == Vec3(2, 2, 2))
        },
        Check("core.topology.basics") {
            var m = Molecule(atoms: (0..<4).map { Atom(id: $0, atomicNumber: 6, position: Vec3(Double($0) * 1.5, 0, 0)) },
                             bonds: [Bond(1, 0), Bond(1, 2, order: .double), Bond(2, 3), Bond(2, 1), Bond(3, 3), Bond(0, 9)])
            m.normalizeBonds()
            try expect(m.bonds.count == 3, "normalize \(m.bonds)")
            try expect(m.adjacency() == [[1], [0, 2], [1, 3], [2]])
            try expect(m.neighbors(of: 1).sorted() == [0, 2])
            try expect(m.bondIndex(2, 1) == 1 && m.bondIndex(0, 3) == nil)
            try expect(m.bond(between: 2, and: 1)?.order == .double)
            try expect(m.areBonded(3, 2) && !m.areBonded(0, 2))
            try expect(m.degree(of: 1) == 2 && m.degree(of: 0) == 1)
            try expectClose(m.bondOrderSum(of: 1), 3)
            try expectClose(m.distance(0, 3), 4.5)
            m.atoms[3].position = Vec3(3, 1.5, 0)
            try expectClose(m.angle(1, 2, 3), 90)
            m.atoms[0].position = Vec3(0, 0, 1.5)
            try expectClose(abs(m.dihedral(0, 1, 2, 3)), 90)
            var p = m.positions
            p[0] = Vec3(9, 9, 9)
            m.positions = p
            try expect(m.atoms[0].position == Vec3(9, 9, 9))
            m.atoms[2].id = 42
            m.renumberAtomIDs()
            try expect(m.atoms[2].id == 2)
            let empty = Molecule()
            try expect(empty.adjacency().isEmpty && empty.positions.isEmpty && empty.neighbors(of: 0).isEmpty)
        },
    ]
}
