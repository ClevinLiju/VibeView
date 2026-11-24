import Foundation
import SceneKit
import Metal
import simd
import MolCore
@testable import MolRender

// Round 3 (Lead B): GPU vibration checks + an opt-in frame-time benchmark (VIBEVIEW_PERF=1).
enum VibFixtures {
    /// Grid of n x n x n waters (3 n^3 atoms, 2 n^3 bonds), spacing 3.1 Å.
    static func waterBox(_ n: Int) -> Molecule {
        var atoms: [Atom] = [], bonds: [Bond] = []
        for i in 0..<n { for j in 0..<n { for k in 0..<n {
            let c = Vec3(Double(i), Double(j), Double(k)) * 3.1
            let o = atoms.count
            atoms.append(Atom(id: o, atomicNumber: 8, position: c))
            atoms.append(Atom(id: o + 1, atomicNumber: 1, position: c + Vec3(0.7572, 0.5865, 0)))
            atoms.append(Atom(id: o + 2, atomicNumber: 1, position: c + Vec3(-0.7572, 0.5865, 0)))
            bonds.append(Bond(o, o + 1)); bonds.append(Bond(o, o + 2))
        } } }
        return Molecule(atoms: atoms, bonds: bonds, title: "waterbox")
    }
    /// Deterministic symmetric-stretch-like mode for any molecule (H atoms move most).
    static func mode(for m: Molecule) -> NormalMode {
        let d = m.atoms.enumerated().map { (i, a) -> Vec3 in
            let s = a.atomicNumber == 1 ? 0.6 : 0.08
            return Vec3(sin(Double(i) * 1.7), cos(Double(i) * 0.9), sin(Double(i) * 0.4)) * s
        }
        return NormalMode(frequency: 1600, irIntensity: 1, displacements: d)
    }
}

/// RGBA8 pixels of a CGImage.
func vibPixels(_ img: CGImage) -> [UInt8] {
    let w = img.width, h = img.height
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    buf.withUnsafeMutableBytes { p in
        let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    return buf
}
/// Mean absolute per-channel difference (0...255).
func vibMeanDiff(_ a: CGImage, _ b: CGImage) -> Double {
    let pa = vibPixels(a), pb = vibPixels(b)
    guard pa.count == pb.count, !pa.isEmpty else { return 255 }
    var s = 0
    for i in pa.indices { s += abs(Int(pa[i]) - Int(pb[i])) }
    return Double(s) / Double(pa.count)
}

extension Checks {
    static let renderVibration: [Check] = [
        Check("render.vibration.gpu.layerLifecycle") {
            try MainActor.assumeIsolated {
                let r = MoleculeRenderer(molecule: RenderFixtures.benzene)
                let base = r.molecule.atoms.map(\.position)
                let mode = VibFixtures.mode(for: r.molecule)
                r.vibration.play(mode)
                try expect(r.vibration.isGPUActive, "gpu active")
                let gpu = r.vibration.gpuLayer
                try expect(gpu?.parent != nil, "gpu node in scene")
                try expect(r.atomLayer.isHidden && r.bondLayer.isHidden, "cpu layers hidden")
                try expect(r.view.rendersContinuously, "continuous rendering while playing")
                try expect(r.molecule.atoms.map(\.position) == base, "model untouched without overlays")
                // every vibration material carries the geometry modifier
                let mats = r.vibration.gpuMaterialList
                try expect(!mats.isEmpty && mats.allSatisfy { $0.shaderModifiers?[.geometry] != nil }, "modifier on all materials")
                // option change rebuilds the gpu layer and keeps the cpu layers hidden
                var o = r.options; o.style = .tube; r.options = o
                try expect(r.vibration.isGPUActive && r.vibration.gpuLayer !== gpu, "rebuilt on options change")
                try expect(r.atomLayer.isHidden && r.bondLayer.isHidden, "still hidden after rebuild")
                r.vibration.stop()
                try expect(!r.vibration.isGPUActive && r.vibration.gpuLayer == nil, "removed")
                try expect(!r.atomLayer.isHidden && !r.bondLayer.isHidden, "cpu layers back")
                try expect(!r.view.rendersContinuously, "continuous off")
                try expect(r.molecule.atoms.map(\.position) == base, "restored")
                // setMolecule with another atom count stops the vibration
                r.vibration.play(mode)
                r.setMolecule(RenderFixtures.water)
                try expect(!r.vibration.isPlaying && !r.vibration.isGPUActive, "stopped on topology change")
                try expect(!r.atomLayer.isHidden, "visible after stop")
            }
        },
        Check("render.vibration.gpu.vertexAttributes") {
            try MainActor.assumeIsolated {
                let r = MoleculeRenderer(molecule: RenderFixtures.water)
                let mode = NormalMode(frequency: 1, irIntensity: 0, displacements: [Vec3(0, 0.1, 0), Vec3(0.3, 0, 0), Vec3(-0.3, 0, 0)])
                r.vibration.play(mode)
                guard let gpu = r.vibration.gpuLayer else { throw CheckFailure(description: "no gpu layer") }
                var sawAtoms = false, sawBonds = false
                for n in gpu.childNodes {
                    guard let g = n.geometry else { continue }
                    try expect(g.sources(for: .tangent).count == 1, "tangent source")
                    try expect(g.sources(for: .texcoord).count == 3, "3 texcoord channels")
                    if n.name?.hasPrefix("vibration:atoms") == true { sawAtoms = true }
                    if n.name?.hasPrefix("vibration:bonds") == true { sawBonds = true }
                }
                try expect(sawAtoms && sawBonds, "atoms and bonds present")
                r.vibration.stop()
            }
        },
        Check("render.vibration.gpu.ringMath") {
            // A bond from A=(0,0,0) to B=(1,0,0); B moves by (0,1,0) per unit f (pure bend), A fixed.
            let r: Float = 0.1
            let d0 = SIMD3<Float>(1, 0, 0), dd = SIMD3<Float>(0, 1, 0)
            let n = SIMD3<Float>(0, 0, 1)
            let f: Float = 0.5
            // vertex on the B end ring: axial s = 1 -> disp = dB
            let p = GPUVibration.displacedRingVertex(position: SIMD3(1, 0, 0) + n * r, normal: n, disp: dd, radius: r, d0: d0, dd: dd, f: f)
            let axisB = SIMD3<Float>(1, 0.5, 0)
            try expectClose(Double(simd_distance(p, axisB)), Double(r), tol: 1e-5)
            let newDir = simd_normalize(SIMD3<Float>(1, 0.5, 0))
            try expectClose(Double(simd_dot(p - axisB, newDir)), 0, tol: 1e-5)     // ring stays perpendicular to the new axis
            // a radial vertex in the bend plane rotates with the axis
            let n2 = SIMD3<Float>(0, 1, 0)
            let q = GPUVibration.displacedRingVertex(position: SIMD3(1, 0, 0) + n2 * r, normal: n2, disp: dd, radius: r, d0: d0, dd: dd, f: f)
            try expectClose(Double(simd_dot(q - axisB, newDir)), 0, tol: 1e-5)
            try expectClose(Double(simd_distance(q, axisB)), Double(r), tol: 1e-5)
            // f = 0 leaves the vertex alone; atoms (r = 0) translate
            let z = GPUVibration.displacedRingVertex(position: SIMD3(1, 0, 0.1), normal: n, disp: dd, radius: r, d0: d0, dd: dd, f: 0)
            try expect(simd_distance(z, SIMD3(1, 0, 0.1)) < 1e-6, "identity at f=0")
            let a = GPUVibration.displacedRingVertex(position: SIMD3(2, 0, 0), normal: n, disp: SIMD3(0, 0, 1), radius: 0, d0: .zero, dd: .zero, f: 0.3)
            try expect(simd_distance(a, SIMD3(2, 0, 0.3)) < 1e-6, "atom translate")
        },
        Check("render.vibration.gpu.matchesCPUPose") {
            // Rendered GPU pose at a held phase must match the CPU pose at the same phase.
            try MainActor.assumeIsolated {
                var o = ImageExportOptions(); o.widthPoints = 240; o.heightPoints = 180; o.dpi = 72; o.supersampling = 1
                var ro = RenderOptions(); ro.ambientOcclusion = false; ro.shadows = false
                let mol = RenderFixtures.water
                let mode = NormalMode(frequency: 1, irIntensity: 0, displacements: [Vec3(0, 0.12, 0), Vec3(0.45, -0.3, 0.2), Vec3(-0.45, -0.3, -0.2)])
                @MainActor func render(gpu: Bool, time: Double?) throws -> CGImage {
                    let r = MoleculeRenderer(molecule: mol, options: ro)
                    r.fitToView(animated: false)
                    r.vibration.useGPU = gpu; r.vibration.amplitude = 1
                    if let time { r.vibration.play(mode); r.vibration.tick(time: time) }
                    defer { r.vibration.stop() }
                    return try r.renderImage(o)
                }
                let still = try render(gpu: false, time: nil)
                let cpu = try render(gpu: false, time: 0.25)
                let gpu = try render(gpu: true, time: 0.25)
                let gpuZero = try render(gpu: true, time: 0)
                let moved = vibMeanDiff(still, cpu), match = vibMeanDiff(cpu, gpu), rest = vibMeanDiff(still, gpuZero)
                try expect(moved > 1.0, "pose visibly differs from rest (\(moved))")
                try expect(match < moved * 0.25, "gpu pose matches cpu pose (diff \(match) vs moved \(moved))")
                try expect(rest < moved * 0.25, "gpu at phase 0 equals rest (\(rest))")
            }
        },
        Check("render.vibration.gpu.noMainThreadWork") {
            try MainActor.assumeIsolated {
                let r = MoleculeRenderer(molecule: RenderFixtures.benzene)
                let base = r.molecule.atoms.map(\.position)
                r.vibration.play(VibFixtures.mode(for: r.molecule))
                // let the 60 Hz timer fire a few times: without overlays it must not touch the model
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                try expect(r.molecule.atoms.map(\.position) == base, "no per-frame model updates")
                try expect(r.vibration.lastFrameWork == 0, "no main-thread frame work")
                // with a measurement, the overlay follows (live monitor) and the model moves
                var o = r.options; o.measurements = [.distance(0, 6)]; r.options = o
                RunLoop.main.run(until: Date().addingTimeInterval(0.12))
                try expect(r.molecule.atoms.map(\.position) != base, "overlay update moved the model")
                r.vibration.pause()
                let held = r.vibration.clock.phase()
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                try expectClose(r.vibration.clock.phase(), held, tol: 1e-12)
                r.vibration.resume()
                try expect(abs(r.vibration.clock.phase() - held) < 0.05, "resume continues phase")
                r.vibration.stop()
                try expect(r.molecule.atoms.map(\.position) == base, "stop restores")
            }
        },
        Check("render.vibration.perf") {
            guard ProcessInfo.processInfo.environment["VIBEVIEW_PERF"] != nil else { return }
            try MainActor.assumeIsolated {
                for (label, mol) in [("benzene(12)", RenderFixtures.benzene), ("waterbox(1536)", VibFixtures.waterBox(8)), ("waterbox(5184)", VibFixtures.waterBox(12))] {
                    let st = try vibBenchmark(mol, gpu: true, frames: 60, animate: false)
                    print(String(format: "PERF %@ static orbit: frame %.2f ms (p95 %.2f) -> %.0f fps", label, st.frameMean, st.frameP95, 1000 / st.frameMean))
                    for gpu in [false, true] {
                        let s = try vibBenchmark(mol, gpu: gpu, frames: 120)
                        print(String(format: "PERF %@ %@: main-thread anim %.3f ms/frame (p95 %.3f), frame %.2f ms (p95 %.2f) -> %.0f fps, setup %.1f ms",
                                     label, gpu ? "GPU" : "CPU", s.animMean, s.animP95, s.frameMean, s.frameP95, 1000 / s.frameMean, s.setup))
                    }
                }
            }
        },
    ]
}

struct VibBench { var animMean, animP95, frameMean, frameP95, setup: Double }

/// Offscreen frame loop at 1280x800: per frame, the animation work (CPU: `tick`; GPU: the render-thread
/// clock update), a programmatic camera orbit, then a full SceneKit render waited to GPU completion.
@MainActor func vibBenchmark(_ mol: Molecule, gpu: Bool, frames: Int, animate: Bool = true) throws -> VibBench {
    guard let dev = MTLCreateSystemDefaultDevice(), let queue = dev.makeCommandQueue() else { throw CheckFailure(description: "no Metal") }
    let r = MoleculeRenderer(molecule: mol)
    r.fitToView(animated: false)
    r.vibration.useGPU = gpu
    let t0 = ProcessInfo.processInfo.systemUptime
    if animate { r.vibration.play(VibFixtures.mode(for: mol)) }
    let setup = (ProcessInfo.processInfo.systemUptime - t0) * 1000
    defer { r.vibration.stop() }
    let w = 1280, h = 800
    let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
    td.usage = [.renderTarget, .shaderRead]; td.storageMode = .private
    let dd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: w, height: h, mipmapped: false)
    dd.usage = .renderTarget; dd.storageMode = .private
    guard let color = dev.makeTexture(descriptor: td), let depth = dev.makeTexture(descriptor: dd) else { throw CheckFailure(description: "texture") }
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = color; pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
    pass.depthAttachment.texture = depth; pass.depthAttachment.loadAction = .clear; pass.depthAttachment.storeAction = .dontCare
    let sr = SCNRenderer(device: dev, options: nil)
    sr.scene = r.scene; sr.pointOfView = r.cameraNode
    var anim: [Double] = [], frame: [Double] = []
    let start = ProcessInfo.processInfo.systemUptime
    for i in 0..<(frames + 10) {
        let f0 = ProcessInfo.processInfo.systemUptime
        let a0 = f0
        if !animate {} else if gpu { r.vibration.clock.renderer(sr, updateAtTime: f0) } else { r.vibration.tick(time: f0 - start) }
        let a1 = ProcessInfo.processInfo.systemUptime
        r.camera.orbit(dx: 6, dy: 1.5)
        guard let cb = queue.makeCommandBuffer() else { throw CheckFailure(description: "cb") }
        sr.render(atTime: f0 - start, viewport: CGRect(x: 0, y: 0, width: w, height: h), commandBuffer: cb, passDescriptor: pass)
        cb.commit(); cb.waitUntilCompleted()
        let f1 = ProcessInfo.processInfo.systemUptime
        if i >= 10 { anim.append((a1 - a0) * 1000); frame.append((f1 - f0) * 1000) }
    }
    func p95(_ v: [Double]) -> Double { let s = v.sorted(); return s[min(s.count - 1, Int(Double(s.count) * 0.95))] }
    let mean = { (v: [Double]) in v.reduce(0, +) / Double(max(v.count, 1)) }
    return VibBench(animMean: mean(anim), animP95: p95(anim), frameMean: mean(frame), frameP95: p95(frame), setup: setup)
}
