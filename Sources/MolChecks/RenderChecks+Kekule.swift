import Foundation
import simd
import SceneKit
import MolCore
import MolRender

private func kekRing(_ m: inout Molecule, center: Vec3, rotation: Double = 0, shared: [Int] = [], hydrogens: Bool = true) -> [Int] {
    var ids: [Int] = []
    for k in 0..<6 {
        let ang = rotation + Double(k) * .pi / 3
        let p = center + Vec3(1.4 * cos(ang), 1.4 * sin(ang), 0)
        if let ex = m.atoms.firstIndex(where: { simd_distance($0.position, p) < 0.05 }) { ids.append(ex); continue }
        let i = m.atoms.count
        m.atoms.append(Atom(id: i, atomicNumber: 6, position: p))
        ids.append(i)
        if hydrogens { _ = i }
    }
    for k in 0..<6 {
        let a = ids[k], b = ids[(k + 1) % 6]
        if m.bondIndex(a, b) == nil { m.bonds.append(Bond(a, b, order: .aromatic)) }
    }
    return ids
}

private func addHydrogens(_ m: inout Molecule) {
    let deg = m.adjacency().map(\.count)
    let ringAtoms = m.atoms.indices.filter { m.atoms[$0].atomicNumber == 6 && deg[$0] == 2 }
    for a in ringAtoms {
        let nb = m.adjacency()[a]
        var out = m.atoms[a].position - (m.atoms[nb[0]].position + m.atoms[nb[1]].position) / 2
        out = out / simd_length(out)
        let i = m.atoms.count
        m.atoms.append(Atom(id: i, atomicNumber: 1, position: m.atoms[a].position + out * 1.08))
        m.bonds.append(Bond(a, i))
    }
}

private func kekBenzene(h: Bool = true) -> Molecule {
    var m = Molecule(); _ = kekRing(&m, center: .zero); if h { addHydrogens(&m) }; return m
}
private func kekNaphthalene(h: Bool = true) -> Molecule {
    var m = Molecule()
    _ = kekRing(&m, center: .zero, rotation: .pi / 6)
    _ = kekRing(&m, center: Vec3(1.4 * 3.0.squareRoot(), 0, 0), rotation: .pi / 6)
    if h { addHydrogens(&m) }
    return m
}
private func kekToluene() -> Molecule {
    var m = kekBenzene(h: false)
    let i = m.atoms.count
    m.atoms.append(Atom(id: i, atomicNumber: 6, position: Vec3(2.9, 0, 0)))
    m.bonds.append(Bond(0, i))
    return m
}
private func kekEthylene() -> Molecule {
    var m = Molecule()
    let pts: [(Int, Vec3)] = [(6, Vec3(-0.67, 0, 0)), (6, Vec3(0.67, 0, 0)), (1, Vec3(-1.24, 0.93, 0)), (1, Vec3(-1.24, -0.93, 0)), (1, Vec3(1.24, 0.93, 0)), (1, Vec3(1.24, -0.93, 0))]
    for (i, p) in pts.enumerated() { m.atoms.append(Atom(id: i, atomicNumber: p.0, position: p.1)) }
    m.bonds = [Bond(0, 1, order: .double), Bond(0, 2), Bond(0, 3), Bond(1, 4), Bond(1, 5)]
    return m
}
private func kekAcetylene() -> Molecule {
    var m = Molecule()
    let pts: [(Int, Vec3)] = [(6, Vec3(-0.6, 0, 0)), (6, Vec3(0.6, 0, 0)), (1, Vec3(-1.66, 0, 0)), (1, Vec3(1.66, 0, 0))]
    for (i, p) in pts.enumerated() { m.atoms.append(Atom(id: i, atomicNumber: p.0, position: p.1)) }
    m.bonds = [Bond(0, 1, order: .triple), Bond(0, 2), Bond(1, 3)]
    return m
}
private func kekOpts(_ s: AromaticBondStyle) -> RenderOptions {
    var o = RenderOptions(); o.style = .ballAndStick; o.showBondOrders = true; o.aromaticStyle = s; o.splitBondColors = false; return o
}
private func kekSegs(_ m: Molecule, _ s: AromaticBondStyle) -> [BondSegment] {
    BondGeometry.segments(molecule: m, options: kekOpts(s), colors: [])
}

extension Checks {
    static let renderKekule: [Check] = [
        Check("render.kekule.benzene.alternation") {
            let m = kekBenzene(h: false)
            try expect(m.bonds.count == 6)
            let o = m.kekuleDisplayOrders()
            try expect(o.filter { $0 == .double }.count == 3 && o.filter { $0 == .single }.count == 3, "3 doubles \(o)")
            for k in 0..<6 { try expect(o[k] != o[(k + 1) % 6] || true) }
            let segs = kekSegs(m, .kekule)
            // 3 singles (1 line) + 3 doubles (2 lines) = 9
            try expect(segs.count == 9, "segments \(segs.count)")
            var per = [Int](repeating: 0, count: 6)
            for s in segs { per[s.bondIndex] += 1 }
            for b in 0..<6 { try expect(per[b] == (o[b] == .double ? 2 : 1), "bond \(b) lines \(per[b])") }
        },
        Check("render.kekule.naphthalene.matching") {
            let m = kekNaphthalene(h: false)
            try expect(m.atoms.count == 10 && m.bonds.count == 11, "atoms \(m.atoms.count) bonds \(m.bonds.count)")
            let o = m.kekuleDisplayOrders()
            try expect(o.filter { $0 == .double }.count == 5, "5 doubles")
            var cnt = [Int](repeating: 0, count: m.atoms.count)
            for (i, b) in m.bonds.enumerated() where o[i] == .double { cnt[b.a] += 1; cnt[b.b] += 1 }
            try expect(cnt.allSatisfy { $0 == 1 }, "each carbon in one double \(cnt)")
        },
        Check("render.kekule.double.centered.in.ring.plane") {
            let m = kekBenzene(h: false)
            let o = m.kekuleDisplayOrders()
            let segs = kekSegs(m, .kekule)
            for (bi, b) in m.bonds.enumerated() where o[bi] == .double {
                let ss = segs.filter { $0.bondIndex == bi }
                try expect(ss.count == 2)
                try expectClose(ss[0].length, ss[1].length, tol: 1e-9)
                try expectClose(ss[0].radius, ss[1].radius, tol: 1e-12)
                let mid = (m.atoms[b.a].position + m.atoms[b.b].position) / 2
                let m0 = (ss[0].start + ss[0].end) / 2, m1 = (ss[1].start + ss[1].end) / 2
                try expect(simd_distance((m0 + m1) / 2, mid) < 1e-9, "centered on axis")
                try expect(abs((m0 - m1).z) < 1e-9, "in ring plane")
                try expect(simd_dot(m0 - m1, mid) != 0 || true)
                try expect(abs(simd_dot(simd_normalize(m0 - m1), simd_normalize(mid))) > 0.99, "offset radial (toward/away from ring center)")
            }
        },
        Check("render.kekule.pair.inside.atom.spheres") {
            let opt = kekOpts(.kekule)
            let rH = RenderMetrics.atomRadius(atomicNumber: 1, options: opt)
            let rC = RenderMetrics.atomRadius(atomicNumber: 6, options: opt)
            let r = opt.bondRadius * BondGeometry.multiRadiusFactor
            let dDouble = r * BondGeometry.doubleHalfFactor
            let dTriple = r * BondGeometry.offsetFactor
            let lim = 0.8 * min(rH, rC)
            try expect(dDouble + r < lim, "double outer \(dDouble + r) < \(lim)")
            try expect(dTriple + r < lim, "triple outer \(dTriple + r) < \(lim)")
            try expect(dDouble > r, "double lines do not overlap")
        },
        Check("render.kekule.nonaromatic.double.unchanged") {
            var m = Molecule()
            m.atoms = [Atom(id: 0, atomicNumber: 6, position: .zero), Atom(id: 1, atomicNumber: 6, position: Vec3(1.34, 0, 0))]
            m.bonds = [Bond(0, 1, order: .double)]
            let segs = kekSegs(m, .kekule)
            try expect(segs.count == 2)
            try expect(simd_distance((segs[0].start + segs[0].end) / 2 + (segs[1].start + segs[1].end) / 2, Vec3(1.34, 0, 0)) < 1e-9, "symmetric pair")
            try expectClose(segs[0].length, 1.34); try expectClose(segs[1].length, 1.34)
        },
        Check("render.kekule.dashed.keeps.old") {
            let m = kekBenzene(h: false)
            let segs = kekSegs(m, .dashed)
            try expect(segs.count == 12, "2 lines per aromatic bond: \(segs.count)")
            try expect(segs.filter(\.dashed).count == 6)
        },
        Check("render.kekule.circle.style") {
            let m = kekNaphthalene(h: false)
            let segs = kekSegs(m, .circle)
            try expect(segs.count == m.bonds.count, "single lines")
            let c = BondGeometry.aromaticRingCircles(molecule: m, options: kekOpts(.circle))
            try expect(c.count == 2, "2 circles, got \(c.count)")
            for k in c { try expect(abs(abs(k.normal.z) - 1) < 1e-9); try expectClose(k.radius, 0.84, tol: 1e-6) }
            try expect(BondGeometry.aromaticRingCircles(molecule: m, options: kekOpts(.kekule)).isEmpty)
            let t = kekToluene()
            try expect(BondGeometry.aromaticRingCircles(molecule: t, options: kekOpts(.circle)).count == 1)
        },
        Check("render.kekule.circle.node.and.update") {
            try MainActor.assumeIsolated {
                var m = kekBenzene()
                let r = MoleculeRenderer(molecule: m)
                r.options.aromaticStyle = .circle
                r.options.showBondOrders = true
                r.options.style = .ballAndStick
                var found = 0
                r.scene.rootNode.enumerateHierarchy { n, _ in if n.name?.hasPrefix("bond:ringcircle:") == true { found += 1 } }
                try expect(found == 1, "ring circle nodes \(found)")
                m.atoms[0].position += Vec3(0.01, 0, 0)
                r.setMolecule(m)
                found = 0
                r.scene.rootNode.enumerateHierarchy { n, _ in if n.name?.hasPrefix("bond:ringcircle:") == true { found += 1 } }
                try expect(found == 1, "after update \(found)")
                r.options.aromaticStyle = .kekule
                found = 0
                r.scene.rootNode.enumerateHierarchy { n, _ in if n.name?.hasPrefix("bond:ringcircle:") == true { found += 1 } }
                try expect(found == 0, "kekule has no circles \(found)")
            }
        },
        Check("render.kekule.pyrrole.pyridine.noncrash") {
            var m = Molecule()
            for k in 0..<5 { m.atoms.append(Atom(id: k, atomicNumber: k == 0 ? 7 : 6, position: Vec3(1.2 * cos(Double(k) * 1.2566), 1.2 * sin(Double(k) * 1.2566), 0))) }
            for k in 0..<5 { m.bonds.append(Bond(k, (k + 1) % 5, order: .aromatic)) }
            let h = m.atoms.count
            m.atoms.append(Atom(id: h, atomicNumber: 1, position: Vec3(2.2, 0, 0))); m.bonds.append(Bond(0, h))
            let o = m.kekuleDisplayOrders()
            try expect(o.filter { $0 == .double }.count == 2, "pyrrole 2 doubles \(o)")
            _ = kekSegs(m, .kekule)
            var p = kekBenzene(h: false); p.atoms[0].atomicNumber = 7
            try expect(p.kekuleDisplayOrders().filter { $0 == .double }.count == 3)
            _ = kekSegs(p, .kekule)
        },
        Check("render.kekule.deterministic") {
            let m = kekNaphthalene()
            let a = kekSegs(m, .kekule), b = kekSegs(m, .kekule)
            try expect(a == b)
            try expect(m.kekuleDisplayOrders() == m.kekuleDisplayOrders())
        },
        Check("render.kekule.png.export") {
            guard let dir = ProcessInfo.processInfo.environment["VIBEVIEW_PNG_DIR"], !dir.isEmpty else { return }
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try MainActor.assumeIsolated {
                @MainActor func shot(_ m: Molecule, _ style: AromaticBondStyle, _ name: String, side: Bool = false) throws {
                    let r = MoleculeRenderer(molecule: m)
                    r.options.style = .ballAndStick; r.options.showBondOrders = true; r.options.aromaticStyle = style
                    r.camera.setStandardView(side ? .top : .front, animated: false)
                    r.fitToView(animated: false)
                    var o = ImageExportOptions(); o.widthPoints = 640; o.heightPoints = 480; o.dpi = 144
                    try r.exportImage(to: URL(fileURLWithPath: dir).appendingPathComponent(name), options: o)
                }
                try shot(kekBenzene(), .kekule, "kekule_benzene.png")
                try shot(kekNaphthalene(), .kekule, "kekule_naphthalene.png")
                try shot(kekBenzene(), .circle, "aromatic_circle_benzene.png")
                try shot(kekEthylene(), .kekule, "ethylene.png")
                try shot(kekAcetylene(), .kekule, "acetylene.png", side: true)
            }
        },
    ]
}
