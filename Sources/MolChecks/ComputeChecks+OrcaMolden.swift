import Foundation
import MolCore
import MolIO
import MolBuild
import MolCompute

/// ORCA for live checks: `VIBEVIEW_ORCA`, then PATH, then ~/Library/orca*/orca and /Applications/orca*/orca.
private func checkLocateORCA() -> URL? {
    let fm = FileManager.default
    var c: [String] = []
    if let e = ProcessInfo.processInfo.environment["VIBEVIEW_ORCA"], !e.isEmpty { c.append(e) }
    for d in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") { c.append("\(d)/orca") }
    for parent in [NSHomeDirectory() + "/Library", "/Applications", "/opt"] {
        let names = ((try? fm.contentsOfDirectory(atPath: parent)) ?? []).filter { $0.lowercased().hasPrefix("orca") }
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        c += names.map { "\(parent)/\($0)/orca" }
    }
    return c.first { p in var dir: ObjCBool = false; return fm.fileExists(atPath: p, isDirectory: &dir) && !dir.boolValue && fm.isExecutableFile(atPath: p) }
        .map { URL(fileURLWithPath: $0) }
}

extension Checks {
    static let computeOrcaMolden: [Check] = [
        Check("compute.orcaMolden.missingInputs") {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vibeview-2mkl-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            try expect(!OrcaMoldenConversion.hasWavefunction(baseName: "job", in: dir))
            try expect(OrcaMoldenConversion.moldenFileName(baseName: "job") == "job.molden.input")
            // No .gbw: a clear notFound error, no process started.
            let e1 = computeRunAsyncError { _ = try await OrcaMoldenConversion.convert(baseName: "job", in: dir, tool: URL(fileURLWithPath: "/usr/bin/true")) }
            guard case .notFound? = e1 as? ComputeError else { throw CheckFailure(description: "expected notFound, got \(String(describing: e1))") }
            // A .gbw but a tool that writes nothing: processFailed, not success.
            try Data([0, 1, 2]).write(to: dir.appendingPathComponent("job.gbw"))
            let e2 = computeRunAsyncError { _ = try await OrcaMoldenConversion.convert(baseName: "job", in: dir, tool: URL(fileURLWithPath: "/usr/bin/true")) }
            guard case .processFailed? = e2 as? ComputeError else { throw CheckFailure(description: "expected processFailed, got \(String(describing: e2))") }
            // A tool that is not there.
            let e3 = computeRunAsyncError { _ = try await OrcaMoldenConversion.convert(baseName: "job", in: dir, orca: dir.appendingPathComponent("orca")) }
            guard case .notFound? = e3 as? ComputeError else { throw CheckFailure(description: "expected notFound for missing orca_2mkl, got \(String(describing: e3))") }
        },
        // Real ORCA run: water HF/STO-3G single point on 1 core, then orca_2mkl, then load with companions.
        Check("compute.orcaMolden.live") {
            guard let orca = checkLocateORCA() else { print("    SKIP (ORCA not installed)"); return }
            guard let tool = OrcaMoldenConversion.locateTool(nextTo: orca) else { throw CheckFailure(description: "orca_2mkl not next to \(orca.path)") }
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vibeview-orca-check-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let water = Molecule(atoms: [Atom(id: 0, atomicNumber: 8, position: Vec3(0, 0, 0.117)),
                                         Atom(id: 1, atomicNumber: 1, position: Vec3(0, 0.757, -0.469)),
                                         Atom(id: 2, atomicNumber: 1, position: Vec3(0, -0.757, -0.469))])
            var s = CalcSetup(molecule: water, program: .orca)
            s.jobType = .energy; s.method = "HF"; s.basis = "STO-3G"; s.nprocs = 1; s.memoryMB = 1024
            let input = s.inputText(molecule: water)
            try input.write(to: dir.appendingPathComponent("job.inp"), atomically: true, encoding: .utf8)
            let t0 = Date()
            let run = try computeRunAsync(timeout: 180) {
                try await ProgramRunner.run(executable: orca, arguments: ["job.inp"], workingDirectory: dir, timeout: 170, throwOnFailure: false)
            }
            try run.stdout.write(to: dir.appendingPathComponent("job.out"), atomically: true, encoding: .utf8)
            print(String(format: "    orca %.1f s, exit %d", Date().timeIntervalSince(t0), run.exitCode))
            try expect(run.stdout.contains("ORCA TERMINATED NORMALLY"), "ORCA did not terminate normally:\n" + String(run.stdout.suffix(800)) + run.stderr)
            try expect(OrcaMoldenConversion.hasWavefunction(baseName: "job", in: dir), "no job.gbw")
            let out = try computeRunAsync(timeout: 60) { try await OrcaMoldenConversion.convert(baseName: "job", in: dir, tool: tool) }
            try expect(out.moldenURL.lastPathComponent == "job.molden.input" && FileManager.default.fileExists(atPath: out.moldenURL.path))
            print("    \(out.commandLine) → \(out.moldenURL.lastPathComponent)")
            let loaded = try MolecularFileLoader.loadWithCompanions(url: dir.appendingPathComponent("job.out"))
            try expect(loaded.companions.contains { $0.fileName == "job.molden.input" && $0.used }, "companions \(loaded.companions.map { "\($0.fileName) \($0.used) \($0.note)" })")
            guard let wf = loaded.file.wavefunction else { throw CheckFailure(description: "no wavefunction after conversion") }
            // Water / STO-3G: 7 basis functions, 7 MOs, 5 doubly occupied.
            try expect(wf.alpha.orbitalCount == 7 && wf.alpha.basisCount == 7, "MOs \(wf.alpha.orbitalCount) basis \(wf.alpha.basisCount)")
            try expect(wf.homoIndex == 4, "HOMO \(String(describing: wf.homoIndex))")
            if let e = loaded.file.result?.extras?.finalEnergy { try expect(abs(e + 74.96) < 0.02, "E \(e)") }
        },
    ]
}

private func computeRunAsyncError(_ op: @escaping @Sendable () async throws -> Void) -> Error? {
    do { try computeRunAsync(timeout: 30, op); return nil } catch { return error }
}
