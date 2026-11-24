import Foundation
import MolBuild

// Non-UI job machinery: executable discovery, per-program log scanning, and the Process runner.
// Foundation + MolBuild only so it can be driven headless.

// MARK: - Locator

enum ProgramLocator {
    static func settingKey(_ p: QCProgram) -> String {
        switch p {
        case .gaussian: AppSettings.gaussianPathKey
        case .orca: AppSettings.orcaPathKey
        case .qchem: AppSettings.qchemPathKey
        case .xtb: AppSettings.xtbPathKey
        }
    }

    static func savedPath(_ p: QCProgram) -> String? { UserDefaults.standard.string(forKey: settingKey(p)) }

    /// Directories GUI apps do not get in their minimal PATH.
    static let extraPathDirs = ["/opt/homebrew/bin", "/usr/local/bin"]

    static func pathDirs(env: [String: String]) -> [String] {
        let fromEnv = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>(), out: [String] = []
        for d in fromEnv + extraPathDirs where !d.isEmpty && seen.insert(d).inserted { out.append(d) }
        return out
    }

    /// Directories like ~/Library/orca_6_1_1, newest name first, each contributing `<dir>/<exe>`.
    private static func globDirs(in parent: String, prefix: String, exe: String) -> [String] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: parent) else { return [] }
        return names.filter { $0.lowercased().hasPrefix(prefix) }
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            .map { "\(parent)/\($0)/\(exe)" }
    }

    /// Every path that would be probed, in priority order (duplicates removed).
    static func candidatePaths(_ p: QCProgram, settingsPath: String?, env: [String: String]) -> [String] {
        var c: [String] = []
        if let s = settingsPath?.trimmingCharacters(in: .whitespaces), !s.isEmpty { c.append((s as NSString).expandingTildeInPath) }
        let home = NSHomeDirectory()
        switch p {
        case .gaussian:
            if let d = env["GAUSS_EXEDIR"], !d.isEmpty { for part in d.split(separator: ":") { c += ["\(part)/g16", "\(part)/g09"] } }
            if let r = env["g16root"], !r.isEmpty { c.append("\(r)/g16/g16") }
            if let r = env["g09root"], !r.isEmpty { c.append("\(r)/g09/g09") }
            for d in pathDirs(env: env) { c += ["\(d)/g16", "\(d)/g09"] }
            c += ["/usr/local/g16/g16", "/opt/g16/g16", "/Applications/g16/g16"]
        case .orca:
            for d in pathDirs(env: env) { c.append("\(d)/orca") }
            c += globDirs(in: "\(home)/Library", prefix: "orca", exe: "orca")
            c += globDirs(in: "/Applications", prefix: "orca", exe: "orca")
            c += globDirs(in: "/opt", prefix: "orca", exe: "orca")
        case .qchem:
            if let q = env["QC"], !q.isEmpty { c.append("\(q)/bin/qchem") }
            for d in pathDirs(env: env) { c.append("\(d)/qchem") }
            c += ["/opt/qchem/bin/qchem", "/usr/local/qchem/bin/qchem"]
        case .xtb:
            if let x = env["XTBHOME"], !x.isEmpty { c += ["\(x)/bin/xtb", "\(x)/xtb"] }
            for d in pathDirs(env: env) { c.append("\(d)/xtb") }
            c += ["/opt/homebrew/bin/xtb", "/usr/local/bin/xtb"]
            for m in ["miniconda3", "miniforge3", "mambaforge", "anaconda3"] { c.append("\(home)/\(m)/bin/xtb") }
        }
        var seen = Set<String>()
        return c.filter { seen.insert($0).inserted }
    }

    private static func isExecutableFile(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && !isDir.boolValue && FileManager.default.isExecutableFile(atPath: path)
    }

    static func locate(_ p: QCProgram, settingsPath: String? = nil, env: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        let s = settingsPath ?? savedPath(p)
        for c in candidatePaths(p, settingsPath: s, env: env) where isExecutableFile(c) { return URL(fileURLWithPath: c) }
        return nil
    }

    /// Candidate paths with whether an executable exists there (for Preferences).
    static func candidates(_ p: QCProgram, settingsPath: String? = nil,
                           env: [String: String] = ProcessInfo.processInfo.environment) -> [(path: String, found: Bool)] {
        candidatePaths(p, settingsPath: settingsPath ?? savedPath(p), env: env).map { ($0, isExecutableFile($0)) }
    }

    /// An MPI launcher ORCA needs for nprocs > 1.
    static func mpirun(env: [String: String] = ProcessInfo.processInfo.environment, orca: URL? = nil) -> URL? {
        var dirs = pathDirs(env: env)
        if let o = orca { dirs.insert(o.deletingLastPathComponent().path, at: 0) }
        for d in dirs where isExecutableFile("\(d)/mpirun") { return URL(fileURLWithPath: "\(d)/mpirun") }
        return nil
    }

    static func notFoundMessage(_ p: QCProgram) -> String { "\(p.title) not found \u{2014} set its path in Settings" }

    // MARK: Environments

    /// Base environment for GUI-launched children: a usable PATH.
    static func baseEnvironment(extraDirs: [String] = []) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (extraDirs + pathDirs(env: env) + ["/usr/bin", "/bin"]).joined(separator: ":")
        return env
    }

    static func gaussianEnvironment(exe: URL, scratchSetting: String?, jobDirectory: URL) -> [String: String] {
        var env = baseEnvironment()
        let exeDir = exe.deletingLastPathComponent()
        if (env["GAUSS_EXEDIR"] ?? "").isEmpty { env["GAUSS_EXEDIR"] = exeDir.path }
        let name = exeDir.lastPathComponent
        if name == "g16", (env["g16root"] ?? "").isEmpty { env["g16root"] = exeDir.deletingLastPathComponent().path }
        if name == "g09", (env["g09root"] ?? "").isEmpty { env["g09root"] = exeDir.deletingLastPathComponent().path }
        if let s = scratchSetting?.trimmingCharacters(in: .whitespaces), !s.isEmpty {
            let p = (s as NSString).expandingTildeInPath
            try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
            env["GAUSS_SCRDIR"] = p
        } else if (env["GAUSS_SCRDIR"] ?? "").isEmpty {
            env["GAUSS_SCRDIR"] = jobDirectory.path
        }
        return env
    }
}

// MARK: - Status

enum JobStatus: Equatable, Sendable {
    case queued, running, finished(normal: Bool), failed(String), cancelled
    var isActive: Bool { self == .queued || self == .running }
    var label: String {
        switch self {
        case .queued: "Queued"
        case .running: "Running"
        case .finished(let n): n ? "Finished" : "Error termination"
        case .failed(let m): "Failed: \(m)"
        case .cancelled: "Cancelled"
        }
    }
    var symbol: String {
        switch self {
        case .queued: "clock"
        case .running: "play.circle.fill"
        case .finished(let n): n ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
        case .failed: "xmark.octagon.fill"
        case .cancelled: "stop.circle"
        }
    }
}

// MARK: - Log scanning

/// Incremental scanner for a growing program log (patterns depend on the program).
struct LogScanner: Sendable {
    let program: QCProgram
    private(set) var energies: [Double] = []
    private(set) var tail: [String] = []
    private(set) var lastTerminationNormal: Bool? = nil
    private var partial = ""
    let tailLimit: Int
    init(program: QCProgram = .gaussian, tailLimit: Int = 200) { self.program = program; self.tailLimit = tailLimit }

    var lastEnergy: Double? { energies.last }
    var tailText: String { tail.joined(separator: "\n") }

    mutating func feed(_ chunk: String) {
        guard !chunk.isEmpty else { return }
        let text = partial + chunk
        var lines = text.components(separatedBy: "\n")
        partial = lines.removeLast()
        for l in lines { ingest(l) }
        if tail.count > tailLimit { tail.removeFirst(tail.count - tailLimit) }
    }

    /// Flush a trailing line with no newline.
    mutating func finish() {
        if !partial.isEmpty { ingest(partial); partial = "" }
        if tail.count > tailLimit { tail.removeFirst(tail.count - tailLimit) }
    }

    private mutating func ingest(_ raw: String) {
        let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
        tail.append(line)
        switch program {
        case .gaussian:
            if line.contains("SCF Done:"), let e = Self.parseSCF(line) { energies.append(e) }
            else if line.contains("Normal termination") { lastTerminationNormal = true }
            else if line.contains("Error termination") { lastTerminationNormal = false }
        case .orca:
            if let e = Self.number(after: "FINAL SINGLE POINT ENERGY", in: line) { energies.append(e) }
            else if line.contains("ORCA TERMINATED NORMALLY") { lastTerminationNormal = true }
            else if line.contains("ORCA finished by error") { lastTerminationNormal = false }
        case .qchem:
            if let e = Self.number(after: "Total energy in the final basis set =", in: line) ?? Self.number(after: "Final energy is", in: line) { energies.append(e) }
            else if line.contains("Thank you very much for using Q-Chem") { lastTerminationNormal = true }
        case .xtb:
            if line.contains("TOTAL ENERGY"), let e = Self.number(after: "TOTAL ENERGY", in: line) { energies.append(e) }
            else if line.contains("abnormal termination of xtb") { lastTerminationNormal = false }
            else if line.contains("normal termination of xtb") { lastTerminationNormal = true }
        }
    }

    /// "SCF Done:  E(RB3LYP) =  -76.4  A.U. after 9 cycles" -> -76.4
    static func parseSCF(_ line: String) -> Double? {
        guard let r = line.range(of: "SCF Done:") else { return nil }
        let rest = line[r.upperBound...]
        guard let eq = rest.firstIndex(of: "=") else { return nil }
        let tok = rest[rest.index(after: eq)...].split(whereSeparator: { $0 == " " || $0 == "\t" }).first
        return tok.flatMap { Double($0) }
    }

    /// First numeric token (within the first three) after `marker`, ignoring "=" / ":" separators.
    static func number(after marker: String, in line: String) -> Double? {
        guard let r = line.range(of: marker) else { return nil }
        let toks = line[r.upperBound...].split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" || $0 == ":" || $0 == "|" })
        for t in toks.prefix(3) { if let d = Double(t) { return d } }
        return nil
    }
}

// MARK: - Process runner

struct JobSnapshot: Sendable {
    var tail: String
    var energies: [Double]
}

enum JobOutcome: Sendable, Equatable {
    case finished(normal: Bool), failed(String), cancelled
}

/// Describes one process invocation.
struct JobLaunch: Sendable {
    var program: QCProgram
    var executable: URL
    var arguments: [String] = []
    var stdinFile: URL? = nil
    /// The file whose growth is tailed (the program's output).
    var outputFile: URL
    /// Where the process's stdout/stderr go (defaults to `outputFile`; use a different file for programs that write their own output).
    var stdoutFile: URL? = nil
    var workingDirectory: URL
    var environment: [String: String]
}

/// Runs a launch description and tails the output. Callbacks arrive on an internal serial queue.
final class JobProcess: @unchecked Sendable {
    private let launch: JobLaunch
    private let queue = DispatchQueue(label: "molscope.jobprocess")
    private let process = Process()
    private var timer: DispatchSourceTimer?
    private var scanner: LogScanner
    private var readHandle: FileHandle?
    private var cancelled = false
    private var finished = false
    private let onUpdate: @Sendable (JobSnapshot) -> Void
    private let onExit: @Sendable (JobOutcome, JobSnapshot) -> Void
    private let interval: TimeInterval

    init(launch: JobLaunch, interval: TimeInterval = 0.5,
         onUpdate: @escaping @Sendable (JobSnapshot) -> Void, onExit: @escaping @Sendable (JobOutcome, JobSnapshot) -> Void) {
        self.launch = launch; self.scanner = LogScanner(program: launch.program)
        self.interval = interval; self.onUpdate = onUpdate; self.onExit = onExit
    }

    func start() throws {
        let fm = FileManager.default
        let outURL = launch.stdoutFile ?? launch.outputFile
        fm.createFile(atPath: outURL.path, contents: nil)
        let out = try FileHandle(forWritingTo: outURL)
        let inp = try launch.stdinFile.map { try FileHandle(forReadingFrom: $0) }
        readHandle = try? FileHandle(forReadingFrom: launch.outputFile)   // opened lazily when the program creates its own file
        process.executableURL = launch.executable
        process.arguments = launch.arguments
        process.currentDirectoryURL = launch.workingDirectory
        process.environment = launch.environment
        if let inp { process.standardInput = inp } else { process.standardInput = FileHandle.nullDevice }
        process.standardOutput = out
        process.standardError = out
        process.terminationHandler = { [weak self] _ in
            self?.queue.async { self?.processEnded(out: out, inp: inp) }
        }
        do { try process.run() } catch {
            try? out.close(); try? inp?.close(); try? readHandle?.close()
            throw error
        }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + interval, repeating: interval)
        t.setEventHandler { [weak self] in self?.poll() }
        timer = t
        t.resume()
    }

    func cancel() {
        queue.async {
            self.cancelled = true
            if self.process.isRunning { self.process.terminate() }
        }
    }

    private func drain() {
        if readHandle == nil { readHandle = try? FileHandle(forReadingFrom: launch.outputFile) }
        guard let h = readHandle else { return }
        while let data = try? h.read(upToCount: 1 << 20), !data.isEmpty {
            scanner.feed(String(decoding: data, as: UTF8.self))
        }
    }

    private func snapshot() -> JobSnapshot { JobSnapshot(tail: scanner.tailText, energies: scanner.energies) }

    private func poll() {
        guard !finished else { return }
        drain()
        onUpdate(snapshot())
    }

    private func processEnded(out: FileHandle, inp: FileHandle?) {
        guard !finished else { return }
        finished = true
        timer?.cancel(); timer = nil
        drain(); scanner.finish()
        try? out.close(); try? inp?.close(); try? readHandle?.close()
        let status = process.terminationStatus
        let outcome: JobOutcome
        if cancelled { outcome = .cancelled }
        else if let normal = scanner.lastTerminationNormal { outcome = .finished(normal: normal && status == 0) }
        else if status != 0 { outcome = .failed("\(launch.program.title) exited with status \(status)") }
        else { outcome = .finished(normal: true) }
        onExit(outcome, snapshot())
    }
}
