import Foundation
import MolCore
import MolIO
import MolBuild

// Z-Matrix tab and From Z-Matrix (MolCore `ZMatrix.connectivityOrder`, MolIO `ZMatrixTable` / `ZMatrixText`).

fileprivate let zmEthanol = """
0 1
C
C  1  1.52
O  2  1.43  1  109.5
H  3  0.96  2  108.0  1  180.0
H  1  1.09  2  110.0  3   60.0
H  1  1.09  2  110.0  3  180.0
H  1  1.09  2  110.0  3  -60.0
H  2  1.09  1  110.0  3  120.0
H  2  1.09  1  110.0  3 -120.0
"""

fileprivate func zmShuffled(_ m: Molecule) -> Molecule {
    // Hydrogens first, then heavy atoms reversed: an input order unlike the connectivity order.
    let order = m.atoms.indices.filter { m.atoms[$0].atomicNumber == 1 } + m.atoms.indices.filter { m.atoms[$0].atomicNumber > 1 }.reversed()
    return ZMatrixTable.reordered(m, order)
}

fileprivate func zmRMSD(_ a: Molecule, _ b: Molecule) -> Double {
    Geometry.kabsch(moving: a.positions, target: b.positions).rmsd
}

extension Checks {
    static let ioZMatrixTable: [Check] = [
        Check("io.zmatrix.connectivityOrderFollowsBonds") {
            let m = zmShuffled(try ZMatrixText.parse(zmEthanol).molecule)
            try expect(m.atoms.count == 9 && m.bonds.count == 8, "\(m.atoms.count) atoms \(m.bonds.count) bonds")
            let order = ZMatrix.connectivityOrder(m)
            try expect(Set(order) == Set(m.atoms.indices) && order.count == 9, "permutation")
            try expect(m.atoms[order[0]].atomicNumber > 1 && m.atoms[order[1]].atomicNumber > 1, "backbone first")
            let t = try ZMatrixTable.make(m).orThrow("table")
            try expect(t.rows.dropFirst().allSatisfy(\.bonded), "every bond reference is a bond")
            try expect(t.rows[0].bondAtom == nil && t.rows[1].angleAtom == nil && t.rows[2].dihedralAtom == nil && t.rows[3].dihedralAtom != nil)
            try expectClose(t.rows[1].bond ?? 0, VecMath.distance(m.atoms[t.order[0]].position, m.atoms[t.order[1]].position), tol: 1e-9)
            try expect(m.atoms[t.order[0]].atomicNumber == 8, "starts at the lowest-index heavy atom (O after shuffling)")
        },
        Check("io.zmatrix.textRoundTripsKeepIndices") {
            let m = zmShuffled(try ZMatrixText.parse(zmEthanol).molecule)
            let t = try ZMatrixTable.make(m).orThrow("table")
            for style in ZMatrixTable.TextStyle.allCases {
                let text = t.text(style)
                let p = try ZMatrixText.parse(text)
                try expect(p.molecule.atoms.count == 9 && p.chargeGiven, "\(style): \(p.molecule.atoms.count)")
                // Applying the unchanged text keeps every atom where it is, under the same index.
                let (back, mode) = ZMatrixText.apply(p, onto: m, order: t.order)
                try expect(mode == .positions, "\(style) mode \(mode)")
                try expect(zip(back.atoms, m.atoms).allSatisfy { VecMath.distance($0.position, $1.position) < 2e-3 && $0.atomicNumber == $1.atomicNumber },
                           "\(style) positions kept")
                try expect(back.bonds == m.bonds, "\(style) bonds kept")
            }
            try expect(t.text(.gaussianVariables).contains("R2    =") && t.text(.orca).hasPrefix("* int 0 1"), t.text(.gaussianVariables))
            // An edited dihedral moves only what depends on it.
            var txt = t.text(.gaussian).components(separatedBy: "\n")
            let k = t.rows.indices.last!
            var parts = txt[k + 1].split(separator: " ").map(String.init)
            parts[parts.count - 1] = String(format: "%.4f", (t.rows[k].dihedral ?? 0) + 30)
            txt[k + 1] = parts.joined(separator: "  ")
            let (moved, _) = ZMatrixText.apply(try ZMatrixText.parse(txt.joined(separator: "\n")), onto: m, order: t.order)
            let r = t.rows[k]
            try expectClose(GeometryEdit.dihedral(moved, r.atom, r.bondAtom!, r.angleAtom!, r.dihedralAtom!), (r.dihedral ?? 0) + 30, tol: 0.05)
            // Different atoms: the structure is replaced.
            let (rep, mode2) = ZMatrixText.apply(try ZMatrixText.parse("O\nH 1 0.96\nH 1 0.96 2 104.5\n"), onto: m, order: t.order)
            try expect(mode2 == .replace && rep.atoms.count == 3 && rep.charge == m.charge)
        },
        Check("io.zmatrix.parsesPastedForms") {
            let orca = try ZMatrixText.parse("! HF\n* int 1 2\nO 0 0 0 0 0 0\nH 1 0 0 0.98 0 0\nH 1 2 0 0.98 105 0\n*\n")
            try expect(orca.molecule.atoms.count == 3 && orca.molecule.charge == 1 && orca.molecule.multiplicity == 2 && orca.source == "orcaInput")
            let bare = try ZMatrixText.parse("O 0 0 0 0 0 0\nH 1 0 0 0.98 0 0\nH 1 2 0 0.98 105 0\n")
            try expect(bare.source == "orcaInternal" && !bare.chargeGiven && bare.molecule.bonds.count == 2)
            try expectClose(GeometryEdit.angle(bare.molecule, 1, 0, 2), 105, tol: 0.01)
            let vars = try ZMatrixText.parse("O\nH 1 r\nH 1 r 2 a\n\nr = 0.97\na = 104.0\n")
            try expectClose(VecMath.distance(vars.molecule.atoms[0].position, vars.molecule.atoms[1].position), 0.97, tol: 1e-6)
            let gjf = try ZMatrixText.parse("%chk=w.chk\n#p HF/STO-3G\n\nwater\n\n0 1\nO\nH 1 0.96\nH 1 0.96 2 104.5\n\n")
            try expect(gjf.source == "gaussianInput" && gjf.molecule.atoms.count == 3, "\(gjf.molecule.atoms.count)")
            let dummy = try ZMatrixText.parse("X\nC 1 1.0\nH 2 1.07 1 90.0\n")
            try expect(dummy.dummyCount == 1 && dummy.molecule.atoms.count == 2)
            do { _ = try ZMatrixText.parse("   \n"); throw CheckFailure(description: "empty accepted") } catch is MolIOError {}
            do { _ = try ZMatrixText.parse("C\nC 7 1.5\n"); throw CheckFailure(description: "bad reference accepted") } catch is MolIOError {}
        },
        Check("io.zmatrix.tableEditsMoveTheSmallerSide") {
            // What the tab does for an edited cell: GeometryEdit.set*MovingSmaller on the row's atoms.
            let m = try ZMatrixText.parse(zmEthanol).molecule
            let t = try ZMatrixTable.make(m).orThrow("table")
            guard let r = t.rows.first(where: { $0.dihedralAtom != nil && m.atoms[$0.atom].atomicNumber == 1 && m.atoms[$0.bondAtom!].atomicNumber == 8 })
            else { throw CheckFailure(description: "no OH row") }
            var e = m
            GeometryEdit.setDihedralMovingSmaller(&e, r.dihedralAtom!, r.angleAtom!, r.bondAtom!, r.atom, to: 60)
            try expectClose(GeometryEdit.dihedral(e, r.atom, r.bondAtom!, r.angleAtom!, r.dihedralAtom!), 60, tol: 1e-6)
            let movedCount = zip(e.atoms, m.atoms).filter { VecMath.distance($0.position, $1.position) > 1e-6 }.count
            try expect(movedCount == 1, "only the hydroxyl H moves (\(movedCount))")
            var d = m
            GeometryEdit.setDistanceMovingSmaller(&d, r.bondAtom!, r.atom, to: 1.10)
            try expectClose(GeometryEdit.distance(d, r.atom, r.bondAtom!), 1.10, tol: 1e-9)
            try expect(zmRMSD(d, m) < 0.1)
        },
    ]
}

fileprivate extension Optional {
    func orThrow(_ what: String) throws -> Wrapped {
        guard let v = self else { throw CheckFailure(description: "missing \(what)") }
        return v
    }
}
