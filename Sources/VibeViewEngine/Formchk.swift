import Foundation
import MolCore
import MolIO
import MolAnalysis
import MolCompute

/// Automatic Gaussian `.chk` → `.fchk` conversion with `formchk`, so orbitals work without a manual step.
///
/// - Runs `formchk <stem>.chk <stem>.fchk` in the checkpoint's folder (relative names, so spaces and non-ASCII
///   folder names never pass through a command line). The output goes to a temporary name first and replaces
///   `<stem>.fchk` only when that file is missing or older than the `.chk`, so a newer `.fchk` is never overwritten.
/// - Used after a Gaussian `calc.run` job and, in the background, after `doc.open` of a Gaussian log whose `.chk`
///   companion has no up-to-date `.fchk`.
enum Formchk {
    static let timeout: TimeInterval = 600

    /// `<stem>.fchk` next to `chk`.
    static func fchkURL(for chk: URL) -> URL {
        chk.deletingPathExtension().appendingPathExtension("fchk")
    }

    static func modificationDate(_ u: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: u.path))?[.modificationDate] as? Date
    }

    /// True when `fchk` exists, isn't empty and is at least as new as `chk`.
    static func isUpToDate(chk: URL, fchk: URL) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fchk.path),
              ((attrs[.size] as? NSNumber)?.intValue ?? 0) > 0,
              let tf = attrs[.modificationDate] as? Date else { return false }
        guard let tc = modificationDate(chk) else { return true }
        return tf >= tc
    }

    static func executableNames() -> [String] {
        #if os(Windows)
        return ["formchk.exe", "formchk.bat", "formchk.cmd", "formchk"]
        #else
        return ["formchk"]
        #endif
    }

    /// Lookup order: `calc.setProgramPath {program: "formchk"}`, `VIBEVIEW_FORMCHK`, the `GAUSS_EXEDIR` folders,
    /// the folder of the Gaussian executable, PATH (MolCompute's search), then on Windows the usual G16W/G09W folders.
    static func locate(_ programs: ProgramPaths) -> URL? {
        if let o = programs.formchkOverride, ProgramPaths.isRunnable(o) { return URL(fileURLWithPath: o) }
        let env = ProcessInfo.processInfo.environment
        if let v = env["VIBEVIEW_FORMCHK"], !v.isEmpty, ProgramPaths.isRunnable(v) { return URL(fileURLWithPath: v) }
        var dirs: [String] = []
        #if os(Windows)
        let sep: Character = ";"
        #else
        let sep: Character = ":"
        #endif
        if let e = env["GAUSS_EXEDIR"], !e.isEmpty { dirs += e.split(separator: sep).map(String.init) }
        if let g = programs.locate(.gaussian) { dirs.append(ProgramPaths.nativePath(g.deletingLastPathComponent())) }
        #if os(Windows)
        let pf = env["ProgramFiles"] ?? "C:\\Program Files"
        let pf86 = env["ProgramFiles(x86)"] ?? "C:\\Program Files (x86)"
        for root in ["C:\\", pf, pf86] {
            for name in ["G16W", "G09W", "G16", "G09", "Gaussian 16W", "Gaussian09W"] {
                dirs.append((root as NSString).appendingPathComponent(name))
            }
        }
        #endif
        for d in dirs {
            for n in executableNames() {
                let p = (d as NSString).appendingPathComponent(n)
                if ProgramPaths.isRunnable(p) { return URL(fileURLWithPath: p) }
            }
        }
        for n in executableNames() { if let u = ProgramLocator.find(n) { return u } }
        #if os(Windows)
        for d in ProgramPaths.windowsSearchDirectories(.gaussian) {
            for n in executableNames() {
                let p = (d as NSString).appendingPathComponent(n)
                if ProgramPaths.isRunnable(p) { return URL(fileURLWithPath: p) }
            }
        }
        #endif
        return nil
    }

    enum Outcome {
        /// The `.fchk` was already up to date (nothing ran).
        case upToDate(URL)
        /// formchk wrote a new `.fchk`.
        case converted(URL)
        /// A newer `.fchk` appeared while formchk ran; it was kept and formchk's output discarded.
        case keptNewer(URL)
    }

    /// Converts `chk` (honours task cancellation and `timeout`). Throws `RPCError` with a readable message.
    static func convert(chk: URL, executable exe: URL, log: (@Sendable (String) -> Void)? = nil) async throws -> Outcome {
        let fm = FileManager.default
        guard fm.fileExists(atPath: chk.path) else { throw RPCError.notFound("no checkpoint file \(chk.path)") }
        let target = fchkURL(for: chk)
        if isUpToDate(chk: chk, fchk: target) { return .upToDate(target) }
        let dir = chk.deletingLastPathComponent()
        let stem = chk.deletingPathExtension().lastPathComponent
        let tmp = dir.appendingPathComponent("\(stem).vibeview-\(ProcessInfo.processInfo.processIdentifier)-\(UInt32.random(in: 0...UInt32.max)).fchk")
        try? fm.removeItem(at: tmp)
        defer { try? fm.removeItem(at: tmp) }
        var env = ProcessInfo.processInfo.environment
        if (env["GAUSS_EXEDIR"] ?? "").isEmpty { env["GAUSS_EXEDIR"] = ProgramPaths.nativePath(exe.deletingLastPathComponent()) }
        let started = Date()
        log?("formchk \(chk.lastPathComponent) \(target.lastPathComponent)")
        let out: ProcessOutput
        do {
            out = try await ProgramRunner.run(executable: exe, arguments: [chk.lastPathComponent, tmp.lastPathComponent],
                                              workingDirectory: dir, environment: env, timeout: timeout, throwOnFailure: false)
        } catch {
            if Task.isCancelled { throw RPCError.cancelled }
            throw RPCError(code: RPCError.from(error).code, message: "formchk failed: \(RPCError.from(error).message)")
        }
        try Task.checkCancellation()
        let size = ((try? fm.attributesOfItem(atPath: tmp.path))?[.size] as? NSNumber)?.intValue ?? 0
        guard out.exitCode == 0, size > 0 else {
            let tail = (out.stderr + "\n" + out.stdout).split(whereSeparator: \.isNewline).suffix(4).joined(separator: " | ")
            throw RPCError.io("formchk exited with code \(out.exitCode)\(tail.isEmpty ? "" : ": " + tail)")
        }
        // Never overwrite a .fchk that is newer than the checkpoint (written by the user or another formchk meanwhile).
        if let t = modificationDate(target), fm.fileExists(atPath: target.path), t >= started || isUpToDate(chk: chk, fchk: target) {
            log?("kept the newer \(target.lastPathComponent)")
            return .keptNewer(target)
        }
        do {
            // FileManager.replaceItemAt traps ("not yet implemented") in swift-corelibs-foundation on Windows.
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.moveItem(at: tmp, to: target)
            // Stamp the result as made now, so it counts as up to date even when the converter kept the source
            // file's timestamp (a copy-based formchk wrapper, or a clock skew on a network share).
            try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: target.path)
        } catch {
            throw RPCError.io("could not write \(target.path): \(error.localizedDescription)")
        }
        log?("wrote \(target.lastPathComponent)")
        return .converted(target)
    }

    static func url(of o: Outcome) -> URL {
        switch o { case .upToDate(let u), .converted(let u), .keptNewer(let u): return u }
    }

    /// The `.chk` companion of a loaded document, if any.
    static func checkpointCompanion(_ d: EngineDocument) -> URL? {
        d.companions.first { $0.role == .binary && $0.url.pathExtension.lowercased() == "chk" }?.url
    }
}

extension Engine {
    /// Reads `fchk` and gives its wavefunction to document `docId`. Replaces a wavefunction only when it came from
    /// that same (stale) `.fchk`. Returns the updated document.
    func attachFormattedCheckpoint(docId: String, fchk: URL, note: String) async throws -> EngineDocument {
        let fc: FormattedCheckpoint
        do { fc = try FormattedCheckpoint.read(url: fchk) } catch {
            throw RPCError.parse("could not read \(fchk.lastPathComponent): \(RPCError.from(error).message)")
        }
        guard let wf = fc.wavefunction else { throw RPCError.parse("\(fchk.lastPathComponent) has no basis set or MOs") }
        let orbs = fc.calculationResult.orbitals
        let n = fc.molecule.atoms.count
        return try await store.mutate(docId) { d in
            let atoms = d.molecule.atoms.count
            guard atoms == 0 || n == atoms else {
                throw RPCError.badRequest("\(fchk.lastPathComponent) has \(n) atoms, the document has \(atoms)")
            }
            let fromSameFile = d.companions.contains { $0.role == .wavefunction && $0.used && $0.url.path == fchk.path }
            guard d.wavefunction == nil || fromSameFile else {
                throw RPCError.badRequest("the document already has a wavefunction")
            }
            d.wavefunction = wf
            d.surfaces = OrbitalSurfaceService(wavefunction: wf)
            if var r = d.result {
                if r.orbitals.isEmpty || fromSameFile { r.orbitals = orbs }
                d.result = r
            }
            d.companions.removeAll { $0.url.path == fchk.path }
            d.companions.append(CompanionFile(url: fchk, role: .wavefunction, used: true,
                                              note: "wavefunction (\(wf.alpha.orbitalCount) MOs\(wf.isUnrestricted ? ", unrestricted" : "")), \(note)"))
            if let k = d.companions.firstIndex(where: { $0.role == .binary && $0.url.pathExtension.lowercased() == "chk" }) {
                d.companions[k].note = "binary checkpoint; converted to \(fchk.lastPathComponent) with formchk"
            }
            d.formchkPending = false
            return d
        }
    }

    /// After `doc.open` of a Gaussian log: convert its `.chk` companion in the background when no up-to-date `.fchk`
    /// exists. Sends `doc.wavefunction` when done. Missing formchk is not an error: the companion keeps its hint.
    func scheduleFormchkIfNeeded(_ d: EngineDocument) async -> EngineDocument {
        guard let chk = Formchk.checkpointCompanion(d) else { return d }
        let fchk = Formchk.fchkURL(for: chk)
        guard !Formchk.isUpToDate(chk: chk, fchk: fchk) else { return d }
        guard let exe = Formchk.locate(programs) else {
            let doc = try? await store.mutate(d.id) { doc -> EngineDocument in
                if let k = doc.companions.firstIndex(where: { $0.url.path == chk.path }) {
                    doc.companions[k].note += " (formchk not found: add it to PATH, set GAUSS_EXEDIR, or calc.setProgramPath {program: \"formchk\"})"
                }
                return doc
            }
            return doc ?? d
        }
        let docId = d.id
        let jobId = await jobs.newId()
        await jobs.add(jobId, .init(kind: "formchk", docId: docId, directory: chk.deletingLastPathComponent().path, task: nil,
                                    status: "running", commandLine: shellQuoted([ProgramPaths.nativePath(exe), chk.lastPathComponent, fchk.lastPathComponent])))
        let updated = (try? await store.mutate(docId) { doc -> EngineDocument in doc.formchkPending = true; return doc }) ?? d
        let gate = ResponseGate.current
        let task = Task.detached { [self] in
            await gate?.wait()
            var payload: [String: JSON] = ["docId": .string(docId), "jobId": .string(jobId), "chk": .string(chk.path)]
            do {
                let outcome = try await Formchk.convert(chk: chk, executable: exe) { line in Log.info("formchk: \(line)") }
                let u = Formchk.url(of: outcome)
                let doc = try await self.attachFormattedCheckpoint(docId: docId, fchk: u, note: "made by formchk")
                payload["ok"] = true
                payload["error"] = .null
                payload["fchk"] = .string(u.path)
                payload["summary"] = doc.summary()
                await self.jobs.setStatus(jobId, "finished")
            } catch {
                let e = Task.isCancelled ? RPCError.cancelled : RPCError.from(error)
                payload["ok"] = false
                payload["error"] = .string(e.message)
                payload["errorCode"] = .string(e.code)
                payload["fchk"] = .null
                _ = try? await self.store.mutate(docId) { doc in
                    doc.formchkPending = false
                    if let k = doc.companions.firstIndex(where: { $0.url.path == chk.path }) {
                        doc.companions[k].note += " (automatic formchk failed: \(e.message))"
                    }
                }
                payload["summary"] = (try? await self.store.summary(docId)) ?? .null
                await self.jobs.setStatus(jobId, e.code == "cancelled" ? "cancelled" : "failed")
            }
            // A closed document gets no event.
            if (try? await self.store.get(docId)) != nil || payload["ok"] == true {
                self.notify("doc.wavefunction", .object(payload))
            }
        }
        await jobs.setTask(jobId, task)
        return updated
    }

    /// After a Gaussian `calc.run`: convert `<checkpoint>.chk` before the results are collected. Never throws.
    func formchkAfterGaussianJob(jobId: String, chk: URL) async -> (fchk: URL?, error: String?) {
        guard FileManager.default.fileExists(atPath: chk.path) else { return (nil, nil) }
        guard let exe = Formchk.locate(programs) else {
            return (nil, "formchk not found: run `formchk \(chk.lastPathComponent) \(Formchk.fchkURL(for: chk).lastPathComponent)` to view orbitals")
        }
        do {
            let o = try await Formchk.convert(chk: chk, executable: exe) { [self] line in
                notify("job.log", obj(["jobId": jobId, "stream": "stdout", "file": JSON.null, "line": line]))
            }
            return (Formchk.url(of: o), nil)
        } catch {
            return (nil, RPCError.from(error).message)
        }
    }
}
