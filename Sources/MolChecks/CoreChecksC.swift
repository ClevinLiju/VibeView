import Foundation
import simd
import MolCore

// Core team checks, owned by Lead 1 Worker C. Names must start with "core.".

private func mol(_ atoms: [(Int, Vec3)], _ bonds: [(Int, Int)] = []) -> Molecule {
    var m = Molecule()
    for (i, a) in atoms.enumerated() { m.atoms.append(Atom(id: i, atomicNumber: a.0, position: a.1)) }
    m.bonds = bonds.map { Bond($0.0, $0.1) }
    return m
}
private func ang(_ r: Double, _ deg: Double, _ z: Double) -> Vec3 {
    Vec3(r * cos(degToRad(deg)), r * sin(degToRad(deg)), z)
}
private func group(_ m: Molecule, tol: Double = 0.1) -> String { Symmetry.detect(m, tolerance: tol).schoenflies }

private let water = mol([(8, Vec3(0, 0, 0.117)), (1, Vec3(0, 0.757, -0.469)), (1, Vec3(0, -0.757, -0.469))], [(0, 1), (0, 2)])
private let ammonia = mol([(7, Vec3(0, 0, 0.1)), (1, ang(0.94, 0, -0.3)), (1, ang(0.94, 120, -0.3)), (1, ang(0.94, 240, -0.3))], [(0, 1), (0, 2), (0, 3)])
private let methane: Molecule = {
    let s = 0.629
    return mol([(6, .zero), (1, Vec3(s, s, s)), (1, Vec3(s, -s, -s)), (1, Vec3(-s, s, -s)), (1, Vec3(-s, -s, s))],
               [(0, 1), (0, 2), (0, 3), (0, 4)])
}()
private func ethane(staggered: Bool) -> Molecule {
    var a: [(Int, Vec3)] = [(6, Vec3(0, 0, 0.765)), (6, Vec3(0, 0, -0.765))]
    for k in 0..<3 { a.append((1, ang(1.02, Double(k) * 120, 1.13))) }
    for k in 0..<3 { a.append((1, ang(1.02, Double(k) * 120 + (staggered ? 60 : 0), -1.13))) }
    return mol(a, [(0, 1), (0, 2), (0, 3), (0, 4), (1, 5), (1, 6), (1, 7)])
}
private let benzene: Molecule = {
    var a: [(Int, Vec3)] = []
    for k in 0..<6 { a.append((6, ang(1.39, Double(k) * 60, 0))) }
    for k in 0..<6 { a.append((1, ang(2.48, Double(k) * 60, 0))) }
    var b: [(Int, Int)] = []
    for k in 0..<6 { b.append((k, (k + 1) % 6)); b.append((k, 6 + k)) }
    return mol(a, b)
}()
private let sf6 = mol([(16, .zero), (9, Vec3(1.56, 0, 0)), (9, Vec3(-1.56, 0, 0)), (9, Vec3(0, 1.56, 0)),
                       (9, Vec3(0, -1.56, 0)), (9, Vec3(0, 0, 1.56)), (9, Vec3(0, 0, -1.56))])
private let c60: Molecule = {
    let phi = (1 + 5.0.squareRoot()) / 2
    var pts: [Vec3] = []
    func addAll(_ b: [Double]) {
        for sx in [1.0, -1.0] { for sy in [1.0, -1.0] { for sz in [1.0, -1.0] {
            let v = [b[0] * sx, b[1] * sy, b[2] * sz]
            for r in 0..<3 {
                let p = Vec3(v[r % 3], v[(r + 1) % 3], v[(r + 2) % 3]) * 0.7
                if !pts.contains(where: { simd_length($0 - p) < 1e-6 }) { pts.append(p) }
            }
        } } }
    }
    addAll([0, 1, 3 * phi]); addAll([1, 2 + phi, 2 * phi]); addAll([phi, 2, phi * phi * phi])
    return mol(pts.map { (6, $0) })
}()
private let co2 = mol([(6, .zero), (8, Vec3(0, 0, 1.16)), (8, Vec3(0, 0, -1.16))], [(0, 1), (0, 2)])
private let hcn = mol([(6, .zero), (1, Vec3(0, 0, -1.06)), (7, Vec3(0, 0, 1.15))], [(0, 1), (0, 2)])
private let h2o2 = mol([(8, Vec3(0.73, 0, 0)), (8, Vec3(-0.73, 0, 0)), (1, Vec3(0.9, 0.5, 0.75)), (1, Vec3(-0.9, -0.5, 0.75))],
                       [(0, 1), (0, 2), (1, 3)])
private let chfclbr = mol([(6, .zero), (1, Vec3(0.63, 0.63, 0.63)), (9, Vec3(1.0, -1.0, -0.9)),
                          (17, Vec3(-1.4, 1.2, -1.2)), (35, Vec3(-1.2, -1.6, 1.5))], [(0, 1), (0, 2), (0, 3), (0, 4)])
private let bf3 = mol([(5, .zero), (9, ang(1.31, 0, 0)), (9, ang(1.31, 120, 0)), (9, ang(1.31, 240, 0))])
private let allene = mol([(6, .zero), (6, Vec3(0, 0, 1.31)), (6, Vec3(0, 0, -1.31)),
                          (1, Vec3(0.93, 0, 1.87)), (1, Vec3(-0.93, 0, 1.87)),
                          (1, Vec3(0, 0.93, -1.87)), (1, Vec3(0, -0.93, -1.87))])
private let transDFE = mol([(6, Vec3(0.67, 0, 0)), (6, Vec3(-0.67, 0, 0)), (9, Vec3(1.35, 1.1, 0)), (1, Vec3(1.2, -0.95, 0)),
                            (9, Vec3(-1.35, -1.1, 0)), (1, Vec3(-1.2, 0.95, 0))])
private let ethylene = mol([(6, Vec3(0.667, 0, 0)), (6, Vec3(-0.667, 0, 0)), (1, Vec3(1.23, 0.92, 0)), (1, Vec3(1.23, -0.92, 0)),
                            (1, Vec3(-1.23, 0.92, 0)), (1, Vec3(-1.23, -0.92, 0))], [(0, 1), (0, 2), (0, 3), (1, 4), (1, 5)])

private func maxDiff(_ a: Molecule, _ b: Molecule) -> Double {
    zip(a.atoms, b.atoms).map { simd_length($0.position - $1.position) }.max() ?? 0
}
private func jitter(_ m: Molecule, _ amp: Double) -> Molecule {
    var o = m
    var seed: UInt64 = 12345
    func rnd() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 33) / Double(1 << 31) - 0.5 }
    for i in o.atoms.indices { o.atoms[i].position += Vec3(rnd(), rnd(), rnd()) * (2 * amp) }
    return o
}
private func orderCount(_ m: Molecule, _ o: BondOrder) -> Int { m.bonds.filter { $0.order == o }.count }

private let pyridine: Molecule = {
    var a: [(Int, Vec3)] = [(7, ang(1.34, 0, 0))]
    for k in 1..<6 { a.append((6, ang(1.39, Double(k) * 60, 0))) }
    for k in 1..<6 { a.append((1, ang(2.48, Double(k) * 60, 0))) }
    var b: [(Int, Int)] = []
    for k in 0..<6 { b.append((k, (k + 1) % 6)) }
    for k in 1..<6 { b.append((k, 5 + k)) }
    return mol(a, b)
}()
private let pyrrole: Molecule = {
    var a: [(Int, Vec3)] = [(7, ang(1.17, 90, 0))]
    for k in 1..<5 { a.append((6, ang(1.17, 90 + Double(k) * 72, 0))) }
    for k in 0..<5 { a.append((1, ang(2.15, 90 + Double(k) * 72, 0))) }
    var b: [(Int, Int)] = []
    for k in 0..<5 { b.append((k, (k + 1) % 5)); b.append((k, 5 + k)) }
    return mol(a, b)
}()
private let naphthalene: Molecule = {
    let h = 3.0.squareRoot() / 2 * 1.4
    let c: [Vec3] = [Vec3(0, 0.7, 0), Vec3(0, -0.7, 0),
                     Vec3(h, 1.4, 0), Vec3(2 * h, 0.7, 0), Vec3(2 * h, -0.7, 0), Vec3(h, -1.4, 0),
                     Vec3(-h, 1.4, 0), Vec3(-2 * h, 0.7, 0), Vec3(-2 * h, -0.7, 0), Vec3(-h, -1.4, 0)]
    var a: [(Int, Vec3)] = c.map { (6, $0) }
    for i in 2..<10 { a.append((1, c[i] + simd_normalize(c[i]) * 1.08)) }
    let ring: [(Int, Int)] = [(0, 2), (2, 3), (3, 4), (4, 5), (5, 1), (0, 1), (0, 6), (6, 7), (7, 8), (8, 9), (9, 1)]
    var b = ring
    for i in 2..<10 { b.append((i, 8 + i)) }
    return mol(a, b)
}()

extension Checks {
    static let coreC: [Check] = [
        // MARK: symmetry
        Check("core.symmetry.water.C2v") {
            let r = Symmetry.detect(water)
            try expect(r.schoenflies == "C2v", r.schoenflies); try expect(r.order == 4)
            try expect(r.principalAxis != nil && abs(r.principalAxis!.z) > 0.99)
            try expectClose(r.tolerance, 0.1)
        },
        Check("core.symmetry.ammonia.C3v") { try expect(group(ammonia) == "C3v", group(ammonia)) },
        Check("core.symmetry.methane.Td") {
            let r = Symmetry.detect(methane); try expect(r.schoenflies == "Td", r.schoenflies); try expect(r.order == 24)
        },
        Check("core.symmetry.ethane.D3d") { let g = group(ethane(staggered: true)); try expect(g == "D3d", g) },
        Check("core.symmetry.ethane.D3h") { let g = group(ethane(staggered: false)); try expect(g == "D3h", g) },
        Check("core.symmetry.benzene.D6h") {
            let r = Symmetry.detect(benzene); try expect(r.schoenflies == "D6h", r.schoenflies); try expect(r.order == 24)
        },
        Check("core.symmetry.sf6.Oh") { let g = group(sf6); try expect(g == "Oh", g) },
        Check("core.symmetry.c60.Ih") {
            try expect(c60.atoms.count == 60, "\(c60.atoms.count)")
            let r = Symmetry.detect(c60); try expect(r.schoenflies == "Ih", r.schoenflies); try expect(r.order == 120)
        },
        Check("core.symmetry.co2.Dinfh") {
            let r = Symmetry.detect(co2); try expect(r.schoenflies == "D*h", r.schoenflies); try expect(r.order == 0)
        },
        Check("core.symmetry.hcn.Cinfv") { try expect(group(hcn) == "C*v") },
        Check("core.symmetry.h2o2.C2") { let g = group(h2o2); try expect(g == "C2", g) },
        Check("core.symmetry.chfclbr.C1") {
            let r = Symmetry.detect(chfclbr); try expect(r.schoenflies == "C1"); try expect(r.order == 1)
        },
        Check("core.symmetry.bf3.D3h") { let g = group(bf3); try expect(g == "D3h", g) },
        Check("core.symmetry.allene.D2d") { let g = group(allene); try expect(g == "D2d", g) },
        Check("core.symmetry.transDifluoroethylene.C2h") { let g = group(transDFE); try expect(g == "C2h", g) },
        Check("core.symmetry.ethylene.D2h") { let g = group(ethylene); try expect(g == "D2h", g) },
        Check("core.symmetry.detect.edgeCases") {
            try expect(group(Molecule()) == "C1")
            let one = mol([(6, Vec3(3, 4, 5))])
            try expect(group(one) == "Kh")
            try expect(Symmetry.detect(one).order == 0)
            try expect(group(mol([(1, .zero), (1, Vec3(0, 0, 0.74))])) == "D*h")
            try expect(group(mol([(1, .zero), (9, Vec3(0, 0.9, 0))])) == "C*v")
            try expect(group(mol([(6, Vec3(1, 1, 1)), (6, Vec3(2, 2, 2)), (8, Vec3(3, 3, 3))])) == "C*v")
            // translated / rotated copies keep the group
            var t = benzene
            for i in t.atoms.indices { t.atoms[i].position = VecMath.rotate(t.atoms[i].position, about: .zero, axis: Vec3(1, 2, 3), degrees: 37) + Vec3(10, -4, 2) }
            try expect(group(t) == "D6h", group(t))
            // planar Cs, Ci
            try expect(group(mol([(6, .zero), (9, Vec3(1, 0, 0)), (17, Vec3(0, 1.5, 0)), (1, Vec3(-0.7, -0.7, 0))])) == "Cs")
            let ci = mol([(6, Vec3(0.7, 0.1, 0.2)), (6, Vec3(-0.7, -0.1, -0.2)), (9, Vec3(1.5, 1.1, 0.4)), (9, Vec3(-1.5, -1.1, -0.4)),
                          (17, Vec3(1.1, -1.2, 0.9)), (17, Vec3(-1.1, 1.2, -0.9))])
            try expect(group(ci) == "Ci", group(ci))
        },
        Check("core.symmetry.detect.tolerance") {
            let noisy = jitter(water, 0.02)
            try expect(group(noisy, tol: 0.1) == "C2v")
            try expect(group(noisy, tol: 1e-6) == "Cs", "planar triatomic keeps the molecular plane: \(group(noisy, tol: 1e-6))")
            try expect(group(jitter(methane, 0.02), tol: 1e-6) == "C1" && group(jitter(methane, 0.02)) == "Td")
            try expect(group(jitter(benzene, 0.01)) == "D6h")
        },
        Check("core.symmetry.detect.large") {
            var a: [(Int, Vec3)] = []
            var seed: UInt64 = 99
            func rnd() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 33) / Double(1 << 31) }
            for i in 0..<1500 { a.append((i % 3 == 0 ? 6 : 1, Vec3(rnd() * 30, rnd() * 30, rnd() * 30))) }
            let big = mol(a)
            let t0 = Date()
            let r = Symmetry.detect(big)
            try expect(r.schoenflies == "C1", r.schoenflies)
            try expect(Date().timeIntervalSince(t0) < 20, "too slow: \(Date().timeIntervalSince(t0))")
            var huge = mol(Array(repeating: (6, Vec3(1, 2, 3)), count: 2500))
            huge.atoms[0].position = .zero
            try expect(Symmetry.detect(huge).schoenflies == "C1")
        },
        Check("core.symmetry.apply") {
            let p = Vec3(1, 2, 3)
            try expect(Symmetry.apply(.identity, to: p) == p)
            try expect(Symmetry.apply(.inversion, to: p) == -p)
            let r = Symmetry.apply(.rotation(axis: Vec3(0, 0, 1), order: 4), to: Vec3(1, 0, 5))
            try expectClose(r.x, 0); try expectClose(r.y, 1); try expectClose(r.z, 5)
            let m = Symmetry.apply(.reflection(normal: Vec3(0, 0, 2)), to: p)
            try expectClose(m.z, -3); try expectClose(m.x, 1)
            let s = Symmetry.apply(.improperRotation(axis: Vec3(0, 0, 1), order: 4), to: Vec3(1, 0, 5))
            try expectClose(s.x, 0); try expectClose(s.y, 1); try expectClose(s.z, -5)
            try expect(Symmetry.apply(.rotation(axis: Vec3(0, 0, 1), order: 0), to: p) == p)
            // elements of water map the molecule onto itself
            let r2 = Symmetry.detect(water)
            for e in r2.elements {
                for a in water.atoms {
                    let q = Symmetry.apply(e, to: a.position - Vec3(0, 0, 0.0))
                    _ = q
                }
            }
            try expect(r2.elements.contains(.identity))
            try expect(r2.elements.filter { if case .reflection = $0 { return true }; return false }.count == 2)
        },
        Check("core.symmetry.symmetrize.exact") {
            for (name, m, expected) in [("water", water, "C2v"), ("ammonia", ammonia, "C3v"), ("methane", methane, "Td"),
                                        ("benzene", benzene, "D6h"), ("ethane", ethane(staggered: true), "D3d"), ("bf3", bf3, "D3h")] {
                let s = Symmetry.symmetrize(jitter(m, 0.02))
                try expect(group(s, tol: 1e-5) == expected, "\(name): \(group(s, tol: 1e-5))")
                try expect(s.atoms.count == m.atoms.count && s.bonds == m.bonds)
                try expect(maxDiff(s, m) < 0.2, "\(name) moved \(maxDiff(s, m))")
            }
            let again = Symmetry.symmetrize(Symmetry.symmetrize(jitter(water, 0.02)))
            try expect(maxDiff(again, Symmetry.symmetrize(jitter(water, 0.02))) < 1e-6)
            // exact input stays put; C1 untouched; linear projected
            try expect(maxDiff(Symmetry.symmetrize(benzene), benzene) < 1e-8)
            try expect(maxDiff(Symmetry.symmetrize(chfclbr), chfclbr) == 0)
            try expect(Symmetry.symmetrize(Molecule()).atoms.isEmpty)
            let bent = mol([(6, .zero), (8, Vec3(0.02, 0.01, 1.16)), (8, Vec3(-0.01, 0.0, -1.15))])
            let lin = Symmetry.symmetrize(bent)
            try expect(group(lin, tol: 1e-6) == "D*h", group(lin, tol: 1e-6))
        },
        Check("core.symmetry.standardOrientation") {
            let w = Symmetry.standardOrientation(jitter(water, 0))
            // planar C2v: C2 along z, molecule in yz plane, O on +z, center of mass at origin
            for a in w.atoms { try expectClose(a.position.x, 0, tol: 1e-6) }
            try expect(w.atoms[0].position.z > 0 && w.atoms[1].position.z < 0)
            var com = Vec3.zero, mt = 0.0
            for a in w.atoms { let m = Elements.element(a.atomicNumber).mass; com += m * a.position; mt += m }
            try expect(simd_length(com / mt) < 1e-9)
            // rotated + translated input gives same internal geometry
            var t = water
            for i in t.atoms.indices { t.atoms[i].position = VecMath.rotate(t.atoms[i].position, about: .zero, axis: Vec3(1, 1, 0), degrees: 50) + Vec3(5, 5, 5) }
            let w2 = Symmetry.standardOrientation(t)
            try expect(maxDiff(w, w2) < 1e-6, "\(maxDiff(w, w2))")
            // idempotent
            for m in [water, ammonia, co2, hcn, ethylene, chfclbr, h2o2, benzene] {
                let o1 = Symmetry.standardOrientation(m)
                let o2 = Symmetry.standardOrientation(o1)
                try expect(maxDiff(o1, o2) < 1e-6, "not idempotent \(group(m)): \(maxDiff(o1, o2))")
            }
            // benzene: principal axis on z
            for a in Symmetry.standardOrientation(benzene).atoms { try expectClose(a.position.z, 0, tol: 1e-6) }
            // linear along z
            for a in Symmetry.standardOrientation(co2).atoms { try expect(abs(a.position.x) < 1e-9 && abs(a.position.y) < 1e-9) }
            // C3v: axis on z
            for a in Symmetry.standardOrientation(ammonia).atoms.dropFirst() { try expectClose(a.position.z, Symmetry.standardOrientation(ammonia).atoms[1].position.z, tol: 1e-6) }
            // empty / single atom
            try expect(Symmetry.standardOrientation(Molecule()).atoms.isEmpty)
            let one = Symmetry.standardOrientation(mol([(8, Vec3(3, 3, 3))]))
            try expect(simd_length(one.atoms[0].position) < 1e-12)
            // bonds preserved
            try expect(Symmetry.standardOrientation(water).bonds == water.bonds)
            // oriented molecule keeps its point group
            try expect(group(Symmetry.standardOrientation(c60)) == "Ih")
            try expect(group(Symmetry.standardOrientation(methane)) == "Td")
        },

        // MARK: selection
        Check("core.selection.basics") {
            var s = AtomSelection()
            try expect(s.isEmpty && s.count == 0)
            s.insert(3); s.insert(1); s.insert(3)
            try expect(s.count == 2 && s.contains(1) && s.sorted == [1, 3])
            s.toggle(1); try expect(!s.contains(1)); s.toggle(1); try expect(s.contains(1))
            s.remove(3); s.remove(99); try expect(s.sorted == [1])
            s.selectAll(count: 4); try expect(s.sorted == [0, 1, 2, 3])
            s.invert(count: 4); try expect(s.isEmpty)
            s.insert(2); s.invert(count: 4); try expect(s.sorted == [0, 1, 3])
            s.selectAll(count: 0); try expect(s.isEmpty)
            s.selectAll(count: -2); try expect(s.isEmpty)
            s.insert(1); s.clear(); try expect(s.isEmpty)
            try expect(AtomSelection([5, 5, 6]).count == 2)
            let data = try JSONEncoder().encode(AtomSelection([1, 2]))
            let back = try JSONDecoder().decode(AtomSelection.self, from: data)
            try expect(back == AtomSelection([1, 2]))
            try expect(AtomSelection([1]) == AtomSelection([1]) && AtomSelection([1]).hashValue == AtomSelection([1]).hashValue)
        },
        Check("core.selection.remap") {
            var m = ethane(staggered: true)
            var s = AtomSelection([0, 2, 5, 7])
            let map = m.removeAtoms([2, 5])
            s.remap(map)
            try expect(s.sorted == [0, 5], "\(s.sorted)")
            var t = AtomSelection([0, 100, -1])
            t.remap([0, nil, 1])
            try expect(t.sorted == [0])
            var e = AtomSelection(); e.remap([]); try expect(e.isEmpty)
        },
        Check("core.selection.bondsFragmentsElementRadius") {
            let two = mol([(6, .zero), (6, Vec3(1.5, 0, 0)), (8, Vec3(3, 0, 0)), (8, Vec3(30, 0, 0)), (1, Vec3(31, 0, 0))],
                          [(0, 1), (1, 2), (3, 4)])
            let s = AtomSelection([0, 1, 3])
            try expect(s.bonds(in: two) == [0])
            try expect(AtomSelection([0, 1, 2]).bonds(in: two) == [0, 1])
            try expect(AtomSelection().bonds(in: two).isEmpty)
            try expect(AtomSelection.fragment(of: 0, in: two).sorted == [0, 1, 2])
            try expect(AtomSelection.fragment(of: 4, in: two).sorted == [3, 4])
            try expect(AtomSelection.fragment(of: 9, in: two).isEmpty)
            try expect(AtomSelection.fragment(of: 0, in: Molecule()).isEmpty)
            try expect(AtomSelection.byElement(8, in: two).sorted == [2, 3])
            try expect(AtomSelection.byElement(26, in: two).isEmpty)
            try expect(AtomSelection.within(radius: 1.6, of: 1, in: two).sorted == [0, 2])
            try expect(AtomSelection.within(radius: 100, of: 0, in: two).count == 4)
            try expect(AtomSelection.within(radius: 1, of: -1, in: two).isEmpty)
        },

        // MARK: document model
        Check("core.document.undoRedo") {
            var d = MoleculeDocumentModel()
            try expect(!d.canUndo && !d.canRedo && d.undoName == nil && d.redoName == nil)
            d.undo(); d.redo()   // empty stacks are no-ops
            try expect(d.molecule.atoms.isEmpty)
            let c0 = d.changeCount
            d.perform("Add C") { _ = $0.addAtom(atomicNumber: 6, position: .zero) }
            d.perform("Add O") { _ = $0.addAtom(atomicNumber: 8, position: Vec3(1, 0, 0)) }
            try expect(d.molecule.atoms.count == 2 && d.canUndo && d.undoName == "Add O" && d.changeCount > c0)
            d.undo(); try expect(d.molecule.atoms.count == 1 && d.redoName == "Add O" && d.undoName == "Add C")
            d.undo(); try expect(d.molecule.atoms.isEmpty && !d.canUndo && d.canRedo)
            d.redo(); d.redo(); try expect(d.molecule.atoms.count == 2 && !d.canRedo)
            d.undo(); d.perform("Add N") { _ = $0.addAtom(atomicNumber: 7, position: .zero) }
            try expect(!d.canRedo, "new edit clears redo")
            let cc = d.changeCount
            d.perform("noop") { _ in }
            try expect(d.changeCount == cc && d.undoName == "Add N", "no-change edit must not push")
        },
        Check("core.document.selectionAndRemap") {
            var d = MoleculeDocumentModel(molecule: ethane(staggered: true))
            d.selection = AtomSelection([0, 7])
            d.performRemapping("Delete") { $0.removeAtoms([3, 4]) }
            try expect(d.molecule.atoms.count == 6 && d.selection.sorted == [0, 5], "\(d.selection.sorted)")
            d.undo()
            try expect(d.molecule.atoms.count == 8 && d.selection.sorted == [0, 7], "\(d.selection.sorted)")
            d.redo()
            try expect(d.selection.sorted == [0, 5])
            // selection clamped when molecule shrinks without remap
            var e = MoleculeDocumentModel(molecule: water)
            e.selection = AtomSelection([0, 1, 2])
            e.perform("Remove") { m in _ = m.removeAtoms([2]) }
            try expect(e.selection.sorted == [0, 1])
            e.replaceMolecule(Molecule(), actionName: "Clear")
            try expect(e.selection.isEmpty && e.canUndo)
            e.undo(); try expect(e.molecule.atoms.count == 2)
            var changed = e.changeCount; e.selection.insert(2); try expect(e.changeCount > changed)
            e.selection.remove(1)
            changed = e.changeCount; e.selection.remove(1); try expect(e.changeCount == changed)
        },
        Check("core.document.limitAndGroups") {
            var d = MoleculeDocumentModel()
            d.undoLimit = 3
            for i in 0..<10 { d.perform("a\(i)") { _ = $0.addAtom(atomicNumber: 1, position: Vec3(Double(i), 0, 0)) } }
            var n = 0; while d.canUndo { d.undo(); n += 1 }
            try expect(n == 3 && d.molecule.atoms.count == 7, "\(n) \(d.molecule.atoms.count)")
            var z = MoleculeDocumentModel(); z.undoLimit = 0
            z.perform("x") { _ = $0.addAtom(atomicNumber: 1, position: .zero) }
            try expect(!z.canUndo && z.molecule.atoms.count == 1)
            // groups coalesce a drag
            var g = MoleculeDocumentModel(molecule: water)
            g.beginGroup("Drag")
            for i in 1...20 { g.perform("step") { $0.atoms[0].position.x = Double(i) } }
            try expect(g.isGrouping && !g.canUndo)
            g.beginGroup("inner"); g.endGroup()
            g.endGroup()
            try expect(!g.isGrouping && g.undoName == "Drag")
            g.undo(); try expect(g.molecule == water && !g.canUndo)
            g.redo(); try expect(g.molecule.atoms[0].position.x == 20)
            g.beginGroup("empty"); g.endGroup(); try expect(g.undoName == "Drag", "empty group pushes nothing")
            g.endGroup()  // unbalanced end is harmless
            try expect(!g.isGrouping)
        },
        Check("core.document.replaceAndDirty") {
            var d = MoleculeDocumentModel()
            try expect(!d.isDirty)
            d.perform("Add") { _ = $0.addAtom(atomicNumber: 6, position: .zero) }
            try expect(d.isDirty)
            d.undo(); try expect(!d.isDirty, "undo back to saved state is clean")
            d.redo(); try expect(d.isDirty)
            d.markSaved(); try expect(!d.isDirty)
            d.perform("Add") { _ = $0.addAtom(atomicNumber: 6, position: .zero) }
            try expect(d.isDirty); d.undo(); try expect(!d.isDirty)
            d.perform("Add") { _ = $0.addAtom(atomicNumber: 6, position: .zero) }
            let c = d.changeCount
            d.replaceMolecule(water, actionName: nil)
            try expect(!d.canUndo && !d.canRedo && !d.isDirty && d.molecule == water && d.changeCount > c)
            d.replaceMolecule(benzene, actionName: "Replace")
            try expect(d.canUndo && d.isDirty && d.undoName == "Replace")
            d.undo(); try expect(d.molecule == water && !d.isDirty)
            d.selection = AtomSelection([0, 1, 2]); d.replaceMolecule(mol([(6, .zero)]), actionName: nil)
            try expect(d.selection.isEmpty)
        },

        // MARK: bond orders
        Check("core.bondorders.simpleMolecules") {
            var eth = ethylene; eth.perceiveBondOrders()
            try expect(eth.bond(between: 0, and: 1)?.order == .double && orderCount(eth, .single) == 4)
            var acet = mol([(6, Vec3(0.6, 0, 0)), (6, Vec3(-0.6, 0, 0)), (1, Vec3(1.66, 0, 0)), (1, Vec3(-1.66, 0, 0))], [(0, 1), (0, 2), (1, 3)])
            acet.perceiveBondOrders(); try expect(acet.bond(between: 0, and: 1)?.order == .triple)
            var c = co2; c.perceiveBondOrders(); try expect(orderCount(c, .double) == 2)
            var f = mol([(6, .zero), (8, Vec3(0, 0, 1.21)), (1, Vec3(0, 0.94, -0.59)), (1, Vec3(0, -0.94, -0.59))], [(0, 1), (0, 2), (0, 3)])
            f.perceiveBondOrders(); try expect(f.bond(between: 0, and: 1)?.order == .double && orderCount(f, .single) == 2)
            var e = ethane(staggered: true); e.perceiveBondOrders(); try expect(e.bonds.allSatisfy { $0.order == .single })
            var w = water; w.perceiveBondOrders(); try expect(w.bonds.allSatisfy { $0.order == .single })
            var h = hcn; h.perceiveBondOrders(); try expect(h.bond(between: 0, and: 2)?.order == .triple)
            var n = Molecule(); n.perceiveBondOrders(); try expect(n.bonds.isEmpty)
            var one = mol([(6, .zero)]); one.perceiveBondOrders(); try expect(one.atoms.count == 1)
            var ch4 = methane; ch4.perceiveBondOrders(); try expect(ch4.bonds.allSatisfy { $0.order == .single })
        },
        Check("core.bondorders.aromatic") {
            var b = benzene; b.perceiveBondOrders()
            try expect(orderCount(b, .aromatic) == 6 && orderCount(b, .single) == 6, "\(b.bonds.map(\.order))")
            try expect(b.aromaticRings().count == 1 && b.aromaticRings()[0].count == 6)
            var p = pyridine; p.perceiveBondOrders(); try expect(orderCount(p, .aromatic) == 6, "\(p.bonds.map(\.order))")
            var r = pyrrole; r.perceiveBondOrders(); try expect(orderCount(r, .aromatic) == 5, "\(r.bonds.map(\.order))")
            var nap = naphthalene; nap.perceiveBondOrders()
            try expect(orderCount(nap, .aromatic) == 11, "\(orderCount(nap, .aromatic))")
            try expect(nap.aromaticRings().count == 2)
            // cyclohexane-like: sp3 ring is not aromatic
            var cy = benzene
            for k in 0..<6 { let i = cy.atoms.count; cy.atoms.append(Atom(id: i, atomicNumber: 1, position: ang(1.4, Double(k) * 60, 1))); cy.bonds.append(Bond(k, i)) }
            cy.perceiveBondOrders(); try expect(cy.aromaticRings().isEmpty && cy.bonds.allSatisfy { $0.order == .single })
            // cyclohexadiene-like ring with only two doubles: not aromatic
            var q = benzene
            for k in [0, 3] { let i = q.atoms.count; q.atoms.append(Atom(id: i, atomicNumber: 1, position: ang(1.4, Double(k) * 60, 1))); q.bonds.append(Bond(k, i)) }
            q.perceiveBondOrders(); try expect(orderCount(q, .aromatic) == 0)
        },
        Check("core.bondorders.markKekulize") {
            var b = benzene; b.perceiveBondOrders()
            try expect(b.kekulize())
            try expect(orderCount(b, .double) == 3 && orderCount(b, .aromatic) == 0)
            for i in 0..<6 { try expectClose(b.bondOrderSum(of: i), 4) }
            b.markAromaticBonds(); try expect(orderCount(b, .aromatic) == 6)
            var r = pyrrole; r.perceiveBondOrders(); try expect(r.kekulize() && orderCount(r, .double) == 2)
            try expectClose(r.bondOrderSum(of: 0), 3)
            var nap = naphthalene; nap.perceiveBondOrders(); try expect(nap.kekulize() && orderCount(nap, .double) == 5)
            var p = pyridine; p.perceiveBondOrders(); try expect(p.kekulize() && orderCount(p, .double) == 3)
            // impossible: 5 aromatic carbons (odd ring, no heteroatom)
            let ringC = (0..<5).map { (k: Int) in (6, ang(1.2, Double(k) * 72, 0)) }
            let ringH = (0..<5).map { (k: Int) in (1, ang(2.2, Double(k) * 72, 0)) }
            var cp = mol(ringC + ringH)
            for k in 0..<5 { cp.bonds.append(Bond(k, (k + 1) % 5, order: .aromatic)); cp.bonds.append(Bond(k, 5 + k)) }
            let before = cp
            try expect(!cp.kekulize() && cp == before)
            var none = water; try expect(none.kekulize())
            var empty = Molecule(); try expect(empty.kekulize())
        },
        Check("core.bondorders.chargesAndMetals") {
            // acetate
            var ac = mol([(6, .zero), (6, Vec3(1.52, 0, 0)), (8, Vec3(2.2, 1.1, 0)), (8, Vec3(2.2, -1.1, 0)),
                          (1, Vec3(-0.4, 1.0, 0)), (1, Vec3(-0.4, -0.5, 0.9)), (1, Vec3(-0.4, -0.5, -0.9))],
                         [(0, 1), (1, 2), (1, 3), (0, 4), (0, 5), (0, 6)])
            ac.charge = -1
            ac.perceiveBondOrders()
            try expect(orderCount(ac, .double) == 1)
            let fc = ac.formalCharges()
            try expect(fc.reduce(0, +) == -1 && fc[2] + fc[3] == -1 && fc[1] == 0, "\(fc)")
            // nitromethane
            var nm = mol([(6, .zero), (7, Vec3(1.49, 0, 0)), (8, Vec3(2.1, 1.07, 0)), (8, Vec3(2.1, -1.07, 0)),
                          (1, Vec3(-0.4, 1.0, 0)), (1, Vec3(-0.4, -0.5, 0.9)), (1, Vec3(-0.4, -0.5, -0.9))],
                         [(0, 1), (1, 2), (1, 3), (0, 4), (0, 5), (0, 6)])
            nm.perceiveBondOrders()
            try expect(orderCount(nm, .double) == 1, "\(nm.bonds.map(\.order))")
            let nf = nm.formalCharges()
            try expect(nf[1] == 1 && nf[2] + nf[3] == -1 && nf.reduce(0, +) == 0, "\(nf)")
            // ammonium
            let s = 0.6
            var am = mol([(7, .zero), (1, Vec3(s, s, s)), (1, Vec3(s, -s, -s)), (1, Vec3(-s, s, -s)), (1, Vec3(-s, -s, s))], [(0, 1), (0, 2), (0, 3), (0, 4)])
            am.charge = 1; am.perceiveBondOrders()
            try expect(am.bonds.allSatisfy { $0.order == .single } && am.formalCharges() == [1, 0, 0, 0, 0])
            // neutral molecules have zero charges
            try expect(benzene.formalCharges().allSatisfy { $0 == 0 })
            var pyr = pyrrole; pyr.perceiveBondOrders(); try expect(pyr.formalCharges().allSatisfy { $0 == 0 })
            var w = water; w.perceiveBondOrders(); try expect(w.formalCharges() == [0, 0, 0])
            // missing hydrogens: ethanol heavy atoms only stays neutral
            var eoh = mol([(6, .zero), (6, Vec3(1.5, 0, 0)), (8, Vec3(2.2, 1.2, 0))], [(0, 1), (1, 2)])
            try expect(eoh.formalCharges() == [0, 0, 0], "\(eoh.formalCharges())")
            // cyanide anion
            var cn = mol([(6, .zero), (7, Vec3(0, 0, 1.17))], [(0, 1)]); cn.charge = -1; cn.perceiveBondOrders()
            try expect(cn.bonds[0].order == .triple && cn.formalCharges() == [-1, 0], "\(cn.formalCharges())")
            // sulfate keeps neutral sum of -2 and two S=O
            var so4 = mol([(16, .zero), (8, Vec3(1.47, 0, 0)), (8, Vec3(-0.5, 1.4, 0)), (8, Vec3(-0.5, -0.7, 1.2)), (8, Vec3(-0.5, -0.7, -1.2))],
                          [(0, 1), (0, 2), (0, 3), (0, 4)])
            so4.charge = -2; so4.perceiveBondOrders()
            try expect(orderCount(so4, .double) == 2 && so4.formalCharges().reduce(0, +) == -2, "\(so4.bonds.map(\.order)) \(so4.formalCharges())")
            // metals: bonds to metals stay single; the C-O bond of a carbonyl ligand is perceived (double: O has valence 2)
            var fe = mol([(26, .zero), (6, Vec3(1.8, 0, 0)), (8, Vec3(2.95, 0, 0))], [(0, 1), (1, 2)])
            fe.perceiveBondOrders()
            try expect(fe.bond(between: 0, and: 1)?.order == .single && fe.bond(between: 1, and: 2)?.order == .double)
        },
    ]
}
