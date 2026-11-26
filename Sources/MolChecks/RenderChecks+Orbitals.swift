#if canImport(MolRender)  // SceneKit/AppKit/Metal render checks: macOS only
import Foundation
import MolSIMD
import SceneKit
import AppKit
import MolCore
import MolIO
import MolAnalysis
import MolRender

/// Unwelded octahedron-subdivision sphere (every triangle owns its vertices), radius 1, optional position-based noise.
private func orbSphere(level: Int, noise: Float) -> IsoSurfaceMesh {
    var tris: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = []
    let x = SIMD3<Float>(1, 0, 0), y = SIMD3<Float>(0, 1, 0), z = SIMD3<Float>(0, 0, 1)
    for sx in [Float(1), -1] { for sy in [Float(1), -1] { for sz in [Float(1), -1] {
        var t = (x * sx, y * sy, z * sz)
        if sx * sy * sz < 0 { t = (t.0, t.2, t.1) }
        tris.append(t)
    } } }
    for _ in 0..<level {
        var next: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = []
        for (a, b, c) in tris {
            let ab = simd_normalize(a + b), bc = simd_normalize(b + c), ca = simd_normalize(c + a)
            next += [(a, ab, ca), (ab, b, bc), (ca, bc, c), (ab, bc, ca)]
        }
        tris = next
    }
    func perturb(_ p: SIMD3<Float>) -> SIMD3<Float> {
        let n = noise * sin(37 * p.x + 11 * p.y) * cos(29 * p.z - 7 * p.x)
        return p * (1 + n)
    }
    var m = IsoSurfaceMesh()
    for (a, b, c) in tris {
        let base = UInt32(m.vertices.count)
        m.vertices += [perturb(a), perturb(b), perturb(c)]
        m.indices += [base, base + 1, base + 2]
    }
    return m
}

private func radialRMS(_ m: IsoSurfaceMesh) -> Double {
    let r = m.vertices.map { Double(simd_length($0)) }
    let mean = r.reduce(0, +) / Double(r.count)
    return (r.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(r.count)).squareRoot()
}

private func pngDir() -> URL? {
    guard let p = ProcessInfo.processInfo.environment["MOLSCOPE_PNG_DIR"], !p.isEmpty else { return nil }
    let u = URL(fileURLWithPath: p, isDirectory: true)
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

extension Checks {
    static let renderOrbitals: [Check] = [
        Check("render.orbital.weld") {
            let raw = orbSphere(level: 3, noise: 0)
            let w = IsosurfaceSmoothing.weld(raw)
            try expect(w.vertices.count < raw.vertices.count / 3, "weld \(raw.vertices.count) -> \(w.vertices.count)")
            // closed sphere: V - E + F = 2
            let e = IsosurfaceGeometry.uniqueEdges(w.indices).count / 2
            try expect(w.vertices.count - e + w.indices.count / 3 == 2, "euler")
            try expect(w.normals.count == w.vertices.count, "normals")
        },
        Check("render.orbital.normals") {
            let w = IsosurfaceSmoothing.weld(orbSphere(level: 3, noise: 0))
            let n = IsosurfaceSmoothing.smoothNormals(vertices: w.vertices, indices: w.indices)
            for (v, nn) in zip(w.vertices, n) {
                try expectClose(Double(simd_length(nn)), 1, tol: 1e-4)
                try expect(simd_dot(nn, simd_normalize(v)) > 0.99, "outward")
            }
        },
        Check("render.orbital.taubin") {
            let w = IsosurfaceSmoothing.weld(orbSphere(level: 4, noise: 0.04))
            let t = IsosurfaceSmoothing.taubin(w, iterations: 6)
            try expect(t.vertices.count == w.vertices.count && t.indices == w.indices, "topology kept")
            let v0 = IsosurfaceSmoothing.signedVolume(w), v1 = IsosurfaceSmoothing.signedVolume(t)
            try expect(abs(v1 - v0) / abs(v0) < 0.05, "volume \(v0) -> \(v1)")
            let r0 = radialRMS(w), r1 = radialRMS(t)
            try expect(r1 < r0 * 0.7, "roughness \(r0) -> \(r1)")
            // unwelded input is welded first
            let t2 = IsosurfaceSmoothing.taubin(orbSphere(level: 3, noise: 0.03), iterations: 2)
            try expect(t2.vertices.count < 1000, "welded in taubin")
            try expect(IsosurfaceSmoothing.taubin(w, iterations: 0) == w, "zero iterations identity")
        },
        Check("render.orbital.colors") {
            let o = OrbitalColorScheme.forOccupation(occupied: true), v = OrbitalColorScheme.forOccupation(occupied: false)
            try expect(o.positive.r > o.positive.b && o.negative.b > o.negative.r, "occupied red/blue")
            try expect(v.positive.g > v.positive.r && v.positive.g > v.positive.b, "virtual green positive")
            try expect(v.negative.r > 0.8 && v.negative.g > 0.6 && v.negative.b < 0.3, "virtual yellow negative")
            var s = Isosurface(id: "c", meshes: [], colors: .virtual)
            try expect(s.positiveColor == v.positive && s.negativeColor == v.negative, "init colors")
            s.apply(.occupied)
            try expect(s.positiveColor == o.positive, "apply")
            let data = try JSONEncoder().encode(o)
            try expect(try JSONDecoder().decode(OrbitalColorScheme.self, from: data) == o, "codable")
        },
        Check("render.orbital.modes") {
            try MainActor.assumeIsolated {
                var a = orbSphere(level: 2, noise: 0.01); a.sign = .positive
                var b = a; b.sign = .negative
                b.vertices = b.vertices.map { $0 + SIMD3<Float>(0, 0, 0.5) }
                var s = Isosurface(id: "m", meshes: [a, b])
                for mode in SurfaceDisplayMode.allCases {
                    s.mode = mode
                    let n = IsosurfaceNodeBuilder.build(s)
                    try expect(n.childNodes.count == 2, "\(mode) lobes")
                    try expect(n.childNodes.allSatisfy { $0.geometry != nil }, "\(mode) geometry")
                }
                s.mode = .wireframe
                let wf = IsosurfaceNodeBuilder.build(s).childNodes[0].geometry!
                try expect(wf.elements[0].primitiveType == .line, "wireframe lines")
                let welded = IsosurfaceSmoothing.weld(a)
                try expect(wf.elements[0].primitiveCount == IsosurfaceGeometry.uniqueEdges(welded.indices).count / 2, "unique edges")
                s.mode = .points
                try expect(IsosurfaceNodeBuilder.build(s).childNodes[0].geometry!.elements[0].primitiveType == .point, "points")
                s.mode = .transparent
                let tn = IsosurfaceNodeBuilder.build(s).childNodes[0]
                try expect(tn.childNode(withName: "lobe.back", recursively: false) != nil, "back pass")
                try expect(!tn.geometry!.firstMaterial!.writesToDepthBuffer, "no depth write")
                s.mode = .solid
                try expect(IsosurfaceNodeBuilder.build(s).childNodes[0].geometry!.firstMaterial!.writesToDepthBuffer, "solid opaque")
            }
        },
        Check("render.orbital.png") {
            guard let dir = pngDir() else { return }
            guard let wf = try MoldenFile.read(url: testDataURL("io/orca/h2co_tddft.molden.input")).wavefunction else {
                throw CheckFailure(description: "no wavefunction")
            }
            let homo = wf.homoIndex!
            let pos = WavefunctionSurfaces.atomPositions(wf)
            var mol = Molecule(atoms: pos.enumerated().map { Atom(id: $0.offset, atomicNumber: wf.atomicNumbers[$0.offset], position: $0.element) })
            mol.perceiveBonds()
            let spec = GridSpec.automatic(around: pos, padding: 4, spacing: 0.15)
            for (name, mo, occ) in [("homo", homo, true), ("lumo", homo + 1, false)] {
                let grid = WavefunctionSurfaces.orbitalGrid(wf, mo: mo, spin: .alpha, grid: spec)
                let lobes = MarchingCubes.orbitalLobes(grid: grid, isovalue: 0.04)
                try expect(!lobes.isEmpty, "\(name) lobes")
                try MainActor.assumeIsolated {
                    let r = MoleculeRenderer(molecule: mol)
                    r.fitToView(animated: false)
                    for mode in SurfaceDisplayMode.allCases {
                        var s = Isosurface(id: name, meshes: lobes, colors: .forOccupation(occupied: occ))
                        s.mode = mode
                        r.setIsosurface(s)
                        // Oblique 3/4 view (not down the C=O axis), framed on atoms + lobes.
                        r.camera.setStandardView(.front, animated: false)
                        r.camera.orbit(dx: 70, dy: 45)
                        r.fitToView(animated: false)
                        var o = ImageExportOptions(); o.widthPoints = 900; o.heightPoints = 700; o.dpi = 72
                        try r.exportImage(to: dir.appendingPathComponent("orbital_\(name)_\(mode.rawValue).png"), options: o)
                    }
                }
            }
        },
    ]
}

#endif  // canImport(MolRender)
