import Foundation
import MolCore
import MolIO
import MolCompute

// MARK: - Program discovery

/// Finds xtb / ORCA / Gaussian / Q-Chem. Order: path set with `calc.setProgramPath`, `VIBEVIEW_<NAME>` env var,
/// then MolCompute's search (PATH, conda, …) plus common Windows install folders.
final class ProgramPaths: @unchecked Sendable {
    private let lock = NSLock()
    private var overrides: [QCProgram: String] = [:]

    func set(_ p: QCProgram, path: String?) {
        lock.lock(); overrides[p] = path; lock.unlock()
    }

    private func override(_ p: QCProgram) -> String? { lock.lock(); defer { lock.unlock() }; return overrides[p] }

    private var formchkPath: String?
    /// `calc.setProgramPath {program: "formchk"}`.
    var formchkOverride: String? {
        get { lock.lock(); defer { lock.unlock() }; return formchkPath }
        set { lock.lock(); formchkPath = newValue; lock.unlock() }
    }

    /// A file path for display and for child processes: on Windows with backslashes, no doubled separators
    /// ("C://G09W/g09.exe" → "C:\G09W\g09.exe") and no leading slash before the drive letter. Unchanged elsewhere.
    static func nativePath(_ u: URL) -> String { nativePath(u.path) }

    static func nativePath(_ path: String) -> String {
        #if os(Windows)
        var s = path.replacingOccurrences(of: "/", with: "\\")
        let c = Array(s)
        if c.count >= 3, c[0] == "\\", c[2] == ":", c[1].isLetter { s.removeFirst() }
        let unc = s.hasPrefix("\\\\")
        var body = unc ? String(s.dropFirst(2)) : s
        while body.contains("\\\\") { body = body.replacingOccurrences(of: "\\\\", with: "\\") }
        if body.count > 3, body.hasSuffix("\\") { body.removeLast() }
        return (unc ? "\\\\" : "") + body
        #else
        return path
        #endif
    }

    static func isRunnable(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else { return false }
        #if os(Windows)
        return ["exe", "bat", "cmd", "com"].contains((path as NSString).pathExtension.lowercased())
        #else
        return FileManager.default.isExecutableFile(atPath: path)
        #endif
    }

    static func executableNames(_ p: QCProgram) -> [String] {
        switch p {
        case .xtb: return ["xtb"]
        case .orca: return ["orca"]
        case .gaussian: return ["g16", "g09"]
        case .qchem: return ["qchem"]
        }
    }

    static func envName(_ p: QCProgram) -> String {
        switch p {
        case .xtb: return "XTB"
        case .orca: return "ORCA"
        case .gaussian: return "GAUSSIAN"
        case .qchem: return "QCHEM"
        }
    }

    func locate(_ p: QCProgram) -> URL? {
        if let o = override(p), Self.isRunnable(o) { return URL(fileURLWithPath: o) }
        let env = ProcessInfo.processInfo.environment
        for key in ["VIBEVIEW_" + Self.envName(p), "MOLSCOPE_" + Self.envName(p)] {
            if let v = env[key], !v.isEmpty, Self.isRunnable(v) { return URL(fileURLWithPath: v) }
        }
        if p == .xtb, let u = XTBRunner.locate() { return u }
        for name in Self.executableNames(p) {
            if let u = ProgramLocator.find(name) { return u }
            #if os(Windows)
            for ext in ["exe", "bat", "cmd"] { if let u = ProgramLocator.find(name + "." + ext) { return u } }
            for d in Self.windowsSearchDirectories(p) {
                for ext in ["exe", "bat", "cmd"] {
                    let path = (d as NSString).appendingPathComponent(name + "." + ext)
                    if Self.isRunnable(path) { return URL(fileURLWithPath: path) }
                }
            }
            #endif
        }
        return nil
    }

    #if os(Windows)
    /// PATH entries plus typical install folders (C:\ORCA_6_1_1, C:\Program Files\ORCA…, conda envs).
    static func windowsSearchDirectories(_ p: QCProgram) -> [String] {
        let env = ProcessInfo.processInfo.environment
        var dirs = (env["PATH"] ?? env["Path"] ?? "").split(separator: ";").map(String.init)
        let fm = FileManager.default
        var roots = ["C:\\", env["ProgramFiles"] ?? "C:\\Program Files", env["LOCALAPPDATA"].map { $0 + "\\Programs" } ?? ""]
        roots = roots.filter { !$0.isEmpty }
        let prefixes: [String]
        switch p {
        case .orca: prefixes = ["orca"]
        case .gaussian: prefixes = ["g16", "g09"]   // C:\G16W, C:\G09W
        case .qchem: prefixes = ["qchem"]
        case .xtb: prefixes = ["xtb"]
        }
        for r in roots {
            let names = ((try? fm.contentsOfDirectory(atPath: r)) ?? []).filter { n in prefixes.contains { n.lowercased().hasPrefix($0) } }
                .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            for n in names {
                let base = (r as NSString).appendingPathComponent(n)
                dirs += [base, (base as NSString).appendingPathComponent("bin")]
            }
        }
        let home = NSHomeDirectory()
        for c in ["miniconda3", "miniforge3", "anaconda3", "mambaforge"] {
            let root = (home as NSString).appendingPathComponent(c)
            dirs += [(root as NSString).appendingPathComponent("Library\\bin"), (root as NSString).appendingPathComponent("Scripts")]
            let envs = (root as NSString).appendingPathComponent("envs")
            for e in ((try? fm.contentsOfDirectory(atPath: envs)) ?? []).sorted() {
                dirs.append(((envs as NSString).appendingPathComponent(e) as NSString).appendingPathComponent("Library\\bin"))
            }
        }
        return dirs
    }
    #endif

    /// Adapting inputs to the located Gaussian is off in the self-test, which checks the writer rather than the Gaussian installed on the machine.
    nonisolated(unsafe) static var adaptToInstalledGaussian = true

    /// What the located Gaussian can do (32-bit memory limit, G09 before rev. D.01); nil when none is found or adaptation is off.
    func gaussianProfile() -> GaussianInstallProfile? {
        guard Self.adaptToInstalledGaussian else { return nil }
        guard let exe = locate(.gaussian) else { return nil }
        let info = ExecutableInfo.read(exe)
        return GaussianInstallProfile.detect(executableName: exe.lastPathComponent, is32Bit: info?.is32Bit ?? false,
                                             linkYear: info?.linkYear)
    }

    func json() -> JSON {
        var o: [String: JSON] = [:]
        for p in QCProgram.allCases { o[p.rawValue] = locate(p).map { .string(Self.nativePath($0)) } ?? .null }
        o["formchk"] = Formchk.locate(self).map { .string(Self.nativePath($0)) } ?? .null
        return .object(o)
    }
}

// MARK: - Jobs

actor JobRegistry {
    struct Info {
        var kind: String
        var docId: String?
        var directory: String
        var task: Task<Void, Never>?
        var status: String
        var commandLine: String
        var cancelRequested = false
    }
    private var jobs: [String: Info] = [:]
    private var next = 1

    func newId() -> String { defer { next += 1 }; return "j\(next)" }
    func add(_ id: String, _ info: Info) { jobs[id] = info }
    func setTask(_ id: String, _ t: Task<Void, Never>) {
        jobs[id]?.task = t
        if jobs[id]?.cancelRequested == true { t.cancel() }   // calc.cancel arrived before the task was registered
    }
    func setStatus(_ id: String, _ s: String) { jobs[id]?.status = s }
    func setCommandLine(_ id: String, _ s: String) { jobs[id]?.commandLine = s }

    func cancel(_ id: String) throws {
        guard let j = jobs[id] else { throw RPCError.notFound("no job '\(id)'") }
        jobs[id]?.cancelRequested = true
        j.task?.cancel()
    }

    func cancel(kind: String, docId: String) {
        for (_, j) in jobs where j.kind == kind && j.docId == docId { j.task?.cancel() }
    }

    func cancelAll() async {
        let ts = jobs.values.compactMap(\.task)
        for t in ts { t.cancel() }
        for t in ts { await t.value }
    }

    func waitAll() async {
        for t in jobs.values.compactMap(\.task) { await t.value }
    }

    func list() -> JSON {
        ["jobs": .array(jobs.keys.sorted().map { k in
            let j = jobs[k]!
            return obj(["jobId": k, "kind": j.kind, "docId": j.docId, "directory": j.directory, "status": j.status,
                        "commandLine": j.commandLine])
        })]
    }
}

extension Engine {
    func calcSetProgramPath(_ p: Params) throws -> JSON {
        let name = try p.string("program")
        let path = p.optString("path").flatMap { $0.isEmpty ? nil : $0 }
        if let path, !ProgramPaths.isRunnable(path) { throw RPCError.notFound("not an executable: \(path)") }
        if name == "formchk" { programs.formchkOverride = path; return programs.json() }
        guard let prog = QCProgram(rawValue: name) else { throw RPCError.badRequest("unknown program '\(name)'") }
        programs.set(prog, path: path)
        return programs.json()
    }

    /// `CalcSpecJSON` → `CalcSpec` for the document's molecule.
    static func calcSpec(_ s: Params, molecule m0: Molecule) throws -> CalcSpec {
        let progName = try s.string("program")
        guard let program = QCProgram(rawValue: progName) else { throw RPCError.badRequest("unknown program '\(progName)'") }
        var m = m0
        if let c = s.optInt("charge") { m.charge = c }
        if let mult = s.optInt("multiplicity") { m.multiplicity = mult }
        let taskName = s.optString("task") ?? "energy"
        guard let task = CalcTask(rawValue: taskName) else { throw RPCError.badRequest("unknown task '\(taskName)'") }
        let method = s.optString("method") ?? (program == .xtb ? "GFN2-xTB" : "")
        var spec = CalcSpec(program: program, task: task, method: method, basis: s.optString("basis") ?? "", molecule: m,
                            title: s.optString("title") ?? "")
        if let d = s.optString("dispersion"), !d.isEmpty, d != "none" {
            guard let dd = DispersionCorrection(rawValue: d) else { throw RPCError.badRequest("unknown dispersion '\(d)'") }
            spec.dispersion = dd
        }
        if let sol = s.optObject("solvation") {
            let mn = try sol.string("model")
            guard let model = SolvationModel(rawValue: mn) else { throw RPCError.badRequest("unknown solvation model '\(mn)'") }
            spec.solvation = Solvation(model: model, solvent: sol.optString("solvent") ?? "water")
        }
        spec.unrestricted = s.optBool("unrestricted")
        if let es = s.optObject("excitedStates") {
            spec.excitedStates = ExcitedStatesSpec(roots: es.optInt("roots") ?? 10, triplets: es.bool("triplets", default: false),
                                                   tammDancoff: es.bool("tammDancoff", default: false))
        }
        if let sc = s.optObject("scan") {
            let atoms = try sc.ints("atoms")
            spec.scan = ScanCoordinate(atoms: atoms, start: try sc.double("start"), end: try sc.double("end"), steps: try sc.int("steps"))
        }
        spec.frozenAtoms = try s.optInts("frozenAtoms") ?? []
        spec.tightOptimization = s.bool("tightOptimization", default: false)
        spec.computeFrequenciesAfterTS = s.bool("computeFrequenciesAfterTS", default: true)
        spec.nprocs = max(1, s.optInt("nprocs") ?? 1)
        spec.memoryMB = max(100, s.optInt("memoryMB") ?? 2000)
        if let arr = s["extraKeywords"]?.arrayValue {
            spec.extraKeywords = arr.compactMap(\.stringValue).filter { !$0.isEmpty }
        } else if let str = s.optString("extraKeywords") {
            spec.extraKeywords = str.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        }
        spec.extraInput = s.optString("extraInput") ?? ""
        if let c = s.optString("checkpointName"), !c.isEmpty { spec.checkpointName = c }
        return spec
    }

    static func commandLine(_ plan: CalcJobPlan, executable: String? = nil) -> String {
        var s = shellQuoted([executable ?? plan.executableName] + plan.arguments)
        if plan.captureStdout { s += " > " + plan.outputFileName }
        return s
    }

    /// Adapts a Gaussian spec to the installed program (GaussianInstallProfile.adapt): a %mem that a 32-bit build can't
    /// allocate (G09W stops right after Link 1, so the job "has no atoms") is lowered; builds before G09 D.01 get the
    /// older Ahlrichs basis names for def2 and no EmpiricalDispersion (both are syntax errors there). One note per change.
    static func adaptGaussian(_ spec: inout CalcSpec, profile: GaussianInstallProfile?) -> [String] {
        guard spec.program == .gaussian, let p = profile else { return [] }
        return p.adapt(&spec)
    }

    static func issuesJSON(_ issues: [InputIssue]) -> JSON {
        .array(issues.map { obj(["severity": $0.severity.rawValue, "line": $0.line, "message": $0.message, "fixable": $0.fixable]) })
    }

    static func profileJSON(_ p: GaussianInstallProfile?) -> JSON {
        guard let p else { return .null }
        return obj(["name": p.name, "maxMemoryMB": p.maxMemoryMB, "hasDef2AndGD3": p.hasDef2AndGD3])
    }

    func calcPreview(_ p: Params) async throws -> JSON {
        let d = try await store.get(try p.docId())
        var spec = try Engine.calcSpec(try p.object("spec"), molecule: d.molecule)
        let errors = spec.validationErrors()
        guard errors.isEmpty else {
            return obj(["input": "", "errors": errors, "files": [String](), "commandLine": "", "warnings": [String](), "check": JSON.array([])])
        }
        let profile = spec.program == .gaussian ? programs.gaussianProfile() : nil
        var warnings = Engine.adaptGaussian(&spec, profile: profile)
        let plan = try CalcJobPlanner.plan(spec, baseName: p.optString("baseName") ?? "job")
        // The command line names the executable that calc.run will start (g09 vs g16, a configured path, …).
        let exe = programs.locate(spec.program)
        let issues = spec.program == .gaussian ? GaussianInputCheck.check(plan.inputText, profile: profile) : []
        warnings += issues.map(\.message)
        return obj([
            "input": plan.inputText, "errors": [String](), "files": plan.files.map(\.name),
            "fileContents": JSON.array(plan.files.map { obj(["name": $0.name, "contents": $0.contents]) }),
            "commandLine": Engine.commandLine(plan, executable: exe.map(ProgramPaths.nativePath)), "outputFile": plan.outputFileName,
            "executable": exe.map(ProgramPaths.nativePath),
            "warnings": warnings, "check": Engine.issuesJSON(issues), "gaussian": Engine.profileJSON(profile),
        ])
    }

    /// `calc.checkInput {program, text}`: structural check of an (edited) input file against the installed program.
    func calcCheckInput(_ p: Params) async throws -> JSON {
        let name = p.optString("program") ?? "gaussian"
        guard let prog = QCProgram(rawValue: name) else { throw RPCError.badRequest("unknown program '\(name)'") }
        let text = try p.string("text")
        guard prog == .gaussian else { return obj(["issues": JSON.array([]), "repaired": JSON.null, "fixes": [String](), "gaussian": JSON.null]) }
        let profile = programs.gaussianProfile()
        let issues = GaussianInputCheck.check(text, profile: profile)
        let r = issues.contains(where: \.fixable) ? GaussianInputCheck.repair(text, profile: profile) : nil
        return obj(["issues": Engine.issuesJSON(issues), "repaired": r?.text, "fixes": r?.fixes ?? [], "gaussian": Engine.profileJSON(profile)])
    }


    /// Default job folder: ~/VibeView Jobs/<prefix>-<timestamp>.
    static func defaultJobDirectory(prefix: String) -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("VibeView Jobs", isDirectory: true)
        var dir = root.appendingPathComponent("\(prefix)-\(f.string(from: Date()))", isDirectory: true)
        var k = 2
        while FileManager.default.fileExists(atPath: dir.path) {
            dir = root.appendingPathComponent("\(prefix)-\(f.string(from: Date()))-\(k)", isDirectory: true); k += 1
        }
        return dir
    }

    func forward(_ jobId: String, _ ev: RunLogEvent) async {
        switch ev {
        case .started(let dir, let cmd):
            await jobs.setCommandLine(jobId, cmd)
            notify("job.started", obj(["jobId": jobId, "directory": dir.path, "commandLine": cmd]))
        case .stdout(let l): notify("job.log", obj(["jobId": jobId, "stream": "stdout", "file": JSON.null, "line": l]))
        case .stderr(let l): notify("job.log", obj(["jobId": jobId, "stream": "stderr", "file": JSON.null, "line": l]))
        case .file(let n, let l): notify("job.log", obj(["jobId": jobId, "stream": "file", "file": n, "line": l]))
        case .finished: break
        }
    }

    /// The `%chk=` file named in a (hand-edited) Gaussian input, or nil. Relative names are relative to the job folder.
    static func gaussianCheckpoint(in text: String, directory: URL) -> URL? {
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") { break }   // Link 0 ends at the route
            guard line.lowercased().hasPrefix("%chk=") else { continue }
            var name = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            if name.count >= 2, name.hasPrefix("\""), name.hasSuffix("\"") { name = String(name.dropFirst().dropLast()) }
            guard !name.isEmpty else { return nil }
            if !name.lowercased().hasSuffix(".chk") { name += ".chk" }
            let isAbsolute = name.hasPrefix("/") || name.hasPrefix("\\") || (name.count > 2 && name.dropFirst().hasPrefix(":"))
            return isAbsolute ? URL(fileURLWithPath: name) : directory.appendingPathComponent(name)
        }
        return nil
    }

    func calcRun(_ p: Params) async throws -> JSON {
        let docId = try p.docId()
        let d = try await store.get(docId)
        var spec = try Engine.calcSpec(try p.object("spec"), molecule: d.molecule)
        let errors = spec.validationErrors()
        guard errors.isEmpty else { throw RPCError.badRequest(errors.joined(separator: "; ")) }
        let profile = spec.program == .gaussian ? programs.gaussianProfile() : nil
        var warnings = Engine.adaptGaussian(&spec, profile: profile)
        var plan0 = try CalcJobPlanner.plan(spec, baseName: p.optString("baseName") ?? "job")
        // `inputText`: the input file as the user edited it in the setup dialog; written verbatim instead of the generated one.
        // A Gaussian input gets the safe repairs of GaussianInputCheck (missing title section, missing blank line after a
        // section or at the end, %mem above a 32-bit build's limit), which are listed in `repairs`.
        let editedText = p.optString("inputText")
        var repairs: [String] = []
        var inputIssues: [InputIssue] = []
        if let text = editedText {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RPCError.badRequest("inputText is empty") }
            var t = text
            if spec.program == .gaussian {
                (t, repairs) = GaussianInputCheck.repair(text, profile: profile)
                inputIssues = GaussianInputCheck.check(t, profile: profile)
            }
            plan0.files[0].contents = t.hasSuffix("\n") ? t : t + "\n"
        } else if spec.program == .gaussian {
            inputIssues = GaussianInputCheck.check(plan0.inputText, profile: profile)
        }
        if editedText != nil { warnings = [] }   // the edited text has its own %mem (checked below)
        warnings += repairs.map { "Fixed: " + $0 } + inputIssues.map(\.message)
        let plan = plan0
        guard let exe = programs.locate(spec.program) else {
            throw RPCError.notInstalled("\(spec.program.displayName) was not found. Set its path in Settings (calc.setProgramPath) or add it to PATH.")
        }
        let dir = p.optString("directory").map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? Engine.defaultJobDirectory(prefix: spec.program.rawValue)
        do { try plan.write(to: dir) } catch { throw RPCError.io("could not write job files to \(dir.path): \(error.localizedDescription)") }
        // A hand-edited Gaussian input may name another checkpoint: run formchk on that one.
        let chkOverride = spec.program == .gaussian ? editedText.flatMap { Engine.gaussianCheckpoint(in: $0, directory: dir) } : nil
        var env = ProcessInfo.processInfo.environment
        for (k, v) in plan.environment { env[k] = v }
        if spec.program == .gaussian {
            if (env["GAUSS_EXEDIR"] ?? "").isEmpty { env["GAUSS_EXEDIR"] = ProgramPaths.nativePath(exe.deletingLastPathComponent()) }
            if (env["GAUSS_SCRDIR"] ?? "").isEmpty { env["GAUSS_SCRDIR"] = ProgramPaths.nativePath(dir) }
        }
        let jobId = await jobs.newId()
        let cmd = Engine.commandLine(plan, executable: ProgramPaths.nativePath(exe))
        let notes = warnings
        await jobs.add(jobId, .init(kind: "calc", docId: docId, directory: dir.path, task: nil, status: "running", commandLine: cmd))
        let env2 = env
        // Capture only what the job needs: EngineDocument holds CalculationResult (inline SIMD3 dipole), which must
        // not be captured by an async closure (Windows codegen bug, see MolSIMD/AsyncCapture.swift).
        let sourceTitle = d.displayTitle
        let gate = ResponseGate.current
        let task = Task.detached { [self] in
            await gate?.wait()
            for n in notes { self.notify("job.log", obj(["jobId": jobId, "stream": "stderr", "file": JSON.null, "line": "VibeView: " + n])) }
            let handle = ProgramRunner.stream(executable: exe, arguments: plan.arguments, workingDirectory: dir, environment: env2,
                                              stdin: nil, timeout: nil, throwOnFailure: false,
                                              tailFiles: plan.captureStdout ? [] : CalcJobResults.outputFileCandidates(plan),
                                              stdoutFile: plan.captureStdout ? plan.outputFileName : nil)
            await withTaskCancellationHandler {
                for await ev in handle.events { await self.forward(jobId, ev) }
            } onCancel: { handle.cancel() }
            var exitCode = -1
            var errorText: String? = nil
            do { exitCode = Int(try await handle.value.exitCode) } catch { errorText = RPCError.from(error).message }
            let cancelled = Task.isCancelled
            if cancelled { errorText = "cancelled" }
            // Gaussian: make <checkpoint>.fchk from the .chk so the result document has orbitals.
            var fchk: URL? = nil
            var formchkError: String? = nil
            if spec.program == .gaussian, !cancelled {
                var stem = spec.checkpointName ?? plan.baseName
                if stem.lowercased().hasSuffix(".chk") { stem = String(stem.dropLast(4)) }
                let chk = chkOverride ?? dir.appendingPathComponent(stem + ".chk")
                (fchk, formchkError) = await self.formchkAfterGaussianJob(jobId: jobId, chk: chk)
            }
            // Load whatever the job produced (works for failed/partial runs too) into a new document.
            var newDoc: EngineDocument?
            var normal = false
            do {
                let file = try CalcJobResults.collect(plan, directory: dir)
                normal = file.result?.normalTermination ?? (exitCode == 0)
                let nid = await self.store.newId()
                let outName = CalcJobResults.resolvedOutputFileName(plan, directory: dir) ?? plan.outputFileName   // G09W writes job.out
                var nd = Preparation.document(id: nid, file: file, path: dir.appendingPathComponent(outName).path, fileName: outName)
                nd.displayTitle = "\(spec.program.displayName) \(spec.task.rawValue) – \(sourceTitle)"
                await self.store.insert(nd)
                newDoc = nd
                // A custom checkpoint name doesn't share the log's stem, so the companion merge can't find its .fchk.
                if let f = fchk, nd.wavefunction == nil {
                    do { newDoc = try await self.attachFormattedCheckpoint(docId: nid, fchk: f, note: "made by formchk") } catch {
                        if formchkError == nil { formchkError = RPCError.from(error).message }
                    }
                }
            } catch {
                if errorText == nil { errorText = "could not read results: \(RPCError.from(error).message)" }
            }
            let ok = !cancelled && exitCode == 0 && normal && errorText == nil
            // Gaussian's own reason ("End of file in ZSymb", "stopped right after Link 1", …) instead of "no atoms".
            if !ok, !cancelled, spec.program == .gaussian,
               let out = CalcJobResults.resolvedOutputFileName(plan, directory: dir),
               let text = try? String(contentsOf: dir.appendingPathComponent(out), encoding: .utf8),
               let reason = GaussianInputCheck.failureReason(output: text) {
                // "could not read results: … no atoms" only repeats that Gaussian stopped early.
                let keep = errorText.flatMap { $0.hasPrefix("could not read results") ? nil : $0 }
                errorText = "Gaussian: " + reason + (keep.map { " — " + $0 } ?? "")
            }
            await self.jobs.setStatus(jobId, cancelled ? "cancelled" : (ok ? "finished" : "failed"))
            if !ok, errorText == nil { errorText = exitCode == 0 ? "the program did not terminate normally" : "exit code \(exitCode)" }
            self.notify("job.finished", obj([
                "jobId": jobId, "exitCode": exitCode, "ok": ok, "error": errorText, "cancelled": cancelled,
                "docId": newDoc?.id, "summary": newDoc?.summary() ?? JSON.null, "directory": dir.path,
                "fchk": fchk?.path, "formchkError": formchkError,
            ]))
        }
        await jobs.setTask(jobId, task)
        return obj(["jobId": jobId, "directory": dir.path, "commandLine": cmd, "inputFile": plan.inputFileName,
                    "outputFile": plan.outputFileName, "warnings": warnings, "repairs": repairs,
                    "check": Engine.issuesJSON(inputIssues)])
    }

    func calcCancel(_ p: Params) async throws -> JSON {
        try await jobs.cancel(try p.string("jobId"))
        return [:]
    }

    /// Starts an xtb run on a document (also used by the console `xtb opt`). Returns the job id and directory.
    func startXTB(docId: String, settings: XTBSettings, directory: URL?) async throws -> (String, URL) {
        let d = try await store.get(docId)
        let mol = d.molecule
        guard !mol.atoms.isEmpty else { throw RPCError.badRequest("the document has no atoms") }
        let problems = settings.validationErrors(molecule: mol)
        guard problems.isEmpty else { throw RPCError.badRequest(problems.joined(separator: " ")) }
        guard let exe = programs.locate(.xtb) else {
            throw RPCError.notInstalled("xtb was not found. Install it (conda install -c conda-forge xtb) or set its path in Settings.")
        }
        let dir = directory ?? Engine.defaultJobDirectory(prefix: "xtb")
        let jobId = await jobs.newId()
        await jobs.add(jobId, .init(kind: "xtb", docId: docId, directory: dir.path, task: nil, status: "running",
                                    commandLine: settings.commandLine(molecule: mol, executable: ProgramPaths.nativePath(exe))))
        let gate = ResponseGate.current
        let task = Task.detached { [self] in
            await gate?.wait()
            let handle = XTBRunner(executable: exe).stream(mol, settings: settings, runDirectory: dir)
            await withTaskCancellationHandler {
                for await ev in handle.events { await self.forward(jobId, ev) }
            } onCancel: { handle.cancel() }
            var payload: [String: JSON] = ["jobId": .string(jobId), "docId": .string(docId), "directory": .string(dir.path),
                                           "cancelled": false, "error": .null]
            do {
                let r = try await handle.value
                if Task.isCancelled { throw CancellationError() }
                if settings.task != .singlePoint {
                    // Adopt the optimized coordinates (one undo step) when the topology is unchanged.
                    let newPositions = r.molecule.atoms.map(\.position)
                    _ = try? await self.store.mutate(docId) { doc in
                        guard doc.molecule.atoms.count == newPositions.count else { return }
                        var m = doc.molecule
                        for i in m.atoms.indices { m.atoms[i].position = newPositions[i] }
                        doc.model.perform("xtb Optimization") { $0 = m }
                    }
                }
                let ok = r.exitCode == 0 && r.converged != false
                let err: String? = ok ? nil : (r.converged == false ? "optimization did not converge" : "xtb exit code \(r.exitCode)")
                payload["exitCode"] = Int(r.exitCode).json
                payload["ok"] = .bool(ok)
                payload["error"] = err.json
                payload["summary"] = (try? await self.store.summary(docId)) ?? .null
                payload["energy"] = .number(r.energy)
                payload["gradientNorm"] = r.gradientNorm.json
                payload["homoLumoGapEV"] = r.homoLumoGap.json
                payload["converged"] = r.converged.json
                payload["cycles"] = r.optimizationCycles.json
                payload["frequencies"] = r.frequencies.json
                await self.jobs.setStatus(jobId, ok ? "finished" : "failed")
            } catch {
                let e = Task.isCancelled ? RPCError.cancelled : RPCError.from(error)
                payload["exitCode"] = -1
                payload["ok"] = false
                payload["error"] = .string(e.message)
                payload["errorCode"] = .string(e.code)
                payload["cancelled"] = .bool(e.code == "cancelled")
                payload["summary"] = (try? await self.store.summary(docId)) ?? .null
                await self.jobs.setStatus(jobId, e.code == "cancelled" ? "cancelled" : "failed")
            }
            self.notify("job.finished", .object(payload))
        }
        await jobs.setTask(jobId, task)
        return (jobId, dir)
    }

    func xtbRun(_ p: Params) async throws -> JSON {
        let docId = try p.docId()
        var settings = XTBSettings()
        if let sj = p["settings"] {
            do { settings = try sj.decode(XTBSettings.self) } catch { throw RPCError.badRequest("invalid xtb settings: \(error)") }
        }
        let (jobId, dir) = try await startXTB(docId: docId, settings: settings,
                                              directory: p.optString("directory").map { URL(fileURLWithPath: $0, isDirectory: true) })
        return obj(["jobId": jobId, "directory": dir.path])
    }
}
