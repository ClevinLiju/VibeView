import Foundation

public enum ProgramLocator {
    public static func searchDirectories(for name: String = "") -> [String] {
        #if os(Windows)
        var seenWin = Set<String>()
        return windowsSearchDirectories(for: name, env: ProcessInfo.processInfo.environment)
            .filter { !$0.isEmpty && seenWin.insert($0.lowercased()).inserted }
        #else
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
        #endif
    }

    public static func find(_ name: String, extraDirectories: [String] = []) -> URL? {
        #if os(Windows)
        // A path (absolute or relative): accept it as given, or with a PATHEXT extension appended.
        if name.contains("\\") || name.contains("/") || name.contains(":") {
            for c in candidateFileNames(name) where isExecutable(atPath: c) { return URL(fileURLWithPath: c) }
            return isExecutable(atPath: name) ? URL(fileURLWithPath: name) : nil
        }
        return find(name, inDirectories: extraDirectories + searchDirectories(for: name))
        #else
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
        #endif
    }
}

#if os(Windows)
/// `taskkill /PID <pid> /T /F`: terminates a process and all its descendants. Waits at most 5 s.
func killProcessTreeWindows(pid: Int32) {
    let root = ProgramLocator.environmentValue("SystemRoot") ?? "C:\\Windows"
    let tk = Process()
    tk.executableURL = URL(fileURLWithPath: root + "\\System32\\taskkill.exe")
    tk.arguments = ["/PID", String(pid), "/T", "/F"]
    tk.standardInput = FileHandle.nullDevice
    tk.standardOutput = FileHandle.nullDevice
    tk.standardError = FileHandle.nullDevice
    let done = DispatchSemaphore(value: 0)
    tk.terminationHandler = { _ in done.signal() }
    do { try tk.run() } catch { return }
    _ = done.wait(timeout: .now() + 5)
}
#endif

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
        if let environment { process.environment = ProgramLocator.normalizedEnvironment(environment) }
        let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = inPipe
        let state = State()

        func kill(_ p: Process) {
            guard p.isRunning else { return }
            #if os(Windows)
            // terminate() is TerminateProcess on the child only; MPI ranks / helper processes it started would
            // survive (and keep our pipes open). Kill the whole tree with taskkill first, then fall back.
            let pid = p.processIdentifier
            DispatchQueue.global().async {
                killProcessTreeWindows(pid: pid)
                if p.isRunning { p.terminate() }
            }
            #else
            p.terminate()
            let pid = p.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if p.isRunning { Foundation.kill(pid, SIGKILL) }
            }
            #endif
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
