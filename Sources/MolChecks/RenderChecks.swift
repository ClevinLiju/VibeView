import Foundation
import simd
import SceneKit
import MolCore
import MolAnalysis
import MolRender
import AppKit

// Lead 3 (Render). All check names start with "render." so `molscope-check render` selects them.
// Sub-suites: RenderChecks+Scene.swift (worker A), RenderChecks+Interaction.swift (worker B),
// RenderChecks+Media.swift (worker C). SceneKit/AppKit objects are created on the main thread;
// main-actor APIs are reached with MainActor.assumeIsolated (checks run on the main thread).
extension Checks {
    static let render: [Check] = renderCore + renderScene + renderInteraction + renderMedia + renderVisual
        + renderKekule + renderOrbitals + renderVibration + renderFeatures

    static let renderCore: [Check] = [
        Check("render.core.chargeColorMap") {
            let n = ColorMap.charge(-1, range: 1), z = ColorMap.charge(0, range: 1), p = ColorMap.charge(1, range: 1)
            try expect(n == ColorMap.negative && z == .white && p == ColorMap.positive, "endpoints \(n) \(z) \(p)")
            let half = ColorMap.charge(0.5, range: 1)
            try expectClose(half.r, (1 + ColorMap.positive.r) / 2, tol: 1e-12)
            try expect(ColorMap.charge(-5, range: 1) == ColorMap.negative, "clamped")
            try expect(ColorMap.charge(0.3, range: 0) == .white && ColorMap.charge(.nan, range: 1) == .white, "degenerate")
            // red component decreases monotonically from q=-1..1 on the blue side
            var last = 2.0
            for i in 0...20 { let c = ColorMap.charge(Double(i) / 20, range: 1); try expect(c.r <= last + 1e-12); last = c.r }
        },
        Check("render.core.atomColorsSchemes") {
            var o = RenderOptions()
            let w = RenderFixtures.water
            let el = RenderMetrics.atomColors(for: w, options: o)
            try expect(el.count == 3 && el[1] == el[2] && el[0] != el[1], "element colors")
            try expect(el[1] == ElementPalette.color(1))
            o.colorScheme = .charge(range: nil)       // auto range = 0.8
            let q = RenderMetrics.atomColors(for: w, options: o)
            try expect(q[0] == ColorMap.negative, "O most negative is full red, got \(q[0])")
            try expectClose(q[1].b, ColorMap.charge(0.4, range: 0.8).b)
            o.colorScheme = .uniform(.yellow)
            try expect(RenderMetrics.atomColors(for: w, options: o).allSatisfy { $0 == .yellow })
        },
        Check("render.core.elementPalette") {
            try expect(ElementPalette.symbol(6) == "C" && ElementPalette.symbol(8) == "O")
            try expect(ElementPalette.vdwRadius(1) > 1.0 && ElementPalette.vdwRadius(1) < ElementPalette.vdwRadius(6))
            try expect(ElementPalette.color(8).r > 0.8 && ElementPalette.color(8).g < 0.2, "O is red")
            try expect(ElementPalette.color(500).a == 1 && ElementPalette.vdwRadius(500) > 0, "out of range safe")
        },
        Check("render.core.metrics") {
            var o = RenderOptions()
            try expectClose(RenderMetrics.atomRadius(atomicNumber: 6, options: o), max(0.25 * ElementPalette.vdwRadius(6), 0.12 * 1.15))
            o.style = .spaceFilling
            try expectClose(RenderMetrics.atomRadius(atomicNumber: 6, options: o), ElementPalette.vdwRadius(6))
            try expect(RenderMetrics.bondRadius(options: o) == 0)
            try expect(!RenderMetrics.isBondVisible(Bond(0, 1), in: RenderFixtures.water, options: o))
            o.style = .tube
            try expect(RenderMetrics.atomRadius(atomicNumber: 1, options: o) == o.tubeRadius)
            o.showHydrogens = false
            try expect(!RenderMetrics.isBondVisible(Bond(0, 1), in: RenderFixtures.water, options: o))
            try expect(!RenderMetrics.isBondVisible(Bond(0, 7), in: RenderFixtures.water, options: RenderOptions()), "out of range bond")
        },
        Check("render.core.orientationMath") {
            for d in [Vec3(0, 1, 0), Vec3(0, -1, 0), Vec3(1, 0, 0), Vec3(0, 0, -2), Vec3(1, 2, 3), Vec3(-1e-3, -1, 1e-4)] {
                let q = RenderMath.orientationFromY(to: d)
                let r = q.act(SIMD3<Float>(0, 1, 0))
                let u = simd_normalize(d)
                try expect(simd_distance(SIMD3<Double>(r), u) < 1e-5, "Y -> \(d) gave \(r)")
                let p = RenderMath.perpendicular(to: u)
                try expect(abs(simd_dot(p, u)) < 1e-9 && abs(simd_length(p) - 1) < 1e-9)
            }
            try expect(RenderMath.orientationFromY(to: .zero).angle == 0)
        },
        Check("render.core.unitCell") {
            let c = UnitCell(a: 3, b: 4, c: 5, alpha: 90, beta: 90, gamma: 90)
            try expectClose(c.volume, 60, tol: 1e-9)
            try expect(c.corners.count == 8 && UnitCell.edges.count == 12)
            try expect(simd_distance(c.corners[7], Vec3(3, 4, 5)) < 1e-9)
            // every edge connects corners differing in exactly one lattice vector
            for (i, j) in UnitCell.edges { try expect((i ^ j).nonzeroBitCount == 1, "edge \(i)-\(j)") }
            let h = UnitCell(a: 2, b: 2, c: 3, alpha: 90, beta: 90, gamma: 120)   // hexagonal
            try expectClose(simd_length(h.b), 2, tol: 1e-12)
            try expectClose(acos(simd_dot(h.a, h.b) / 4) * 180 / .pi, 120, tol: 1e-9)
            try expectClose(h.volume, 2 * 2 * 3 * sin(120 * Double.pi / 180), tol: 1e-9)
            let tri = UnitCell(a: 5, b: 6, c: 7, alpha: 80, beta: 95, gamma: 105)
            try expectClose(simd_length(tri.c), 7, tol: 1e-9)
            try expectClose(acos(simd_dot(tri.b, tri.c) / 42) * 180 / .pi, 80, tol: 1e-9)
            try expectClose(acos(simd_dot(tri.a, tri.c) / 35) * 180 / .pi, 95, tol: 1e-9)
            let node = UnitCellLayerBuilder.build(cell: c, options: RenderOptions())
            var lines = 0, axes = 0
            node.enumerateHierarchy { n, _ in
                if n.name == "cell.edges", let el = n.geometry?.elements.first { lines = el.primitiveCount }
                if n.name?.hasPrefix("cell.axis.") == true { axes += 1 }
            }
            try expect(lines == 12 && axes == 3, "lines \(lines) axes \(axes)")
        },
        Check("render.core.rendererLifecycle") {
            try MainActor.assumeIsolated {
                var o = RenderOptions()
                o.unitCell = UnitCell(a: 10, b: 10, c: 10, alpha: 90, beta: 90, gamma: 90)
                let r = MoleculeRenderer(molecule: RenderFixtures.water, options: o)
                try expect(r.view.scene === r.scene && r.view.pointOfView === r.cameraNode, "view wiring")
                try expect(r.geometryNodeCount(layer: MoleculeRenderer.layerNames.cell) == 4, "cell edges + 3 axes")
                // bounds include the cell corners
                let b = r.boundingSphere()
                try expect(b.radius >= 10 * sqrt(3) / 2 - 1e-9, "bounds \(b.radius)")
                r.options.showUnitCell = false
                try expect(r.geometryNodeCount(layer: MoleculeRenderer.layerNames.cell) == 0)
                try expect(r.boundingSphere().radius < 3, "molecule-only bounds")
                // selection is clamped when the molecule shrinks
                r.selection = [0, 2]
                var got: Set<Int>? = nil
                r.onSelectionChange = { got = $0 }
                var m = RenderFixtures.water; m.atoms.removeLast(); m.bonds.removeLast()
                r.setMolecule(m)
                try expect(r.selection == [0] && got == [0], "selection clamp \(r.selection)")
                // updatePositions ignores wrong counts and applies right ones
                r.updatePositions([Vec3(1, 1, 1)])
                try expect(r.molecule.atoms[0].position == Vec3(0, 0, 0))
                r.updatePositions([Vec3(1, 1, 1), Vec3(2, 2, 2)])
                try expect(r.molecule.atoms[1].position == Vec3(2, 2, 2))
                // every layer container is attached exactly once under the root
                let names = r.scene.rootNode.childNode(withName: "molscope.root", recursively: false)?.childNodes.compactMap(\.name) ?? []
                try expect(Set(names).count == names.count, "duplicate layers \(names)")
                for n in [MoleculeRenderer.layerNames.atoms, MoleculeRenderer.layerNames.bonds, MoleculeRenderer.layerNames.highlight,
                          MoleculeRenderer.layerNames.labels, MoleculeRenderer.layerNames.measurements, MoleculeRenderer.layerNames.surfaces,
                          MoleculeRenderer.layerNames.cell, MoleculeRenderer.layerNames.vectors] {
                    try expect(names.contains(n), "missing layer \(n) in \(names)")
                }
            }
        },
        Check("render.core.environment") {
            try MainActor.assumeIsolated {
                let r = MoleculeRenderer(molecule: RenderFixtures.benzene)
                @MainActor func bg() -> NSColor? { (r.scene.background.contents as? NSColor)?.usingColorSpace(.sRGB) }
                r.options.theme = .dark
                try expect(abs((bg()?.redComponent ?? -1) - CGFloat(RenderTheme.dark.background.r)) < 1e-3, "dark bg")
                r.options.backgroundColor = RGBA(0.2, 0.4, 0.6)
                try expect(abs((bg()?.blueComponent ?? -1) - 0.6) < 1e-3, "custom bg")
                r.options.transparentBackground = true
                try expect((bg()?.alphaComponent ?? 1) == 0, "transparent bg")
                r.options.transparentBackground = false
                r.options.depthCueing = true
                r.fitToView(animated: false)
                try expect(r.scene.fogEndDistance > r.scene.fogStartDistance, "fog range \(r.scene.fogStartDistance)..\(r.scene.fogEndDistance)")
                r.options.depthCueing = false
                try expect(r.scene.fogEndDistance == 0, "fog off")
                r.options.ambientOcclusion = true
                try expect((r.cameraNode.camera?.screenSpaceAmbientOcclusionIntensity ?? 0) > 0, "SSAO on")
                r.options.material = .flat
                let lights = r.cameraNode.childNodes.compactMap(\.light)
                try expect(lights.count == 3 && lights.allSatisfy { $0.intensity == 0 }, "flat preset disables directional lights")
                r.options.material = .metallic
                try expect(r.scene.lightingEnvironment.contents != nil, "metallic uses environment")
                r.options.projection = .orthographic
                try expect(r.camera.projection == .orthographic)
            }
        },
    ]
}

/// Shared fixtures for render checks.
enum RenderFixtures {
    /// Water, O at origin, H in the xy plane.
    static var water: Molecule {
        var o = Atom(id: 0, atomicNumber: 8, position: Vec3(0, 0, 0))
        o.charge = -0.8
        var h1 = Atom(id: 1, atomicNumber: 1, position: Vec3(0.7572, 0.5865, 0)); h1.charge = 0.4
        var h2 = Atom(id: 2, atomicNumber: 1, position: Vec3(-0.7572, 0.5865, 0)); h2.charge = 0.4
        return Molecule(atoms: [o, h1, h2], bonds: [Bond(0, 1), Bond(0, 2)], title: "water")
    }
    /// Benzene in the xy plane with alternating double bonds and 6 H.
    static var benzene: Molecule {
        var atoms: [Atom] = []
        for i in 0..<6 {
            let t = Double(i) * .pi / 3
            atoms.append(Atom(id: i, atomicNumber: 6, position: Vec3(1.39 * cos(t), 1.39 * sin(t), 0)))
        }
        for i in 0..<6 {
            let t = Double(i) * .pi / 3
            atoms.append(Atom(id: 6 + i, atomicNumber: 1, position: Vec3(2.47 * cos(t), 2.47 * sin(t), 0)))
        }
        var bonds: [Bond] = []
        for i in 0..<6 { bonds.append(Bond(i, (i + 1) % 6, order: i % 2 == 0 ? .double : .single)) }
        for i in 0..<6 { bonds.append(Bond(i, 6 + i)) }
        return Molecule(atoms: atoms, bonds: bonds, title: "benzene")
    }
    /// Acetylene along x (triple bond).
    static var acetylene: Molecule {
        let a = [Atom(id: 0, atomicNumber: 1, position: Vec3(-1.66, 0, 0)), Atom(id: 1, atomicNumber: 6, position: Vec3(-0.6, 0, 0)),
                 Atom(id: 2, atomicNumber: 6, position: Vec3(0.6, 0, 0)), Atom(id: 3, atomicNumber: 1, position: Vec3(1.66, 0, 0))]
        return Molecule(atoms: a, bonds: [Bond(0, 1), Bond(1, 2, order: .triple), Bond(2, 3)], title: "acetylene")
    }
    /// n x n x n simple cubic lattice of carbon atoms 1.5 Å apart, bonded to +x/+y/+z neighbors.
    static func lattice(_ n: Int) -> Molecule {
        var atoms: [Atom] = [], bonds: [Bond] = []
        func idx(_ i: Int, _ j: Int, _ k: Int) -> Int { (i * n + j) * n + k }
        for i in 0..<n { for j in 0..<n { for k in 0..<n {
            atoms.append(Atom(id: idx(i, j, k), atomicNumber: 6, position: Vec3(Double(i), Double(j), Double(k)) * 1.5))
            if i + 1 < n { bonds.append(Bond(idx(i, j, k), idx(i + 1, j, k))) }
            if j + 1 < n { bonds.append(Bond(idx(i, j, k), idx(i, j + 1, k))) }
            if k + 1 < n { bonds.append(Bond(idx(i, j, k), idx(i, j, k + 1))) }
        }}}
        return Molecule(atoms: atoms, bonds: bonds, title: "lattice")
    }
}
