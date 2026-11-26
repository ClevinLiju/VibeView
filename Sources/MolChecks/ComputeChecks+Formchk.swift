import Foundation
import MolCore
import MolIO
import MolCompute

// Automatic formchk (MolCompute/GaussianFormchk.swift), with a fake `formchk` shell script in a temp folder.

fileprivate func fcTempDir() throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("vibeview-formchk-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

/// Writes an executable `formchk` script into `dir/bin`.
fileprivate func fcFakeTool(_ dir: URL, _ body: String) throws -> URL {
    let bin = dir.appendingPathComponent("bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let u = bin.appendingPathComponent("formchk")
    try ("#!/bin/sh\n" + body + "\n").write(to: u, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: u.path)
    return u
}

fileprivate func fcRead(_ u: URL) -> String { (try? String(contentsOf: u, encoding: .utf8)) ?? "" }
fileprivate func fcAge(_ u: URL, _ seconds: TimeInterval) throws {
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -seconds)], ofItemAtPath: u.path)
}

extension Checks {
    static let computeFormchk: [Check] = [
        Check("compute.formchk.locateAndParse") {
            let dir = try fcTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
            let tool = try fcFakeTool(dir, "exit 0")
            let bin = tool.deletingLastPathComponent()
            try expect(GaussianFormchk.locate(environment: ["GAUSS_EXEDIR": "/nonexistent:" + bin.path], searchPath: false)?.path == tool.path, "GAUSS_EXEDIR")
            try expect(GaussianFormchk.locate(gaussian: bin.appendingPathComponent("g16"), environment: [:], searchPath: false)?.path == tool.path, "next to g16")
            try expect(GaussianFormchk.locate(gaussian: dir.appendingPathComponent("g16"), environment: [:], searchPath: false) == nil, "not found")
            try expect(GaussianFormchk.checkpointName(inGaussianInput: "%nprocshared=4\n%chk=water\n#p B3LYP/6-31G(d) Opt\n\n%chk=no\n") == "water.chk")
            try expect(GaussianFormchk.checkpointName(inGaussianInput: "%Chk=a b.chk\n# HF\n") == "a b.chk")
            try expect(GaussianFormchk.checkpointName(inGaussianInput: "# HF/STO-3G\n") == nil)
            try expect(GaussianFormchk.fchkURL(for: dir.appendingPathComponent("job.chk")).lastPathComponent == "job.fchk")
        },
        Check("compute.formchk.convertsOnceAndKeepsNewer") {
            let dir = try fcTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
            let fchkData = testDataURL("io/fchk/h2_sto3g.fchk").path
            let counter = dir.appendingPathComponent("runs.txt")
            // Copies a real fchk to the requested (temporary) name and counts its runs.
            let tool = try fcFakeTool(dir, "echo run >> '\(counter.path)'\ntest -f \"$1\" || exit 3\ncp '\(fchkData)' \"$2\"")
            let chk = dir.appendingPathComponent("my job.chk")
            try Data([1, 2, 3]).write(to: chk)
            let target = GaussianFormchk.fchkURL(for: chk)
            try expect(GaussianFormchk.needsConversion(chk: chk))
            let o1 = try computeRunAsync { try await GaussianFormchk.convert(chk: chk, executable: tool) }
            try expect(o1 == .converted(target), "\(o1)")
            try expect(!GaussianFormchk.needsConversion(chk: chk), "up to date after conversion")
            let fc = try FormattedCheckpoint.read(url: target)
            try expect(fc.wavefunction != nil && fc.molecule.atoms.count == 2, "fchk loads with a wavefunction")
            let left = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains("vibeview-") }
            try expect(left.isEmpty, "temporary file removed: \(left)")
            // Up to date: nothing runs.
            let o2 = try computeRunAsync { try await GaussianFormchk.convert(chk: chk, executable: tool) }
            try expect(o2 == .upToDate(target) && fcRead(counter).components(separatedBy: "run").count - 1 == 1, "ran once")
            // A stale fchk (older than the chk) is replaced.
            try "stale".write(to: target, atomically: true, encoding: .utf8)
            try fcAge(target, 3600)
            let o3 = try computeRunAsync { try await GaussianFormchk.convert(chk: chk, executable: tool) }
            try expect(o3 == .converted(target) && fcRead(target) != "stale", "stale replaced")
            // A .fchk written while formchk runs is newer: it is kept, formchk's output discarded.
            try fcAge(target, 3600)
            let racer = try fcFakeTool(dir, "echo user > \"$(basename \"$1\" .chk).fchk\"\ncp '\(fchkData)' \"$2\"")
            let o4 = try computeRunAsync { try await GaussianFormchk.convert(chk: chk, executable: racer) }
            try expect(o4 == .keptNewer(target) && fcRead(target) == "user\n", "kept newer: \(o4) \(fcRead(target))")
        },
        Check("compute.formchk.failuresDegradeGracefully") {
            let dir = try fcTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
            let chk = dir.appendingPathComponent("job.chk")
            let bad = try fcFakeTool(dir, "echo 'Error reading checkpoint' >&2\nexit 2")
            let e1: Error? = { do { _ = try computeRunAsync { try await GaussianFormchk.convert(chk: chk, executable: bad) }; return nil } catch { return error } }()
            guard case .notFound? = e1 as? ComputeError else { throw CheckFailure(description: "missing chk: \(String(describing: e1))") }
            try Data([0]).write(to: chk)
            let e2: Error? = { do { _ = try computeRunAsync { try await GaussianFormchk.convert(chk: chk, executable: bad) }; return nil } catch { return error } }()
            guard case .processFailed(let code, let msg)? = e2 as? ComputeError, code == 2, msg.contains("Error reading") else {
                throw CheckFailure(description: "failing formchk: \(String(describing: e2))")
            }
            try expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("job.fchk").path), "no fchk on failure")
            let empty = try fcFakeTool(dir, "exit 0")
            let e3: Error? = { do { _ = try computeRunAsync { try await GaussianFormchk.convert(chk: chk, executable: empty) }; return nil } catch { return error } }()
            guard case .processFailed? = e3 as? ComputeError else { throw CheckFailure(description: "no output: \(String(describing: e3))") }
        },
        Check("compute.formchk.logSeesCheckpointCompanion") {
            // The open-time conversion keys on the `.chk` companion of a Gaussian log.
            let dir = try fcTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
            let log = dir.appendingPathComponent("water.log")
            try readText(testDataURL("io/gaussian/water_optfreq_td.log")).write(to: log, atomically: true, encoding: .utf8)
            try Data([0, 1]).write(to: dir.appendingPathComponent("water.chk"))
            let (_, comps) = try MolecularFileLoader.loadWithCompanions(url: log)
            let chk = comps.first { $0.role == .binary && $0.url.pathExtension == "chk" }
            try expect(chk != nil, "companions \(comps.map(\.fileName))")
            try expect(GaussianFormchk.needsConversion(chk: chk!.url), "no fchk yet")
        },
    ]
}
