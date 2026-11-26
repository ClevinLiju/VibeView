import Foundation
import MolCore
import MolIO
import MolCompute
import simd

/// Thread-safe result slot for async work driven from synchronous checks.
final class ComputeResultBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<T, Error>?
    var result: Result<T, Error>? { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ r: Result<T, Error>) { lock.lock(); value = r; lock.unlock() }
}

struct CheckHardTimeout: Error, CustomStringConvertible {
    let seconds: TimeInterval
    var description: String { "hard timeout: async work did not finish within \(Int(seconds)) s (cancelled)" }
}

/// Runs async work from a synchronous check without deadlocking: on the main thread the main run loop keeps
/// spinning (so main-actor/main-queue work can proceed), and a hard timeout turns a hang into a FAIL.
func computeRunAsync<T: Sendable>(timeout: TimeInterval = 30, _ op: @escaping @Sendable () async throws -> T) throws -> T {
    let box = ComputeResultBox<T>()
    let sem = DispatchSemaphore(value: 0)
    let task = Task.detached {
        do { box.set(.success(try await op())) } catch { box.set(.failure(error)) }
        sem.signal()
    }
    let deadline = Date().addingTimeInterval(timeout)
    while box.result == nil {
        if Date() >= deadline { task.cancel(); throw CheckHardTimeout(seconds: timeout) }
        if Thread.isMainThread {
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
            _ = sem.wait(timeout: .now() + .milliseconds(2))
        } else {
            _ = sem.wait(timeout: .now() + .milliseconds(50))
        }
    }
    return try box.result!.get()
}

func computeAsyncError(timeout: TimeInterval = 30, _ op: @escaping @Sendable () async throws -> Void) -> Error? {
    do { try computeRunAsync(timeout: timeout, op); return nil } catch { return error }
}

private func runAsync<T: Sendable>(_ op: @escaping @Sendable () async throws -> T) throws -> T { try computeRunAsync(op) }
private func asyncError(_ op: @escaping @Sendable () async throws -> Void) -> Error? { computeAsyncError(op) }

private let methaneSDF = """
methane
  test

  5  4  0  0  0  0  0  0  0  0999 V2000
    0.0000    0.0000    0.0000 C   0  0  0  0  0  0  0  0  0  0  0  0
    0.6290    0.6290    0.6290 H   0  0  0  0  0  0  0  0  0  0  0  0
   -0.6290   -0.6290    0.6290 H   0  0  0  0  0  0  0  0  0  0  0  0
   -0.6290    0.6290   -0.6290 H   0  0  0  0  0  0  0  0  0  0  0  0
    0.6290   -0.6290   -0.6290 H   0  0  0  0  0  0  0  0  0  0  0  0
  1  2  1  0
  1  3  1  0
  1  4  1  0
  1  5  1  0
M  END
> <PUBCHEM_COMPOUND_CID>
297

> <PUBCHEM_CID>
297

$$$$

"""

private let ethane2D = """
ethane
  test

  8  7  0  0  0  0  0  0  0  0999 V2000
    0.0000    0.0000    0.0000 C   0  0  0  0  0  0  0  0  0  0  0  0
    1.5000    0.0000    0.0000 C   0  0  0  0  0  0  0  0  0  0  0  0
   -0.5000    0.9000    0.0000 H   0  0  0  0  0  0  0  0  0  0  0  0
   -0.5000   -0.9000    0.0000 H   0  0  0  0  0  0  0  0  0  0  0  0
   -0.7000    0.0000    0.0000 H   0  0  0  0  0  0  0  0  0  0  0  0
    2.0000    0.9000    0.0000 H   0  0  0  0  0  0  0  0  0  0  0  0
    2.0000   -0.9000    0.0000 H   0  0  0  0  0  0  0  0  0  0  0  0
    2.7000    0.0000    0.0000 H   0  0  0  0  0  0  0  0  0  0  0  0
  1  2  1  0
  1  3  1  0
  1  4  1  0
  1  5  1  0
  2  6  1  0
  2  7  1  0
  2  8  1  0
M  END
$$$$

"""

private func isOfflineish(_ e: Error?) -> Bool {
    if let c = e as? ComputeError { return c == .offline || c == .timeout }
    return false
}

private func formula(_ m: Molecule) -> [Int: Int] {
    Dictionary(m.atoms.map { ($0.atomicNumber, 1) }, uniquingKeysWith: +)
}

extension Checks {
    static let compute: [Check] = computeCore + computeLive + computeXTBSettings + computeLookup + computeOrcaMolden

    static let computeCore: [Check] = [
        Check("compute.locator") {
            try expect(ProgramLocator.find("sh") != nil, "sh not found")
            try expect(ProgramLocator.find("ls") != nil, "ls not found")
            try expect(ProgramLocator.find("definitely-not-a-program-xyz") == nil, "bogus found")
            try expect(!ProgramLocator.searchDirectories(for: "x").isEmpty)
        },
        Check("compute.runner.echo") {
            let echo = URL(fileURLWithPath: "/bin/echo")
            let o = try runAsync { try await ProgramRunner.run(executable: echo, arguments: ["hello", "world"]) }
            try expect(o.stdout == "hello world\n" && o.exitCode == 0, "stdout=\(o.stdout)")
            let f = URL(fileURLWithPath: "/usr/bin/false")
            let e = asyncError { _ = try await ProgramRunner.run(executable: f, arguments: []) }
            guard case .processFailed(let code, _)? = e as? ComputeError else { throw CheckFailure(description: "expected processFailed, got \(String(describing: e))") }
            try expect(code == 1)
            let o2 = try runAsync { try await ProgramRunner.run(executable: f, arguments: [], throwOnFailure: false) }
            try expect(o2.exitCode == 1)
            let cat = URL(fileURLWithPath: "/bin/cat")
            let big = String(repeating: "abcdefghij\n", count: 50_000)
            let o3 = try runAsync { try await ProgramRunner.run(executable: cat, arguments: [], stdin: big) }
            try expect(o3.stdout == big, "stdin passthrough (large) mismatch \(o3.stdout.count)")
            // cancellation
            let sleep = URL(fileURLWithPath: "/bin/sleep")
            let t0 = Date()
            let ce = asyncError {
                let t = Task { _ = try await ProgramRunner.run(executable: sleep, arguments: ["30"]) }
                try await Task.sleep(nanoseconds: 300_000_000)
                t.cancel()
                try await t.value
            }
            try expect((ce as? ComputeError) == .cancelled, "expected cancelled, got \(String(describing: ce))")
            try expect(Date().timeIntervalSince(t0) < 5, "cancel too slow")
            let te = asyncError { _ = try await ProgramRunner.run(executable: sleep, arguments: ["30"], timeout: 0.3) }
            try expect((te as? ComputeError) == .timeout, "expected timeout, got \(String(describing: te))")
        },
        Check("compute.xtb.notInstalled") {
            let water = Molecule(atoms: [Atom(id: 0, atomicNumber: 8, position: Vec3(0, 0, 0.12)),
                                         Atom(id: 1, atomicNumber: 1, position: Vec3(0, 0.76, -0.47)),
                                         Atom(id: 2, atomicNumber: 1, position: Vec3(0, -0.76, -0.47))])
            let empty = FileManager.default.temporaryDirectory.appendingPathComponent("vibeview-empty-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: empty) }
            var runner = XTBRunner()
            runner.searchDirectories = [empty.path]
            try expect(XTBRunner.locate(searchDirectories: [empty.path]) == nil)
            let r = runner
            let e = asyncError { _ = try await r.run(water, task: .optimize) }
            guard case .notInstalled(let p, let s)? = e as? ComputeError else { throw CheckFailure(description: "got \(String(describing: e))") }
            try expect(p == "xtb" && s == [empty.path], "\(s)")
            let d = (e as! LocalizedError).errorDescription ?? ""
            try expect(d.contains("xtb") && d.contains("conda install -c conda-forge xtb"), d)
            let bad = XTBRunner(executable: empty.appendingPathComponent("nope"))
            let e2 = asyncError { _ = try await bad.run(water, task: .optimize) }
            guard case .notInstalled("xtb", _)? = e2 as? ComputeError else { throw CheckFailure(description: "explicit: \(String(describing: e2))") }
            let log = """
             :: total energy              -5.070544 Eh    ::
             :: gradient norm              0.000123 Eh/a0 ::
             :: HOMO-LUMO gap              14.5 eV    ::
            ::::::::
                   | TOTAL ENERGY               -5.070544423 Eh   |
                   | GRADIENT NORM               0.000123456 Eh/α  |
                   | HOMO-LUMO GAP              14.552173618 eV    |
            """
            try expectClose(XTBRunner.parseEnergy(log)!, -5.070544423, tol: 1e-9)
            try expectClose(XTBRunner.parseGradientNorm(log)!, 0.000123456, tol: 1e-12)
            try expectClose(XTBRunner.parseGap(log)!, 14.552173618, tol: 1e-9)
            let vib = """
            $vibrational spectrum
            #  mode     symmetry     wave number   IR intensity    selection rules
            #                         cm**(-1)      km*mol⁻¹        IR        RAMAN
                1                        0.00       0.00000       -         -
                2                        0.00       0.00000       -         -
                7          a          1590.31      60.12345       YES       YES
                8          a          3650.20       5.50000       YES       YES
            $end
            """
            let (f, ir) = XTBRunner.parseVibSpectrum(vib)
            try expect(f == [1590.31, 3650.20] && ir == [60.12345, 5.5], "\(f) \(ir)")
            let xyz = "3\n energy: -5.07\nO 0 0 0.1\nH 0 0.7 -0.5\nH 0 -0.7 -0.5\n"
            try expect(XTBRunner.parseXYZCoordinates(xyz)?.count == 3)
        },
        Check("compute.pubchem.parse") {
            let c = try PubChemClient.parseSDF(methaneSDF, fallbackTitle: "methane", is3D: true)
            try expect(c.cid == 297, "cid \(String(describing: c.cid))")
            try expect(c.molecule.atoms.count == 5 && c.is3D && c.title == "methane")
            try expect(c.molecule.bonds.count == 4)
        },
        Check("compute.pubchem.embed2D") {
            let c = try PubChemClient.parseSDF(ethane2D, is3D: false)
            try expect(!c.is3D)
            let a = c.molecule.atoms
            let cc = simd_distance(a[0].position, a[1].position)
            try expect(cc > 1.4 && cc < 1.65, "C-C \(cc)")
            let ch = simd_distance(a[0].position, a[2].position)
            try expect(ch > 0.95 && ch < 1.2, "C-H \(ch)")
            try expect(Set(a.map { Int($0.position.z * 100) }).count > 1, "still planar")
        },
        Check("compute.pubchem.caffeine") {
            let client = PubChemClient()
            let t0 = Date()
            do {
                let c = try runAsync { try await client.fetch(name: "caffeine") }
                try expect(c.molecule.atoms.count == 24, "atoms \(c.molecule.atoms.count)")
                try expect(c.cid == 2519 && c.is3D, "cid \(String(describing: c.cid)) 3d \(c.is3D)")
                let f = formula(c.molecule)
                try expect(f[6] == 8 && f[1] == 10 && f[7] == 4 && f[8] == 2, "formula \(f)")
                print("    caffeine fetched in \(String(format: "%.2f", Date().timeIntervalSince(t0))) s")
                let c2 = try runAsync { try await client.fetch(cid: 2519) }
                try expect(c2.molecule.atoms.count == 24 && c2.cid == 2519)
                let c3 = try runAsync { try await client.fetch(smiles: "CN1C=NC2=C1C(=O)N(C(=O)N2C)C") }
                try expect(c3.cid == 2519 && c3.molecule.atoms.count == 24, "smiles cid \(String(describing: c3.cid))")
                let e = asyncError { _ = try await client.fetch(name: "notarealmoleculexyz123") }
                try expect((e as? ComputeError) == .notFound("notarealmoleculexyz123"), "got \(String(describing: e))")
            } catch {
                if isOfflineish(error) { print("    SKIP (offline)"); return }
                throw error
            }
        },
    ]
}
