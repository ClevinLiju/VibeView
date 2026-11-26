import Foundation
import MolCore
import MolIO
import MolBuild
import MolCompute

/// ORCA for live checks: `VIBEVIEW_ORCA`, then the program search (PATH, C:\ORCA*, …).
private func checkLocateORCA() -> URL? {
    if let e = ProgramLocator.environmentValue("VIBEVIEW_ORCA"), !e.isEmpty, ProgramLocator.isExecutable(atPath: e) {
        return URL(fileURLWithPath: e)
    }
    return ProgramLocator.find("orca")
}

private func tempDir(_ prefix: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

#if os(Windows)
/// Running processes whose command line contains `marker` (PowerShell/CIM; the check's own query is excluded).
private func processCount(commandLineContaining marker: String) -> Int {
    let p = Process()
    let root = ProgramLocator.environmentValue("SystemRoot") ?? "C:\\Windows"
    p.executableURL = URL(fileURLWithPath: root + "\\System32\\WindowsPowerShell\\v1.0\\powershell.exe")
    p.arguments = ["-NoProfile", "-NonInteractive", "-Command",
                   "@(Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like '*\(marker)*' -and $_.Name -ne 'powershell.exe' }).Count"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    p.standardInput = FileHandle.nullDevice
    do { try p.run() } catch { return -1 }
    let d = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return Int(String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
}
#endif

extension Checks {
    static let computeOrcaMolden: [Check] = [
        Check("compute.orcaMolden.missingInputs") {
            let dir = try tempDir("vibeview-2mkl")
            defer { try? FileManager.default.removeItem(at: dir) }
            try expect(!OrcaMoldenConversion.hasWavefunction(baseName: "job", in: dir))
            try expect(OrcaMoldenConversion.moldenFileName(baseName: "job") == "job.molden.input")
            // A program that exits 0 and writes nothing stands in for orca_2mkl.
            let noop = CheckTool.echo
            // No .gbw: a clear notFound error, no process started.
            let e1 = computeAsyncError { _ = try await OrcaMoldenConversion.convert(baseName: "job", in: dir, tool: noop.executable) }
            guard case .notFound? = e1 as? ComputeError else { throw CheckFailure(description: "expected notFound, got \(String(describing: e1))") }
            // A .gbw but a tool that writes nothing: processFailed, not success.
            try Data([0, 1, 2]).write(to: dir.appendingPathComponent("job.gbw"))
            let e2 = computeAsyncError { _ = try await OrcaMoldenConversion.convert(baseName: "job", in: dir, tool: noop.executable) }
            guard case .processFailed? = e2 as? ComputeError else { throw CheckFailure(description: "expected processFailed, got \(String(describing: e2))") }
            // An orca without orca_2mkl next to it.
            let e3 = computeAsyncError { _ = try await OrcaMoldenConversion.convert(baseName: "job", in: dir, orca: dir.appendingPathComponent("orca.exe")) }
            guard case .notFound? = e3 as? ComputeError else { throw CheckFailure(description: "expected notFound for missing orca_2mkl, got \(String(describing: e3))") }
        },
        Check("compute.orcaMolden.locateTool") {
            // orca_2mkl(.exe) next to orca(.exe) is found; nothing else is.
            let dir = try tempDir("vibeview-2mkl-loc")
            defer { try? FileManager.default.removeItem(at: dir) }
            let ext = ProgramLocator.isWindows ? ".exe" : ""
            let orca = dir.appendingPathComponent("orca" + ext), tool = dir.appendingPathComponent("orca_2mkl" + ext)
            try Data("x".utf8).write(to: orca)
            try expect(OrcaMoldenConversion.locateTool(nextTo: orca) == nil, "no tool yet")
            try Data("x".utf8).write(to: tool)
            #if !os(Windows)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
            #endif
            let found = OrcaMoldenConversion.locateTool(nextTo: orca)
            try expect(found?.lastPathComponent.lowercased() == "orca_2mkl" + ext, "\(String(describing: found))")
        },
        Check("compute.orcaMolden.companionSkipsBinaryOnceLoaded") {
            // job.out + job.molden.input + job.gbw: orbitals come from the Molden file, the .gbw is "not needed".
            let dir = try tempDir("vibeview-2mkl-comp")
            defer { try? FileManager.default.removeItem(at: dir) }
            let src = testDataURL("io/orca")
            try FileManager.default.copyItem(at: src.appendingPathComponent("water_optfreq.molden.input"), to: dir.appendingPathComponent("job.molden.input"))
            try FileManager.default.copyItem(at: src.appendingPathComponent("water_optfreq.out"), to: dir.appendingPathComponent("job.out"))
            try Data([0, 1, 2]).write(to: dir.appendingPathComponent("job.gbw"))
            var loaded = try MolecularFileLoader.load(url: dir.appendingPathComponent("job.out"))
            try expect(loaded.wavefunction == nil)
            let report = CompanionFiles.merge(into: &loaded, primaryURL: dir.appendingPathComponent("job.out"))
            try expect(loaded.wavefunction != nil, "\(report.map { "\($0.fileName) \($0.used) \($0.note)" })")
            let gbw = report.first { $0.fileName == "job.gbw" }
            try expect(gbw?.used == false && gbw?.note.hasPrefix("not needed") == true, "\(String(describing: gbw))")
        },
        // Real ORCA run: water HF/STO-3G single point on 1 core, then orca_2mkl, then load with companions.
        Check("compute.orcaMolden.live") {
            guard let orca = checkLocateORCA() else { print("    SKIP (ORCA not installed)"); return }
            guard let tool = OrcaMoldenConversion.locateTool(nextTo: orca) else { throw CheckFailure(description: "orca_2mkl not next to \(orca.path)") }
            let dir = try tempDir("vibeview-orca-check")
            defer { try? FileManager.default.removeItem(at: dir) }
            let water = Molecule(atoms: [Atom(id: 0, atomicNumber: 8, position: Vec3(0, 0, 0.117)),
                                         Atom(id: 1, atomicNumber: 1, position: Vec3(0, 0.757, -0.469)),
                                         Atom(id: 2, atomicNumber: 1, position: Vec3(0, -0.757, -0.469))])
            var s = CalcSetup(molecule: water, program: .orca)
            s.jobType = .energy; s.method = "HF"; s.basis = "STO-3G"; s.nprocs = 1; s.memoryMB = 1024
            try s.inputText(molecule: water).write(to: dir.appendingPathComponent("job.inp"), atomically: true, encoding: .utf8)
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
            let loaded = try MolecularFileLoader.loadWithCompanions(url: dir.appendingPathComponent("job.out"))
            try expect(loaded.companions.contains { $0.fileName == "job.molden.input" && $0.used }, "companions \(loaded.companions.map { "\($0.fileName) \($0.used) \($0.note)" })")
            guard let wf = loaded.file.wavefunction else { throw CheckFailure(description: "no wavefunction after conversion") }
            try expect(wf.alpha.orbitalCount == 7 && wf.alpha.basisCount == 7, "MOs \(wf.alpha.orbitalCount) basis \(wf.alpha.basisCount)")
        },
    ]

    /// Stopping whole process trees, the managed xtb folder and XTBPATH.
    static let computeProcessTree: [Check] = [
        Check("compute.processTree.cancelKillsOrphanedGrandchild") {
            #if os(Windows)
            // outer.bat starts an intermediate cmd that launches a ping and exits at once, so the ping's parent is gone
            // (taskkill /T can no longer reach it) while it still holds the output pipe. Cancelling must stop it.
            let dir = try tempDir("vibeview-tree")
            defer { try? FileManager.default.removeItem(at: dir) }
            let n = 40 + Int.random(in: 0..<50)   // unique ping count = marker in the command line
            let marker = "-n \(n) -w 1001"
            let bat = "@echo off\r\necho begin\r\ncmd /d /c start \"\" /b ping \(marker) 127.0.0.1\r\nping -n 60 127.0.0.1 >nul\r\necho never\r\n"
            try bat.write(to: dir.appendingPathComponent("outer.bat"), atomically: true, encoding: .utf8)
            let cmd = URL(fileURLWithPath: (ProgramLocator.environmentValue("ComSpec") ?? "C:\\Windows\\System32\\cmd.exe"))
            let t0 = Date()
            let task = Task.detached {
                try await ProgramRunner.run(executable: cmd, arguments: ["/d", "/c", ProgramLocator.nativePath(dir.appendingPathComponent("outer.bat"))], workingDirectory: dir, throwOnFailure: false)
            }
            Thread.sleep(forTimeInterval: 2.0)
            let before = processCount(commandLineContaining: marker)
            try expect(before >= 1, "the orphaned ping did not start (\(before))")
            task.cancel()
            let e = computeAsyncError(timeout: 20) { _ = try await task.value }
            let took = Date().timeIntervalSince(t0)
            guard case .cancelled? = e as? ComputeError else { throw CheckFailure(description: "expected cancelled, got \(String(describing: e))") }
            try expect(took < 12, String(format: "cancel took %.1f s (pipe held open?)", took))
            Thread.sleep(forTimeInterval: 0.5)
            let after = processCount(commandLineContaining: marker)
            try expect(after == 0, "\(after) process(es) with '\(marker)' still running after cancel")
            print(String(format: "    orphan ping stopped; run ended %.1f s after start", took))
            #else
            print("    SKIP (Windows job objects)")
            #endif
        },
        Check("compute.processTree.normalExitIsNotHeldByLeftovers") {
            #if os(Windows)
            // A program that exits normally but leaves a helper running: the result arrives promptly and the helper is
            // stopped with the job (KILL_ON_JOB_CLOSE).
            let dir = try tempDir("vibeview-tree2")
            defer { try? FileManager.default.removeItem(at: dir) }
            let n = 100 + Int.random(in: 0..<50)
            let marker = "-n \(n) -w 1002"
            let bat = "@echo off\r\necho begin\r\nstart \"\" /b ping \(marker) 127.0.0.1\r\necho done\r\n"
            try bat.write(to: dir.appendingPathComponent("leave.bat"), atomically: true, encoding: .utf8)
            let cmd = URL(fileURLWithPath: (ProgramLocator.environmentValue("ComSpec") ?? "C:\\Windows\\System32\\cmd.exe"))
            let t0 = Date()
            let r = try computeRunAsync(timeout: 40) {
                try await ProgramRunner.run(executable: cmd, arguments: ["/d", "/c", ProgramLocator.nativePath(dir.appendingPathComponent("leave.bat"))], workingDirectory: dir, throwOnFailure: false)
            }
            let took = Date().timeIntervalSince(t0)
            try expect(r.stdout.contains("begin") && r.stdout.contains("done"), "stdout: \(r.stdout) stderr: \(r.stderr)")
            try expect(took < 10, String(format: "result took %.1f s", took))
            Thread.sleep(forTimeInterval: 0.5)
            let left = processCount(commandLineContaining: marker)
            try expect(left == 0, "\(left) leftover helper(s) still running")
            #else
            print("    SKIP (Windows job objects)")
            #endif
        },
        Check("compute.managedXTB.searchedAndXTBPATH") {
            let root = try tempDir("vibeview-managed")
            defer { try? FileManager.default.removeItem(at: root) }
            ProgramLocator.managedDirectoryOverride = root
            defer { ProgramLocator.managedDirectoryOverride = nil }
            try expect(ProgramLocator.managedDirectory.standardizedFileURL.path == root.standardizedFileURL.path, ProgramLocator.managedDirectory.path)
            let bin = root.appendingPathComponent("xtb/bin", isDirectory: true)
            let share = root.appendingPathComponent("xtb/share/xtb", isDirectory: true)
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: share, withIntermediateDirectories: true)
            let exe = bin.appendingPathComponent(ProgramLocator.isWindows ? "xtb.exe" : "xtb")
            try Data("x".utf8).write(to: exe)
            #if !os(Windows)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
            #endif
            let dirs = ProgramLocator.searchDirectories(for: "xtb").map { $0.replacingOccurrences(of: "\\", with: "/").lowercased() }
            let want = bin.path.replacingOccurrences(of: "\\", with: "/").lowercased()
            try expect(dirs.contains { $0.hasSuffix(want.split(separator: ":").last.map(String.init) ?? want) }, "managed bin not searched: \(dirs.suffix(5))")
            // No parameter files yet: no XTBPATH; with them: XTBPATH points at share/xtb, unless the user set one.
            var base = ProcessInfo.processInfo.environment
            ProgramLocator.setEnvironmentValue(nil, forKey: "XTBPATH", in: &base)
            func env() -> [String: String] { XTBRunner.environment(for: exe, settings: XTBSettings(), base: base) }
            try expect(ProgramLocator.environmentValue("XTBPATH", in: env()) == nil)
            try Data("p".utf8).write(to: share.appendingPathComponent("param_gfn2-xtb.txt"))
            let x = ProgramLocator.environmentValue("XTBPATH", in: env()) ?? ""
            try expect(x.replacingOccurrences(of: "\\", with: "/").lowercased().hasSuffix("xtb/share/xtb"), x)
            #if os(Windows)
            try expect(!x.hasPrefix("/") && !x.contains("/"), "native path: \(x)")
            #endif
            ProgramLocator.setEnvironmentValue("C:\\mine", forKey: "XTBPATH", in: &base)
            try expect(ProgramLocator.environmentValue("XTBPATH", in: env()) == "C:\\mine", "user XTBPATH kept")
        },
    ]
}
