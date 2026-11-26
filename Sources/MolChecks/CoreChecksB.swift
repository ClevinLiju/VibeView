import Foundation
import MolSIMD
import MolCore

// Core team checks, owned by Lead 1 Worker B. Names must start with "core.".

private func water() -> Molecule {
    var m = Molecule()
    m.addAtom(atomicNumber: 8, position: Vec3(0, 0, 0))
    m.addAtom(atomicNumber: 1, position: Vec3(0.96, 0, 0))
    let t = degToRad(104.5)
    m.addAtom(atomicNumber: 1, position: Vec3(0.96 * cos(t), 0.96 * sin(t), 0))
    m.addBond(0, 1); m.addBond(0, 2)
    return m
}

/// Butane-like chain 0-1-2-3 with substituents; atoms beyond bond 1-2 on each side.
private func chain(_ n: Int, seed: UInt64 = 1) -> Molecule {
    var s = seed
    func rnd() -> Double { s = s &* 6364136223846793005 &+ 1442695040888963407; return Double(s >> 33) / Double(1 << 31) }
    var m = Molecule()
    var p = Vec3.zero
    for i in 0..<n {
        m.addAtom(atomicNumber: i % 3 == 0 ? 6 : (i % 3 == 1 ? 7 : 8), position: p)
        if i > 0 { m.addBond(i - 1, i) }
        p += Vec3(rnd() - 0.5, rnd() - 0.5, rnd() - 0.5) * 3 + Vec3(1.2, 0, 0)
    }
    return m
}

private func expectT(_ f: () throws -> Bool, file: StaticString = #fileID, line: UInt = #line) throws {
    let ok = try f()
    try expect(ok, "expectT failed", file: file, line: line)
}

private func randomRotation(_ k: Int) -> simd_double3x3 {
    VecMath.rotationMatrix(axis: Vec3(Double(k) + 1, 2, -3), degrees: 37.0 + Double(k) * 11)
}

private func ethane() -> Molecule {
    var m = Molecule()
    let c1 = m.addAtom(atomicNumber: 6, position: Vec3(0, 0, 0))
    let c2 = m.addAtom(atomicNumber: 6, position: Vec3(0, 0, 1.54))
    m.addBond(c1, c2)
    for (c, zs, dir) in [(c1, -1.0, 0.0), (c2, 1.0, 60.0)] {
        for k in 0..<3 {
            let a = degToRad(Double(k) * 120 + dir)
            let h = m.addAtom(atomicNumber: 1, position: Vec3(1.03 * cos(a), 1.03 * sin(a), (c == c1 ? 0 : 1.54) + zs * 0.36))
            m.addBond(c, h)
        }
    }
    return m
}

private func benzene() -> Molecule {
    var m = Molecule()
    for k in 0..<6 {
        let a = degToRad(Double(k) * 60)
        m.addAtom(atomicNumber: 6, position: Vec3(1.39 * cos(a), 1.39 * sin(a), 0))
    }
    for k in 0..<6 {
        let a = degToRad(Double(k) * 60)
        m.addAtom(atomicNumber: 1, position: Vec3(2.47 * cos(a), 2.47 * sin(a), 0))
    }
    for k in 0..<6 { m.addBond(k, (k + 1) % 6, order: k % 2 == 0 ? .double : .single); m.addBond(k, k + 6) }
    return m
}

extension Checks {
    static let coreB: [Check] = [
        // MARK: geometry
        Check("core.geometry.centroid") {
            try expect(Geometry.centroid([]) == .zero)
            try expect(Geometry.centroid([Vec3(1, 2, 3)]) == Vec3(1, 2, 3))
            let c = Geometry.centroid([Vec3(0, 0, 0), Vec3(2, 4, 6)])
            try expectClose(c.x, 1); try expectClose(c.y, 2); try expectClose(c.z, 3)
            try expect(Molecule().centroid == .zero)
        },
        Check("core.geometry.centerOfMass") {
            let c = Geometry.centerOfMass([Vec3(0, 0, 0), Vec3(3, 0, 0)], masses: [1, 2])
            try expectClose(c.x, 2)
            // zero masses fall back to centroid
            let d = Geometry.centerOfMass([Vec3(0, 0, 0), Vec3(2, 0, 0)], masses: [0, 0])
            try expectClose(d.x, 1)
            let w = water()
            try expect(simd_length(w.centerOfMass - w.centroid) > 1e-3)
            var dm = Molecule()
            dm.addAtom(atomicNumber: 6, position: Vec3(0, 0, 0))
            dm.addAtom(atomicNumber: 0, position: Vec3(10, 0, 0))
            try expectClose(dm.centerOfMass.x, 0)
        },
        Check("core.geometry.inertia.diatomic") {
            // two unit masses at +-1 on x: Ixx=0, Iyy=Izz=2
            let I = Geometry.inertiaTensor([Vec3(1, 0, 0), Vec3(-1, 0, 0)], masses: [1, 1], about: .zero)
            try expectClose(I[0][0], 0); try expectClose(I[1][1], 2); try expectClose(I[2][2], 2)
            let r = Geometry.principalAxes([Vec3(0, 0, 1), Vec3(0, 0, -1)], masses: [1, 1])
            try expectClose(r.moments.x, 0); try expectClose(r.moments.y, 2); try expectClose(r.moments.z, 2)
            try expectClose(abs(r.axes.columns.0.z), 1)
            try expectClose(simd_determinant(r.axes), 1, tol: 1e-9)
            // HCl-like reduced mass: I = mu r^2
            var m = Molecule()
            m.addAtom(atomicNumber: 1, position: Vec3(0, 0, 0)); m.addAtom(atomicNumber: 17, position: Vec3(1.2746, 0, 0))
            let mu = 1.008 * 35.45 / (1.008 + 35.45)
            let pa = m.principalAxes()
            try expectClose(pa.moments.y, mu * 1.2746 * 1.2746, tol: 0.05)
        },
        Check("core.geometry.principalAxes.molecule") {
            let w = water()
            let pa = w.principalAxes()
            try expect(pa.moments.x <= pa.moments.y && pa.moments.y <= pa.moments.z)
            try expectClose(simd_determinant(pa.axes), 1, tol: 1e-9)
            let I = w.inertiaTensor()
            try expectClose(I[0][1], I[1][0])
            // empty / single atom
            let e = Molecule().principalAxes()
            try expect(e.moments == .zero)
            var s = Molecule(); s.addAtom(atomicNumber: 6, position: Vec3(1, 1, 1))
            try expect(s.principalAxes().moments == .zero)
        },
        Check("core.geometry.rmsd") {
            try expect(Geometry.rmsd([], []) == 0)
            try expectClose(Geometry.rmsd([Vec3(0, 0, 0)], [Vec3(3, 4, 0)]), 5)
            let w = water()
            try expectClose(w.rmsd(to: w), 0)
            try expectClose(w.translated(by: Vec3(1, 0, 0)).rmsd(to: w), 1)
        },
        Check("core.geometry.kabsch.knownRotation") {
            let m = chain(30)
            let R = VecMath.rotationMatrix(axis: Vec3(1, 2, 3), degrees: 77)
            let t = Vec3(5, -2, 1)
            let moved = m.transformed(rotation: R, translation: t)
            let k = Geometry.kabsch(moving: m.positions, target: moved.positions)
            try expect(k.rmsd < 1e-9, "rmsd \(k.rmsd)")
            for c in 0..<3 { for r in 0..<3 { try expectClose(k.rotation[c][r], R[c][r], tol: 1e-8) } }
            try expect(simd_length(k.translation - t) < 1e-8)
            try expect(m.alignedRMSD(to: moved) < 1e-9)
            try expect(m.aligned(onto: moved).rmsd(to: moved) < 1e-9)
        },
        Check("core.geometry.kabsch.reflection") {
            // mirror image must give a proper rotation (det +1) and a nonzero residual
            let m = chain(12)
            var mirror = m
            for i in mirror.atoms.indices { mirror.atoms[i].position.z *= -1 }
            let k = Geometry.kabsch(moving: m.positions, target: mirror.positions)
            try expectClose(simd_determinant(k.rotation), 1, tol: 1e-9)
            try expect(k.rmsd > 1e-3)
        },
        Check("core.geometry.kabsch.edge") {
            let k0 = Geometry.kabsch(moving: [], target: [])
            try expect(k0.rmsd == 0)
            let k1 = Geometry.kabsch(moving: [Vec3(1, 2, 3)], target: [Vec3(4, 5, 6)])
            try expect(k1.rmsd < 1e-9)
            // linear
            let lin = (0..<5).map { Vec3(0, 0, Double($0)) }
            let k2 = Geometry.kabsch(moving: lin, target: lin.map { Vec3($0.z, 0, 0) + Vec3(1, 1, 1) })
            try expect(k2.rmsd < 1e-9)
            // weights: heavy weight on first point pins it
            let a = [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(0, 1, 0)]
            let k3 = Geometry.kabsch(moving: a, target: a, weights: [1, 2, 3])
            try expect(k3.rmsd < 1e-9)
        },
        Check("core.geometry.kabsch.large") {
            let m = chain(1500, seed: 7)
            let R = randomRotation(3)
            let moved = m.transformed(rotation: R, translation: Vec3(1, 2, 3))
            try expect(m.alignedRMSD(to: moved) < 1e-8)
        },
        Check("core.geometry.transform") {
            var m = water()
            let orig = m
            m.translate(by: Vec3(1, 2, 3))
            try expect(simd_length(m.atoms[0].position - Vec3(1, 2, 3)) < 1e-12)
            let r = orig.transformed(rotation: VecMath.rotationMatrix(axis: Vec3(0, 0, 1), degrees: 90), translation: .zero)
            try expect(simd_length(r.atoms[1].position - Vec3(0, 0.96, 0)) < 1e-9)
            var e = Molecule(); e.translate(by: Vec3(1, 1, 1)); try expect(e.atoms.isEmpty)
            m.transform(rotation: matrix_identity_double3x3, translation: Vec3(-1, -2, -3))
            try expect(m.rmsd(to: orig) < 1e-12)
        },
        Check("core.geometry.boundingBox.rg") {
            let e = Molecule().boundingBox()
            try expect(e.min == .zero && e.max == .zero)
            let w = water()
            let bb = w.boundingBox()
            try expectClose(bb.min.x, 0.96 * cos(degToRad(104.5))); try expectClose(bb.max.x, 0.96)
            try expectClose(Molecule().radiusOfGyration, 0)
            var two = Molecule()
            two.addAtom(atomicNumber: 6, position: Vec3(1, 0, 0)); two.addAtom(atomicNumber: 6, position: Vec3(-1, 0, 0))
            try expectClose(two.radiusOfGyration, 1)
            try expect(w.radiusOfGyration > 0)
            var dum = Molecule(); dum.addAtom(atomicNumber: 0, position: Vec3(1, 0, 0)); dum.addAtom(atomicNumber: 0, position: Vec3(-1, 0, 0))
            try expectClose(dum.radiusOfGyration, 1)
        },

        // MARK: editing
        Check("core.edit.addRemoveAtoms") {
            var m = water()
            let i = m.addAtom(atomicNumber: 6, position: Vec3(5, 5, 5))
            try expect(i == 3 && m.atoms[3].id == 3)
            let map = m.removeAtoms([0])
            try expect(map == [nil, 0, 1, 2])
            try expect(m.atoms.count == 3 && m.bonds.isEmpty)
            try expect(m.atoms.enumerated().allSatisfy { $0.offset == $0.element.id })
            var w = water()
            w.removeAtom(1)
            try expect(w.atoms.count == 2 && w.bonds == [Bond(0, 1)])
            var a = water()
            let mp = a.removeAtoms(0..<3)
            try expect(a.atoms.isEmpty && a.bonds.isEmpty && mp == [nil, nil, nil])
            var b = water()
            b.removeAtoms([99, -1, 1, 1])
            try expect(b.atoms.count == 2)
            var e = Molecule()
            try expect(e.removeAtoms([0]).isEmpty)
        },
        Check("core.edit.bonds") {
            var m = water()
            try expect(!m.addBond(0, 1))
            try expect(!m.addBond(1, 1))
            try expect(!m.addBond(0, 9))
            try expect(m.addBond(1, 2, order: .double))
            try expect(m.bond(between: 2, and: 1)?.order == .double)
            try expect(m.removeBond(2, 1))
            try expect(!m.removeBond(2, 1))
            m.setBondOrder(0, 1, .triple)
            try expect(m.bond(between: 0, and: 1)?.order == .triple)
            m.setBondOrder(1, 2, .aromatic)
            try expect(m.bond(between: 1, and: 2)?.order == .aromatic)
            let n = m.bonds.count
            m.setBondOrder(1, 2, .single)
            try expect(m.bonds.count == n)
        },
        Check("core.edit.fragments") {
            var m = water()
            m.addAtom(atomicNumber: 6, position: Vec3(9, 0, 0))
            m.addAtom(atomicNumber: 6, position: Vec3(10, 0, 0))
            m.addBond(3, 4)
            let f = m.fragments()
            try expect(f == [[0, 1, 2], [3, 4]], "\(f)")
            try expect(m.fragment(containing: 4) == [3, 4])
            try expect(m.fragment(containing: 77).isEmpty)
            try expect(Molecule().fragments().isEmpty)
            let b = benzene()
            try expect(b.fragments().count == 1)
        },
        Check("core.edit.atomsOnSide") {
            let m = ethane()
            let s = m.atomsOnSide(of: 1, from: 0)
            try expect(s == [1, 5, 6, 7], "\(s)")
            let r = benzene().atomsOnSide(of: 1, from: 0)
            try expect(r.contains(0), "ring side must include i")
            try expect(m.atomsOnSide(of: 99, from: 0).isEmpty)
        },
        Check("core.edit.setDistance") {
            for mode in [MoveMode.second, .first, .both, .atomsOnly] {
                var m = ethane()
                let before = m
                m.setDistance(0, 1, to: 1.80, moving: mode)
                try expectClose(m.distance(0, 1), 1.80, tol: 1e-9)
                // internal geometry of side fragments is preserved
                if mode != .atomsOnly { try expectClose(m.distance(1, 5), before.distance(1, 5), tol: 1e-9) }
                try expectClose(m.distance(0, 2), before.distance(0, 2), tol: 1e-9)
            }
            var m = ethane()
            let h = m.atoms[5].position - m.atoms[1].position
            m.setDistance(0, 1, to: 2.0)
            try expect(simd_length((m.atoms[5].position - m.atoms[1].position) - h) < 1e-9)
            try expectClose(m.distance(0, 1), 2.0, tol: 1e-9)
        },
        Check("core.edit.setDistance.ring") {
            var m = benzene()
            let h = m.positions
            m.setDistance(0, 1, to: 1.6)
            try expectClose(m.distance(0, 1), 1.6, tol: 1e-9)
            // only atom 1 moved
            for i in 0..<12 where i != 1 { try expect(simd_length(m.atoms[i].position - h[i]) < 1e-12, "atom \(i) moved") }
            var u = ethane()
            u.setDistance(0, 5, to: 3.0)   // non-bonded, same fragment: only atom 5
            try expectClose(u.distance(0, 5), 3.0, tol: 1e-9)
            var two = water(); two.addAtom(atomicNumber: 6, position: Vec3(9, 0, 0))
            two.setDistance(0, 3, to: 4.0)
            try expectClose(two.distance(0, 3), 4.0, tol: 1e-9)
            try expectClose(two.distance(0, 1), 0.96, tol: 1e-12)
            var z = Molecule()
            z.addAtom(atomicNumber: 6, position: .zero); z.addAtom(atomicNumber: 6, position: .zero)
            z.setDistance(0, 1, to: 1.5)
            try expectClose(z.distance(0, 1), 1.5, tol: 1e-9)
        },
        Check("core.edit.setAngle") {
            for mode in [MoveMode.second, .first, .both, .atomsOnly] {
                var m = ethane()
                m.setAngle(0, 1, 5, to: 120.0, moving: mode)
                try expectClose(m.angle(0, 1, 5), 120.0, tol: 1e-6)
            }
            var w = water()
            w.setAngle(1, 0, 2, to: 90)
            try expectClose(w.angle(1, 0, 2), 90, tol: 1e-6)
            w.setAngle(1, 0, 2, to: 180)
            try expectClose(w.angle(1, 0, 2), 180, tol: 1e-6)
            // from collinear
            w.setAngle(1, 0, 2, to: 60)
            try expectClose(w.angle(1, 0, 2), 60, tol: 1e-6)
            try expectClose(w.distance(0, 2), 0.96, tol: 1e-9)
            var b = benzene()
            b.setAngle(0, 1, 2, to: 100)
            try expectClose(b.angle(0, 1, 2), 100, tol: 1e-6)
        },
        Check("core.edit.setDihedral") {
            for mode in [MoveMode.second, .first, .both, .atomsOnly] {
                for target in [-170.0, -60.0, 0.0, 45.0, 180.0] {
                    var m = ethane()
                    m.setDihedral(2, 0, 1, 5, to: target, moving: mode)
                    var d = m.dihedral(2, 0, 1, 5) - target
                    d = abs(d.truncatingRemainder(dividingBy: 360)); d = min(d, 360 - d)
                    try expect(d < 1e-6, "mode \(mode) target \(target) got \(m.dihedral(2, 0, 1, 5))")
                    try expectClose(m.distance(0, 1), 1.54, tol: 1e-9)
                }
            }
            var m = ethane()
            let before = m
            m.setDihedral(2, 0, 1, 5, to: 90)
            // whole far-side rigid: H5-H6 distance unchanged
            try expectClose(m.distance(5, 6), before.distance(5, 6), tol: 1e-9)
            var r = benzene()
            r.setDihedral(0, 1, 2, 3, to: 30)    // ring: only atom l moves
            try expect(abs(r.dihedral(0, 1, 2, 3) - 30) < 1e-6)
        },
        Check("core.edit.rotateTranslateAtoms") {
            var m = water()
            m.rotate(atoms: [1], about: .zero, axis: Vec3(0, 0, 1), degrees: 90)
            try expect(simd_length(m.atoms[1].position - Vec3(0, 0.96, 0)) < 1e-9)
            m.translate(atoms: Set([2]), by: Vec3(0, 0, 1))
            try expectClose(m.atoms[2].position.z, 1)
            m.translate(atoms: [50], by: Vec3(1, 1, 1))
            try expect(m.atoms.count == 3)
        },
        Check("core.edit.mergeSub") {
            var a = water()
            let b = ethane()
            let r = a.merge(b)
            try expect(r == 3..<11 && a.atoms.count == 11)
            try expect(a.atoms.enumerated().allSatisfy { $0.offset == $0.element.id })
            try expect(a.areBonded(3, 4) && a.fragments().count == 2)
            let s = a.subMolecule([4, 3, 5])
            try expect(s.atoms.count == 3 && s.bonds.count == 2, "\(s.bonds)")
            try expect(s.atoms[0].atomicNumber == 6)
            try expect(a.subMolecule([]).atoms.isEmpty)
            var e = Molecule(); try expect(e.merge(Molecule()) == 0..<0)
            try expect(a.subMolecule([3, 3, 99]).atoms.count == 1)
        },
        Check("core.edit.large") {
            var m = chain(2000)
            try expect(m.fragments().count == 1)
            let side = m.atomsOnSide(of: 1000, from: 999)
            try expect(side.count == 1000)
            m.setDihedral(998, 999, 1000, 1001, to: 33)
            try expectClose(m.dihedral(998, 999, 1000, 1001), 33, tol: 1e-6)
            let map = m.removeAtoms(0..<1000)
            try expect(map[1500] == 500 && m.atoms.count == 1000 && m.bonds.count == 999)
        },

        // MARK: zmatrix
        Check("core.zmatrix.water") {
            let zm = try ZMatrix.parse("O\nH 1 0.96\nH 1 0.96 2 104.5")
            let m = try zm.molecule()
            try expect(m.atoms.count == 3)
            try expectClose(m.angle(1, 0, 2), 104.5, tol: 1e-9)
            try expectClose(m.distance(0, 1), 0.96, tol: 1e-12)
            let c = try zm.cartesian()
            try expect(c[0] == .zero)
            try expectClose(c[1].x, 0, tol: 1e-12); try expectClose(c[1].z, 0.96)
            try expect(c[2].x > 0 && abs(c[2].y) < 1e-12)
        },
        Check("core.zmatrix.labelsAndSeparators") {
            let zm = try ZMatrix.parse("C1\nCl2, C1, 1.77\nH3(Fragment=1) 1 1.09 2 109.5\n6 1 1.5 2 100 3 120\nX 1 1.0 2 90 3 0\nBq 1 1.0 2 90 3 90")
            try expect(zm.rows.map(\.atomicNumber) == [6, 17, 1, 6, 0, 0])
            try expect(zm.rows[1].bondAtom == 0)
            let m = try zm.molecule()
            try expect(m.atoms.count == 4)
            try expectT { try zm.molecule(includeDummies: true).atoms.count == 6 }
            // label references and tabs
            let t = try ZMatrix.parse("O1\nH2\t1\t0.96\nH3 O1 0.96 H2 104.5")
            try expectClose(try t.molecule().angle(1, 0, 2), 104.5, tol: 1e-9)
        },
        Check("core.zmatrix.variables") {
            let txt = "O\nH 1 r\nH 1 r 2 -a\n\nVariables:\nr 0.96\na=-104.5\nConstants:\nq 3.0\n"
            let zm = try ZMatrix.parse(txt)
            try expectClose(zm.variables["r"]!, 0.96); try expectClose(zm.variables["a"]!, -104.5)
            try expectClose(zm.constants["q"]!, 3.0)
            try expectClose(try zm.molecule().angle(1, 0, 2), 104.5, tol: 1e-9)
            let nb = try ZMatrix.parse("O\nH 1 r\nH 1 r 2 a\n\nr=0.96\na 104.5")
            try expectClose(try nb.molecule().angle(1, 0, 2), 104.5, tol: 1e-9)
            let bad = try ZMatrix.parse("O\nH 1 rr")
            do { _ = try bad.cartesian(); try expect(false, "expected throw") } catch let e as ZMatrixError {
                try expect(e == .unknownVariable("rr"))
            }
            // constants used in rows
            let c = try ZMatrix.parse("O\nH 1 r\n\nConstants:\nr 1.1")
            try expectClose(try c.cartesian()[1].z, 1.1)
            try expectClose(try ZValue.variable("x", negated: true).resolve(["x": 2]), -2)
        },
        Check("core.zmatrix.errors") {
            func fails(_ s: String) -> Bool { (try? ZMatrix.parse(s)) == nil }
            try expect(fails(""))
            try expect(fails("Zz"))
            try expect(fails("O\nH 5 1.0"))
            try expect(fails("O\nH 1 1.0 2 3 4"))
            try expect(fails("O\nH 1 1.0\nH 1 1.0 1 100"))
            try expect(fails("O\nH 1 1.0\n\nVariables:\nr abc"))
            do { _ = try ZMatrix.parse("O\nH 3 1.0") } catch let e as ZMatrixError {
                if case .badReference(let row) = e { try expect(row == 1) } else { try expect(false, "\(e)") }
            }
            try expect(ZMatrixError.badReference(row: 0).description.contains("1"))
        },
        Check("core.zmatrix.cartesianRows") {
            let zm = try ZMatrix.parse("C 0 0.0 0.0 0.0\nO 0 0.0 0.0 1.2\nH 1.0 2.0 3.0")
            let c = try zm.cartesian()
            try expect(c[1] == Vec3(0, 0, 1.2) && c[2] == Vec3(1, 2, 3))
        },
        Check("core.zmatrix.dihedral.sign") {
            // placing with a positive dihedral must measure positive (IUPAC)
            let zm = try ZMatrix.parse("C\nC 1 1.5\nC 2 1.5 1 110\nC 3 1.5 2 110 1 60")
            let m = try zm.molecule()
            try expectClose(m.dihedral(3, 2, 1, 0), 60, tol: 1e-8)
            let neg = try ZMatrix.parse("C\nC 1 1.5\nC 2 1.5 1 110\nC 3 1.5 2 110 1 -120").molecule()
            try expectClose(neg.dihedral(3, 2, 1, 0), -120, tol: 1e-8)
            try expectClose(neg.angle(3, 2, 1), 110, tol: 1e-8)
            try expectClose(neg.distance(3, 2), 1.5, tol: 1e-12)
        },
        Check("core.zmatrix.alternateForm") {
            let zm = try ZMatrix.parse("C\nC 1 1.5\nC 2 1.5 1 110\nH 3 1.1 2 109.5 1 109.5 1\nH 3 1.1 2 109.5 1 109.5 -1")
            try expect(zm.rows[3].dihedralIsSecondAngle == 1 && zm.rows[4].dihedralIsSecondAngle == -1)
            let m = try zm.molecule()
            try expectClose(m.angle(3, 2, 1), 109.5, tol: 1e-8)
            try expectClose(m.angle(3, 2, 0), 109.5, tol: 1e-8)
            try expectClose(m.angle(4, 2, 1), 109.5, tol: 1e-8)
            try expectClose(m.angle(4, 2, 0), 109.5, tol: 1e-8)
            try expectClose(m.distance(3, 2), 1.1, tol: 1e-9)
            // opposite sides of the C-C-C plane
            try expect(simd_length(m.atoms[3].position - m.atoms[4].position) > 0.5)
            try expect(m.dihedral(3, 2, 1, 0) * m.dihedral(4, 2, 1, 0) < 0)
            let back = try ZMatrix.parse(zm.formatted(useVariables: false))
            try expect(back.rows[3].dihedralIsSecondAngle == 1)
            // impossible combination
            let bad = try ZMatrix.parse("C\nC 1 1.5\nC 2 1.5 1 110\nH 3 1.1 2 10 1 170 1")
            do { _ = try bad.cartesian(); try expect(false, "expected throw") } catch is ZMatrixError {}
        },
        Check("core.zmatrix.collinearReferences") {
            // acetylene-like linear chain, then an off-axis atom
            let zm = try ZMatrix.parse("C\nC 1 1.2\nC 2 1.4 1 180\nH 3 1.0 2 90 1 0")
            let c = try zm.cartesian()
            try expect(c.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
            let m = try zm.molecule()
            try expectClose(m.angle(3, 2, 1), 90, tol: 1e-8)
            try expectClose(m.distance(3, 2), 1.0, tol: 1e-9)
            // linear molecule round trip
            var lin = Molecule()
            for k in 0..<6 { lin.addAtom(atomicNumber: 6, position: Vec3(0.3, -0.2, Double(k) * 1.3)) }
            for k in 0..<5 { lin.addBond(k, k + 1) }
            let rt = try ZMatrix(molecule: lin).molecule()
            try expect(rt.alignedRMSD(to: lin) < 1e-6)
        },
        Check("core.zmatrix.roundTrip") {
            for (name, m) in [("ethane", ethane()), ("benzene", benzene()), ("chain50", chain(50, seed: 5)),
                              ("water", water())] {
                for useVars in [false, true] {
                    let zm = ZMatrix(molecule: m, useVariables: useVars)
                    let back = try zm.molecule(includeDummies: true)
                    try expect(back.atoms.count == m.atoms.count, name)
                    let r = back.alignedRMSD(to: m)
                    try expect(r < 1e-6, "\(name) vars=\(useVars) rmsd=\(r)")
                    try expect(back.atoms.map(\.atomicNumber) == m.atoms.map(\.atomicNumber), name)
                    // text round trip at 6 decimals
                    let txt = zm.formatted()
                    let r2 = try ZMatrix.parse(txt).molecule(includeDummies: true).alignedRMSD(to: m)
                    try expect(r2 < 1e-4, "\(name) text rmsd=\(r2)")
                }
            }
        },
        Check("core.zmatrix.roundTrip.chirality") {
            // chiral center must keep handedness (Kabsch is proper-rotation only)
            var m = Molecule()
            m.addAtom(atomicNumber: 6, position: .zero)
            m.addAtom(atomicNumber: 9, position: Vec3(1, 1, 1))
            m.addAtom(atomicNumber: 17, position: Vec3(-1, -1, 1))
            m.addAtom(atomicNumber: 35, position: Vec3(-1, 1, -1))
            m.addAtom(atomicNumber: 1, position: Vec3(1, -1, -1))
            for i in 1..<5 { m.addBond(0, i) }
            let back = try ZMatrix(molecule: m).molecule()
            try expect(back.alignedRMSD(to: m) < 1e-6)
        },
        Check("core.zmatrix.formatted") {
            let zm = ZMatrix(molecule: water(), useVariables: true)
            try expect(zm.variables["R2"] != nil && zm.variables["A3"] != nil)
            let t = zm.formatted()
            try expect(t.contains("\n\n"), t)
            try expect(t.contains("R2=") && t.contains("A3="), t)
            let n = zm.formatted(useVariables: false)
            try expect(!n.contains("R2") && !n.contains("="), n)
            let v = ZMatrix(molecule: water()).formatted(useVariables: true)
            try expect(v.contains("R2="), v)
            let first = t.split(separator: "\n").first.map(String.init)
            try expect(first == "O", "\(String(describing: first))")
        },
        Check("core.zmatrix.edge") {
            let e = ZMatrix(molecule: Molecule())
            try expect(e.rows.isEmpty && ((try? e.cartesian()) ?? [.zero]).isEmpty)
            var s = Molecule(); s.addAtom(atomicNumber: 6, position: Vec3(3, 3, 3))
            let z1 = ZMatrix(molecule: s)
            try expectT { try z1.cartesian() == [.zero] }
            // dummy atoms
            var d = water(); d.addAtom(atomicNumber: 0, position: Vec3(0, 2, 0))
            let zd = ZMatrix(molecule: d)
            try expect(zd.rows[3].atomicNumber == 0 && zd.rows[3].label == "X")
            try expectT { try zd.molecule().atoms.count == 3 }
            try expectT { try zd.molecule(includeDummies: true).alignedRMSD(to: d) < 1e-6 }
            // codable
            let data = try JSONEncoder().encode(zd)
            try expectT { try JSONDecoder().decode(ZMatrix.self, from: data) == zd }
            // perceiveBonds option
            let pb = try ZMatrix.parse("O\nH 1 0.96\nH 1 0.96 2 104.5").molecule(perceiveBonds: true)
            try expect(pb.bonds.count == 2)
        },
        Check("core.zmatrix.large") {
            let m = chain(1200, seed: 3)
            let zm = ZMatrix(molecule: m)
            try expect(zm.rows.count == 1200)
            try expectT { try zm.molecule().alignedRMSD(to: m) < 1e-4 }
        },
        Check("core.zmatrix.connectivityOrder") {
            func reordered(_ m: Molecule, _ order: [Int]) -> Molecule {
                var inv = [Int](repeating: -1, count: order.count)
                for (k, i) in order.enumerated() { inv[i] = k }
                var r = Molecule()
                for i in order { r.addAtom(atomicNumber: m.atoms[i].atomicNumber, position: m.atoms[i].position) }
                for b in m.bonds { r.addBond(inv[b.a], inv[b.b], order: b.order) }
                return r
            }
            // ethane with the hydrogens listed first: backbone rows come first, every bond reference is a bond
            let e = reordered(ethane(), [2, 3, 4, 5, 6, 7, 0, 1])
            let order = ZMatrix.connectivityOrder(e)
            try expect(order.sorted() == Array(0..<e.atoms.count), "\(order)")
            try expect(e.atoms[order[0]].atomicNumber == 6 && e.atoms[order[1]].atomicNumber == 6, "\(order)")
            let re = reordered(e, order)
            let zm = ZMatrix(molecule: re)
            for (r, row) in zm.rows.enumerated() where r > 0 {
                try expect(re.areBonded(r, row.bondAtom!), "row \(r) bond ref \(row.bondAtom!) not bonded")
            }
            try expectT { try zm.molecule().alignedRMSD(to: re) < 1e-6 }
            // benzene, a chain and disconnected fragments (water + free atom) keep every atom exactly once
            var frag = water()
            let w2 = water()
            for a in w2.atoms { frag.addAtom(atomicNumber: a.atomicNumber, position: a.position + Vec3(5, 0, 0)) }
            frag.addBond(3, 4); frag.addBond(3, 5)
            frag.addAtom(atomicNumber: 18, position: Vec3(0, 5, 0))
            for m in [benzene(), chain(80, seed: 9), frag] {
                let o = ZMatrix.connectivityOrder(m)
                try expect(o.sorted() == Array(0..<m.atoms.count))
                let rm = reordered(m, o)
                try expectT { try ZMatrix(molecule: rm).molecule().alignedRMSD(to: rm) < 1e-6 }
            }
            try expect(ZMatrix.connectivityOrder(Molecule()).isEmpty)
            var h2 = Molecule(); h2.addAtom(atomicNumber: 1, position: .zero); h2.addAtom(atomicNumber: 1, position: Vec3(0, 0, 0.74)); h2.addBond(0, 1)
            try expect(ZMatrix.connectivityOrder(h2) == [0, 1])
        },
    ]
}
