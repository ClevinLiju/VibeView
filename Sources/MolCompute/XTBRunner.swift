import Foundation
import MolCore
import MolIO

public enum XTBTask: String, Sendable, CaseIterable, Codable { case singlePoint, optimize, hessian }
public enum XTBMethod: String, Sendable, CaseIterable, Codable, Identifiable {
    case gfn2, gfn1, gfnff, gfn0
    public var id: String { rawValue }
    public var title: String {
        switch self { case .gfn2: "GFN2-xTB"; case .gfn1: "GFN1-xTB"; case .gfn0: "GFN0-xTB"; case .gfnff: "GFN-FF" }
    }
    public var flag: [String] {
        switch self {
        case .gfn2: return ["--gfn", "2"]; case .gfn1: return ["--gfn", "1"]; case .gfn0: return ["--gfn", "0"]
        case .gfnff: return ["--gfnff"]
        }
    }
}

public struct XTBResult: Sendable {
    public var energy: Double            // Eh
    public var gradientNorm: Double?     // Eh/a0
    public var homoLumoGap: Double?      // eV
    public var molecule: Molecule
    public var frequencies: [Double]     // cm^-1
    public var irIntensities: [Double]   // km/mol
    public var log: String
    /// Run directory (input.xyz, xtb.out, xtbopt.xyz/log, ...). Deleted after the run unless the caller
    /// passed `runDirectory`, set `keepFiles`, or used `stream(...)`.
    public var workingDirectory: URL
    /// Optimizations: false when xtb stopped at the cycle limit without converging; nil for single points.
    public var converged: Bool? = nil
    /// Optimization cycles performed (from the CYCLE banners in the log).
    public var optimizationCycles: Int? = nil
    public var commandLine: String = ""
    public var exitCode: Int32 = 0
}

public struct XTBRunner: Sendable {
    public typealias Task = XTBTask
    public typealias Method = XTBMethod
    public var executable: URL?
    public var keepFiles = false
    /// nil = default search (VIBEVIEW_XTB, PATH, conda envs, homebrew). When set, only these directories are searched.
    public var searchDirectories: [String]?

    public init(executable: URL? = nil) { self.executable = executable }

    public static func locate(searchDirectories: [String]? = nil) -> URL? {
        if let dirs = searchDirectories {
            let fm = FileManager.default
            for d in dirs {
                let p = (d as NSString).appendingPathComponent("xtb")
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: p, isDirectory: &isDir), !isDir.boolValue, fm.isExecutableFile(atPath: p) {
                    return URL(fileURLWithPath: p)
                }
            }
            return nil
        }
        if let o = ProcessInfo.processInfo.environment["VIBEVIEW_XTB"], !o.isEmpty,
           FileManager.default.isExecutableFile(atPath: o) { return URL(fileURLWithPath: o) }
        return ProgramLocator.find("xtb")
    }

    public func run(_ molecule: Molecule, task: XTBTask, method: XTBMethod = .gfn2, solvent: String? = nil,
                    threads: Int = 4, accuracy: Double = 1.0) async throws -> XTBResult {
        var st = XTBSettings(method: method, task: task, threads: threads)
        if let s = solvent, !s.isEmpty { st.solvationModel = .alpb; st.solvent = s }
        if accuracy != 1.0 { st.accuracy = accuracy }
        return try await run(molecule, settings: st)
    }

    func resolveExecutable() throws -> URL {
        if let given = executable {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: given.path, isDirectory: &isDir), !isDir.boolValue,
                  FileManager.default.isExecutableFile(atPath: given.path) else {
                throw ComputeError.notInstalled(program: "xtb", searched: [given.path])
            }
            return given
        } else if let found = Self.locate(searchDirectories: searchDirectories) {
            return found
        }
        throw ComputeError.notInstalled(program: "xtb", searched: searchDirectories ?? ProgramLocator.searchDirectories(for: "xtb"))
    }

    /// The settings' environment plus `XTBPATH` when the executable ships its parameter files beside it
    /// (`<prefix>/bin/xtb` with `<prefix>/share/xtb`, the layout of the official release archives), unless
    /// the user already set one.
    static func environment(for exe: URL, settings: XTBSettings) -> [String: String] {
        var env = settings.environment()
        let share = exe.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("share/xtb")
        if env["XTBPATH"] == nil, FileManager.default.fileExists(atPath: share.appendingPathComponent("param_gfn2-xtb.txt").path) {
            env["XTBPATH"] = share.path
        }
        return env
    }

    static func newRunDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("vibeview-xtb-\(UUID().uuidString)")
    }

    /// Runs xtb with full settings. `onEvent` receives live lines: stdout/stderr and new lines of `xtbopt.log`
    /// (tailed while running). stdout is also saved as `xtb.out` in the run directory. A passed `runDirectory`
    /// is created if needed and kept. Throws `.invalidSettings`-style `ComputeError.parse` for invalid settings.
    public func run(_ molecule: Molecule, settings: XTBSettings, runDirectory: URL? = nil,
                    onEvent: (@Sendable (RunLogEvent) -> Void)? = nil) async throws -> XTBResult {
        let problems = settings.validationErrors(molecule: molecule)
        if !problems.isEmpty { throw ComputeError.parse("invalid xtb settings: " + problems.joined(separator: " ")) }
        let exe = try resolveExecutable()
        let dir = runDirectory ?? Self.newRunDirectory()
        let keep = keepFiles || runDirectory != nil
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var ok = false
        defer { if !ok && !keep { try? FileManager.default.removeItem(at: dir) } }
        try XYZFormat.write(molecule).write(to: dir.appendingPathComponent("input.xyz"), atomically: true, encoding: .utf8)
        let args = settings.arguments(molecule: molecule)
        let cmd = settings.commandLine(molecule: molecule, executable: exe.path)
        let sink = onEvent ?? { _ in }
        let out = try await ProgramRunner.runLogged(
            executable: exe, arguments: args, workingDirectory: dir, environment: Self.environment(for: exe, settings: settings),
            timeout: settings.timeout, throwOnFailure: false,
            tailFiles: settings.task == .singlePoint ? [] : ["xtbopt.log"], stdoutFile: "xtb.out", onEvent: sink)
        let log = out.stdout
        guard let energy = Self.parseEnergy(log) else {
            if out.exitCode != 0 {
                throw ComputeError.processFailed(code: out.exitCode, stderr: out.stderr.isEmpty ? String(log.suffix(1500)) : out.stderr)
            }
            throw ComputeError.parse("xtb output has no TOTAL ENERGY\n" + String(log.suffix(400)))
        }
        var mol = molecule
        let optURL = dir.appendingPathComponent("xtbopt.xyz")
        if settings.task != .singlePoint, let t = try? String(contentsOf: optURL, encoding: .utf8),
           let g = Self.parseXYZCoordinates(t), g.count == mol.atoms.count {
            for i in 0..<g.count { mol.atoms[i].position = g[i] }
        }
        var freqs: [Double] = [], ir: [Double] = []
        if settings.task == .hessian, let t = try? String(contentsOf: dir.appendingPathComponent("vibspectrum"), encoding: .utf8) {
            (freqs, ir) = Self.parseVibSpectrum(t)
        }
        var result = XTBResult(energy: energy, gradientNorm: Self.parseGradientNorm(log),
                               homoLumoGap: Self.parseGap(log), molecule: mol, frequencies: freqs,
                               irIntensities: ir, log: log, workingDirectory: dir)
        if settings.task != .singlePoint {
            let notConv = FileManager.default.fileExists(atPath: dir.appendingPathComponent("NOT_CONVERGED").path)
            result.converged = Self.parseConverged(log).map { $0 && !notConv } ?? (notConv ? false : nil)
            result.optimizationCycles = Self.parseCycleCount(log)
        }
        result.commandLine = cmd
        result.exitCode = out.exitCode
        ok = true
        if !keep { try? FileManager.default.removeItem(at: dir) }
        return result
    }

    /// Starts xtb and returns a handle with a live `events` stream, the run directory (kept after the run),
    /// and the result task. `handle.cancel()` terminates xtb.
    public func stream(_ molecule: Molecule, settings: XTBSettings, runDirectory: URL? = nil) -> XTBRunHandle {
        let dir = runDirectory ?? Self.newRunDirectory()
        let runner = self
        return .make(runDirectory: dir) { emit in
            try await runner.run(molecule, settings: settings, runDirectory: dir, onEvent: emit)
        }
    }

    /// true = "GEOMETRY OPTIMIZATION CONVERGED", false = "FAILED TO CONVERGE", nil = no optimization in the log.
    public static func parseConverged(_ log: String) -> Bool? {
        let u = log.uppercased()
        if u.contains("FAILED TO CONVERGE GEOMETRY") || u.contains("GEOMETRY OPTIMIZATION DID NOT CONVERGE") { return false }
        if u.contains("GEOMETRY OPTIMIZATION CONVERGED") || u.contains("*** GEOMETRY OPTIMIZATION CONVERGED") { return true }
        return nil
    }

    /// Number of optimization cycles (highest "CYCLE n" banner).
    public static func parseCycleCount(_ log: String) -> Int? {
        var best: Int?
        for line in log.split(whereSeparator: \.isNewline) where line.contains(" CYCLE ") {
            let toks = line.split(separator: " ")
            if let i = toks.firstIndex(of: "CYCLE"), i + 1 < toks.count, let n = Int(toks[i + 1]) { best = max(best ?? 0, n) }
        }
        return best
    }

    // MARK: parsers (internal-public for tests)

    /// Last "TOTAL ENERGY   -5.07 Eh" value.
    public static func parseEnergy(_ log: String) -> Double? { lastValue(log, key: "TOTAL ENERGY") }
    public static func parseGradientNorm(_ log: String) -> Double? { lastValue(log, key: "GRADIENT NORM") }
    public static func parseGap(_ log: String) -> Double? { lastValue(log, key: "HOMO-LUMO GAP") }

    private static func lastValue(_ log: String, key: String) -> Double? {
        var result: Double?
        for line in log.split(whereSeparator: \.isNewline) {
            guard let r = line.range(of: key) else { continue }
            let rest = line[r.upperBound...].replacingOccurrences(of: "|", with: " ")
            for tok in rest.split(separator: " ") { if let v = Double(tok) { result = v; break } }
        }
        return result
    }

    public static func parseXYZCoordinates(_ text: String) -> [Vec3]? {
        guard let mols = try? XYZFormat.parse(text), let m = mols.last else { return nil }
        return m.atoms.map(\.position)
    }

    /// Turbomole `$vibrational spectrum` block. Skips zero-frequency (translation/rotation) modes.
    public static func parseVibSpectrum(_ text: String) -> (frequencies: [Double], intensities: [Double]) {
        var f: [Double] = [], ir: [Double] = []
        var inBlock = false
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("$vibrational") { inBlock = true; continue }
            if line.hasPrefix("$end") { break }
            if !inBlock || line.hasPrefix("#") || line.isEmpty { continue }
            let t = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            // mode [symmetry] wavenumber intensity selection
            guard t.count >= 4, Int(t[0]) != nil else { continue }
            let nums = t.dropFirst().compactMap { Double($0) }
            guard nums.count >= 2 else { continue }
            if abs(nums[0]) < 1e-6 { continue }
            f.append(nums[0]); ir.append(nums[1])
        }
        return (f, ir)
    }
}
