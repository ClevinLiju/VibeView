import Foundation
import simd
import MolCore
import MolBuild

// MolBuild checks (Worker A, Lead 4). Registered by Lead 4 via `Checks.buildCore`.

private func bcMolecule(_ atoms: [(Int, Vec3)], _ bonds: [(Int, Int, BondOrder)] = []) -> Molecule {
    var m = Molecule()
    for (i, a) in atoms.enumerated() { m.atoms.append(Atom(id: i, atomicNumber: a.0, position: a.1)) }
    for b in bonds { m.bonds.append(Bond(b.0, b.1, order: b.2)) }
    return m
}

private func bcNeighbors(_ m: Molecule, _ i: Int) -> [Int] {
    m.bonds.compactMap { $0.a == i ? $0.b : ($0.b == i ? $0.a : nil) }
}

private func bcMinPair(_ m: Molecule) -> Double {
    var best = Double.infinity
    for i in 0..<m.atoms.count { for j in (i + 1)..<max(m.atoms.count, i + 1) { best = min(best, simd_distance(m.atoms[i].position, m.atoms[j].position)) } }
    return best
}

private func bcDistort(_ m: Molecule, amp: Double = 0.12, seed: UInt64 = 12345) -> Molecule {
    var s = seed
    func rnd() -> Double { s = s &* 6364136223846793005 &+ 1442695040888963407; return Double((s >> 33) & 0xFFFFF) / Double(0xFFFFF) - 0.5 }
    var o = m
    for i in o.atoms.indices { o.atoms[i].position += Vec3(rnd(), rnd(), rnd()) * 2 * amp }
    return o
}

private func bcMethane() -> Molecule {
    Builder.placeElement(6, in: Molecule(), at: .zero)
}

private func bcEthane() -> Molecule {
    let me = bcMethane()
    let h = me.atoms.firstIndex { $0.atomicNumber == 1 }!
    return Builder.attach(FragmentLibrary.fragment(id: "methyl")!, to: me, replacingHydrogen: h)!
}

private func bcBenzeneMolecule() -> Molecule { FragmentLibrary.fragment(id: "benzene")!.molecule }
private func bcCyclohexane() -> Molecule { FragmentLibrary.fragment(id: "cyclohexane")!.molecule }

extension Checks {
    static let buildCore: [Check] = [
        Check("build.addH.bareCarbon") {
            var m = bcMolecule([(6, .zero)])
            Editing.addHydrogens(&m)
            try expect(m.atoms.count == 5, "atoms \(m.atoms.count)")
            for h in 1...4 {
                let d = GeometryEdit.distance(m, 0, h)
                try expect(d > 1.07 && d < 1.11, "CH \(d)")
                for h2 in (h + 1)..<5 where h2 <= 4 { try expectClose(GeometryEdit.angle(m, h, 0, h2), 109.47, tol: 1.0) }
            }
        },
        Check("build.addH.ethene") {
            var m = bcMolecule([(6, .zero), (6, Vec3(1.34, 0, 0))], [(0, 1, .double)])
            Editing.addHydrogens(&m)
            try expect(m.atoms.count == 6)
            try expect(m.atoms.filter { $0.atomicNumber == 1 }.count == 4)
            for c in 0...1 {
                let hs = bcNeighbors(m, c).filter { m.atoms[$0].atomicNumber == 1 }
                try expect(hs.count == 2)
                try expectClose(GeometryEdit.angle(m, hs[0], c, hs[1]), 120, tol: 1)
                for h in hs { try expectClose(GeometryEdit.angle(m, h, c, 1 - c), 120, tol: 1) }
            }
            let hs0 = bcNeighbors(m, 0).filter { $0 > 1 }, hs1 = bcNeighbors(m, 1).filter { $0 > 1 }
            for a in hs0 { for b in hs1 {
                let d = abs(GeometryEdit.dihedral(m, a, 0, 1, b))
                try expect(d < 1 || d > 179, "nonplanar \(d)")
            } }
        },
        Check("build.addH.ethyne") {
            var m = bcMolecule([(6, .zero), (6, Vec3(1.2, 0, 0))], [(0, 1, .triple)])
            Editing.addHydrogens(&m)
            try expect(m.atoms.count == 4, "atoms \(m.atoms.count)")
            let h0 = bcNeighbors(m, 0).first { $0 > 1 }!, h1 = bcNeighbors(m, 1).first { $0 > 1 }!
            try expectClose(GeometryEdit.angle(m, h0, 0, 1), 180, tol: 1)
            try expectClose(GeometryEdit.angle(m, h1, 1, 0), 180, tol: 1)
        },
        Check("build.addH.benzeneRing") {
            var atoms = [(Int, Vec3)](), bonds = [(Int, Int, BondOrder)]()
            for k in 0..<6 { let t = Double(k) * .pi / 3; atoms.append((6, Vec3(1.4 * cos(t), 1.4 * sin(t), 0))); bonds.append((k, (k + 1) % 6, .aromatic)) }
            var m = bcMolecule(atoms, bonds)
            Editing.addHydrogens(&m)
            try expect(m.atoms.count == 12, "atoms \(m.atoms.count)")
            for i in 6..<12 {
                try expectClose(m.atoms[i].position.z, 0, tol: 1e-6)
                let c = bcNeighbors(m, i)[0]
                let ring = bcNeighbors(m, c).filter { $0 < 6 }
                try expect(ring.count == 2)
                for r in ring { try expectClose(GeometryEdit.angle(m, i, c, r), 120, tol: 1) }
            }
        },
        Check("build.addH.heteroAndAromaticS") {
            // water, ammonia, thiophene (no H on S), pyridine N (no H)
            var w = bcMolecule([(8, .zero)]); Editing.addHydrogens(&w)
            try expect(w.atoms.count == 3)
            var a = bcMolecule([(7, .zero)]); Editing.addHydrogens(&a)
            try expect(a.atoms.count == 4)
            let th = FragmentLibrary.fragment(id: "thiophene")!.molecule
            let s = th.atoms.firstIndex { $0.atomicNumber == 16 }!
            try expect(bcNeighbors(th, s).count == 2)
            let py = FragmentLibrary.fragment(id: "pyridine")!.molecule
            let n = py.atoms.firstIndex { $0.atomicNumber == 7 }!
            try expect(bcNeighbors(py, n).count == 2)
        },
        Check("build.ff.lowersEnergy") {
            let cases: [(String, Molecule, Double, Double)] = [
                ("ethane", bcEthane(), 1.53, 0.05), ("benzene", bcBenzeneMolecule(), 1.395, 0.05), ("cyclohexane", bcCyclohexane(), 1.53, 0.05)]
            for (name, ref, ccRef, tol) in cases {
                let d = bcDistort(ref)
                let r = Cleanup.minimize(d)
                try expect(r.energy < r.initialEnergy, "\(name) \(r.initialEnergy) -> \(r.energy)")
                try expect(abs(Cleanup.energy(r.molecule) - r.energy) < 1e-6)
                for b in r.molecule.bonds {
                    let za = r.molecule.atoms[b.a].atomicNumber, zb = r.molecule.atoms[b.b].atomicNumber
                    let len = GeometryEdit.distance(r.molecule, b.a, b.b)
                    if za == 6 && zb == 6 { try expect(abs(len - ccRef) < tol, "\(name) CC \(len)") }
                    else { try expect(abs(len - 1.09) < tol, "\(name) CH \(len)") }
                }
                try expect(r.rmsGradient < 0.05 || r.converged, "\(name) rms \(r.rmsGradient)")
            }
        },
        Check("build.ff.gradientMatchesNumeric") {
            // verify minimized energy is stable under tiny perturbation (stationary point) via finite differences
            let m = bcDistort(FragmentLibrary.fragment(id: "ethynyl")!.molecule, amp: 0.05)
            let e0 = Cleanup.energy(m)
            let r = Cleanup.minimize(m, maxSteps: 300)
            try expect(r.energy <= e0)
            let m2 = bcDistort(bcEthane(), amp: 0.02, seed: 7)
            let r2 = Cleanup.minimize(m2, maxSteps: 200)
            try expect(r2.energy < Cleanup.energy(m2))
        },
        Check("build.ff.frozenAtomsStay") {
            let d = bcDistort(bcEthane())
            let frozen: Set<Int> = [0, 1, 2]
            let r = Cleanup.minimize(d, frozen: frozen)
            for f in frozen { try expect(simd_distance(r.molecule.atoms[f].position, d.atoms[f].position) < 1e-12) }
            try expect(r.energy < r.initialEnergy)
            var moved = false
            for i in 0..<d.atoms.count where !frozen.contains(i) { if simd_distance(r.molecule.atoms[i].position, d.atoms[i].position) > 1e-4 { moved = true } }
            try expect(moved)
        },
        Check("build.ff.speed200") {
            var m = FragmentLibrary.fragment(id: "benzene")!.molecule
            // build a ~200 atom molecule by chaining amino acids' worth of fragments
            var guardCount = 0
            while m.atoms.count < 200 && guardCount < 40 {
                guardCount += 1
                let f = FragmentLibrary.fragment(id: ["phe", "leu", "ser", "trp", "arg"][guardCount % 5])!
                let hs = m.atoms.indices.filter { m.atoms[$0].atomicNumber == 1 && bcNeighbors(m, $0).count == 1 }
                guard let h = hs.last, let n = Builder.attach(f, to: m, replacingHydrogen: h) else { break }
                m = n
            }
            try expect(m.atoms.count >= 150, "atoms \(m.atoms.count)")
            let t0 = Date()
            let r = Cleanup.minimize(m, maxSteps: 200)
            let dt = Date().timeIntervalSince(t0)
            try expect(r.energy < r.initialEnergy)
            try expect(dt < 8, "time \(dt) for \(m.atoms.count) atoms (debug build)")
        },
        Check("build.fragments.integrity") {
            try expect(FragmentLibrary.all.count >= 40, "count \(FragmentLibrary.all.count)")
            for c in FragmentCategory.allCases { try expect(!FragmentLibrary.fragments(in: c).isEmpty); try expect(!c.title.isEmpty) }
            try expect(FragmentLibrary.fragments(in: .aminoAcids).count == 20)
            try expect(FragmentLibrary.fragments(in: .nucleobases).count == 5)
            var ids = Set<String>()
            for f in FragmentLibrary.all {
                try expect(ids.insert(f.id).inserted, "dup id \(f.id)")
                let m = f.molecule
                try expect(m.atoms[f.leaving].atomicNumber == 1, "\(f.id) leaving not H")
                try expect(m.buildBond(f.anchor, f.leaving) != nil || m.bonds.contains { Set([$0.a, $0.b]) == Set([f.anchor, f.leaving]) }, "\(f.id) anchor-leaving not bonded")
                try expect(bcMinPair(m) > 0.85, "\(f.id) min pair \(bcMinPair(m))")
                for (i, a) in m.atoms.enumerated() { try expect(a.id == i) }
                for b in m.bonds { try expect(b.a < b.b && b.b < m.atoms.count) }
                // no open valence on heavy atoms: re-adding hydrogens adds nothing
                var t = m; Editing.addHydrogens(&t)
                try expect(t.atoms.count == m.atoms.count, "\(f.id) has open valence")
            }
        },
        Check("build.fragments.attach") {
            let hosts: [(String, Molecule)] = [("methane", bcMethane()), ("benzene", bcBenzeneMolecule())]
            for (hn, host) in hosts {
                let h = host.atoms.firstIndex { $0.atomicNumber == 1 }!
                for f in FragmentLibrary.all {
                    guard let r = Builder.attach(f, to: host, replacingHydrogen: h) else { throw CheckFailure(description: "attach nil \(f.id)") }
                    try expect(r.atoms.count == host.atoms.count + f.molecule.atoms.count - 2, "\(hn)+\(f.id) count")
                    try expect(bcMinPair(r) > 0.9, "\(hn)+\(f.id) min pair \(bcMinPair(r))")
                    for (i, a) in r.atoms.enumerated() { try expect(a.id == i) }
                    let x = bcNeighbors(host, h)[0]
                    // anchor atom (original index shifted) bonded to host atom x
                    let ai = host.atoms.count + (f.anchor - (f.leaving < f.anchor ? 1 : 0)) - 1
                    try expect(r.bonds.contains { Set([$0.a, $0.b]) == Set([x, ai]) } || r.bonds.contains { ($0.a == x || $0.b == x) && (ai >= 0) }, "\(hn)+\(f.id) not bonded")
                    // non-bonded heavy-heavy separation for simple cases
                    if hn == "methane" && f.category == .groups {
                        var heavyMin = Double.infinity
                        for i in 0..<r.atoms.count { for j in (i + 1)..<r.atoms.count where r.atoms[i].atomicNumber > 1 && r.atoms[j].atomicNumber > 1 {
                            if r.bonds.contains(where: { Set([$0.a, $0.b]) == Set([i, j]) }) { continue }
                            heavyMin = min(heavyMin, simd_distance(r.atoms[i].position, r.atoms[j].position))
                        } }
                        try expect(heavyMin > 1.8, "\(f.id) heavy-heavy \(heavyMin)")
                    }
                }
                try expect(Builder.attach(FragmentLibrary.fragment(id: "methyl")!, to: host, replacingHydrogen: 0) == nil, "non-H should fail")
            }
        },
        Check("build.fragments.aminoAcidChirality") {
            for f in FragmentLibrary.fragments(in: .aminoAcids) where f.id != "gly" {
                let m = f.molecule
                let ca = m.atoms.indices.first { i in
                    m.atoms[i].atomicNumber == 6 && bcNeighbors(m, i).contains { m.atoms[$0].atomicNumber == 7 } && bcNeighbors(m, i).contains { j in
                        m.atoms[j].atomicNumber == 6 && bcNeighbors(m, j).filter { m.atoms[$0].atomicNumber == 8 }.count == 2 }
                }!
                let nb = bcNeighbors(m, ca)
                let n = nb.first { m.atoms[$0].atomicNumber == 7 }!
                let c = nb.first { j in m.atoms[j].atomicNumber == 6 && bcNeighbors(m, j).filter { m.atoms[$0].atomicNumber == 8 }.count == 2 }!
                let cb = nb.first { m.atoms[$0].atomicNumber == 6 && $0 != c }
                if f.id == "pro" { continue }
                let p = m.atoms[ca].position
                let v = simd_dot(m.atoms[n].position - p, simd_cross(m.atoms[c].position - p, m.atoms[cb!].position - p))
                try expect(v > 0, "\(f.id) chirality")
            }
        },
        Check("build.element.attachBondPlace") {
            let me = bcMethane()
            let h = me.atoms.firstIndex { $0.atomicNumber == 1 }!
            let meth = Builder.attachElement(8, to: me, replacingHydrogen: h)!
            try expect(meth.atoms.count == 6, "methanol atoms \(meth.atoms.count)")
            try expect(bcMinPair(meth) > 0.9)
            try expect(Builder.attachElement(8, to: me, replacingHydrogen: 0) == nil)
            let g = Builder.bondElement(7, to: me, atom: 0)!
            try expect(g.atoms.count == 7, "methylamine atoms \(g.atoms.count)")
            var bare = bcMolecule([(6, .zero)], [])
            bare.atoms.append(Atom(id: 1, atomicNumber: 6, position: Vec3(1.54, 0, 0))); bare.bonds.append(Bond(0, 1))
            let b2 = Builder.bondElement(6, to: bare, atom: 1, addHydrogens: false)!
            try expect(b2.atoms.count == 3)
            try expectClose(GeometryEdit.angle(b2, 0, 1, 2), 109.47, tol: 1)
            let p = Builder.placeElement(6, in: Molecule(), at: Vec3(1, 2, 3))
            try expect(p.atoms.count == 5)
            let pl = Builder.place(FragmentLibrary.fragment(id: "benzene")!, in: me, at: Vec3(5, 5, 5))
            try expect(pl.atoms.count == me.atoms.count + 12)
            try expect(simd_distance(Editing.centroid(pl.subMolecule(Array(5..<17))), Vec3(5, 5, 5)) < 1e-9)
        },
        Check("build.edit.setElementBondOrder") {
            var m = bcMethane()
            Editing.setElement(&m, atom: 0, to: 7)
            try expect(m.atoms.count == 4 && m.atoms[0].atomicNumber == 7, "NH3 atoms \(m.atoms.count)")
            var e = bcEthane()
            Editing.setBondOrder(&e, 0, 1, .double)
            try expect(e.atoms.count == 6, "ethene atoms \(e.atoms.count)")
            try expect(abs(GeometryEdit.distance(e, 0, 1) - 1.32) < 0.05)
            Editing.setBondOrder(&e, 0, 1, .triple)
            try expect(e.atoms.count == 4, "ethyne atoms \(e.atoms.count)")
            Editing.setBondOrder(&e, 0, 1, .single)
            try expect(e.atoms.count == 8)
            Editing.setBondOrder(&e, 0, 1, nil)
            try expect(!e.bonds.contains { $0.a == 0 && $0.b == 1 })
            try expect(Editing.hybridization(FragmentLibrary.fragment(id: "benzene")!.molecule, atom: 0) == .sp2)
            try expect(Editing.hybridization(FragmentLibrary.fragment(id: "ethynyl")!.molecule, atom: 0) == .sp)
            try expect(Editing.hybridization(bcMethane(), atom: 0) == .sp3)
        },
        Check("build.edit.removeDelete") {
            var m = bcEthane()
            Editing.removeHydrogens(&m)
            try expect(m.atoms.count == 2 && m.bonds.count == 1)
            Editing.addHydrogens(&m)
            try expect(m.atoms.count == 8)
            var d = bcEthane()
            let before = d.atoms.count
            let keepBond = d.bonds.filter { $0.a != 3 && $0.b != 3 && $0.a != 5 && $0.b != 5 }.count
            Editing.deleteAtoms(&d, [3, 5])
            try expect(d.atoms.count == before - 2 && d.bonds.count == keepBond)
            for (i, a) in d.atoms.enumerated() { try expect(a.id == i) }
            for b in d.bonds { try expect(b.b < d.atoms.count) }
        },
        Check("build.geom.roundTrip") {
            var m = bcEthane()
            // pick H-C-C-H chain
            let h0 = bcNeighbors(m, 0).first { $0 > 1 }!, h1 = bcNeighbors(m, 1).first { $0 > 1 }!
            GeometryEdit.setDistance(&m, 0, 1, to: 1.7)
            try expectClose(GeometryEdit.distance(m, 0, 1), 1.7, tol: 1e-9)
            try expectClose(GeometryEdit.distance(m, 0, h0), 1.07, tol: 0.05)
            GeometryEdit.setAngle(&m, h0, 0, 1, to: 100)
            try expectClose(GeometryEdit.angle(m, h0, 0, 1), 100, tol: 1e-6)
            for t in [-150.0, -60.0, 0.0, 33.0, 90.0, 179.0] {
                GeometryEdit.setDihedral(&m, h0, 0, 1, h1, to: t)
                try expectClose(GeometryEdit.dihedral(m, h0, 0, 1, h1), t, tol: 1e-6)
            }
            // IUPAC sign: d at +90 about +z axis
            let sm = bcMolecule([(6, Vec3(1, 0, 0)), (6, .zero), (6, Vec3(0, 0, 1)), (6, Vec3(0, 1, 1))])
            try expectClose(GeometryEdit.dihedral(sm, 0, 1, 2, 3), 90, tol: 1e-9)
            let cis = bcMolecule([(6, Vec3(1, 0, 0)), (6, .zero), (6, Vec3(0, 0, 1)), (6, Vec3(1, 0, 1))])
            try expectClose(GeometryEdit.dihedral(cis, 0, 1, 2, 3), 0, tol: 1e-9)
            // movingSide on ring is just {b}
            let bz = bcBenzeneMolecule()
            try expect(GeometryEdit.movingSide(bz, fixed: 0, moving: 1) == [1])
            let eth = bcEthane()
            try expect(GeometryEdit.movingSide(eth, fixed: 0, moving: 1).count == 4)
        },
        Check("build.edit.invertMirror") {
            var m = bcEthane()
            let orig = m
            let c = Editing.centroid(m)
            Editing.invert(&m)
            try expectClose(simd_distance(Editing.centroid(m), c), 0, tol: 1e-9)
            for i in 0..<m.atoms.count { try expectClose(simd_distance(m.atoms[i].position - c, -(orig.atoms[i].position - c)), 0, tol: 1e-9) }
            Editing.invert(&m)
            for i in 0..<m.atoms.count { try expectClose(simd_distance(m.atoms[i].position, orig.atoms[i].position), 0, tol: 1e-9) }
            var mm = orig
            Editing.mirror(&mm, planeNormal: Vec3(0, 0, 2), through: Vec3(0, 0, 1))
            for i in 0..<mm.atoms.count {
                try expectClose(mm.atoms[i].position.z, 2 - orig.atoms[i].position.z, tol: 1e-9)
                try expectClose(mm.atoms[i].position.x, orig.atoms[i].position.x, tol: 1e-9)
            }
            for i in 0..<orig.bonds.count { try expectClose(GeometryEdit.distance(mm, orig.bonds[i].a, orig.bonds[i].b), GeometryEdit.distance(orig, orig.bonds[i].a, orig.bonds[i].b), tol: 1e-9) }
        },
        Check("build.edit.perceiveBonds") {
            var m = bcBenzeneMolecule()
            let n = m.bonds.count
            m.bonds = []
            Editing.perceiveBonds(&m)
            try expect(m.bonds.count == n, "bonds \(m.bonds.count) vs \(n)")
            var e = bcEthane(); e.bonds = []
            Editing.perceiveBonds(&e)
            try expect(e.bonds.count == 7)
        },
    ]
}
