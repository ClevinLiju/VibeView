import Foundation
import MolCore
import MolIO
import MolBuild
import MolCompute
import simd

// Round 3 (Lead D): XTBSettings, live log streaming, run directories, generic ProgramRunner streaming.

private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(Date, RunLogEvent)] = []
    func add(_ e: RunLogEvent) { lock.lock(); items.append((Date(), e)); lock.unlock() }
    var all: [(Date, RunLogEvent)] { lock.lock(); defer { lock.unlock() }; return items }
}

private func water() -> Molecule {
    Molecule(atoms: [Atom(id: 0, atomicNumber: 8, position: Vec3(0, 0, 0.12)),
                     Atom(id: 1, atomicNumber: 1, position: Vec3(0, 0.80, -0.47)),
                     Atom(id: 2, atomicNumber: 1, position: Vec3(0, -0.80, -0.47))])
}

private func scratchDir(_ tag: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("molscope-xtb-check-\(tag)-\(UUID().uuidString)")
}

extension Checks {
    static let computeXTBSettings: [Check] = [
        Check("compute.xtbsettings.commandLine") {
            var s = XTBSettings(method: .gfn2, task: .optimize, optLevel: .tight, maxCycles: 3,
                                solvationModel: .alpb, solvent: "water", electronicTemperature: 500, accuracy: 0.5, threads: 2)
            s.extraArguments = ["--verbose"]
            let args = s.arguments(molecule: water())
            let cl = s.commandLine(molecule: water())
            print("    \(cl)")
            try expect(args.first == "input.xyz")
            for frag in ["--gfn 2", "--opt tight", "--cycles 3", "--alpb water", "--etemp 500", "--acc 0.5", "-P 2",
                         "--chrg 0", "--uhf 0", "--verbose", "OMP_NUM_THREADS=2,1"] {
                try expect(cl.contains(frag), "missing \(frag) in \(cl)")
            }
            s.solvationModel = .gbsa; s.solvent = "chcl3"; s.method = .gfnff; s.task = .singlePoint
            let c2 = s.commandLine()
            try expect(c2.contains("--gbsa chcl3") && c2.contains("--gfnff") && !c2.contains("--cycles") && !c2.contains("--opt"), c2)
            s = XTBSettings(method: .gfn0, task: .hessian, optLevel: .vtight)
            try expect(s.commandLine().contains("--gfn 0") && s.commandLine().contains("--ohess vtight"))
            s.extraArguments = ["--name", "a b"]
            try expect(s.commandLine().contains("'a b'"), "quoting")
        },
        Check("compute.xtbsettings.validation+codable") {
            try expect(XTBSettings().validationErrors(molecule: water()).isEmpty)
            var s = XTBSettings(solvationModel: .alpb, solvent: "unobtainium")
            try expect(!s.validationErrors().isEmpty)
            s.solvent = nil
            try expect(!s.validationErrors().isEmpty, "missing solvent")
            s = XTBSettings(method: .gfn0, solvationModel: .alpb, solvent: "water")
            try expect(!s.validationErrors().isEmpty, "gfn0 + solvent")
            s = XTBSettings(maxCycles: 0, threads: 0)
            try expect(s.validationErrors().count == 2)
            s = XTBSettings(charge: 1)   // water+ with uhf 0 is odd-electron
            try expect(!s.validationErrors(molecule: water()).isEmpty, "parity")
            s.uhf = 1
            try expect(s.validationErrors(molecule: water()).isEmpty)
            let full = XTBSettings(method: .gfn1, task: .hessian, optLevel: .extreme, maxCycles: 50, solvationModel: .gbsa,
                                   solvent: "dmso", charge: -1, uhf: 1, electronicTemperature: 1000, accuracy: 0.1,
                                   threads: 3, extraArguments: ["--json"], timeout: 60)
            let data = try JSONEncoder().encode(full)
            try expect(try JSONDecoder().decode(XTBSettings.self, from: data) == full)
            let partial = try JSONDecoder().decode(XTBSettings.self, from: Data(#"{"method":"gfnff","maxCycles":7}"#.utf8))
            try expect(partial.method == .gfnff && partial.maxCycles == 7 && partial.threads == 4 && partial.task == .optimize)
            try expect(XTBSolvents.alpb.contains("water") && XTBSolvents.gbsa.contains("chcl3"))
            try expect(XTBRunner.parseConverged("   *** GEOMETRY OPTIMIZATION CONVERGED AFTER 5 ITERATIONS ***") == true)
            try expect(XTBRunner.parseConverged("   *** FAILED TO CONVERGE GEOMETRY OPTIMIZATION IN 3 ITERATIONS ***") == false)
            try expect(XTBRunner.parseCycleCount("...... CYCLE    1 ....\n..... CYCLE    2 ....\n") == 2)
        },
        Check("compute.runner.streamLines") {
            // Generic runner: lines arrive before exit, a tailed file is followed, stdout is teed.
            let dir = scratchDir("stream")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let script = "for i in 1 2 3; do echo line$i; echo err$i >&2; echo file$i >> job.out; sleep 0.4; done"
            let log = EventLog()
            let t0 = Date()
            let out = try computeRunAsync(timeout: 20) {
                try await ProgramRunner.runLogged(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script],
                                                  workingDirectory: dir, tailFiles: ["job.out"], stdoutFile: "tee.out",
                                                  onEvent: { log.add($0) })
            }
            let end = Date()
            let ev = log.all
            let stdoutLines = ev.compactMap { if case .stdout(let s) = $0.1 { return s } else { return nil } }
            let errLines = ev.compactMap { if case .stderr(let s) = $0.1 { return s } else { return nil } }
            let fileLines = ev.compactMap { if case .file(let n, let l) = $0.1, n == "job.out" { return l } else { return nil } }
            try expect(stdoutLines == ["line1", "line2", "line3"], "\(stdoutLines)")
            try expect(errLines == ["err1", "err2", "err3"], "\(errLines)")
            try expect(fileLines == ["file1", "file2", "file3"], "\(fileLines)")
            if case .started(let d, let c)? = ev.first?.1 { try expect(d == dir && c.contains("/bin/sh")) } else { throw CheckFailure(description: "no .started first") }
            if case .finished(0)? = ev.last?.1 {} else { throw CheckFailure(description: "no .finished last") }
            let firstLine = ev.first { if case .stdout = $0.1 { return true }; return false }!.0
            try expect(end.timeIntervalSince(firstLine) > 0.6, "first line arrived only \(end.timeIntervalSince(firstLine)) s before exit")
            let firstFile = ev.first { if case .file = $0.1 { return true }; return false }!.0
            try expect(end.timeIntervalSince(firstFile) > 0.4, "file tail not live")
            try expect(out.stdout == "line1\nline2\nline3\n")
            try expect((try? String(contentsOf: dir.appendingPathComponent("tee.out"), encoding: .utf8)) == out.stdout, "tee")
            print(String(format: "    %.2f s total, first stdout line %.2f s, first file line %.2f s after start",
                         end.timeIntervalSince(t0), firstLine.timeIntervalSince(t0), firstFile.timeIntervalSince(t0)))
        },
        Check("compute.runner.streamHandleCancel+timeout") {
            let h = ProgramRunner.stream(executable: URL(fileURLWithPath: "/bin/sh"),
                                         arguments: ["-c", "echo begin; sleep 30; echo never"])
            let r: (lines: [String], err: Error?, secs: Double) = try computeRunAsync(timeout: 20) {
                let t = Date()
                var lines: [String] = []
                for await e in h.events {
                    if case .stdout(let s) = e { lines.append(s); if s == "begin" { h.cancel() } }
                }
                var err: Error?
                do { _ = try await h.value } catch { err = error }
                return (lines, err, Date().timeIntervalSince(t))
            }
            try expect(r.lines == ["begin"], "\(r.lines)")
            try expect((r.err as? ComputeError) == .cancelled, "\(String(describing: r.err))")
            try expect(r.secs < 5, "cancel took \(r.secs)")
            let e = computeAsyncError(timeout: 20) {
                _ = try await ProgramRunner.runLogged(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["20"],
                                                      timeout: 0.5, onEvent: { _ in })
            }
            try expect((e as? ComputeError) == .timeout, "\(String(describing: e))")
            // Never on the main thread: callback thread check.
            let onMain = UncheckedFlag()
            _ = try computeRunAsync(timeout: 10) {
                try await ProgramRunner.runLogged(executable: URL(fileURLWithPath: "/bin/echo"), arguments: ["x"],
                                                  onEvent: { _ in if Thread.isMainThread { onMain.set() } })
            }
            try expect(!onMain.value, "event delivered on the main thread")
        },
        Check("compute.xtbsettings.liveWaterStream") {
            guard let exe = XTBRunner.locate() else { print("    SKIP (xtb not installed)"); return }
            let dir = scratchDir("water")
            defer { try? FileManager.default.removeItem(at: dir) }
            let settings = XTBSettings(task: .optimize, optLevel: .tight, solvationModel: .alpb, solvent: "water", threads: 2)
            let h = XTBRunner(executable: exe).stream(water(), settings: settings, runDirectory: dir)
            try expect(h.runDirectory == dir)
            let t0 = Date()
            let r: (events: [(Date, RunLogEvent)], result: XTBResult, end: Date) = try computeRunAsync(timeout: 120) {
                var ev: [(Date, RunLogEvent)] = []
                for await e in h.events { ev.append((Date(), e)) }
                let res = try await h.value
                return (ev, res, Date())
            }
            let lines = r.events.filter { if case .stdout = $0.1 { return true }; return false }
            let fileLines = r.events.filter { if case .file(let n, _) = $0.1 { return n == "xtbopt.log" }; return false }
            print(String(format: "    %.2f s, %d stdout lines, %d xtbopt.log lines, E=%.6f, converged=%@, cycles=%@",
                         r.end.timeIntervalSince(t0), lines.count, fileLines.count, r.result.energy,
                         String(describing: r.result.converged), String(describing: r.result.optimizationCycles)))
            print("    \(r.result.commandLine)")
            try expect(lines.count > 50, "few lines \(lines.count)")
            try expect(r.events.contains { if case .stdout(let s) = $0.1 { return s.contains("x T B") }; return false })
            try expect(fileLines.count > 0, "xtbopt.log not tailed")
            try expect(r.result.converged == true, "water should converge")
            try expect(r.result.commandLine.contains("--alpb water"))
            try expect(r.result.log.contains("alpb") || r.result.log.lowercased().contains("solvation"), "solvation not in log")
            try expect(abs(r.result.energy + 5.08) < 0.05, "E \(r.result.energy)")
            for f in ["input.xyz", "xtb.out", "xtbopt.xyz", "xtbopt.log"] {
                try expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(f).path), "missing \(f)")
            }
        },
        Check("compute.xtbsettings.liveCycleLimit") {
            guard let exe = XTBRunner.locate() else { print("    SKIP (xtb not installed)"); return }
            var hexane = try Molecule(smiles: "CCCCCC")
            hexane = Cleanup.minimize(hexane, maxSteps: 200).molecule
            // Twist the chain so the optimization cannot finish in 3 cycles.
            for i in hexane.atoms.indices { hexane.atoms[i].position += Vec3(0.12 * sin(Double(i)), 0.1 * cos(Double(i * 3)), 0.08) }
            try expect(hexane.atoms.count == 20, "\(hexane.atoms.count) atoms")
            let settings = XTBSettings(task: .optimize, maxCycles: 3, threads: 2)
            let log = EventLog()
            let t0 = Date()
            let res = try computeRunAsync(timeout: 120) {
                try await XTBRunner(executable: exe).run(hexane, settings: settings, onEvent: { log.add($0) })
            }
            print(String(format: "    %.2f s: converged=%@ cycles=%@ exit=%d E=%.6f, %d events",
                         Date().timeIntervalSince(t0), String(describing: res.converged),
                         String(describing: res.optimizationCycles), res.exitCode, res.energy, log.all.count))
            try expect(res.converged == false, "should not converge in 3 cycles")
            try expect((res.optimizationCycles ?? 99) <= 3, "cycles \(String(describing: res.optimizationCycles))")
            try expect(res.commandLine.contains("--cycles 3"))
            try expect(!FileManager.default.fileExists(atPath: res.workingDirectory.path), "temp run dir not cleaned")
        },
        Check("compute.xtbsettings.liveCancel") {
            guard let exe = XTBRunner.locate() else { print("    SKIP (xtb not installed)"); return }
            var big = try Molecule(smiles: "CCCCCCCCCCCCCCCCCCCC")
            big = Cleanup.minimize(big, maxSteps: 100).molecule
            let h = XTBRunner(executable: exe).stream(big, settings: XTBSettings(task: .hessian, threads: 1))
            let dir = h.runDirectory!
            defer { try? FileManager.default.removeItem(at: dir) }
            let r: (n: Int, err: Error?, secs: Double) = try computeRunAsync(timeout: 60) {
                var n = 0
                var t = Date()
                for await e in h.events {
                    if case .stdout = e { n += 1; if n == 20 { t = Date(); h.cancel() } }
                }
                var err: Error?
                do { _ = try await h.value } catch { err = error }
                return (n, err, Date().timeIntervalSince(t))
            }
            print(String(format: "    cancelled after %d lines, stopped in %.2f s", r.n, r.secs))
            try expect((r.err as? ComputeError) == .cancelled, "\(String(describing: r.err))")
            try expect(r.secs < 5, "cancel slow \(r.secs)")
        },
    ]
}

private final class UncheckedFlag: @unchecked Sendable {
    private let lock = NSLock(); private var v = false
    func set() { lock.lock(); v = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return v }
}
