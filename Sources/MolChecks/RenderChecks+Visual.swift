import Foundation
import simd
import SceneKit
import AppKit
import MolCore
import MolIO
import MolBuild
import MolAnalysis
import MolRender

// Lead B (Render). Visual quality: looks, export quality, sample renders.
// Set MOLSCOPE_RENDER_OUT=/some/dir to also write the sample PNGs (benzene, caffeine, crystal, orbital).
extension Checks {
    static let renderVisual: [Check] = [
        Check("render.visual.looks") {
            for look in RenderLook.allCases {
                var o = RenderOptions(look: look); o.style = .tube
                try expect(o.style == .tube, "look keeps style")
                if look == .whitePaper { try expect(o.resolvedBackground == .white && o.outline && o.ambientOcclusion, "white paper") }
                if look == .illustration { try expect(o.material == .flat && o.outline, "illustration") }
            }
            // lenient decoding: old JSON without new keys still loads
            let json = #"{"style":"spaceFilling","atomScale":0.3}"#.data(using: .utf8)!
            let o = try JSONDecoder().decode(RenderOptions.self, from: json)
            try expect(o.style == .spaceFilling && o.atomScale == 0.3 && o.ambientOcclusion && !o.outline, "lenient decode")
            var full = RenderOptions(look: .whitePaper); full.outlineColor = RGBA(1, 0, 0)
            let back = try JSONDecoder().decode(RenderOptions.self, from: JSONEncoder().encode(full))
            try expect(back == full, "round trip")
        },
        Check("render.visual.environment") {
            try MainActor.assumeIsolated {
                let r = MoleculeRenderer(molecule: RenderFixtures.benzene)
                let key = r.cameraNode.childNodes.compactMap(\.light).first { $0.intensity > 0 && $0.type == .directional }
                try expect(key?.castsShadow == true, "soft shadows by default")
                try expect((r.cameraNode.camera?.screenSpaceAmbientOcclusionIntensity ?? 0) > 0, "AO by default")
                try expect(r.cameraNode.camera?.wantsDepthOfField == false, "DoF off by default")
                try expect(r.scene.lightingEnvironment.contents != nil, "PBR environment")
                r.options.depthOfField = true
                try expect(r.cameraNode.camera?.wantsDepthOfField == true, "DoF on")
                try expectClose(Double(r.cameraNode.camera!.focusDistance), r.camera.distance, tol: 1e-3)
                r.options.outline = true
                try expect(r.view.technique != nil, "outline technique")
                r.options.outline = false
                try expect(r.view.technique == nil, "outline off")
                r.options.shadows = false
                try expect(key?.castsShadow == false, "shadows off")
                let m = MaterialLibrary.makeMaterial(color: RGBA(0.5, 0.5, 0.5), preset: .ceramic)
                try expect(m.lightingModel == .physicallyBased && ((m.clearCoat.contents as? NSNumber)?.doubleValue ?? 0) > 0.5, "ceramic clear coat")
            }
        },
        Check("render.visual.export.supersampledTransparentOutline") {
            try MainActor.assumeIsolated {
                let r = MoleculeRenderer(molecule: RenderFixtures.benzene)
                r.fitToView(animated: false)
                var o = ImageExportOptions.pixels(width: 320, height: 240, dpi: 144)
                o.transparentBackground = true; o.look = .whitePaper
                let img = try r.renderImage(o)
                try expect(img.width == 320 && img.height == 240, "size \(img.width)x\(img.height)")
                let px = try rgba(img)
                try expect(px(0, 0)[3] == 0, "transparent corner")
                // outline: some dark, opaque pixels exist on a white-paper render
                func darkCount(_ img: CGImage) throws -> Int {
                    let px = try rgba(img); var n = 0
                    for y in 0..<img.height { for x in 0..<img.width {
                        let p = px(x, y); if p[3] > 128 && Int(p[0]) + Int(p[1]) + Int(p[2]) < 150 { n += 1 } } }
                    return n
                }
                let dark = try darkCount(img)
                o.look = nil
                let plain = try darkCount(try r.renderImage(o))
                try expect(dark > 10 && dark > plain * 2 + 5, "outline pixels \(dark) vs \(plain) without")
                try expect(!r.options.outline, "look override restored")
                try expect(ImageExportOptions.uhd4K.pixelSize == CGSize(width: 3840, height: 2160), "4K preset")
            }
        },
        Check("render.visual.samples") {
            guard let dir = ProcessInfo.processInfo.environment["MOLSCOPE_RENDER_OUT"] else { return }
            try MainActor.assumeIsolated {
                let out = URL(fileURLWithPath: dir)
                try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
                @MainActor func save(_ r: MoleculeRenderer, _ name: String, _ o: ImageExportOptions) throws {
                    let t0 = Date()
                    try r.exportImage(to: out.appendingPathComponent(name), options: o)
                    print(String(format: "      %@ %dx%d %.2f s", name, Int(o.pixelSize.width), Int(o.pixelSize.height), Date().timeIntervalSince(t0)))
                }
                var o = ImageExportOptions.pixels(width: 1600, height: 1200, dpi: 144)
                // 1. benzene ball-and-stick, studio look
                let b = MoleculeRenderer(molecule: RenderFixtures.benzene)
                b.camera.orbit(dx: 40, dy: 60); b.fitToView(animated: false)
                try save(b, "benzene_ballstick.png", o)
                var bt = o; bt.look = .whitePaper; bt.transparentBackground = true
                try save(b, "benzene_whitepaper_transparent.png", bt)
                // 2. caffeine space-filling with AO
                let caf = Cleanup.minimize(try Molecule(smiles: "CN1C=NC2=C1C(=O)N(C(=O)N2C)C"), maxSteps: 800).molecule
                var co = RenderOptions(); co.style = .spaceFilling
                let c = MoleculeRenderer(molecule: caf, options: co)
                c.camera.orbit(dx: 30, dy: 20); c.fitToView(animated: false)
                try save(c, "caffeine_spacefill_ao.png", o)
                var wp = o; wp.look = .whitePaper
                var cb = RenderOptions(); cb.style = .ballAndStick
                let c2 = MoleculeRenderer(molecule: caf, options: cb)
                c2.camera.orbit(dx: 30, dy: 20); c2.fitToView(animated: false)
                try save(c2, "caffeine_whitepaper.png", wp)
                // 3. ~2400-atom molecular crystal of caffeine
                var big = Molecule()
                let cen = caf.centroid
                for i in 0..<5 { for j in 0..<5 { for k in 0..<4 {
                    let ang = Double((i * 7 + j * 3 + k * 5) % 11) * 0.57
                    let rot = simd_quatd(angle: ang, axis: simd_normalize(Vec3(1, Double((i + k) % 3) - 1, 0.7)))
                    let off = Vec3(Double(i) * 9.5, Double(j) * 9.5, Double(k) * 9.5)
                    let base = big.atoms.count
                    for a in caf.atoms { var a2 = a; a2.id = big.atoms.count; a2.position = rot.act(a.position - cen) + off; big.atoms.append(a2) }
                    for bd in caf.bonds { var b2 = bd; b2.a += base; b2.b += base; big.bonds.append(b2) }
                } } }
                var so = RenderOptions(); so.style = .spaceFilling
                let g = MoleculeRenderer(molecule: big, options: so)
                g.camera.orbit(dx: 35, dy: 25); g.fitToView(animated: false); g.camera.zoom(by: 1.25)
                print("      crystal atoms \(big.atoms.count), atom-layer geometry nodes \(g.geometryNodeCount(layer: MoleculeRenderer.layerNames.atoms)), bond-layer \(g.geometryNodeCount(layer: MoleculeRenderer.layerNames.bonds))")
                try save(g, "crystal_2400.png", o)
                // 4. orbital isosurface (water HOMO cube)
                let cubeURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("TestData/io/cube_water_homo.cube")
                let cube = try CubeFile.read(url: cubeURL)
                let lobes = MarchingCubes.orbitalLobes(grid: cube.grids[0], isovalue: 0.12)
                let w = MoleculeRenderer(molecule: cube.molecule)
                w.setIsosurface(Isosurface(id: "homo", meshes: lobes))
                w.camera.orbit(dx: 50, dy: 30)
                w.fitToView(animated: false); w.camera.zoom(by: 0.7)
                try save(w, "water_homo_isosurface.png", o)
                o = .uhd4K
                try save(c, "caffeine_4k_transparent.png", o)
            }
        },
    ]
}
