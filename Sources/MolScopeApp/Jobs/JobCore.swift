import Foundation

// Non-UI job machinery: executable discovery, log scanning, and the Process runner.
// Foundation-only so it can be driven headless (see the throwaway check package).

// MARK: - Locator

enum GaussianLocator {
    /// Finds a Gaussian executable. `settingsPath` is the user's explicit path (may be empty).
    static func locate(settingsPath: String?, env: [String: String] = ProcessInfo.processInfo.environment,
                       extraSearchPaths: [String] = ["/usr/local/g16/g16", "/opt/g16/g16", "/Applications/g16/g16"]) -> URL? {
        let fm = FileManager.default
        func ok(_ p: String) -> URL? {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: p, isDirectory: &isDir), !isDir.boolValue, fm.isExecutableFile(atPath: p) else { return nil }
            return URL(fileURLWithPath: p)
        }
        if let s = settingsPath?.trimmingCharacters(in: .whitespaces), !s.isEmpty {
            let expanded = (s as NSString).expandingTildeInPath
            if let u = ok(expanded) { return u }
        }
        var candidates: [String] = []
        if let d = env["GAUSS_EXEDIR"], !d.isEmpty {
            // GAUSS_EXEDIR may be a colon-separated list
            for part in d.split(separator: ":") { candidates += ["\(part)/g16", "\(part)/g09"] }
        }
        if let r = env["g16root"], !r.isEmpty { candidates.append("\(r)/g16/g16") }
        if let r = env["g09root"], !r.isEmpty { candidates.append("\(r)/g09/g09") }
        for dir in (env["PATH"] ?? "").split(separator: ":") { candidates += ["\(dir)/g16", "\(dir)/g09"] }
        candidates += extraSearchPaths
        for c in candidates { if let u = ok(c) { return u } }
        return nil
    }

    /// Environment for the Gaussian process.
    static func environment(exe: URL, scratchSetting: String?, jobDirectory: URL,
                            base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = base
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

    /// Convenience: locate using the saved setting and the process environment.
    static func locate() -> URL? { locate(settingsPath: UserDefaults.standard.string(forKey: AppSettings.gaussianPathKey)) }

    /// Every path that would be probed, with whether an executable exists there.
    static func candidates(settingsPath: String? = UserDefaults.standard.string(forKey: AppSettings.gaussianPathKey),
                           env: [String: String] = ProcessInfo.processInfo.environment) -> [(path: String, found: Bool)] {
        var paths: [String] = []
        if let s = settingsPath, !s.isEmpty { paths.append((s as NSString).expandingTildeInPath) }
        if let d = env["GAUSS_EXEDIR"] { for p in d.split(separator: ":") { paths += ["\(p)/g16", "\(p)/g09"] } }
        if let r = env["g16root"], !r.isEmpty { paths.append("\(r)/g16/g16") }
        if let r = env["g09root"], !r.isEmpty { paths.append("\(r)/g09/g09") }
        for dir in (env["PATH"] ?? "").split(separator: ":") { paths += ["\(dir)/g16", "\(dir)/g09"] }
        paths += ["/usr/local/g16/g16", "/opt/g16/g16", "/Applications/g16/g16"]
        return paths.map { ($0, FileManager.default.isExecutableFile(atPath: $0)) }
    }

    static let notFoundMessage = "Gaussian executable not found \u{2014} set its location in Settings \u{25B8} Gaussian"
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
}

// MARK: - Log scanning

/// Incremental scanner for a growing Gaussian log.
struct LogScanner: Sendable {
    private(set) var energies: [Double] = []
    private(set) var tail: [String] = []
    private(set) var lastTerminationNormal: Bool? = nil
    private var partial = ""
    let tailLimit: Int
    init(tailLimit: Int = 200) { self.tailLimit = tailLimit }

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
        if line.contains("SCF Done:"), let e = Self.parseSCF(line) { energies.append(e) }
        else if line.contains("Normal termination") { lastTerminationNormal = true }
        else if line.contains("Error termination") { lastTerminationNormal = false }
    }

    /// "SCF Done:  E(RB3LYP) =  -76.4  A.U. after 9 cycles" -> -76.4
    static func parseSCF(_ line: String) -> Double? {
        guard let r = line.range(of: "SCF Done:") else { return nil }
        let rest = line[r.upperBound...]
        guard let eq = rest.firstIndex(of: "=") else { return nil }
        let tok = rest[rest.index(after: eq)...].split(whereSeparator: { $0 == " " || $0 == "\t" }).first
        return tok.flatMap { Double($0) }
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

/// Runs `exe < input > log` and tails the log. Callbacks arrive on an internal serial queue.
final class JobProcess: @unchecked Sendable {
    private let exe: URL, input: URL, log: URL
    private let environment: [String: String]
    private let queue = DispatchQueue(label: "molscope.jobprocess")
    private let process = Process()
    private var timer: DispatchSourceTimer?
    private var scanner = LogScanner()
    private var readHandle: FileHandle?
    private var cancelled = false
    private var finished = false
    private let onUpdate: @Sendable (JobSnapshot) -> Void
    private let onExit: @Sendable (JobOutcome, JobSnapshot) -> Void
    private let interval: TimeInterval

    init(executable: URL, input: URL, log: URL, environment: [String: String], interval: TimeInterval = 0.5,
         onUpdate: @escaping @Sendable (JobSnapshot) -> Void, onExit: @escaping @Sendable (JobOutcome, JobSnapshot) -> Void) {
        self.exe = executable; self.input = input; self.log = log; self.environment = environment
        self.interval = interval; self.onUpdate = onUpdate; self.onExit = onExit
    }

    func start() throws {
        let fm = FileManager.default
        fm.createFile(atPath: log.path, contents: nil)
        let out = try FileHandle(forWritingTo: log)
        let inp = try FileHandle(forReadingFrom: input)
        readHandle = try FileHandle(forReadingFrom: log)
        process.executableURL = exe
        process.currentDirectoryURL = input.deletingLastPathComponent()
        process.environment = environment
        process.standardInput = inp
        process.standardOutput = out
        process.standardError = out
        process.terminationHandler = { [weak self] _ in
            self?.queue.async { self?.processEnded(out: out, inp: inp) }
        }
        do { try process.run() } catch {
            try? out.close(); try? inp.close(); try? readHandle?.close()
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

    private func processEnded(out: FileHandle, inp: FileHandle) {
        guard !finished else { return }
        finished = true
        timer?.cancel(); timer = nil
        drain(); scanner.finish()
        try? out.close(); try? inp.close(); try? readHandle?.close()
        let status = process.terminationStatus
        let outcome: JobOutcome
        if cancelled { outcome = .cancelled }
        else if let normal = scanner.lastTerminationNormal { outcome = .finished(normal: normal) }
        else if status != 0 { outcome = .failed("Gaussian exited with status \(status)") }
        else { outcome = .finished(normal: false) }
        onExit(outcome, snapshot())
    }
}

/// Tiny observable box used instead of @State (SwiftUI macro plugins are unavailable here).
final class VMBox<T>: ObservableObject {
    @Published var value: T
    init(_ v: T) { value = v }
}
