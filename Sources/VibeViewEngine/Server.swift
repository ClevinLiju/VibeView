import Foundation
import MolCore
import MolIO
import MolCompute

// MARK: - Output

/// The single, serialized writer for stdout. One JSON object per line; nothing else may print to stdout.
final class OutputWriter: @unchecked Sendable {
    static let shared = OutputWriter()
    private let lock = NSLock()
    /// Replaced by `--selftest` to capture messages in process.
    private var sink: ((String) -> Void)?

    func setSink(_ s: ((String) -> Void)?) { lock.lock(); sink = s; lock.unlock() }

    func send(_ message: JSON) {
        let line = message.serialized()
        lock.lock()
        defer { lock.unlock() }
        if let sink { sink(line); return }
        let data = Data((line + "\n").utf8)
        do { try FileHandle.standardOutput.write(contentsOf: data) } catch {
            Log.error("stdout write failed: \(error)")
        }
    }
}

/// stderr diagnostics (free-form; the front end only logs them).
enum Log {
    static let verbose = ProcessInfo.processInfo.environment["VIBEVIEW_ENGINE_VERBOSE"] != nil
    private static let lock = NSLock()
    static func write(_ s: String) {
        lock.lock(); defer { lock.unlock() }
        try? FileHandle.standardError.write(contentsOf: Data(("[engine] " + s + "\n").utf8))
    }
    static func info(_ s: String) { if verbose { write(s) } }
    static func error(_ s: String) { write("error: " + s) }
}

// MARK: - Request tracking (for `cancel`)

final class RequestTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [Int: Task<Void, Never>] = [:]

    /// Starts `body` in a detached task registered under `id`. Registration happens under the lock, so a
    /// fast task cannot deregister before it is registered.
    func start(_ id: Int, _ body: @escaping @Sendable () async -> Void) {
        lock.lock()
        let t = Task.detached { [weak self] in
            await body()
            self?.finish(id)
        }
        tasks[id] = t
        lock.unlock()
    }

    private func finish(_ id: Int) { lock.lock(); tasks[id] = nil; lock.unlock() }

    @discardableResult
    func cancel(_ id: Int) -> Bool {
        lock.lock(); let t = tasks[id]; lock.unlock()
        t?.cancel()
        return t != nil
    }

    var isBusy: Bool { lock.lock(); defer { lock.unlock() }; return !tasks.isEmpty }

    private func snapshot() -> [Task<Void, Never>] { lock.lock(); defer { lock.unlock() }; return Array(tasks.values) }

    func waitAll() async {
        while true {
            let ts = snapshot()
            if ts.isEmpty { return }
            for t in ts { await t.value }
        }
    }
}

// MARK: - Response gate

/// Opened right after a request's response has been written. Jobs started by the request (calc.run, xtb.run,
/// console `xtb opt`) wait for it, so `job.started`/`job.log`/`job.finished` never arrive before the response
/// that tells the front end the job id.
final class ResponseGate: @unchecked Sendable {
    @TaskLocal static var current: ResponseGate?
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        lock.lock(); isOpen = true; let w = waiters; waiters = []; lock.unlock()
        for c in w { c.resume() }
    }

    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if isOpen { lock.unlock(); c.resume(); return }
            waiters.append(c)
            lock.unlock()
        }
    }
}

// MARK: - Engine

final class Engine: @unchecked Sendable {
    let store = DocumentStore()
    let docQueue = DocumentQueue()
    let jobs = JobRegistry()
    let lookup = NameLookup()
    let tracker = RequestTracker()
    let programs = ProgramPaths()
    let candidateCache = CandidateCache()
    let out: OutputWriter

    init(out: OutputWriter = .shared) { self.out = out }

    func notify(_ event: String, _ params: JSON) {
        out.send(["event": .string(event), "params": params])
    }

    func log(_ level: String, _ text: String) {
        notify("engine.log", ["level": .string(level), "text": .string(text)])
    }

    /// Handles one input line: parse, then run the request in its own task.
    func handleLine(_ line: String) {
        let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let msg: JSON
        do { msg = try JSON.parse(t) } catch {
            out.send(["id": .null, "error": RPCError.parse("invalid JSON: \(error)").json])
            return
        }
        guard let id = msg["id"]?.intValue else {
            out.send(["id": msg["id"] ?? .null, "error": RPCError.badRequest("request needs an integer 'id'").json])
            return
        }
        guard let method = msg["method"]?.stringValue else {
            out.send(["id": .number(Double(id)), "error": RPCError.badRequest("request needs a 'method'").json])
            return
        }
        let params = Params(msg["params"])
        if method == "cancel" {
            let target = params.optInt("id") ?? -1
            let found = tracker.cancel(target)
            if target >= 0, !found { Log.info("cancel: request \(target) not running") }
            out.send(["id": .number(Double(id)), "result": ["cancelled": .bool(found)]])
            return
        }
        Log.info("-> \(id) \(method)")
        // Per-document ordering: the ticket is drawn here, in arrival order (see DocumentQueue).
        let orderedDoc = DocumentQueue.orderedMethods.contains(method) ? try? params.docId() : nil
        let ordered = orderedDoc.map { (doc: $0, ticket: docQueue.ticket($0)) }
        tracker.start(id) { [self] in
            if let o = ordered { await docQueue.wait(o.doc, o.ticket) }
            defer { if let o = ordered { docQueue.done(o.doc) } }
            let response: JSON
            let gate = ResponseGate()
            do {
                let r = try await ResponseGate.$current.withValue(gate) { try await dispatch(method, params) }
                if Task.isCancelled { throw RPCError.cancelled }
                response = ["id": .number(Double(id)), "result": r]
            } catch {
                let e = Task.isCancelled ? RPCError.cancelled : RPCError.from(error)
                if e.code == "internal" { Log.error("\(method) failed: \(error)") }
                response = ["id": .number(Double(id)), "error": e.json]
            }
            out.send(response)
            gate.open()
        }
    }

    /// Method table. Every method lives in a `Methods+*.swift` extension.
    func dispatch(_ method: String, _ p: Params) async throws -> JSON {
        switch method {
        case "engine.info": return engineInfo()
        case "engine.ping": return ["pong": true]
        // documents
        case "doc.new": return try await docNew(p)
        case "doc.open": return try await docOpen(p)
        case "doc.openText": return try await docOpenText(p)
        case "doc.close": return try await docClose(p)
        case "doc.list": return await docList()
        case "doc.save": return try await docSave(p)
        case "doc.export": return try await docExport(p)
        case "doc.exportAs": return try await docExportAs(p)          // Methods+Export.swift
        case "doc.exportFormats": return try await docExportFormats(p)
        case "doc.molecule": return try await docMolecule(p)
        case "doc.summary": return try await store.summary(try p.docId())
        case "doc.undo": return try await docUndo(p, redo: false)
        case "doc.redo": return try await docUndo(p, redo: true)
        case "doc.result": return try await docResult(p)
        case "doc.frames": return try await docFrames(p)
        case "doc.setSelection": return try await docSetSelection(p)
        // editing / building
        case "edit.apply": return try await editApply(p)
        case "build.fragments": return buildFragments()
        case "build.groups": return buildGroups(p)            // Methods+Groups.swift
        case "zmatrix.get": return try await zmatrixGet(p)              // Methods+ZMatrix.swift
        case "zmatrix.edit": return try await zmatrixEdit(p)
        case "zmatrix.parse": return try await zmatrixParse(p)
        case "zmatrix.apply": return try await zmatrixApply(p)
        case "zmatrix.addAtom": return try await zmatrixAddAtom(p)
        // analysis
        case "analysis.measure": return try await analysisMeasure(p)
        case "analysis.symmetry": return try await analysisSymmetry(p)
        case "analysis.orbitals": return try await analysisOrbitals(p)
        case "analysis.orbitalSurface": return try await analysisOrbitalSurface(p)
        case "analysis.densitySurface": return try await analysisDensitySurface(p)
        case "analysis.volumeSurface": return try await analysisVolumeSurface(p)
        case "analysis.modes": return try await analysisModes(p)
        case "analysis.spectrum": return try await analysisSpectrum(p)
        case "analysis.thermo": return try await analysisThermo(p)
        case "analysis.secondaryStructure": return try await analysisSecondaryStructure(p)
        // calculations
        case "calc.programs": return programs.json()
        case "calc.setProgramPath": return try calcSetProgramPath(p)
        case "calc.preview": return try await calcPreview(p)
        case "calc.run": return try await calcRun(p)
        case "calc.cancel": return try await calcCancel(p)
        case "xtb.run": return try await xtbRun(p)
        case "jobs.list": return await jobs.list()
        // lookup
        case "lookup.suggest": return try await lookupSuggest(p)
        case "lookup.structure": return try await lookupStructure(p)
        // console
        case "command.execute": return try await commandExecute(p)
        case "command.complete": return try await commandComplete(p)
        // sessions
        case "session.save": return try await sessionSave(p)
        case "session.load": return try await sessionLoad(p)
        default:
            throw RPCError.badRequest("unknown method '\(method)'")
        }
    }

    func engineInfo() -> JSON {
        let read: [JSON] = MoleculeFileFormat.allCases.map {
            ["id": .string($0.rawValue), "name": .string($0.displayName), "extensions": $0.fileExtensions.json]
        }
        let write: [JSON] = MolecularFileLoader.writableFormats.map {
            ["id": .string($0.rawValue), "name": .string($0.displayName), "extensions": $0.fileExtensions.json]
        }
        return [
            "version": .string(engineVersion), "protocol": .number(Double(protocolVersion)), "platform": .string(platformName),
            "formats": ["read": .array(read), "write": .array(write)],
            "programs": programs.json(),
            "pid": .number(Double(ProcessInfo.processInfo.processIdentifier)),
        ]
    }
}

// MARK: - stdio main loop

enum StdioServer {
    /// Reads stdin lines on a background thread and dispatches each request; returns at EOF once in-flight
    /// requests have answered (running jobs are cancelled).
    static func run(waitForJobs: Bool = false) async {
        let engine = Engine()
        let (stream, cont) = AsyncStream<String>.makeStream()
        let reader = Thread {
            while let line = readLine(strippingNewline: true) { cont.yield(line) }
            cont.finish()
        }
        reader.stackSize = 1 << 20
        reader.start()
        Log.info("vibeview-engine \(engineVersion) ready (protocol \(protocolVersion), \(platformName))")
        for await line in stream { engine.handleLine(line) }
        Log.info("stdin closed; finishing in-flight requests")
        await engine.tracker.waitAll()
        if waitForJobs { await engine.jobs.waitAll() } else { await engine.jobs.cancelAll() }
    }
}
