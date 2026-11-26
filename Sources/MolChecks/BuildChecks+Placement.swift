import Foundation
import MolSIMD
import MolCore
import MolBuild

// Round 3 (Lead C): click-to-build replace semantics, bond tool, smaller-side geometry edits.

private func pcMethane() -> Molecule { Builder.placeElement(6, in: Molecule(), at: .zero) }
private func pcEthane() -> Molecule {
    let m = pcMethane()
    let h = m.atoms.firstIndex { $0.atomicNumber == 1 }!
    return try! Builder.click(.element(6), on: .atom(h), in: m)
}
private func pcBenzene() -> Molecule { FragmentLibrary.fragment(id: "benzene")!.molecule }
private func pcMinPair(_ m: Molecule) -> Double {
    var best = Double.infinity
    for i in m.atoms.indices { for j in m.atoms.indices where j > i { best = min(best, simd_distance(m.atoms[i].position, m.atoms[j].position)) } }
    return best
}
private func pcFragments(_ m: Molecule) -> Int {
    var seen = Set<Int>(); var n = 0
    for i in m.atoms.indices where !seen.contains(i) { n += 1; seen.formUnion(Editing.fragmentAtoms(m, i)) }
    return n
}

extension Checks {
    static let buildPlacement: [Check] = [
        Check("build.place.benzeneCarbonToNitrogenElement") {
            let b = pcBenzene()
            let c = b.atoms.firstIndex { $0.atomicNumber == 6 }!
            let r = try Builder.click(.element(7), on: .atom(c), in: b)
            try expect(r.formula == "C5H5N", "got \(r.formula)")
            let n = r.atoms.firstIndex { $0.atomicNumber == 7 }!
            try expect(r.buildNeighbors(of: n).count == 2, "pyridine N should have 2 ring neighbours")
            try expect(simd_distance(r.atoms[n].position, b.atoms[c].position) < 1e-9, "N keeps the carbon's position")
        },
        Check("build.place.benzeneAminoFragmentReplacesRingCarbon") {
            let b = pcBenzene()
            let c = b.atoms.firstIndex { $0.atomicNumber == 6 }!
            let r = try Builder.click(.fragment("amino"), on: .atom(c), in: b)
            try expect(r.formula == "C5H5N", "got \(r.formula) (must be pyridine, not aniline)")
            let n = r.atoms.firstIndex { $0.atomicNumber == 7 }!
            try expect(r.buildNeighbors(of: n).allSatisfy { r.atoms[$0].atomicNumber == 6 }, "N has no H")
        },
        Check("build.place.benzeneAminoOnHydrogenGivesAniline") {
            let b = pcBenzene()
            let h = b.atoms.firstIndex { $0.atomicNumber == 1 }!
            let r = try Builder.click(.fragment("amino"), on: .atom(h), in: b)
            try expect(r.formula == "C6H7N", "got \(r.formula)")
        },
        Check("build.place.methaneHydroxylOnCarbonGivesWater") {
            let m = pcMethane()
            let r = try Builder.click(.fragment("hydroxyl"), on: .atom(0), in: m)
            try expect(r.formula == "H2O", "got \(r.formula)")
            let h = m.atoms.firstIndex { $0.atomicNumber == 1 }!
            let r2 = try Builder.click(.fragment("hydroxyl"), on: .atom(h), in: m)
            try expect(r2.formula == "CH4O", "on H: got \(r2.formula)")
        },
        Check("build.place.ethanePhenylOnCarbonGivesToluene") {
            let e = pcEthane()
            let r = try Builder.click(.fragment("phenyl"), on: .atom(0), in: e)
            try expect(r.formula == "C7H8", "got \(r.formula)")
            try expect(pcMinPair(r) > 0.9, "clash \(pcMinPair(r))")
            try expect(pcFragments(r) == 1)
        },
        Check("build.place.refusesValenceOverflow") {
            let b = pcBenzene()
            let c = b.atoms.firstIndex { $0.atomicNumber == 6 }!
            do { _ = try Builder.click(.element(8), on: .atom(c), in: b); try expect(false, "O in benzene accepted") }
            catch let e as BuildError { if case .valenceExceeded = e {} else { try expect(false, "\(e)") } }
            do { _ = try Builder.click(.fragment("phenyl"), on: .atom(c), in: b); try expect(false, "ring on aromatic C accepted") }
            catch is BuildError {}
        },
        Check("build.place.emptyAndSameElement") {
            let r = try Builder.click(.fragment("benzene"), on: .empty(Vec3(1, 2, 3)), in: Molecule())
            try expect(r.formula == "C6H6")
            let m = pcMethane()
            try expect(try Builder.click(.element(6), on: .atom(0), in: m) == m, "same element is a no-op")
            let ch3n = try Builder.click(.element(7), on: .atom(0), in: pcEthane())
            try expect(ch3n.formula == "CH5N", "ethane C→N gives methylamine, got \(ch3n.formula)")
        },
        Check("build.bond.connectSeparateFragments") {
            var two = pcMethane()
            var other = pcMethane()
            for i in other.atoms.indices { other.atoms[i].position += Vec3(6, 0, 0) }
            two.buildAppend(other)
            try expect(pcFragments(two) == 2)
            let r = try Editing.connect(two, 0, 5, order: .single)
            try expect(r.formula == "C2H6", "got \(r.formula)")
            try expect(pcFragments(r) == 1)
            let cs = r.atoms.indices.filter { r.atoms[$0].atomicNumber == 6 }
            try expectClose(simd_distance(r.atoms[cs[0]].position, r.atoms[cs[1]].position), 1.54, tol: 0.06)
            try expect(pcMinPair(r) > 0.9)
            let ene = try Editing.connect(r, cs[0], cs[1], order: .double)
            try expect(ene.formula == "C2H4", "double: \(ene.formula)")
            let back = try Editing.disconnect(r, cs[0], cs[1])
            try expect(back.formula == "C2H8" && pcFragments(back) == 2, "disconnect: \(back.formula)")
        },
        Check("build.bond.refusals") {
            let e = pcEthane()
            let h = e.atoms.firstIndex { $0.atomicNumber == 1 }!
            do { _ = try Editing.connect(e, h, 1); try expect(false, "bonded H accepted") } catch let x as BuildError { try expect(x == .hydrogenAlreadyBonded || x == .alreadyBonded, "\(x)") }
            do { _ = try Editing.connect(e, 0, 0); try expect(false) } catch let x as BuildError { try expect(x == .sameAtom) }
            // A fifth bond on carbon in neopentane-like centre is refused: C with 4 heavy neighbours.
            var m = Builder.placeElement(6, in: Molecule(), at: .zero)
            for h in m.atoms.indices.filter({ m.atoms[$0].atomicNumber == 1 }).reversed() {
                m = try Builder.click(.element(6), on: .atom(h), in: m)
            }
            let extra = m.buildAddAtom(6, at: Vec3(4, 4, 4))
            do { _ = try Editing.connect(m, 0, extra); try expect(false, "5-valent C accepted") } catch let x as BuildError { if case .valenceExceeded = x {} else { try expect(false, "\(x)") } }
        },
        Check("build.geom.editMovesSmallerSide") {
            let tol = try Builder.click(.fragment("phenyl"), on: .atom(0), in: pcEthane())
            let ring = tol.atoms.indices.filter { Editing.hybridization(tol, atom: $0) == .sp2 }
            let ipso = ring.first { i in tol.buildNeighbors(of: i).contains { tol.atoms[$0].atomicNumber == 6 && !ring.contains($0) } }!
            let methyl = tol.buildNeighbors(of: ipso).first { !ring.contains($0) && tol.atoms[$0].atomicNumber == 6 }!
            var m = tol
            GeometryEdit.setDistanceMovingSmaller(&m, ipso, methyl, to: 1.60)
            try expectClose(GeometryEdit.distance(m, ipso, methyl), 1.60, tol: 1e-6)
            for i in ring { try expect(simd_distance(m.atoms[i].position, tol.atoms[i].position) < 1e-9, "ring moved") }
            var m2 = tol
            GeometryEdit.setDistanceMovingSmaller(&m2, methyl, ipso, to: 1.60)   // argument order doesn't matter
            for i in ring { try expect(simd_distance(m2.atoms[i].position, tol.atoms[i].position) < 1e-9, "ring moved (reversed)") }
            let hm = tol.buildNeighbors(of: methyl).first { tol.atoms[$0].atomicNumber == 1 }!
            let o = ring.first { tol.buildBond($0, ipso) != nil }!
            var m3 = tol
            GeometryEdit.setAngleMovingSmaller(&m3, o, ipso, methyl, to: 115)
            try expectClose(GeometryEdit.angle(m3, o, ipso, methyl), 115, tol: 1e-4)
            GeometryEdit.setDihedralMovingSmaller(&m3, o, ipso, methyl, hm, to: 30)
            try expectClose(GeometryEdit.dihedral(m3, o, ipso, methyl, hm), 30, tol: 1e-4)
            try expect(simd_distance(m3.atoms[o].position, tol.atoms[o].position) < 1e-9, "ring atom moved by angle/dihedral edit")
        },
    ]
}
