import Foundation

public enum ProgramLocator {
    /// Where VibeView keeps helper programs it installed itself, such as xtb (`<this>/xtb/bin`):
    /// `%APPDATA%\VibeView` on Windows (the Electron app's data folder), `~/Library/Application Support/VibeView`
    /// on macOS. `managedDirectoryOverride`, then `VIBEVIEW_MANAGED_DIR`, override it (tests, a custom data folder).
    nonisolated(unsafe) public static var managedDirectoryOverride: URL?
    public static var managedDirectory: URL {
        if let o = managedDirectoryOverride { return o }
        if let o = environmentValue("VIBEVIEW_MANAGED_DIR"), !o.isEmpty { return URL(fileURLWithPath: o, isDirectory: true) }
        #if os(Windows)
        let appData = environmentValue("APPDATA") ?? (NSHomeDirectory() + "\\AppData\\Roaming")
        return URL(fileURLWithPath: appData, isDirectory: true).appendingPathComponent("VibeView", isDirectory: true)
        #else
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/VibeView")
        #endif
    }

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
        // Programs VibeView installed itself (xtb).
        dirs.append(ProgramLocator.managedDirectory.appendingPathComponent("xtb/bin").path)
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
import WinSDK

/// `taskkill /PID <pid> /T /F`: terminates a process and all its descendants that can still be found through
/// their parent process id. Waits at most 5 s. The fallback when the process could not be put in a job object.
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

/// A Windows job object that holds a started program and, automatically, every process it starts (Gaussian's
/// l*.exe links, ORCA's orca_* helpers, mpiexec/smpd and the MPI ranks), even after their parent has exited, which
/// `taskkill /T` can no longer follow. `terminate()` stops the whole tree at once; closing the job (after the run,
/// or when the engine itself dies) kills whatever is left (JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE).
///
/// It also keeps a handle to the started process: Foundation's `Process` on Windows reports the exit only once the
/// output pipes are closed, so a helper that outlives the program (and holds the pipes) would hide the exit.
final class WindowsJobObject: @unchecked Sendable {
    private let lock = NSLock()
    private var job: HANDLE?
    private let process: HANDLE

    /// Creates a job and assigns process `pid` to it; nil when that fails (e.g. a parent job forbids nesting).
    init?(assigning pid: Int32) {
        guard let j = CreateJobObjectW(nil, nil) else { return nil }
        var info = JOBOBJECT_EXTENDED_LIMIT_INFORMATION()
        info.BasicLimitInformation.LimitFlags = DWORD(0x0000_2000)          // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        let set = SetInformationJobObject(j, JobObjectExtendedLimitInformation, &info,
                                          DWORD(MemoryLayout<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>.size))
        // PROCESS_SET_QUOTA | PROCESS_TERMINATE | PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE
        let access = DWORD(0x0100 | 0x0001 | 0x1000 | 0x0010_0000)
        guard set, let proc = OpenProcess(access, false, DWORD(bitPattern: pid)) else { _ = CloseHandle(j); return nil }
        guard AssignProcessToJobObject(j, proc) else { _ = CloseHandle(proc); _ = CloseHandle(j); return nil }
        job = j
        process = proc
    }

    /// Blocks until the started process itself has exited (its helpers may still run) and returns its exit code.
    func waitForProcessExit() -> Int32 {
        _ = WaitForSingleObject(process, INFINITE)
        var code: DWORD = 0
        return GetExitCodeProcess(process, &code) ? Int32(bitPattern: UInt32(code)) : -1
    }

    /// Terminates every process in the job.
    func terminate() {
        lock.lock(); defer { lock.unlock() }
        if let j = job { _ = TerminateJobObject(j, 1) }
    }

    /// Closes the job; processes still in it are killed.
    func close() {
        lock.lock(); defer { lock.unlock() }
        if let j = job { _ = CloseHandle(j); job = nil }
    }

    deinit {
        if let j = job { _ = CloseHandle(j) }
        _ = CloseHandle(process)
    }
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
        #if os(Windows)
        var job: WindowsJobObject?
        /// Exit code seen through the job's process handle (Foundation may not have noticed the exit yet).
        var exitCode: Int32?
        #endif
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

        // Stops the whole process tree: Gaussian, ORCA (orca_* helpers, mpiexec and the MPI ranks) and shells start
        // children that inherit the output pipes, so stopping only the top process would leave them running.
        func kill(_ p: Process) {
            #if os(Windows)
            // The job object holds every descendant, also those whose parent already exited. Without one (it could not
            // be created), taskkill /T follows the parent ids. TerminateProcess on the child alone is the last resort.
            let job = state.withLock { state.job }
            if let job { job.terminate() }
            guard p.isRunning else { return }
            let pid = p.processIdentifier
            DispatchQueue.global().async {
                if job == nil || p.isRunning { killProcessTreeWindows(pid: pid) }
                if p.isRunning { p.terminate() }
            }
            #else
            guard p.isRunning else { return }
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
                #if os(Windows)
                if let job = WindowsJobObject(assigning: process.processIdentifier) {
                    state.withLock { state.job = job }
                    DispatchQueue.global().async {
                        let code = job.waitForProcessExit()
                        state.withLock { state.exitCode = code }
                        exited.signal()
                    }
                } else if process.isRunning {
                    FileHandle.standardError.write(Data("ProgramRunner: no job object for pid \(process.processIdentifier); cancel falls back to taskkill /T\n".utf8))
                }
                #endif
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
                    #if os(Windows)
                    // Helpers the program left behind would keep the output pipes open: the job takes them down.
                    state.withLock { state.job }?.close()
                    #endif
                    // Output normally ends when the process exits. A stopped run (or a leftover grandchild that
                    // still holds the pipe) must not hold the result back indefinitely.
                    let stopped = state.withLock { state.cancelled || state.timedOut }
                    _ = group.wait(timeout: .now() + (stopped ? 3 : 30))
                    let (o, e, c, t) = state.withLock { (state.out, state.err, state.cancelled, state.timedOut) }
                    if c { cont.resume(throwing: ComputeError.cancelled); return }
                    if t { cont.resume(throwing: ComputeError.timeout); return }
                    #if os(Windows)
                    // terminationStatus traps while Foundation still counts the process as running.
                    let code = state.withLock { state.exitCode } ?? (process.isRunning ? -1 : process.terminationStatus)
                    #else
                    let code = process.terminationStatus
                    #endif
                    cont.resume(returning: ProcessOutput(exitCode: code,
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
