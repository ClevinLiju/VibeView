import Foundation
import MolCore
import MolIO
import MolCompute
import simd

// xtb jobs get a 120 s hard timeout; network work uses the 30 s default.
private func runA<T: Sendable>(_ op: @escaping @Sendable () async throws -> T) throws -> T { try computeRunAsync(timeout: 120, op) }
private func errA(_ op: @escaping @Sendable () async throws -> Void) -> Error? { computeAsyncError(timeout: 120, op) }

private func secs(_ t: Date) -> String { String(format: "%.2f s", Date().timeIntervalSince(t)) }

private func xtbChildCount() -> Int {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    p.arguments = ["-f", "molscope-xtb-"]
    let pipe = Pipe(); p.standardOutput = pipe
    do { try p.run() } catch { return 0 }
    let d = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: d, as: UTF8.self).split(whereSeparator: \.isNewline).count
}

extension Checks {
    static let computeLive: [Check] = [
        Check("compute.xtb.live") {
            guard let exe = XTBRunner.locate() else { print("    SKIP (xtb not installed)"); return }
            let water = Molecule(atoms: [Atom(id: 0, atomicNumber: 8, position: Vec3(0, 0, 0.12)),
                                         Atom(id: 1, atomicNumber: 1, position: Vec3(0, 0.80, -0.47)),
                                         Atom(id: 2, atomicNumber: 1, position: Vec3(0, -0.80, -0.47))])
            let runner = XTBRunner(executable: exe)
            var t = Date()
            let sp = try runA { try await runner.run(water, task: .singlePoint) }
            print("    singlePoint \(secs(t)): E=\(sp.energy) gap=\(String(describing: sp.homoLumoGap))")
            try expect(abs(sp.energy + 5.07) < 0.05, "energy \(sp.energy)")
            try expect((sp.homoLumoGap ?? 0) > 0, "gap")
            t = Date()
            let opt = try runA { try await runner.run(water, task: .optimize) }
            print("    optimize \(secs(t)): E=\(opt.energy) |g|=\(String(describing: opt.gradientNorm))")
            try expect(opt.energy <= sp.energy + 1e-9, "opt \(opt.energy) > sp \(sp.energy)")
            let a = opt.molecule.atoms
            let oh = simd_distance(a[0].position, a[1].position)
            try expect(abs(oh - 0.96) < 0.03, "O-H \(oh)")
            try expect((opt.gradientNorm ?? 1) < 1e-2, "grad \(String(describing: opt.gradientNorm))")
            t = Date()
            let hs = try runA { try await runner.run(opt.molecule, task: .hessian) }
            print("    hessian \(secs(t)): freqs=\(hs.frequencies)")
            try expect(hs.frequencies.count == 3 && hs.frequencies.allSatisfy { $0 > 0 }, "\(hs.frequencies)")
            let f = hs.frequencies.sorted()
            try expect(f[0] > 1500 && f[0] < 1650 && f[1] > 3500 && f[1] < 3800 && f[2] > 3500 && f[2] < 3900, "\(f)")
            // cancellation on a larger molecule
            let big = try Molecule(smiles: "CCCCCCCCCCCC")  // dodecane, 38 atoms
            let before = xtbChildCount()
            t = Date()
            let ce = errA {
                let task = Task { _ = try await runner.run(big, task: .hessian) }
                try await Task.sleep(nanoseconds: 300_000_000)
                task.cancel()
                try await task.value
            }
            let dt = Date().timeIntervalSince(t)
            print("    cancel returned in \(secs(t)) (\(String(describing: ce)))")
            try expect((ce as? ComputeError) == .cancelled, "got \(String(describing: ce))")
            try expect(dt < 5, "cancel too slow \(dt)")
            Thread.sleep(forTimeInterval: 0.5)
            try expect(xtbChildCount() <= before, "leftover xtb process")
        },
        Check("compute.pubchem.errors") {
            var t = Date()
            let c1 = PubChemClient(timeout: 3, session: URLSession(configuration: .ephemeral),
                                   baseURL: URL(string: "http://127.0.0.1:9/rest/pug")!)
            let e1 = errA { _ = try await c1.fetch(name: "caffeine") }
            print("    refused: \(String(describing: e1)) in \(secs(t))")
            try expect((e1 as? ComputeError) == .offline, "got \(String(describing: e1))")
            try expect(Date().timeIntervalSince(t) < 3)
            t = Date()
            let c2 = PubChemClient(timeout: 0.5, session: URLSession(configuration: .ephemeral),
                                   baseURL: URL(string: "http://10.255.255.1/rest/pug")!)
            let e2 = errA { _ = try await c2.fetch(name: "caffeine") }
            print("    non-routable: \(String(describing: e2)) in \(secs(t))")
            let ce = e2 as? ComputeError
            try expect(ce == .timeout || ce == .offline, "got \(String(describing: e2))")
            try expect(Date().timeIntervalSince(t) < 8, "too slow")
        },
        Check("compute.pubchem.live2DFallback") {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
            cfg.urlCache = nil
            let client = PubChemClient(timeout: 15, session: URLSession(configuration: cfg))
            do {
                var t = Date()
                let c = try runA { try await client.fetch(name: "caffeine") }
                print("    caffeine fetched in \(secs(t))")
                try expect(c.molecule.atoms.count == 24 && c.cid == 2519 && c.is3D, "atoms \(c.molecule.atoms.count) cid \(String(describing: c.cid)) 3d \(c.is3D)")
                t = Date()
                let s = try runA { try await client.fetch(name: "sodium acetate") }
                print("    sodium acetate (no 3D record) fetched in \(secs(t)): \(s.molecule.atoms.count) atoms, cid \(String(describing: s.cid))")
                try expect(!s.is3D, "expected 2D fallback")
                let zs = Set(s.molecule.atoms.map { Int($0.position.z * 100) })
                try expect(zs.count > 1, "embedded coordinates still planar")
            } catch let e as ComputeError where e == .offline || e == .timeout {
                print("    SKIP (offline)")
            }
        },
    ]
}
