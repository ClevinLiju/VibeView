import Foundation

public enum ProgramLocator {
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

        func kill(_ p: Process) {
            guard p.isRunning else { return }
            p.terminate()
            let pid = p.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if p.isRunning { Foundation.kill(pid, SIGKILL) }
            }
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
                            if let s = String(data: d, encoding: .utf8) { onOutput(s) }
                        }
                        group.leave()
                    }
                }
                do { try process.run() } catch {
                    cont.resume(throwing: ComputeError.processFailed(code: -1, stderr: error.localizedDescription))
                    return
                }
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
                    process.waitUntilExit()
                    group.wait()
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
