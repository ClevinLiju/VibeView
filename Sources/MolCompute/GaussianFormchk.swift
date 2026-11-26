import Foundation

/// Automatic Gaussian `.chk` → `.fchk` conversion with Gaussian's `formchk`, so orbitals can be drawn without a
/// manual step. MolIO loads `<stem>.fchk` as the wavefunction companion of `<stem>.log` / `<stem>.out`.
///
/// - `formchk <stem>.chk <tmp>.fchk` runs in the checkpoint's folder with relative names, so spaces and
///   non-ASCII folder names never pass through a command line.
/// - The output goes to a temporary name first and replaces the target only when the target is missing or older
///   than the `.chk`; a `.fchk` that is newer (written by the user or another formchk meanwhile) is never overwritten.
/// - formchk is looked up in `GAUSS_EXEDIR`, next to the g16/g09 executable, then on PATH. Not finding it is not an
///   error for callers: they keep the "run formchk" hint.
public enum GaussianFormchk {
    public static let defaultTimeout: TimeInterval = 600

    /// `<stem>.fchk` next to `chk`.
    public static func fchkURL(for chk: URL) -> URL {
        chk.deletingPathExtension().appendingPathExtension("fchk")
    }

    static func modificationDate(_ u: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: u.path))?[.modificationDate] as? Date
    }

    /// True when `fchk` exists, is not empty and is at least as new as `chk`.
    public static func isUpToDate(chk: URL, fchk: URL) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fchk.path),
              ((attrs[.size] as? NSNumber)?.intValue ?? 0) > 0,
              let tf = attrs[.modificationDate] as? Date else { return false }
        guard let tc = modificationDate(chk) else { return true }
        return tf >= tc
    }

    /// A conversion is worth running: the `.chk` exists and `fchk` is missing, empty or older.
    public static func needsConversion(chk: URL, fchk: URL? = nil) -> Bool {
        FileManager.default.fileExists(atPath: chk.path) && !isUpToDate(chk: chk, fchk: fchk ?? fchkURL(for: chk))
    }

    /// formchk in the `GAUSS_EXEDIR` folders, next to the Gaussian executable (symlinks followed), then on PATH.
    public static func locate(gaussian: URL? = nil, environment env: [String: String] = ProcessInfo.processInfo.environment,
                              searchPath: Bool = true) -> URL? {
        let fm = FileManager.default
        var dirs: [String] = []
        if let e = env["GAUSS_EXEDIR"], !e.isEmpty { dirs += e.split(separator: ":").map(String.init) }
        if let g = gaussian {
            dirs.append(g.deletingLastPathComponent().path)
            let r = g.resolvingSymlinksInPath().deletingLastPathComponent().path
            if !dirs.contains(r) { dirs.append(r) }
        }
        for d in dirs {
            let p = (d as NSString).appendingPathComponent("formchk")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: p, isDirectory: &isDir), !isDir.boolValue, fm.isExecutableFile(atPath: p) { return URL(fileURLWithPath: p) }
        }
        return searchPath ? ProgramLocator.find("formchk") : nil
    }

    /// The `%chk=` file named in a Gaussian input (the last one wins, as in Gaussian), or nil.
    public static func checkpointName(inGaussianInput text: String) -> String? {
        var name: String?
        for raw in text.split(whereSeparator: \.isNewline) {
            let l = raw.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("#") { break }
            guard l.lowercased().hasPrefix("%chk=") else { continue }
            let v = l.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if !v.isEmpty { name = v.contains(".") ? v : v + ".chk" }
        }
        return name
    }

    public enum Outcome: Sendable, Equatable {
        /// The `.fchk` was already up to date (nothing ran).
        case upToDate(URL)
        /// formchk wrote a new `.fchk`.
        case converted(URL)
        /// A newer `.fchk` appeared while formchk ran; it was kept and formchk's output discarded.
        case keptNewer(URL)
        public var url: URL { switch self { case .upToDate(let u), .converted(let u), .keptNewer(let u): u } }
    }

    /// Converts `chk` to `fchk` (default `<stem>.fchk` next to it). Throws `.notFound` when the checkpoint is missing,
    /// `.processFailed` when formchk fails or writes nothing, `.timeout` / `.cancelled` as `ProgramRunner` does.
    public static func convert(chk: URL, to fchk: URL? = nil, executable exe: URL,
                               timeout: TimeInterval = defaultTimeout) async throws -> Outcome {
        let fm = FileManager.default
        guard fm.fileExists(atPath: chk.path) else { throw ComputeError.notFound(chk.path) }
        let target = fchk ?? fchkURL(for: chk)
        if isUpToDate(chk: chk, fchk: target) { return .upToDate(target) }
        let dir = chk.deletingLastPathComponent()
        let stem = chk.deletingPathExtension().lastPathComponent
        let tmp = dir.appendingPathComponent("\(stem).vibeview-\(ProcessInfo.processInfo.processIdentifier)-\(UInt32.random(in: 0...UInt32.max)).fchk")
        try? fm.removeItem(at: tmp)
        defer { try? fm.removeItem(at: tmp) }
        var env = ProcessInfo.processInfo.environment
        if (env["GAUSS_EXEDIR"] ?? "").isEmpty { env["GAUSS_EXEDIR"] = exe.deletingLastPathComponent().path }
        env["PATH"] = ([exe.deletingLastPathComponent().path] + (env["PATH"] ?? "/usr/bin:/bin").split(separator: ":").map(String.init))
            .joined(separator: ":")
        let started = Date()
        // The checkpoint is passed relative to the folder; a target elsewhere is moved there afterwards.
        let r = try await ProgramRunner.run(executable: exe, arguments: [chk.lastPathComponent, tmp.lastPathComponent],
                                            workingDirectory: dir, environment: env, timeout: timeout, throwOnFailure: false)
        let size = ((try? fm.attributesOfItem(atPath: tmp.path))?[.size] as? NSNumber)?.intValue ?? 0
        guard r.exitCode == 0, size > 0 else {
            let tail = (r.stderr + "\n" + r.stdout).split(whereSeparator: \.isNewline).suffix(4).joined(separator: " | ")
            throw ComputeError.processFailed(code: r.exitCode, stderr: tail.isEmpty ? "formchk wrote no \(target.lastPathComponent)" : tail)
        }
        // Never overwrite a .fchk that appeared or was refreshed while formchk ran.
        if fm.fileExists(atPath: target.path), let t = modificationDate(target), t >= started || isUpToDate(chk: chk, fchk: target) {
            return .keptNewer(target)
        }
        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
        try fm.moveItem(at: tmp, to: target)
        // Stamp as made now so it counts as up to date even if a wrapper kept the source timestamp.
        try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: target.path)
        return .converted(target)
    }
}
