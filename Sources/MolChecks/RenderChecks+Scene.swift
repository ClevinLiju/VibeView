import Foundation
import simd
import SceneKit
import MolCore
import MolAnalysis
import MolRender

// Worker A: scene builders (atoms, bonds, materials). Names "render.scene.*".

private func opts(_ style: RenderStyle = .ballAndStick, _ edit: (inout RenderOptions) -> Void = { _ in }) -> RenderOptions {
    var o = RenderOptions(); o.style = style; edit(&o); return o
}
private func buildAtoms(_ m: Molecule, _ o: RenderOptions, _ lib: MaterialLibrary = MaterialLibrary()) -> SCNNode {
    AtomLayerBuilder.build(molecule: m, options: o, colors: RenderMetrics.atomColors(for: m, options: o), materials: lib)
}
private func buildBonds(_ m: Molecule, _ o: RenderOptions, _ lib: MaterialLibrary = MaterialLibrary()) -> SCNNode {
    BondLayerBuilder.build(molecule: m, options: o, colors: RenderMetrics.atomColors(for: m, options: o), materials: lib)
}
private func geoNodes(_ n: SCNNode) -> [SCNNode] {
    var r: [SCNNode] = []; n.enumerateHierarchy { x, _ in if x.geometry != nil { r.append(x) } }; return r
}
private func segs(_ m: Molecule, _ o: RenderOptions) -> [BondSegment] {
    BondGeometry.segments(molecule: m, options: o, colors: RenderMetrics.atomColors(for: m, options: o))
}
private func v(_ p: SCNVector3) -> Vec3 { Vec3(Double(p.x), Double(p.y), Double(p.z)) }
private func closeV(_ a: Vec3, _ b: Vec3, _ tol: Double = 1e-4) -> Bool { simd_distance(a, b) <= tol }

/// Transform node-local (0,+-0.5*scaleY... ) endpoints: local y = +-0.5 of the unit cylinder.
private func cylinderEndpoints(_ n: SCNNode) -> (Vec3, Vec3) {
    let t = n.simdWorldTransform
    func w(_ y: Float) -> Vec3 { let p = t * SIMD4<Float>(0, y, 0, 1); return Vec3(Double(p.x), Double(p.y), Double(p.z)) }
    return (w(-0.5), w(0.5))
}

extension Checks {
    static let renderScene: [Check] = [
        Check("render.scene.water.ballstick.counts") {
            let m = RenderFixtures.water, o = opts()
            try expect(geoNodes(buildAtoms(m, o)).count == 3, "atoms")
            try expect(geoNodes(buildBonds(m, o)).count == 4, "bond segments \(geoNodes(buildBonds(m, o)).count)")
            let names = buildAtoms(m, o).childNodes.compactMap(\.name)
            try expect(names == ["atom:0", "atom:1", "atom:2"], "\(names)")
            let bn = Set(buildBonds(m, o).childNodes.compactMap(\.name))
            try expect(bn == ["bond:0", "bond:1"], "\(bn)")
            try expect(buildAtoms(m, o).name == "vibeview.atoms" && buildBonds(m, o).name == "vibeview.bonds", "layer names")
        },
        Check("render.scene.unsplit.counts") {
            let m = RenderFixtures.water, o = opts { $0.splitBondColors = false; $0.bondColor = RGBA(0.2, 0.3, 0.4) }
            let s = segs(m, o)
            try expect(s.count == 2 && s.allSatisfy { $0.color == RGBA(0.2, 0.3, 0.4) }, "unsplit")
        },
        Check("render.scene.benzene.bondorders") {
            let m = RenderFixtures.benzene
            // 3 double (2 lines), 3 single, 6 CH single -> 3*2+3+6 = 15 lines, split -> 30
            try expect(segs(m, opts()).count == 30, "ballstick \(segs(m, opts()).count)")
            try expect(segs(m, opts { $0.showBondOrders = false }).count == 24, "no orders")
            try expect(segs(m, opts(.tube)).count == 24, "tube ignores orders")
            try expect(geoNodes(buildBonds(m, opts())).count == 30, "nodes")
            let dbl = segs(m, opts()).filter { $0.bondIndex == 0 }
            try expect(dbl.count == 4, "double bond 2 lines x 2 halves")
            let thin = 0.12 * BondGeometry.multiRadiusFactor
            try expect(dbl.allSatisfy { abs($0.radius - thin) < 1e-12 }, "thin radius")
        },
        Check("render.scene.styles.counts") {
            let m = RenderFixtures.benzene
            let sf = opts(.spaceFilling)
            try expect(geoNodes(buildAtoms(m, sf)).count == 12, "sf atoms")
            try expect(geoNodes(buildBonds(m, sf)).count == 0, "sf bonds")
            let tube = opts(.tube)
            try expect(geoNodes(buildAtoms(m, tube)).count == 12, "tube atoms")
            try expect(geoNodes(buildBonds(m, tube)).count == 24, "tube bonds")
            let wf = opts(.wireframe)
            try expect(geoNodes(buildBonds(m, wf)).count == 1, "wire = 1 geometry node")
            try expect(geoNodes(buildAtoms(m, wf)).count == 0, "wire: no atoms when all bonded")
            let g = geoNodes(buildBonds(m, wf))[0].geometry!
            try expect(g.elements.count == 1 && g.elements[0].primitiveType == .line, "line primitive")
            try expect(g.elements[0].primitiveCount == 24, "24 lines (split) \(g.elements[0].primitiveCount)")
            try expect(g.sources(for: .color).count == 1, "vertex colors")
            // isolated atom marker
            var iso = RenderFixtures.water; iso.atoms.append(Atom(id: 3, atomicNumber: 18, position: Vec3(5, 0, 0)))
            let ia = buildAtoms(iso, wf)
            try expect(ia.childNodes.count == 1 && ia.childNodes[0].name == "atom:3", "isolated marker")
            // tube radius
            let r = (geoNodes(buildAtoms(m, tube))[0].geometry as! SCNSphere).radius
            try expectClose(Double(r), tube.tubeRadius, tol: 1e-6)
            // space-filling radius = vdW
            let rc = (geoNodes(buildAtoms(m, sf))[0].geometry as! SCNSphere).radius
            try expectClose(Double(rc), ElementPalette.vdwRadius(6), tol: 1e-6)
        },
        Check("render.scene.hiddenH") {
            let m = RenderFixtures.benzene
            let o = opts { $0.showHydrogens = false }
            try expect(geoNodes(buildAtoms(m, o)).count == 6, "atoms")
            // only ring bonds: 3 double*2 + 3 single = 9 lines -> 18
            try expect(geoNodes(buildBonds(m, o)).count == 18, "bonds \(geoNodes(buildBonds(m, o)).count)")
            let w = RenderFixtures.water
            try expect(geoNodes(buildAtoms(w, o)).count == 1 && geoNodes(buildBonds(w, o)).count == 0, "water")
            let names = buildAtoms(m, o).childNodes.compactMap(\.name)
            try expect(names == (0..<6).map { "atom:\($0)" }, "\(names)")
        },
        Check("render.scene.cylinder.transform") {
            // bonds along assorted directions incl. +-y, +-x, +-z, diagonal
            let dirs: [Vec3] = [Vec3(0, 1, 0), Vec3(0, -1, 0), Vec3(1, 0, 0), Vec3(-1, 0, 0), Vec3(0, 0, 1), Vec3(0, 0, -1),
                                simd_normalize(Vec3(1, 2, 3)), simd_normalize(Vec3(-1, -1, 0.5)), simd_normalize(Vec3(1e-6, -1, 0))]
            var m = Molecule()
            for (k, d) in dirs.enumerated() {
                let base = Vec3(Double(k) * 5, 0.3, -2)
                m.atoms.append(Atom(id: 2 * k, atomicNumber: 6, position: base))
                m.atoms.append(Atom(id: 2 * k + 1, atomicNumber: 6, position: base + d * (1.2 + 0.1 * Double(k))))
                m.bonds.append(Bond(2 * k, 2 * k + 1))
            }
            for split in [true, false] {
                let o = opts { $0.splitBondColors = split }
                let expected = BondGeometry.renderSegments(molecule: m, options: o, colors: RenderMetrics.atomColors(for: m, options: o))
                let nodes = geoNodes(buildBonds(m, o))
                try expect(nodes.count == expected.count && nodes.count == (split ? 18 : 9), "count")
                for (n, s) in zip(nodes, expected) {
                    let (p, q) = cylinderEndpoints(n)
                    try expect(closeV(p, s.start) && closeV(q, s.end), "\(n.name ?? "?") endpoints \(p) \(q) vs \(s.start) \(s.end)")
                    try expect(n.name == "bond:\(s.bondIndex)", "name")
                    let c = n.geometry as! SCNCylinder
                    try expectClose(Double(c.height), 1)
                    try expectClose(Double(c.radius), s.radius, tol: 1e-6)
                }
            }
            // antiparallel to +Y explicitly: the orientation quaternion must map +Y onto direction
            let q = RenderMath.orientationFromY(to: Vec3(0, -3, 0))
            let y = q.act(SIMD3<Float>(0, 1, 0))
            try expect(abs(y.y + 1) < 1e-5, "antiparallel \(y)")
        },
        Check("render.scene.offsetDirection.benzene") {
            let m = RenderFixtures.benzene
            for bi in 0..<6 {
                let u = BondGeometry.offsetDirection(bondIndex: bi, in: m)
                let b = m.bonds[bi]
                let d = simd_normalize(m.atoms[b.b].position - m.atoms[b.a].position)
                try expect(abs(u.z) < 1e-9, "z \(u.z)")
                try expectClose(simd_length(u), 1, tol: 1e-9)
                try expect(abs(simd_dot(u, d)) < 1e-9, "perp")
                let mid = (m.atoms[b.a].position + m.atoms[b.b].position) / 2
                try expect(simd_dot(u, Vec3(0, 0, 0) - mid) > 0, "toward center bond \(bi)")
            }
            // CH bond: neighbor-based, in plane
            let u = BondGeometry.offsetDirection(bondIndex: 6, in: m)
            try expect(abs(u.z) < 1e-9 && abs(simd_length(u) - 1) < 1e-9, "CH in plane")
        },
        Check("render.scene.offsetDirection.nonring") {
            // ethylene-like in xz-plane: offset must lie in that plane
            let a = [Atom(id: 0, atomicNumber: 6, position: Vec3(0, 0, 0)), Atom(id: 1, atomicNumber: 6, position: Vec3(1.34, 0, 0)),
                     Atom(id: 2, atomicNumber: 1, position: Vec3(-0.5, 0, 0.9)), Atom(id: 3, atomicNumber: 1, position: Vec3(1.84, 0, -0.9))]
            let m = Molecule(atoms: a, bonds: [Bond(0, 1, order: .double), Bond(0, 2), Bond(1, 3)], title: "eth")
            let u = BondGeometry.offsetDirection(bondIndex: 0, in: m)
            try expect(abs(u.y) < 1e-9 && abs(abs(u.z) - 1) < 1e-9, "\(u)")
            try expect(BondGeometry.offsetDirection(bondIndex: 99, in: m) == Vec3(0, 0, 1), "out of range")
        },
        Check("render.scene.acetylene.triple") {
            let m = RenderFixtures.acetylene
            let o = opts { $0.splitBondColors = false }
            let s = segs(m, o).filter { $0.bondIndex == 1 }
            try expect(s.count == 3, "triple -> 3 lines, got \(s.count)")
            for x in s {
                let d = x.end - x.start
                try expect(abs(d.y) < 1e-12 && abs(d.z) < 1e-12 && d.x > 0, "parallel to x")
                try expectClose(x.start.x, -0.6, tol: 1e-12); try expectClose(x.end.x, 0.6, tol: 1e-12)
            }
            let offs = s.map { simd_length(Vec3(0, $0.start.y, $0.start.z)) }.sorted()
            let step = 0.12 * 0.5 * BondGeometry.offsetFactor
            try expectClose(offs[0], 0, tol: 1e-12); try expectClose(offs[1], step, tol: 1e-12); try expectClose(offs[2], step, tol: 1e-12)
            try expect(Set(s.map { Int(($0.start.y * 1e6).rounded()) + 1_000_000 * Int(($0.start.z * 1e6).rounded()) }).count == 3, "distinct")
            try expect(segs(m, opts()).count == (1 + 3 + 1) * 2, "split total")
        },
        Check("render.scene.aromatic.dashed") {
            var m = RenderFixtures.benzene
            for i in 0..<6 { m.bonds[i].order = .aromatic }
            let o = opts { $0.splitBondColors = false }
            let s = segs(m, o).filter { $0.bondIndex == 0 }
            try expect(s.count == 2 && s.filter(\.dashed).count == 1, "one full one dashed")
            let full = s.first { !$0.dashed }!, dash = s.first(where: \.dashed)!
            let u = BondGeometry.offsetDirection(bondIndex: 0, in: m)
            let dv = (dash.start + dash.end) / 2 - (full.start + full.end) / 2
            try expect(simd_dot(dv, u) > 0 && closeV(simd_normalize(dv), u, 1e-9), "offset toward ring center")
        },
        Check("render.scene.dashedBonds") {
            let m = RenderFixtures.water
            let o = opts { $0.dashedBonds = [AtomPair(1, 0)] }   // pair order must not matter
            let logical = segs(m, o)
            try expect(logical.filter(\.dashed).count == 2 && logical.filter { !$0.dashed }.count == 2, "flags")
            let pieces = BondGeometry.renderSegments(molecule: m, options: o, colors: RenderMetrics.atomColors(for: m, options: o))
            let d = pieces.filter { $0.dashed && $0.bondIndex == 0 }
            try expect(d.count >= 4, "several dashes \(d.count)")
            let total = logical.filter(\.dashed).reduce(0) { $0 + $1.length }
            try expect(d.reduce(0) { $0 + $1.length } < total * 0.8, "gaps exist")
            // dashes lie on the bond line, ordered, non-overlapping
            let p0 = m.atoms[0].position, p1 = m.atoms[1].position, dir = simd_normalize(p1 - p0)
            for x in d {
                try expect(simd_length(simd_cross(x.start - p0, dir)) < 1e-9 && simd_length(simd_cross(x.end - p0, dir)) < 1e-9, "on line")
            }
            try expect(geoNodes(buildBonds(m, o)).count == pieces.count, "nodes == pieces")
        },
        Check("render.scene.splitColors") {
            let m = RenderFixtures.water
            let o = opts()
            let colors = RenderMetrics.atomColors(for: m, options: o)
            let s = segs(m, o)
            try expect(s.count == 4, "4")
            for bi in 0..<2 {
                let h = s.filter { $0.bondIndex == bi }
                try expect(h.count == 2, "halves")
                try expect(h[0].color == colors[m.bonds[bi].a] && h[1].color == colors[m.bonds[bi].b], "colors")
                try expect(closeV(h[0].end, h[1].start, 1e-12), "meet at midpoint")
                try expectClose(simd_distance(h[0].start, h[0].end), simd_distance(h[1].start, h[1].end), tol: 1e-12)
                try expect(closeV(h[0].start, m.atoms[m.bonds[bi].a].position, 1e-12) && closeV(h[1].end, m.atoms[m.bonds[bi].b].position, 1e-12), "ends")
            }
            // uniform scheme respected
            let u = opts { $0.colorScheme = .uniform(RGBA(0, 1, 0)) }
            try expect(segs(m, u).allSatisfy { $0.color == RGBA(0, 1, 0) }, "uniform")
        },
        Check("render.scene.materials.shared") {
            let lib = MaterialLibrary(preset: .glossy)
            let m = RenderFixtures.benzene, o = opts()
            let a = buildAtoms(m, o, lib), b = buildBonds(m, o, lib)
            let an = geoNodes(a), bn = geoNodes(b)
            // 6 carbons share geometry and material; 6 H the same
            let carbons = an.filter { Int($0.name!.dropFirst(5))! < 6 }
            try expect(carbons.allSatisfy { $0.geometry === carbons[0].geometry }, "shared sphere")
            let hs = an.filter { Int($0.name!.dropFirst(5))! >= 6 }
            try expect(hs.allSatisfy { $0.geometry === hs[0].geometry }, "shared H sphere")
            try expect(carbons[0].geometry !== hs[0].geometry, "distinct")
            try expect(carbons[0].geometry!.firstMaterial === bn.first { $0.geometry!.firstMaterial === carbons[0].geometry!.firstMaterial }?.geometry?.firstMaterial, "bond shares atom C material")
            try expect(lib.cachedCount == 2, "2 colors cached, got \(lib.cachedCount)")
            let distinctGeos = Set(bn.map { ObjectIdentifier($0.geometry!) }).count
            try expect(distinctGeos <= 4, "bond geometries \(distinctGeos)")   // (thin|thick) x (C|H)
            try expect(lib.material(for: RGBA(0.1, 0.2, 0.3)) === lib.material(for: RGBA(0.1, 0.2, 0.3)), "cache")
        },
        Check("render.scene.materials.presets") {
            let c = RGBA(0.5, 0.2, 0.7)
            let lib = MaterialLibrary(preset: .matte)
            let m0 = lib.material(for: c)
            try expect(m0.lightingModel == .blinn && lib.cachedCount == 1, "matte")
            lib.preset = .glossy
            try expect(lib.cachedCount == 0, "cache cleared on preset change")
            let g = lib.material(for: c)
            try expect(g !== m0 && g.lightingModel == .blinn && g.shininess > m0.shininess, "glossy")
            lib.preset = .metallic
            let me = lib.material(for: c)
            try expect(me.lightingModel == .physicallyBased, "metallic")
            try expectClose(((me.metalness.contents as? NSNumber)?.doubleValue) ?? -1, 0.5, tol: 1e-9)
            try expectClose(((me.roughness.contents as? NSNumber)?.doubleValue) ?? -1, 0.3, tol: 1e-9)
            lib.preset = .flat
            try expect(lib.material(for: c).lightingModel == .constant, "flat")
            lib.preset = .glossy
            let t = lib.material(for: RGBA(1, 0, 0, 0.4))
            try expectClose(Double(t.transparency), 0.4, tol: 1e-6)
            try expect(t.transparencyMode == .dualLayer, "dual layer")
            try expectClose(Double(lib.material(for: c).transparency), 1, tol: 1e-9)
            let lm = lib.lineMaterial()
            try expect(lm === lib.lineMaterial() && lm.lightingModel == .constant, "line material")
        },
        Check("render.scene.quality.reduction") {
            let q = 24
            try expect(SceneQuality.sphereSegments(quality: q, atomCount: 10) == 24, "small")
            try expect(SceneQuality.sphereSegments(quality: q, atomCount: 3000) < 24, "big reduces")
            try expect(SceneQuality.sphereSegments(quality: q, atomCount: 10000) <= SceneQuality.sphereSegments(quality: q, atomCount: 3000), "monotone")
            let m = RenderFixtures.lattice(14)  // 2744
            let g = geoNodes(buildAtoms(m, opts()))[0].geometry as! SCNSphere
            try expect(g.segmentCount < 24, "auto reduced \(g.segmentCount)")
            let w = geoNodes(buildAtoms(RenderFixtures.water, opts()))[0].geometry as! SCNSphere
            try expect(w.segmentCount == 24, "water keeps quality")
        },
        Check("render.scene.updatePositions") {
            var m = RenderFixtures.benzene
            let o = opts { $0.splitBondColors = true }
            let lib = MaterialLibrary()
            let atoms = buildAtoms(m, o, lib), bonds = buildBonds(m, o, lib)
            for i in m.atoms.indices { m.atoms[i].position += Vec3(1, 2, 3) + Vec3(0.01 * Double(i), 0, 0) }
            try expect(AtomLayerBuilder.updatePositions(atoms, molecule: m, options: o), "atoms updated")
            try expect(BondLayerBuilder.updatePositions(bonds, molecule: m, options: o), "bonds updated")
            for (i, n) in atoms.childNodes.enumerated() {
                try expect(closeV(v(n.position), m.atoms[i].position, 1e-5), "atom \(i) moved")
            }
            let expected = BondGeometry.renderSegments(molecule: m, options: o, colors: RenderMetrics.atomColors(for: m, options: o))
            for (n, s) in zip(geoNodes(bonds), expected) {
                let (p, q) = cylinderEndpoints(n)
                try expect(closeV(p, s.start, 1e-4) && closeV(q, s.end, 1e-4), "bond follows")
            }
            // mismatches -> false
            var fewer = m; fewer.atoms.removeLast(); fewer.bonds.removeLast()
            try expect(!AtomLayerBuilder.updatePositions(atoms, molecule: fewer, options: o), "atom count mismatch")
            try expect(!BondLayerBuilder.updatePositions(bonds, molecule: fewer, options: o), "bond count mismatch")
            try expect(!AtomLayerBuilder.updatePositions(SCNNode(), molecule: m, options: o), "foreign node")
            // wireframe geometry refresh
            let wo = opts(.wireframe)
            let wb = buildBonds(m, wo)
            m.atoms[0].position += Vec3(0, 0, 5)
            try expect(BondLayerBuilder.updatePositions(wb, molecule: m, options: wo), "wire update")
            try expect(wb.childNodes.count == 1 && wb.childNodes[0].geometry != nil, "wire node kept")
            let src = wb.childNodes[0].geometry!.sources(for: .vertex)[0]
            try expect(src.vectorCount == 24, "wire vertices")
        },
        Check("render.scene.dash.update") {
            var m = RenderFixtures.water
            let o = opts { $0.dashedBonds = [AtomPair(0, 1)] }
            let bonds = buildBonds(m, o)
            m.atoms[1].position += Vec3(0.001, 0, 0)
            try expect(BondLayerBuilder.updatePositions(bonds, molecule: m, options: o), "tiny move keeps dash count")
            m.atoms[1].position += Vec3(6, 0, 0)
            try expect(!BondLayerBuilder.updatePositions(bonds, molecule: m, options: o), "dash count changes -> rebuild")
        },
        Check("render.scene.empty") {
            let m = Molecule()
            try expect(buildAtoms(m, opts()).childNodes.isEmpty && buildBonds(m, opts()).childNodes.isEmpty, "empty")
            var one = Molecule(); one.atoms = [Atom(id: 0, atomicNumber: 6, position: .zero)]
            try expect(geoNodes(buildAtoms(one, opts())).count == 1 && geoNodes(buildBonds(one, opts())).isEmpty, "single atom")
            // bond referring to coincident atoms must not crash
            var z = one; z.atoms.append(Atom(id: 1, atomicNumber: 6, position: .zero)); z.bonds = [Bond(0, 1, order: .double)]
            _ = buildBonds(z, opts())
        },
        Check("render.scene.perf.lattice10k") {
            let m = RenderFixtures.lattice(22)
            try expect(m.atoms.count == 10648, "fixture")
            let o = opts()
            let lib = MaterialLibrary()
            let t0 = Date()
            let a = buildAtoms(m, o, lib), b = buildBonds(m, o, lib)
            let dt = Date().timeIntervalSince(t0)
            print(String(format: "      lattice(22): %d atom nodes, %d bond nodes, build %.3f s", a.childNodes.count, b.childNodes.count, dt))
            try expect(a.childNodes.count == 10648, "atoms")
            try expect(dt < 5, "build time \(dt)")
            let t1 = Date()
            let okA = AtomLayerBuilder.updatePositions(a, molecule: m, options: o)
            let okB = BondLayerBuilder.updatePositions(b, molecule: m, options: o)
            print(String(format: "      updatePositions: %@ %@ %.3f s", "\(okA)", "\(okB)", Date().timeIntervalSince(t1)))
            try expect(okA, "atoms update")
        },
        Check("render.scene.renderer.integration") {
            try MainActor.assumeIsolated {
                let r = MoleculeRenderer(molecule: RenderFixtures.water)
                let A = MoleculeRenderer.layerNames.atoms, B = MoleculeRenderer.layerNames.bonds
                try expect(r.geometryNodeCount(layer: A) == 3 && r.geometryNodeCount(layer: B) == 4, "water ball&stick")
                var o = r.options; o.style = .spaceFilling; r.options = o
                try expect(r.geometryNodeCount(layer: A) == 3 && r.geometryNodeCount(layer: B) == 0, "space filling")
                o.style = .wireframe; r.options = o
                try expect(r.geometryNodeCount(layer: A) == 0 && r.geometryNodeCount(layer: B) == 1, "wireframe")
                o.style = .tube; r.options = o
                try expect(r.geometryNodeCount(layer: A) == 3 && r.geometryNodeCount(layer: B) == 4, "tube")
                o.showHydrogens = false; r.options = o
                try expect(r.geometryNodeCount(layer: A) == 1 && r.geometryNodeCount(layer: B) == 0, "hidden H")
                o.showHydrogens = true; o.style = .ballAndStick; o.material = .metallic; r.options = o
                try expect(r.geometryNodeCount(layer: A) == 3, "back")
                try expect(r.materials.preset == .metallic, "preset propagated")
                r.setMolecule(RenderFixtures.benzene)
                try expect(r.geometryNodeCount(layer: A) == 12 && r.geometryNodeCount(layer: B) == 30, "benzene")
                var pos = r.molecule.atoms.map(\.position)
                for i in pos.indices { pos[i] += Vec3(1, 1, 1) }
                r.updatePositions(pos)
                try expect(r.geometryNodeCount(layer: A) == 12 && r.geometryNodeCount(layer: B) == 30, "after update")
            }
        },
    ]
}
