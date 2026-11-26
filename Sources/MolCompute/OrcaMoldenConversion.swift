import Foundation

/// Converts an ORCA `.gbw` wavefunction to Molden format with ORCA's own `orca_2mkl <base> -molden`,
/// which writes `<base>.molden.input` next to the `.gbw`. MolIO loads that file as the wavefunction
/// companion of `<base>.out`, so orbitals can be drawn right after an ORCA job.
public enum OrcaMoldenConversion {
    /// File name `orca_2mkl` writes for `baseName`.
    public static func moldenFileName(baseName: String) -> String { baseName + ".molden.input" }

    /// `orca_2mkl` in the folder of the `orca` executable (symlinks to `orca` are followed too).
    public static func locateTool(nextTo orca: URL) -> URL? {
        let fm = FileManager.default
        var dirs = [orca.deletingLastPathComponent()]
        let resolved = orca.resolvingSymlinksInPath().deletingLastPathComponent()
        if resolved.path != dirs[0].path { dirs.append(resolved) }
        for d in dirs {
            let c = d.appendingPathComponent("orca_2mkl")
            if fm.isExecutableFile(atPath: c.path) { return c }
        }
        return nil
    }

    /// Whether a conversion makes sense: `<base>.gbw` exists in `directory`.
    public static func hasWavefunction(baseName: String, in directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(baseName + ".gbw").path)
    }

    public struct Outcome: Sendable, Equatable {
        public var moldenURL: URL
        public var commandLine: String
        public var output: String
    }

    /// Runs `orca_2mkl <baseName> -molden` in `directory` and returns the written Molden file.
    /// Throws `.notFound` when the `.gbw` or the tool is missing, `.processFailed` when the tool fails
    /// or produces no file, `.timeout` / `.cancelled` as `ProgramRunner` does.
    public static func convert(baseName: String, in directory: URL, orca: URL? = nil, tool: URL? = nil,
                               timeout: TimeInterval = 300) async throws -> Outcome {
        guard hasWavefunction(baseName: baseName, in: directory) else {
            throw ComputeError.notFound("\(baseName).gbw in \(directory.path)")
        }
        guard let exe = tool ?? orca.flatMap(locateTool(nextTo:)) else {
            throw ComputeError.notFound("orca_2mkl next to \(orca?.path ?? "orca")")
        }
        let out = directory.appendingPathComponent(moldenFileName(baseName: baseName))
        let before = (try? FileManager.default.attributesOfItem(atPath: out.path)[.modificationDate]) as? Date
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = ([exe.deletingLastPathComponent().path] + (env["PATH"] ?? "/usr/bin:/bin").split(separator: ":").map(String.init))
            .joined(separator: ":")
        let args = [baseName, "-molden"]
        let r = try await ProgramRunner.run(executable: exe, arguments: args, workingDirectory: directory,
                                            environment: env, timeout: timeout, throwOnFailure: false)
        let text = (r.stdout + (r.stderr.isEmpty ? "" : "\n" + r.stderr)).trimmingCharacters(in: .whitespacesAndNewlines)
        let attrs = try? FileManager.default.attributesOfItem(atPath: out.path)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        let modified = attrs?[.modificationDate] as? Date
        let fresh = size > 0 && (before == nil || (modified ?? .distantPast) >= before!)
        guard r.exitCode == 0, fresh else {
            throw ComputeError.processFailed(code: r.exitCode, stderr: text.isEmpty ? "orca_2mkl wrote no \(out.lastPathComponent)" : text)
        }
        return Outcome(moldenURL: out, commandLine: ([exe.lastPathComponent] + args).joined(separator: " "), output: text)
    }
}
