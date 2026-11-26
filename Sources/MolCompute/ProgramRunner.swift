import Foundation

public enum ProgramLocator {
    /// `~/Library/Application Support/VibeView/`: where the installer puts helper programs such as xtb.
    public static var managedDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/VibeView")
    }

    public static func searchDirectories(for name: String = "") -> [String] {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        var dirs: [String] = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        for root in ["miniconda3", "miniforge3", "anaconda3", "mambaforge", "micromamba"] {
            let envs = "\(home)/\(root)/envs"
            if let subs = try? fm.contentsOfDirectory(atPath: envs) {
                dirs += subs.sorted().map { "\(envs)/\($0)/bin" }
            }
            dirs.append("\(home)/\(root)/bin")
        }
        dirs += ["/opt/homebrew/bin", "/usr/local/bin"]
        // Programs VibeView installed itself (scripts/install.sh puts xtb here when none was found).
        dirs.append(ProgramLocator.managedDirectory.appendingPathComponent("xtb/bin").path)
        var seen = Set<String>()
        return dirs.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    public static func find(_ name: String, extraDirectories: [String] = []) -> URL? {
        let fm = FileManager.default
        if name.contains("/") { return fm.isExecutableFile(atPath: name) ? URL(fileURLWithPath: name) : nil }
        for d in extraDirectories + searchDirectories(for: name) {
            let p = (d as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: p, isDirectory: &isDir), !isDir.boolValue, fm.isExecutableFile(atPath: p) {
                return URL(fileURLWithPath: p)
            }
        }
        return nil
    }
}

public struct ProcessOutput: Sendable, Equatable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String
}

public enum ProgramRunner {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var out = Data(), err = Data()
        var cancelled = false, timedOut = false
        func withLock<T>(_ f: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return f() }
    }

    public static func run(executable: URL, arguments: [String], workingDirectory: URL? = nil,
                           environment: [String: String]? = nil, stdin: String? = nil,
                           timeout: TimeInterval? = nil, throwOnFailure: Bool = true) async throws -> ProcessOutput {
        try await runStreaming(executable: executable, arguments: arguments, workingDirectory: workingDirectory,
                               environment: environment, stdin: stdin, timeout: timeout,
                               throwOnFailure: throwOnFailure, onOutput: { _ in })
    }

    /// `onOutput` receives chunks of stdout and stderr as they arrive.
    public static func runStreaming(executable: URL, arguments: [String], workingDirectory: URL? = nil,
                                    environment: [String: String]? = nil, stdin: String? = nil,
                                    timeout: TimeInterval? = nil, throwOnFailure: Bool = true,
                                    onOutput: @escaping @Sendable (String) -> Void) async throws -> ProcessOutput {
        try await runCore(executable: executable, arguments: arguments, workingDirectory: workingDirectory,
                          environment: environment, stdin: stdin, timeout: timeout, throwOnFailure: throwOnFailure,
                          onChunk: { _, d in if let s = String(data: d, encoding: .utf8) { onOutput(s) } })
    }

    /// Core runner: `onChunk(isStdout, data)` is called on a background queue for every chunk read.
    static func runCore(executable: URL, arguments: [String], workingDirectory: URL?,
                        environment: [String: String]?, stdin: String?,
                        timeout: TimeInterval?, throwOnFailure: Bool,
                        onStart: (@Sendable () -> Void)? = nil,
                        onChunk: @escaping @Sendable (Bool, Data) -> Void) async throws -> ProcessOutput {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        if let environment { process.environment = environment }
        let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = inPipe
        let state = State()

        // Stops the whole process tree: programs such as ORCA (and plain shells) start children that inherit
        // the output pipes, so signalling only the top process would leave them running and the pipes open.
        func kill(_ p: Process) {
            guard p.isRunning else { return }
            ProcessTree.terminate(root: p.processIdentifier)
        }

        let output: ProcessOutput = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ProcessOutput, Error>) in
                let group = DispatchGroup()
                func reader(_ pipe: Pipe, isOut: Bool) {
                    group.enter()
                    DispatchQueue.global().async {
                        let h = pipe.fileHandleForReading
                        while true {
                            let d = h.availableData
                            if d.isEmpty { break }
                            state.withLock { if isOut { state.out.append(d) } else { state.err.append(d) } }
                            onChunk(isOut, d)
                        }
                        group.leave()
                    }
                }
                // Exit is observed through terminationHandler (called on a Foundation background queue) instead of
                // waitUntilExit(), which spins the calling thread's run loop; nothing here needs the main thread.
                let exited = DispatchSemaphore(value: 0)
                process.terminationHandler = { _ in exited.signal() }
                do { try process.run() } catch {
                    cont.resume(throwing: ComputeError.processFailed(code: -1, stderr: error.localizedDescription))
                    return
                }
                onStart?()
                reader(outPipe, isOut: true)
                reader(errPipe, isOut: false)
                DispatchQueue.global().async {
                    if let stdin, let d = stdin.data(using: .utf8) { try? inPipe.fileHandleForWriting.write(contentsOf: d) }
                    try? inPipe.fileHandleForWriting.close()
                }
                if let timeout {
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                        if process.isRunning { state.withLock { state.timedOut = true }; kill(process) }
                    }
                }
                // Cancellation may have fired before the process started.
                if Task.isCancelled { state.withLock { state.cancelled = true }; kill(process) }
                DispatchQueue.global().async {
                    exited.wait()
                    // Output normally ends when the process exits. A stopped run (or a leftover grandchild that
                    // still holds the pipe) must not hold the result back indefinitely.
                    let stopped = state.withLock { state.cancelled || state.timedOut }
                    _ = group.wait(timeout: .now() + (stopped ? 3 : 30))
                    let (o, e, c, t) = state.withLock { (state.out, state.err, state.cancelled, state.timedOut) }
                    if c { cont.resume(throwing: ComputeError.cancelled); return }
                    if t { cont.resume(throwing: ComputeError.timeout); return }
                    cont.resume(returning: ProcessOutput(exitCode: process.terminationStatus,
                                                         stdout: String(decoding: o, as: UTF8.self),
                                                         stderr: String(decoding: e, as: UTF8.self)))
                }
            }
        } onCancel: {
            state.withLock { state.cancelled = true }
            kill(process)
        }
        if throwOnFailure && output.exitCode != 0 {
            throw ComputeError.processFailed(code: output.exitCode, stderr: output.stderr.isEmpty ? output.stdout : output.stderr)
        }
        return output
    }
}

/// Child-process lookup for stopping a whole process tree.
enum ProcessTree {
    /// Terminates `root` and everything it started. Each process is paused (SIGSTOP) as it is found, so
    /// nothing in the tree can start new children while it is being collected — otherwise a child forked
    /// at the moment of cancellation escapes as an orphan that keeps running and holds the output pipes.
    /// The tree then gets SIGTERM (with SIGCONT so it can act on it) and SIGKILL two seconds later.
    static func terminate(root: pid_t) {
        var tree: [pid_t] = []
        var seen = Set<pid_t>()
        var frontier = [root]
        for pass in 0..<2 {
            if pass == 1 {
                usleep(20_000)                     // a fork in flight when its parent stopped lands now
                frontier = tree
            }
            while let p = frontier.popLast(), tree.count < 4096 {
                if seen.insert(p).inserted {
                    Foundation.kill(p, SIGSTOP)
                    tree.append(p)
                }
                frontier += children(of: p).filter { !seen.contains($0) }
            }
        }
        for pid in tree { Foundation.kill(pid, SIGTERM); Foundation.kill(pid, SIGCONT) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            for pid in tree where Foundation.kill(pid, 0) == 0 { Foundation.kill(pid, SIGKILL) }
        }
    }

    static func children(of pid: pid_t) -> [pid_t] {
        var buf = [pid_t](repeating: 0, count: 256)
        let bytes = buf.withUnsafeMutableBytes { proc_listchildpids(pid, $0.baseAddress, Int32($0.count)) }
        guard bytes > 0 else { return [] }
        // proc_listchildpids returns the number of pids on recent systems and bytes on older ones.
        let n = min(Int(bytes) > buf.count ? Int(bytes) / MemoryLayout<pid_t>.size : Int(bytes), buf.count)
        return Array(buf.prefix(n)).filter { $0 > 0 }
    }
}
