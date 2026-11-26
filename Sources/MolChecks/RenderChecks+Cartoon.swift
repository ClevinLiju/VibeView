import Foundation
import SceneKit
import ImageIO
import AVFoundation
import MolCore
import MolIO
import MolAnalysis
@testable import MolRender

// Cartoon style on hemoglobin (4HHB chains A+B), and the turntable / extended animation exports.
extension Checks {
    static let renderCartoon: [Check] = [
        Check("render.cartoon.4hhb.build") {
            let m = try ProteinFixture.molecule()
            let rec = PDBProteinRecords.parse(ProteinFixture.text)
            try MainActor.assumeIsolated {
                let r = MoleculeRenderer(molecule: m)
                r.proteinRecords = rec
                var o = r.options; o.style = .cartoon; r.options = o
                let mask = r.options.atomMask
                try expect(mask.state.count == m.atoms.count, "no mask in cartoon style")
                let p = r.protein!
                try expect(p.residueCount == 287 && p.ssSource == .file)
                // Visible: the two hemes and the phosphate P (water hidden), drawn as atoms; CAs are pickable stand-ins.
                let shown = AtomLayerBuilder.displayedAtoms(molecule: m, options: r.options)
                try expect(shown.count == 87, "atoms drawn \(shown.count)")
                try expect(p.residues.allSatisfy { mask.isStandIn($0.ca) })
                try expect(r.geometryNodeCount(layer: MoleculeRenderer.layerNames.cartoon) == 2, "one mesh per chain")
                let st = r.cartoonStats
                try expect(st.segments == 2 && st.residues == 287 && st.vertices > 285 * 10 * 16 && st.triangles > st.vertices, "\(st)")
                // Every bond drawn touches only visible atoms.
                let segs = BondGeometry.renderSegments(molecule: m, options: r.options, colors: r.currentColors)
                try expect(!segs.isEmpty && segs.allSatisfy { !mask.isHidden(m.bonds[$0.bondIndex].a) && !mask.isHidden(m.bonds[$0.bondIndex].b) })
                // Colors: secondary structure = helix + loop materials; by chain = two.
                @MainActor func materials() -> Set<String> {
                    var s = Set<String>()
                    r.root.childNode(withName: MoleculeRenderer.layerNames.cartoon, recursively: false)?.enumerateHierarchy { n, _ in
                        for mat in n.geometry?.materials ?? [] { s.insert("\((mat.diffuse.contents as? NSColor)?.description ?? "")") }
                    }
                    return s
                }
                try expect(materials().count == 2, "ss materials \(materials())")
                o = r.options; o.cartoonColoring = .chain; r.options = o
                try expect(materials().count == 2, "chain materials")
                // Water shown again on request; back to ball-and-stick clears everything.
                o = r.options; o.cartoonHidesWater = false; r.options = o
                try expect(AtomLayerBuilder.displayedAtoms(molecule: m, options: r.options).count == 87 + 113)
                o = r.options; o.style = .ballAndStick; r.options = o
                try expect(r.options.atomMask.state.isEmpty)
                try expect(r.geometryNodeCount(layer: MoleculeRenderer.layerNames.cartoon) == 0)
                try expect(AtomLayerBuilder.displayedAtoms(molecule: m, options: r.options).count == m.atoms.count)
                // Picking a CA stand-in through the ribbon.
                o = r.options; o.style = .cartoon; r.options = o
                let ca = p.residues[40].ca, c = m.atoms[ca].position
                let hit = PickMath.pick(origin: c + Vec3(0, 0, 50), dir: Vec3(0, 0, -1), molecule: m, options: r.options)
                if case .atom(let i)? = hit?.0 { try expect(!mask.isHidden(i) || mask.isStandIn(i), "picked hidden atom \(i)") }
                else { throw CheckFailure(description: "nothing picked over a CA") }
            }
        },
        Check("render.cartoon.boxSelectHonoursMask") {
            // Rubber-band selection over the whole view picks what click picking and the lasso can pick: the CA
            // stand-ins and the atoms still drawn, never the atoms hidden under the cartoon.
            let m = try ProteinFixture.molecule()
            let rec = PDBProteinRecords.parse(ProteinFixture.text)
            try MainActor.assumeIsolated {
                let r = MoleculeRenderer(molecule: m)
                r.proteinRecords = rec
                r.fitToView(animated: false)
                let everything = r.atomsInViewRect(r.view.bounds)
                try expect(everything.count > m.atoms.count / 2, "ball-and-stick box \(everything.count)")
                var o = r.options; o.style = .cartoon; r.options = o
                r.fitToView(animated: false)
                let mask = r.options.atomMask, p = r.protein!
                let boxed = r.atomsInViewRect(r.view.bounds)
                let hidden = boxed.filter { mask.isHidden($0) && !mask.isStandIn($0) }
                try expect(hidden.isEmpty, "\(hidden.count) atoms hidden under the cartoon were boxed")
                try expect(boxed.allSatisfy { RenderMetrics.isAtomPickable($0, in: m, options: r.options) }, "unpickable atom boxed")
                let cas = Set(p.residues.map(\.ca).filter { $0 >= 0 })
                try expect(cas.isSubset(of: boxed), "CA stand-ins missing: \(cas.subtracting(boxed).count)")
                try expect(boxed.count < everything.count, "cartoon box \(boxed.count) vs \(everything.count)")
                // The built-in selection path gives the same set.
                r.selection = []
                r.performBoxSelect(from: .zero, to: CGPoint(x: r.view.bounds.maxX, y: r.view.bounds.maxY))
                try expect(r.selection == boxed, "box selection \(r.selection.count) vs \(boxed.count)")
            }
        },
        Check("render.cartoon.4hhb.timing") {
            // VIBEVIEW_CHECK_PDB=<file> times another structure (e.g. the full 4HHB tetramer) instead of the fixture.
            let path = ProcessInfo.processInfo.environment["VIBEVIEW_CHECK_PDB"]
            let text = try path.map { try String(contentsOfFile: $0, encoding: .utf8) } ?? ProteinFixture.text
            var m = try PDBFormat.parse(text).models[0]
            m.renumberAtomIDs(); m.perceiveBonds()
            try MainActor.assumeIsolated {
                let tStart = CFAbsoluteTimeGetCurrent()
                let r = MoleculeRenderer(molecule: m)
                r.proteinRecords = PDBProteinRecords.parse(text)
                var o = r.options; o.style = .cartoon; r.options = o
                let first = CFAbsoluteTimeGetCurrent() - tStart
                print(String(format: "    %@ (%d atoms, %d residues): renderer + analysis + first cartoon %.1f ms", path ?? "4HHB A+B", m.atoms.count,
                             r.protein?.residueCount ?? 0, first * 1000))
                var builds: [Double] = []
                for k in 0..<3 {
                    var p = m.atoms.map(\.position); p[0].x += 0.01 * Double(k + 1)
                    r.updatePositions(p)          // rebuilds the cartoon (trajectory frames)
                    builds.append(r.cartoonStats.seconds)
                }
                r.fitToView(animated: false)
                var e = ImageExportOptions.pixels(width: 1280, height: 800, dpi: 72); e.supersampling = 1
                _ = try r.renderImage(e)            // warm-up (shader compilation)
                let t0 = CFAbsoluteTimeGetCurrent()
                for _ in 0..<5 { _ = try r.renderImage(e) }
                let frame = (CFAbsoluteTimeGetCurrent() - t0) / 5
                let b = builds.min()!
                print(String(format: "    cartoon (debug build): mesh %.1f ms (%d verts, %d tris), offscreen 1280x800 frame %.1f ms",
                             b * 1000, r.cartoonStats.vertices, r.cartoonStats.triangles, frame * 1000))
                try expect(b < 1.0 && frame < 2.0, "too slow: build \(b) s, frame \(frame) s")
            }
        },
        Check("render.cartoon.strandArrow") {
            // Force a strand on residues 10…19 of chain A: the section widens to the arrowhead, then narrows to a tube.
            let m = try ProteinFixture.molecule()
            var p = ProteinAnalysis.analyze(m, records: PDBProteinRecords.parse(ProteinFixture.text))
            for k in 10...19 { p.ss[k] = .strand }
            let seg = p.segments[0]
            let colors = CartoonLayerBuilder.residueColors(p, options: RenderOptions())
            var cosA = [Double](), sinA = [Double]()
            for k in 0..<16 { cosA.append(cos(Double(k) / 16 * 2 * .pi)); sinA.append(sin(Double(k) / 16 * 2 * .pi)) }
            let mesh = CartoonLayerBuilder.segmentMesh(p, seg: seg, positions: m.atoms.map(\.position), colors: colors, S: 10, cosA: cosA, sinA: sinA)
            try expect(mesh.slot.keys.contains(CartoonLayerBuilder.strandColor))
            // Ring widths: max distance between vertices of one ring.
            let ringCount = (mesh.verts.count - 2 * 17) / 16
            var widths: [Float] = []
            for k in 0..<ringCount {
                let ring = mesh.verts[(k * 16)..<(k * 16 + 16)]
                var w: Float = 0
                for a in ring { for b in ring { w = max(w, simd_distance(a, b)) } }
                widths.append(w)
            }
            let maxW = widths.max() ?? 0
            try expect(abs(maxW - 3.3) < 0.1, "arrowhead width \(maxW)")               // 2 × 1.65 Å
            try expect(widths.min()! > 0.55 && widths.min()! < 0.65, "loop tube \(widths.min()!)") // 2 × 0.3 Å
            // Normals are unit length and the mesh has no NaNs.
            try expect(mesh.normals.allSatisfy { abs(simd_length($0) - 1) < 1e-3 } && mesh.verts.allSatisfy { $0.x.isFinite })
        },
        Check("render.cartoon.nonProteinIsBallAndStick") {
            try MainActor.assumeIsolated {
                let r = MoleculeRenderer(molecule: RenderFixtures.benzene)
                var o = r.options; o.style = .cartoon; r.options = o
                try expect(r.protein?.isEmpty == true && r.geometryNodeCount(layer: MoleculeRenderer.layerNames.cartoon) == 0)
                try expect(r.geometryNodeCount(layer: MoleculeRenderer.layerNames.atoms) == 12)
                try expect(abs(RenderMetrics.atomRadius(atomicNumber: 6, options: o)
                               - RenderMetrics.atomRadius(atomicNumber: 6, options: RenderOptions())) < 1e-12)
            }
            // The mask never changes the options' identity (and is never persisted).
            var a = RenderOptions(); a.atomMask = AtomVisibilityMask(state: [1, 1])
            try expect(a == RenderOptions())
            let data = try JSONEncoder().encode(a)
            let back = try JSONDecoder().decode(RenderOptions.self, from: data)
            try expect(back.atomMask.state.isEmpty)
        },
        Check("render.media.spin.gifAndMP4") {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vibeview-spin-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let gif = dir.appendingPathComponent("spin.gif"), mp4 = dir.appendingPathComponent("spin.mp4")
            try MainActor.assumeIsolated {
                let r = MoleculeRenderer(molecule: RenderFixtures.benzene)
                r.fitToView(animated: false)
                let cam0 = r.camera.state
                let o = ImageExportOptions.pixels(width: 96, height: 64, dpi: 72)
                try AnimationExporter.exportSpin(renderer: r, url: gif, frameCount: 12, fps: 12, format: .gif, options: o)
                try expect(r.camera.state == cam0, "camera restored")
                try AnimationExporter.exportSpin(renderer: r, url: mp4, frameCount: 12, fps: 12, format: .mp4, quality: 0.5, options: o)
            }
            guard let src = CGImageSourceCreateWithURL(gif as CFURL, nil) else { throw CheckFailure(description: "gif unreadable") }
            try expect(CGImageSourceGetCount(src) == 12, "gif frames \(CGImageSourceGetCount(src))")
            let img = CGImageSourceCreateImageAtIndex(src, 3, nil)
            try expect(img?.width == 96 && img?.height == 64)
            let asset = AVURLAsset(url: mp4)
            let tracks = asset.tracks(withMediaType: .video)
            try expect(tracks.count == 1 && tracks[0].naturalSize == CGSize(width: 96, height: 64), "mp4 track \(tracks.map(\.naturalSize))")
            let frames = Int((CMTimeGetSeconds(asset.duration) * 12).rounded())
            try expect(frames == 12, "mp4 duration \(CMTimeGetSeconds(asset.duration)) s")
        },
    ]
}
