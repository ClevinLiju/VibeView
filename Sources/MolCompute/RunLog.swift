import Foundation

/// One live log event from a running program. Text events are whole lines (without the trailing newline).
public enum RunLogEvent: Sendable, Equatable {
    case started(runDirectory: URL, commandLine: String)
    case stdout(String)
    case stderr(String)
    /// A new line appended to a tailed file in the run directory (e.g. `xtbopt.log`, ORCA `job.out`).
    case file(name: String, line: String)
    case finished(exitCode: Int32)

    /// The text of a line event, nil for `.started` / `.finished`.
    public var line: String? {
        switch self {
        case .stdout(let s), .stderr(let s): return s
        case .file(_, let l): return l
        default: return nil
        }
    }
}

/// Splits a byte stream into lines (thread-safe). Partial trailing lines are kept until `flush()`.
final class LineSplitter: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private let emit: @Sendable (String) -> Void
    init(_ emit: @escaping @Sendable (String) -> Void) { self.emit = emit }

    func feed(_ d: Data) {
        lock.lock()
        pending.append(d)
        var lines: [String] = []
        while let nl = pending.firstIndex(of: 0x0A) {
            var lineData = pending[pending.startIndex..<nl]
            if lineData.last == 0x0D { lineData = lineData.dropLast() }
            lines.append(String(decoding: lineData, as: UTF8.self))
            pending = Data(pending[pending.index(after: nl)...])
        }
        lock.unlock()
        for l in lines { emit(l) }
    }

    func flush() {
        lock.lock()
        let rest = pending; pending = Data()
        lock.unlock()
        if !rest.isEmpty { emit(String(decoding: rest, as: UTF8.self)) }
    }
}

/// Polls files in a directory for appended content on a background queue and emits new lines.
/// Files that are truncated or replaced (e.g. xtb rewriting `xtbopt.log`) are re-read from the start.
final class FileTailer: @unchecked Sendable {
    private let lock = NSLock()
    private let directory: URL
    private let names: [String]
    private var offsets: [String: UInt64] = [:]
    private var splitters: [String: LineSplitter] = [:]
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "molcompute.filetailer")

    init(directory: URL, names: [String], interval: TimeInterval = 0.2, emit: @escaping @Sendable (String, String) -> Void) {
        self.directory = directory
        self.names = names
        for n in names { splitters[n] = LineSplitter { emit(n, $0) } }
        guard !names.isEmpty else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + interval, repeating: interval)
        t.setEventHandler { [weak self] in self?.poll() }
        timer = t
        t.resume()
    }

    private func poll() {
        lock.lock(); defer { lock.unlock() }
        for n in names {
            let url = directory.appendingPathComponent(n)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = (attrs[.size] as? NSNumber)?.uint64Value else { continue }
            var off = offsets[n] ?? 0
            if size < off { off = 0 }
            guard size > off, let h = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? h.close() }
            do {
                try h.seek(toOffset: off)
                if let d = try h.readToEnd(), !d.isEmpty {
                    off += UInt64(d.count)
                    splitters[n]?.feed(d)
                }
            } catch { continue }
            offsets[n] = off
        }
    }

    /// Final read plus flush of partial lines; stops the timer.
    func finish() {
        timer?.cancel(); timer = nil
        queue.sync { poll() }
        for n in names { splitters[n]?.flush() }
    }
}

/// A running program: live events plus the eventual result. Cancel to terminate the child process.
public struct RunHandle<Result: Sendable>: Sendable {
    public let events: AsyncStream<RunLogEvent>
    public let runDirectory: URL?
    public let result: Task<Result, Error>
    public func cancel() { result.cancel() }
    public var value: Result { get async throws { try await result.value } }
}
public typealias ProgramRunHandle = RunHandle<ProcessOutput>
public typealias XTBRunHandle = RunHandle<XTBResult>

extension RunHandle {
    /// Builds a handle whose events stream ends when `work` finishes.
    static func make(runDirectory: URL?,
                     _ work: @escaping @Sendable (_ emit: @escaping @Sendable (RunLogEvent) -> Void) async throws -> Result) -> RunHandle {
        let (stream, cont) = AsyncStream<RunLogEvent>.makeStream(bufferingPolicy: .bufferingNewest(20_000))
        let task = Task.detached { () async throws -> Result in
            defer { cont.finish() }
            return try await work { cont.yield($0) }
        }
        return RunHandle(events: stream, runDirectory: runDirectory, result: task)
    }
}

/// Shell-style quoting for command-line previews.
public func shellQuoted(_ args: [String]) -> String {
    args.map { a -> String in
        if a.isEmpty { return "''" }
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./=:,+@%")
        if a.unicodeScalars.allSatisfy({ safe.contains($0) }) { return a }
        return "'" + a.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }.joined(separator: " ")
}

extension ProgramRunner {
    /// Runs a program with line-buffered live events. Same guarantees as `run` (never on the main thread,
    /// Task cancellation terminates the child, optional timeout). `tailFiles` (names relative to
    /// `workingDirectory`) are polled while the process runs and their new lines arrive as `.file` events.
    /// `stdoutFile` (relative to `workingDirectory`) receives a copy of stdout as it streams (ORCA/xtb style).
    public static func runLogged(executable: URL, arguments: [String], workingDirectory: URL? = nil,
                                 environment: [String: String]? = nil, stdin: String? = nil,
                                 timeout: TimeInterval? = nil, throwOnFailure: Bool = true,
                                 tailFiles: [String] = [], stdoutFile: String? = nil,
                                 onEvent: @escaping @Sendable (RunLogEvent) -> Void) async throws -> ProcessOutput {
        let outLines = LineSplitter { onEvent(.stdout($0)) }
        let errLines = LineSplitter { onEvent(.stderr($0)) }
        var tee: FileHandle?
        if let name = stdoutFile, let dir = workingDirectory {
            let url = dir.appendingPathComponent(name)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            tee = try? FileHandle(forWritingTo: url)
        }
        let teeBox = UncheckedBox(tee)
        let tailerBox = UncheckedBox<FileTailer?>(nil)
        let dirURL = workingDirectory ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let cmd = shellQuoted([executable.path] + arguments)
        let tailNames = tailFiles
        defer {
            tailerBox.value?.finish()
            try? teeBox.value?.close()
        }
        do {
            let out = try await runCore(executable: executable, arguments: arguments, workingDirectory: workingDirectory,
                                        environment: environment, stdin: stdin, timeout: timeout, throwOnFailure: false,
                                        onStart: {
                                            onEvent(.started(runDirectory: dirURL, commandLine: cmd))
                                            tailerBox.value = FileTailer(directory: dirURL, names: tailNames) { n, l in
                                                onEvent(.file(name: n, line: l))
                                            }
                                        },
                                        onChunk: { isOut, d in
                                            if isOut { try? teeBox.value?.write(contentsOf: d); outLines.feed(d) } else { errLines.feed(d) }
                                        })
            outLines.flush(); errLines.flush()
            tailerBox.value?.finish(); tailerBox.value = nil
            onEvent(.finished(exitCode: out.exitCode))
            if throwOnFailure && out.exitCode != 0 {
                throw ComputeError.processFailed(code: out.exitCode, stderr: out.stderr.isEmpty ? out.stdout : out.stderr)
            }
            return out
        } catch {
            outLines.flush(); errLines.flush()
            throw error
        }
    }

    /// `runLogged` as a handle with an `AsyncStream` of events. Iterate `handle.events` for live lines and
    /// await `handle.value` for the output; `handle.cancel()` terminates the process.
    public static func stream(executable: URL, arguments: [String], workingDirectory: URL? = nil,
                              environment: [String: String]? = nil, stdin: String? = nil,
                              timeout: TimeInterval? = nil, throwOnFailure: Bool = true,
                              tailFiles: [String] = [], stdoutFile: String? = nil) -> ProgramRunHandle {
        .make(runDirectory: workingDirectory) { emit in
            try await runLogged(executable: executable, arguments: arguments, workingDirectory: workingDirectory,
                                environment: environment, stdin: stdin, timeout: timeout, throwOnFailure: throwOnFailure,
                                tailFiles: tailFiles, stdoutFile: stdoutFile, onEvent: emit)
        }
    }
}

final class UncheckedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ v: T) { _value = v }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}
