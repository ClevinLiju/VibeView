import Foundation
import simd
import SceneKit
import AppKit
import ImageIO
import MolCore
import MolAnalysis
import MolRender

extension Checks {
    static let renderMedia: [Check] = [
        Check("render.media.png.offscreen") {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("vibeview-\(UUID().uuidString).png")
            defer { try? FileManager.default.removeItem(at: tmp) }
            try MainActor.assumeIsolated {
                let r = MoleculeRenderer(molecule: RenderFixtures.water)
                r.fitToView(animated: false)
                var o = ImageExportOptions(); o.widthPoints = 400; o.heightPoints = 300; o.dpi = 144
                try r.exportImage(to: tmp, options: o)
            }
            let size = (try FileManager.default.attributesOfItem(atPath: tmp.path)[.size] as? Int) ?? 0
            try expect(size > 0, "empty file")
            guard let src = CGImageSourceCreateWithURL(tmp as CFURL, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw CheckFailure(description: "cannot read back") }
            try expect(img.width == 800 && img.height == 600, "size \(img.width)x\(img.height)")
            try expectClose((props[kCGImagePropertyDPIWidth] as? Double) ?? 0, 144, tol: 0.5)
            let px = try rgba(img)
            let corner = px(2, 2), center = px(400, 300)
            var differs = false
            for dx in stride(from: -60, through: 60, by: 4) { for dy in stride(from: -60, through: 60, by: 4) where px(400 + dx, 300 + dy) != corner { differs = true } }
            try expect(differs, "image uniform: corner \(corner) center \(center)")
        },
        Check("render.media.png.transparent") {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("vibeview-\(UUID().uuidString).png")
            defer { try? FileManager.default.removeItem(at: tmp) }
            try MainActor.assumeIsolated {
                let r = MoleculeRenderer(molecule: RenderFixtures.water)
                r.fitToView(animated: false)
                var o = ImageExportOptions(); o.widthPoints = 200; o.heightPoints = 150; o.dpi = 72; o.transparentBackground = true
                try r.exportImage(to: tmp, options: o)
                // scene background restored afterwards
                try expect(!(r.scene.background.contents as? NSColor).map { $0.alphaComponent == 0 }!, "background not restored")
            }
            guard let src = CGImageSourceCreateWithURL(tmp as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
                throw CheckFailure(description: "cannot read back")
            }
            let px = try rgba(img)
            try expect(px(1, 1)[3] == 0, "corner alpha \(px(1, 1)[3])")
            var maxA: UInt8 = 0
            for dx in -20...20 { for dy in -20...20 { maxA = max(maxA, px(100 + dx, 75 + dy)[3]) } }
            try expect(maxA > 0, "no opaque pixels near center")
        },
        Check("render.media.tiff.export") {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("vibeview-\(UUID().uuidString).tiff")
            defer { try? FileManager.default.removeItem(at: tmp) }
            try MainActor.assumeIsolated {
                let r = MoleculeRenderer(molecule: RenderFixtures.benzene)
                r.fitToView(animated: false)
                var o = ImageExportOptions(); o.widthPoints = 100; o.heightPoints = 80; o.dpi = 72; o.format = .tiff
                try r.exportImage(to: tmp, options: o)
            }
            guard let src = CGImageSourceCreateWithURL(tmp as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
                throw CheckFailure(description: "tiff unreadable")
            }
            try expect(img.width == 100 && img.height == 80, "tiff size \(img.width)x\(img.height)")
        },
        Check("render.media.image.aspect") {
            // a wide export must not be stretched: water's H-H distance (1.51 A) vs O-H height ratio is preserved
            try MainActor.assumeIsolated {
                let r = MoleculeRenderer(molecule: RenderFixtures.water)
                r.fitToView(animated: false)
                var o = ImageExportOptions(); o.widthPoints = 400; o.heightPoints = 100; o.dpi = 72
                let a = try r.renderImage(o)
                o.widthPoints = 100; o.heightPoints = 400
                let b = try r.renderImage(o)
                try expect(a.width == 400 && a.height == 100 && b.width == 100 && b.height == 400, "sizes")
                func bbox(_ img: CGImage) throws -> (w: Int, h: Int) {
                    let px = try rgba(img); let bg = px(0, 0)
                    var x0 = img.width, x1 = 0, y0 = img.height, y1 = 0
                    for y in 0..<img.height { for x in 0..<img.width where px(x, y) != bg {
                        x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y) } }
                    return (x1 - x0, y1 - y0)
                }
                let ba = try bbox(a), bb = try bbox(b)
                try expect(ba.w > 0 && bb.h > 0, "empty render")
                // wide image: molecule must be (nearly) circular-proportioned: width/height ratio ~ same in both orientations
                let ra = Double(ba.w) / Double(max(1, ba.h)), rb = Double(bb.w) / Double(max(1, bb.h))
                try expect(abs(ra - rb) < 0.35 * max(ra, rb), "aspect distorted: \(ra) vs \(rb)")
            }
        },
        Check("render.media.gif.export") {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("vibeview-\(UUID().uuidString).gif")
            defer { try? FileManager.default.removeItem(at: tmp) }
            let base = RenderFixtures.water
            try MainActor.assumeIsolated {
                let r = MoleculeRenderer(molecule: base)
                r.fitToView(animated: false)
                var o = ImageExportOptions(); o.widthPoints = 80; o.heightPoints = 60; o.dpi = 72
                var seen: [Int] = []
                try AnimationExporter.exportGIF(renderer: r, url: tmp, frameCount: 4, fps: 10, loopCount: 0, options: o) { i in
                    seen.append(i)
                    var p = base.atoms.map(\.position); p[1].y += 0.1 * Double(i); r.updatePositions(p)
                }
                try expect(seen == [0, 1, 2, 3], "prepare order \(seen)")
            }
            guard let src = CGImageSourceCreateWithURL(tmp as CFURL, nil) else { throw CheckFailure(description: "gif unreadable") }
            try expect(CGImageSourceGetCount(src) == 4, "gif frames \(CGImageSourceGetCount(src))")
        },
        Check("render.media.movie.export") {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("vibeview-\(UUID().uuidString).mov")
            defer { try? FileManager.default.removeItem(at: tmp) }
            try MainActor.assumeIsolated {
                let r = MoleculeRenderer(molecule: RenderFixtures.water)
                r.fitToView(animated: false)
                var o = ImageExportOptions(); o.widthPoints = 101; o.heightPoints = 75; o.dpi = 72
                try AnimationExporter.exportMovie(renderer: r, url: tmp, frameCount: 5, fps: 10, options: o) { _ in }
            }
            let size = (try FileManager.default.attributesOfItem(atPath: tmp.path)[.size] as? Int) ?? 0
            try expect(size > 0, "empty movie")
        },
        Check("render.media.vibration.export.restores") {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("vibeview-\(UUID().uuidString).gif")
            defer { try? FileManager.default.removeItem(at: tmp) }
            try MainActor.assumeIsolated {
                let r = MoleculeRenderer(molecule: RenderFixtures.water)
                r.fitToView(animated: false)
                let before = r.molecule.atoms.map(\.position)
                let mode = NormalMode(frequency: 1000, irIntensity: 1, displacements: [Vec3(0, 0.1, 0), Vec3(0.3, -0.2, 0), Vec3(-0.3, -0.2, 0)])
                var o = ImageExportOptions(); o.widthPoints = 60; o.heightPoints = 40; o.dpi = 72
                try AnimationExporter.exportVibration(renderer: r, mode: mode, url: tmp, framesPerCycle: 4, cycles: 1, amplitude: 1, format: .gif, options: o)
                try expect(r.molecule.atoms.map(\.position) == before, "positions not restored")
            }
            guard let src = CGImageSourceCreateWithURL(tmp as CFURL, nil) else { throw CheckFailure(description: "gif unreadable") }
            try expect(CGImageSourceGetCount(src) == 4, "frames")
        },
        Check("render.media.iso.nodeStructure") {
            try MainActor.assumeIsolated {
                let tet = mediaTetra(.positive), tetN = mediaTetra(.negative)
                var s = Isosurface(id: "t", positive: tet, negative: tetN)
                s.opacity = 1
                let n = IsosurfaceNodeBuilder.build(s)
                try expect(n.name == "surface:t", "name")
                try expect(n.childNodes.count == 2, "lobes \(n.childNodes.count)")
                let pos = n.childNode(withName: "lobe.positive", recursively: false)!
                let neg = n.childNode(withName: "lobe.negative", recursively: false)!
                try expect(pos.geometry!.elements[0].primitiveType == .triangles, "solid primitive")
                try expect(pos.geometry!.elements[0].primitiveCount == 4, "tri count")
                let cp = pos.geometry!.firstMaterial!.diffuse.contents as! NSColor
                let cn = neg.geometry!.firstMaterial!.diffuse.contents as! NSColor
                try expectClose(Double(cp.blueComponent), s.positiveColor.b, tol: 0.02)
                try expectClose(Double(cn.redComponent), s.negativeColor.r, tol: 0.02)
                try expect(pos.geometry!.firstMaterial!.writesToDepthBuffer, "opaque writes depth")
                s.opacity = 0.5
                let t = IsosurfaceNodeBuilder.build(s).childNodes[0].geometry!.firstMaterial!
                try expect(!t.writesToDepthBuffer && t.isDoubleSided && t.transparencyMode == .dualLayer, "transparency settings")
                try expectClose(Double(t.transparency), 0.5, tol: 1e-6)
                try expect(IsosurfaceNodeBuilder.build(s).childNodes[0].renderingOrder > 0, "rendering order")
            }
        },
        Check("render.media.iso.modes") {
            let m = mediaTetra(.positive)
            let solid = IsosurfaceGeometry.geometry(for: m, mode: .solid)!
            try expect(solid.elements[0].primitiveCount == m.indices.count / 3, "solid count")
            let mesh = IsosurfaceGeometry.geometry(for: m, mode: .mesh)!
            try expect(mesh.elements[0].primitiveType == .line && mesh.elements[0].primitiveCount == 6, "tetra lines \(mesh.elements[0].primitiveCount)")
            try expect(IsosurfaceGeometry.uniqueEdges(m.indices).count == 12, "uniqueEdges")
            let pts = IsosurfaceGeometry.geometry(for: m, mode: .points)!
            try expect(pts.elements[0].primitiveType == .point && pts.elements[0].primitiveCount == m.vertices.count, "points")
            try expect(pts.elements[0].pointSize > 0 && pts.elements[0].maximumPointScreenSpaceRadius > 0, "point size")
        },
        Check("render.media.iso.vertexColors") {
            var m = mediaTetra(.positive)
            m.vertexColors = Array(repeating: SIMD4<Float>(1, 0, 0, 1), count: 4)
            let g = IsosurfaceGeometry.geometry(for: m, mode: .solid)!
            try expect(!g.sources(for: .color).isEmpty, "color source missing")
            try MainActor.assumeIsolated {
                var s = Isosurface(id: "c", meshes: [m]); s.opacity = 1
                let c = IsosurfaceNodeBuilder.build(s).childNodes[0].geometry!.firstMaterial!.diffuse.contents as! NSColor
                try expectClose(Double(c.redComponent), 1, tol: 0.01); try expectClose(Double(c.blueComponent), 1, tol: 0.01)
            }
        },
        Check("render.media.iso.robust") {
            try MainActor.assumeIsolated {
                // empty meshes
                var s = Isosurface(id: "e", meshes: [IsoSurfaceMesh(), IsoSurfaceMesh(sign: .negative)])
                try expect(IsosurfaceNodeBuilder.build(s).childNodes.isEmpty, "empty -> no children")
                // bad indices and mismatched normals
                var bad = mediaTetra(.positive)
                bad.indices += [0, 1, 99, 2, 3]
                bad.normals = [SIMD3<Float>(0, 0, 1)]
                s = Isosurface(id: "b", meshes: [bad])
                for mode in SurfaceDisplayMode.allCases {
                    s.mode = mode
                    let n = IsosurfaceNodeBuilder.build(s)
                    try expect(n.childNodes.count == 1, "bad mesh \(mode)")
                }
                s.mode = .solid
                try expect(IsosurfaceNodeBuilder.build(s).childNodes[0].geometry!.elements[0].primitiveCount == 4, "bad tris dropped")
                // only invalid indices
                var allBad = mediaTetra(.positive); allBad.indices = [7, 8, 9]
                try expect(IsosurfaceNodeBuilder.build(Isosurface(id: "x", meshes: [allBad])).childNodes.isEmpty, "all-bad -> none")
            }
        },
        Check("render.media.iso.renderer") {
            try MainActor.assumeIsolated {
                let r = MoleculeRenderer(molecule: RenderFixtures.water)
                let layer = MoleculeRenderer.layerNames.surfaces
                try expect(r.geometryNodeCount(layer: layer) == 0, "initial")
                r.setIsosurface(Isosurface(id: "a", positive: mediaTetra(.positive), negative: mediaTetra(.negative)))
                try expect(r.geometryNodeCount(layer: layer) == 2, "after set \(r.geometryNodeCount(layer: layer))")
                r.setIsosurface(Isosurface(id: "a", positive: mediaTetra(.positive), negative: nil))
                try expect(r.geometryNodeCount(layer: layer) == 1, "replace")
                r.setIsosurface(Isosurface(id: "b", positive: mediaTetra(.positive), negative: nil))
                try expect(r.geometryNodeCount(layer: layer) == 2, "two surfaces")
                r.removeIsosurface(id: "a")
                try expect(r.geometryNodeCount(layer: layer) == 1, "after remove")
                var hidden = Isosurface(id: "h", positive: mediaTetra(.positive), negative: nil); hidden.visible = false
                r.setIsosurface(hidden)
                try expect(r.geometryNodeCount(layer: layer) == 1, "hidden")
                r.removeAllIsosurfaces()
                try expect(r.geometryNodeCount(layer: layer) == 0, "removeAll")
            }
        },
        Check("render.media.vibration.math") {
            let base = [Vec3(0, 0, 0), Vec3(1, 0, 0)]
            let d = [Vec3(0, 1, 0), Vec3(0, -2, 0)]
            let mode = NormalMode(frequency: 1, irIntensity: 0, displacements: d)
            let p0 = VibrationMath.displaced(base: base, mode: mode, amplitude: 0.5, phase: 0)
            try expect(p0 == base, "phase 0")
            let p1 = VibrationMath.displaced(base: base, mode: mode, amplitude: 0.5, phase: .pi / 2)
            try expectClose(p1[0].y, 0.5, tol: 1e-12); try expectClose(p1[1].y, -1, tol: 1e-12)
            let pm = VibrationMath.displaced(base: base, mode: mode, amplitude: 0.5, phase: 3 * .pi / 2)
            try expectClose(pm[1].y, 1, tol: 1e-12)
            try expect(VibrationMath.displaced(base: [Vec3(0, 0, 0)], mode: mode, amplitude: 1, phase: 1) == [Vec3(0, 0, 0)], "mismatch guard")
        },
        Check("render.media.vibration.animator") {
            try MainActor.assumeIsolated {
                let r = MoleculeRenderer(molecule: RenderFixtures.water)
                let base = r.molecule.atoms.map(\.position)
                let mode = NormalMode(frequency: 1, irIntensity: 0, displacements: [Vec3(0, 0.1, 0), Vec3(0.3, 0, 0), Vec3(-0.3, 0, 0)])
                let a = r.vibration!
                a.amplitude = 2; a.cyclesPerSecond = 1
                a.tick(time: 0.25)   // not playing: no-op
                try expect(r.molecule.atoms.map(\.position) == base, "tick while stopped")
                a.play(mode)
                try expect(a.isPlaying, "playing")
                a.tick(time: 0.25)   // sin(pi/2) = 1
                let pos = r.molecule.atoms.map(\.position)
                try expectClose(pos[1].x, base[1].x + 0.6, tol: 1e-9)
                try expectClose(pos[0].y, base[0].y + 0.2, tol: 1e-9)
                a.play(mode)         // restarting restores first
                try expect(r.molecule.atoms.map(\.position) == base, "restart restores")
                a.tick(time: 0.1)
                a.stop()
                try expect(!a.isPlaying && a.mode == nil, "stopped")
                try expect(r.molecule.atoms.map(\.position) == base, "stop restores exactly")
                // wrong atom count is rejected
                a.play(NormalMode(frequency: 1, irIntensity: 0, displacements: [Vec3(1, 0, 0)]))
                try expect(!a.isPlaying, "mismatch rejected")
            }
        },
        Check("render.media.arrows") {
            try MainActor.assumeIsolated {
                let w = RenderFixtures.water
                let mode = NormalMode(frequency: 1, irIntensity: 0, displacements: [Vec3(0, 0.01, 0), Vec3(0.3, 0, 0), Vec3(0, 0, -0.4)])
                let arrows = DisplacementArrowBuilder.arrows(molecule: w, mode: mode, scale: 2)
                try expect(arrows.map(\.atom) == [1, 2], "skip short: \(arrows.map(\.atom))")
                try expectClose(arrows[0].end.x, w.atoms[1].position.x + 0.6, tol: 1e-12)
                try expectClose(arrows[1].end.z, -0.8, tol: 1e-12)
                let n = DisplacementArrowBuilder.build(molecule: w, mode: mode, scale: 2, color: .green)
                try expect(n.name == "vibeview.vectors", "name")
                try expect(n.childNodes.map(\.name) == ["arrow:1", "arrow:2"], "children")
                let a = n.childNodes[0]
                try expectClose(Double(a.position.x), w.atoms[1].position.x, tol: 1e-5)
                // arrow's local +Y maps to the displacement direction (+x)
                let tip = a.convertPosition(SCNVector3(0, 1, 0), to: n)
                try expectClose(Double(tip.x - a.position.x), 1, tol: 1e-4)
                try expectClose(Double(tip.y - a.position.y), 0, tol: 1e-4)
                // through the renderer
                let r = MoleculeRenderer(molecule: w)
                r.showDisplacementArrows(mode, scale: 2)
                try expect(r.geometryNodeCount(layer: MoleculeRenderer.layerNames.vectors) == 4, "geometry nodes")
                r.showDisplacementArrows(nil)
                try expect(r.geometryNodeCount(layer: MoleculeRenderer.layerNames.vectors) == 0, "hidden")
            }
        },
        Check("render.media.trajectory") {
            try MainActor.assumeIsolated {
                let r = MoleculeRenderer(molecule: RenderFixtures.water)
                let t = r.trajectory!
                var frames: [Molecule] = []
                for i in 0..<4 { var m = RenderFixtures.water; m.atoms[1].position.y += 0.1 * Double(i); frames.append(m) }
                var seen: [Int] = []
                t.onFrameChange = { seen.append($0) }
                t.load(frames)
                try expect(t.frames.count == 4 && t.currentFrame == 0, "load")
                t.show(frame: 2)
                try expectClose(r.molecule.atoms[1].position.y, frames[2].atoms[1].position.y, tol: 1e-12)
                t.show(frame: 99); try expect(t.currentFrame == 3, "clamp high")
                t.show(frame: -5); try expect(t.currentFrame == 0, "clamp low")
                t.step(2); try expect(t.currentFrame == 2, "step")
                t.step(-1); try expect(t.currentFrame == 1, "step back")
                t.loops = true; t.show(frame: 3); t.advance(); try expect(t.currentFrame == 0, "loop wraps")
                t.loops = false; t.show(frame: 3); t.advance(); try expect(t.currentFrame == 3 && !t.isPlaying, "stops at end")
                t.advance(); try expect(t.currentFrame == 3, "stays")
                try expect(!seen.isEmpty, "callback")
                // fallback to setMolecule on different atom count
                let ch4: Molecule = RenderFixtures.acetylene
                t.load([RenderFixtures.water, ch4])
                t.show(frame: 1)
                try expect(r.molecule.atoms.count == 4, "setMolecule fallback")
                t.show(frame: 0)
                try expect(r.molecule.atoms.count == 3, "back")
                t.load([])
                t.show(frame: 0); t.advance(); t.play()
                try expect(!t.isPlaying, "empty play ignored")
                // play/pause flag
                t.load(frames); t.play(); try expect(t.isPlaying, "play"); t.pause(); try expect(!t.isPlaying, "pause")
            }
        },
    ]

    /// Regular tetrahedron mesh (4 vertices, 4 triangles, outward-facing CCW).
    static func mediaTetra(_ sign: IsoSurfaceMesh.Sign) -> IsoSurfaceMesh {
        let v: [SIMD3<Float>] = [SIMD3(1, 1, 1), SIMD3(1, -1, -1), SIMD3(-1, 1, -1), SIMD3(-1, -1, 1)]
        let idx: [UInt32] = [0, 2, 1, 0, 1, 3, 0, 3, 2, 1, 2, 3]
        let n = v.map { simd_normalize($0) }
        return IsoSurfaceMesh(vertices: v.map { $0 * (sign == .positive ? 1 : -1) }, normals: n, indices: idx, sign: sign, isovalue: sign == .positive ? 0.02 : -0.02)
    }

    /// Returns an accessor (x, y from top-left) -> [r,g,b,a].
    static func rgba(_ img: CGImage) throws -> (Int, Int) -> [UInt8] {
        let w = img.width, h = img.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let ok = data.withUnsafeMutableBytes { p -> Bool in
            guard let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h)); return true
        }
        if !ok { throw CheckFailure(description: "bitmap ctx") }
        return { x, y in let i = (y * w + x) * 4; return Array(data[i..<i + 4]) }
    }
}
