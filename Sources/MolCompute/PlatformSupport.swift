import Foundation

// Platform helpers for program discovery, environments and command-line previews.
// macOS/Linux behaviour is unchanged; the Windows branches follow Windows conventions
// (PATHEXT, `;`-separated case-insensitive `Path`, conda's `Library\bin` / `Scripts`, cmd-style quoting).

extension ProgramLocator {
    /// True when running on Windows.
    public static var isWindows: Bool {
        #if os(Windows)
        return true
        #else
        return false
        #endif
    }

    /// Case-insensitive environment lookup on Windows (`Path` vs `PATH`), exact elsewhere.
    public static func environmentValue(_ key: String, in env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let v = env[key] { return v }
        #if os(Windows)
        let k = key.uppercased()
        return env.first { $0.key.uppercased() == k }?.value
        #else
        return nil
        #endif
    }

    /// Sets `key` in `env`, replacing an existing key that differs only in case on Windows (so `PATH` never
    /// ends up next to `Path`).
    public static func setEnvironmentValue(_ value: String?, forKey key: String, in env: inout [String: String]) {
        #if os(Windows)
        let k = key.uppercased()
        for existing in env.keys where existing != key && existing.uppercased() == k { env.removeValue(forKey: existing) }
        #endif
        env[key] = value
    }

    /// `base` with `overrides` applied (case-insensitively on Windows).
    public static func mergedEnvironment(_ overrides: [String: String],
                                         base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = base
        for (k, v) in overrides { setEnvironmentValue(v, forKey: k, in: &env) }
        return env
    }

    /// On Windows, collapses keys that differ only in case (a child gets one `Path`). When duplicates disagree,
    /// the value that differs from the inherited process environment wins (it is the caller's override).
    /// Identity elsewhere.
    public static func normalizedEnvironment(_ env: [String: String]) -> [String: String] {
        #if os(Windows)
        let inherited = ProcessInfo.processInfo.environment
        var groups: [String: [(String, String)]] = [:]
        for (k, v) in env { groups[k.uppercased(), default: []].append((k, v)) }
        var out: [String: String] = [:]
        for (upper, entries) in groups {
            if entries.count == 1 { out[entries[0].0] = entries[0].1; continue }
            let original = environmentValue(upper, in: inherited)
            let pick = entries.first { $0.1 != original } ?? entries.sorted { $0.0 < $1.0 }[0]
            out[pick.0] = pick.1
        }
        return out
        #else
        return env
        #endif
    }

    /// Directories on `PATH` (`;`-separated on Windows, quotes stripped; `:`-separated elsewhere).
    public static func pathDirectories(env: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        #if os(Windows)
        return (environmentValue("PATH", in: env) ?? "").split(separator: ";").map {
            $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }.filter { !$0.isEmpty }
        #else
        return (env["PATH"] ?? "").split(separator: ":").map(String.init)
        #endif
    }

    /// Executable extensions from `PATHEXT` (lowercased, with the dot), e.g. `.com .exe .bat .cmd`. Empty off Windows.
    public static func executableExtensions(env: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        #if os(Windows)
        let raw = environmentValue("PATHEXT", in: env) ?? ""
        var exts = raw.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { $0.hasPrefix(".") }
        if exts.isEmpty { exts = [".com", ".exe", ".bat", ".cmd"] }
        return exts
        #else
        return []
        #endif
    }

    /// A regular file that can be launched. On Windows: exists and has a `PATHEXT` extension
    /// (`FileManager.isExecutableFile` is unreliable there). Elsewhere: `isExecutableFile`.
    public static func isExecutable(atPath path: String) -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else { return false }
        #if os(Windows)
        let ext = "." + (path as NSString).pathExtension.lowercased()
        return ext != "." && executableExtensions().contains(ext)
        #else
        return fm.isExecutableFile(atPath: path)
        #endif
    }

    /// Candidate file names for `name`: on Windows `name` itself if it already has a PATHEXT extension,
    /// otherwise `name` + each PATHEXT extension (`xtb` -> `xtb.com`, `xtb.exe`, ...). Elsewhere just `name`.
    static func candidateFileNames(_ name: String) -> [String] {
        #if os(Windows)
        let exts = executableExtensions()
        let ext = "." + (name as NSString).pathExtension.lowercased()
        if ext != ".", exts.contains(ext) { return [name] }
        return exts.map { name + $0 }
        #else
        return [name]
        #endif
    }

    /// First executable named `name` in `directories` only (no PATH, no defaults).
    public static func find(_ name: String, inDirectories directories: [String]) -> URL? {
        for d in directories where !d.isEmpty {
            for file in candidateFileNames(name) {
                let p = (d as NSString).appendingPathComponent(file)
                if isExecutable(atPath: p) { return URL(fileURLWithPath: p) }
            }
        }
        return nil
    }

    /// An MPI launcher for parallel ORCA: `mpiexec.exe` (MS-MPI: `MSMPI_BIN`, `C:\Program Files\Microsoft MPI\Bin`,
    /// PATH) on Windows, `mpirun` (next to ORCA, then PATH) elsewhere. Directories next to `orca` are searched first.
    public static func mpiLauncher(orca: URL? = nil, env: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        var dirs: [String] = []
        if let o = orca { dirs.append(o.deletingLastPathComponent().path) }
        #if os(Windows)
        if let b = environmentValue("MSMPI_BIN", in: env), !b.isEmpty { dirs.append(b) }
        dirs += pathDirectories(env: env)
        let pf = environmentValue("ProgramFiles", in: env) ?? "C:\\Program Files"
        dirs.append("\(pf)\\Microsoft MPI\\Bin")
        return find("mpiexec", inDirectories: dirs)
        #else
        dirs += pathDirectories(env: env)
        return find("mpirun", inDirectories: dirs)
        #endif
    }

    /// Checks that ORCA can be launched with `nprocs` processes. ORCA must be started by absolute path when
    /// running in parallel (it re-launches its own helper programs through MPI); on Windows it also needs MS-MPI's
    /// `mpiexec`. Returns the MPI launcher (nil when `nprocs <= 1`). Throws `ComputeError.notInstalled` with an
    /// explanatory message otherwise.
    @discardableResult
    public static func checkORCALaunch(executable: URL, nprocs: Int,
                                       env: [String: String] = ProcessInfo.processInfo.environment) throws -> URL? {
        guard nprocs > 1 else { return nil }
        let path = executable.path
        #if os(Windows)
        let absolute = path.count >= 3 && (path.dropFirst().hasPrefix(":\\") || path.dropFirst().hasPrefix(":/")) || path.hasPrefix("\\\\")
        #else
        let absolute = path.hasPrefix("/")
        #endif
        guard absolute else {
            throw ComputeError.parse("ORCA must be launched by its absolute path when nprocs > 1 (got \"\(path)\").")
        }
        if let m = mpiLauncher(orca: executable, env: env) { return m }
        #if os(Windows)
        throw ComputeError.notInstalled(program: "mpiexec", searched: [
            executable.deletingLastPathComponent().path, "%MSMPI_BIN%", "PATH", "C:\\Program Files\\Microsoft MPI\\Bin"])
        #else
        throw ComputeError.notInstalled(program: "mpirun", searched: [executable.deletingLastPathComponent().path] + pathDirectories(env: env))
        #endif
    }

    #if os(Windows)
    /// Subdirectories of `parent` whose name starts with `prefix` (case-insensitive), sorted descending so newer
    /// versions (`orca_6_1_1` before `orca_5_0_4`) come first.
    static func windowsDirectories(in parent: String, prefix: String) -> [String] {
        guard let subs = try? FileManager.default.contentsOfDirectory(atPath: parent) else { return [] }
        let p = prefix.lowercased()
        return subs.filter { $0.lowercased().hasPrefix(p) }.sorted(by: >).map { (parent as NSString).appendingPathComponent($0) }
            .filter { var d: ObjCBool = false; return FileManager.default.fileExists(atPath: $0, isDirectory: &d) && d.boolValue }
    }

    /// Windows search order: PATH, conda-style installs (root and `envs\*`: `Library\bin`, `Scripts`, `bin`, root),
    /// `%LOCALAPPDATA%\Programs`, plus program-specific default install locations for xtb, ORCA, Gaussian and MS-MPI.
    static func windowsSearchDirectories(for name: String, env: [String: String]) -> [String] {
        let fm = FileManager.default
        func v(_ k: String) -> String? { let x = environmentValue(k, in: env); return (x?.isEmpty ?? true) ? nil : x }
        let home = v("USERPROFILE") ?? NSHomeDirectory()
        let local = v("LOCALAPPDATA") ?? "\(home)\\AppData\\Local"
        let pf = v("ProgramFiles") ?? "C:\\Program Files"
        let pf86 = v("ProgramFiles(x86)")
        let programData = v("ProgramData") ?? "C:\\ProgramData"
        let systemDrive = v("SystemDrive") ?? "C:"
        let prog = ((name as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()

        var dirs = pathDirectories(env: env)
        func condaLayout(_ root: String) -> [String] {
            [root + "\\Library\\bin", root + "\\Scripts", root + "\\bin", root]
        }
        if let p = v("CONDA_PREFIX") { dirs += condaLayout(p) }
        if prog == "xtb", let x = v("XTBHOME") { dirs += [x + "\\bin", x] }
        for parent in [home, local, programData, systemDrive + "\\"] {
            for root in ["miniconda3", "anaconda3", "miniforge3", "mambaforge", "micromamba"] {
                let r = (parent as NSString).appendingPathComponent(root)
                guard fm.fileExists(atPath: r) else { continue }
                dirs += condaLayout(r)
                let envs = r + "\\envs"
                if let subs = try? fm.contentsOfDirectory(atPath: envs) {
                    for e in subs.sorted() { dirs += condaLayout(envs + "\\" + e) }
                }
            }
        }
        // %LOCALAPPDATA%\Programs\<app>[\bin]
        let programs = local + "\\Programs"
        if let subs = try? fm.contentsOfDirectory(atPath: programs) {
            dirs.append(programs)
            for s in subs.sorted() { dirs += [programs + "\\" + s + "\\bin", programs + "\\" + s] }
        }
        let programFiles = [pf] + (pf86.map { [$0] } ?? [])
        switch prog {
        case "xtb":
            for root in programFiles + [systemDrive + "\\"] {
                for d in windowsDirectories(in: root, prefix: "xtb") { dirs += [d + "\\bin", d] }
            }
        case "orca", "orca_2mkl":
            if let o = v("ORCA_PATH") { dirs.append(o) }
            for root in [systemDrive + "\\", home] + programFiles {
                for d in windowsDirectories(in: root, prefix: "orca") { dirs += [d, d + "\\bin"] }
            }
        case "g16", "g09", "formchk", "cubegen":
            if let d = v("GAUSS_EXEDIR") { dirs += d.split(separator: ";").map(String.init) }
            for r in ["g16root", "g09root"] { if let x = v(r) { dirs += [x + "\\G16W", x + "\\G09W", x] } }
            for root in [systemDrive + "\\"] + programFiles {
                dirs += [root + "\\G16W", root + "\\G09W"]
            }
        case "qchem":
            if let q = v("QC") { dirs.append(q + "\\bin") }
        case "mpiexec":
            if let b = v("MSMPI_BIN") { dirs.append(b) }
            dirs.append(pf + "\\Microsoft MPI\\Bin")
        default:
            break
        }
        return dirs
    }
    #endif
}

/// Quotes one argument for display in a command-line preview: POSIX shell style on macOS/Linux, and the
/// Windows (cmd / CommandLineToArgvW) convention on Windows (double quotes, `\"` inside, backslashes doubled
/// before a quote).
func quoteArgument(_ a: String) -> String {
    #if os(Windows)
    if a.isEmpty { return "\"\"" }
    let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./\\=:,+@")
    if a.unicodeScalars.allSatisfy({ safe.contains($0) }) { return a }
    var out = "\"", backslashes = 0
    for ch in a {
        if ch == "\\" { backslashes += 1; continue }
        if ch == "\"" { out += String(repeating: "\\", count: 2 * backslashes + 1) + "\""; backslashes = 0; continue }
        out += String(repeating: "\\", count: backslashes) + String(ch); backslashes = 0
    }
    return out + String(repeating: "\\", count: 2 * backslashes) + "\""
    #else
    if a.isEmpty { return "''" }
    let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./=:,+@%")
    if a.unicodeScalars.allSatisfy({ safe.contains($0) }) { return a }
    return "'" + a.replacingOccurrences(of: "'", with: "'\\''") + "'"
    #endif
}

/// Environment-variable prefix for a command-line preview: `NAME=value ` (POSIX) or `set "NAME=value" && ` (cmd).
func environmentPrefix(_ name: String, _ value: String) -> String {
    #if os(Windows)
    return "set \"\(name)=\(value)\" && "
    #else
    return "\(name)=\(value) "
    #endif
}
