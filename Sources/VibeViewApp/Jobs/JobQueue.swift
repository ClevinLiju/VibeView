import Foundation
import SwiftUI
import AppKit
import MolCore
import MolBuild
import MolCompute

struct JobRunResult {
    var status: JobStatus
    var outputURL: URL
    /// xtb: `xtbopt.xyz`; ORCA: `job.xyz` when present; Q-Chem / Gaussian: nil.
    var finalGeometryURL: URL?
    var directory: URL
}

struct JobRun: Identifiable, Equatable {
    let id: UUID
    var program: QCProgram
    var name: String
    /// The run directory (every file the program writes lands here).
    var directory: URL
    /// The input file as written (Gaussian .gjf, ORCA .inp, Q-Chem .in, xtb .xyz).
    var inputURL: URL
    /// The main output file (Gaussian .log, ORCA/Q-Chem .out, xtb stdout).
    var outputURL: URL
    var setup: CalcSetup
    /// xtb: the arguments the job is started with (from the edited command line when the input was edited).
    var xtbArguments: [String]? = nil
    /// The command line, for display (xtb; ORCA/Gaussian/Q-Chem read the input file).
    var commandLine: String? = nil
    /// True when the input was edited by hand in Calculation Setup.
    var inputEdited = false
    /// Post-processing steps after the program finished (e.g. the ORCA orbital conversion), shown in the job log.
    var postSteps: [String] = []
    var isPostProcessing = false
    /// ORCA: the Molden file written by `orca_2mkl` after the run.
    var moldenURL: URL? = nil
    var status: JobStatus = .queued
    var startDate: Date? = nil
    var endDate: Date? = nil
    var liveLog: String = ""
    var energies: [Double] = []
    var message: String? = nil
    var autoOpen = true

    var lastEnergy: Double? { energies.last }
    var stepCount: Int { energies.count }

    func elapsed(at now: Date = Date()) -> TimeInterval {
        guard let s = startDate else { return 0 }
        return (endDate ?? now).timeIntervalSince(s)
    }

    var finalGeometryURL: URL? {
        let fm = FileManager.default
        let candidate: URL?
        switch program {
        case .xtb: candidate = directory.appendingPathComponent("xtbopt.xyz")
        case .orca: candidate = directory.appendingPathComponent("job.xyz")
        default: candidate = nil
        }
        if let c = candidate, fm.fileExists(atPath: c.path) { return c }
        return nil
    }

    var result: JobRunResult { JobRunResult(status: status, outputURL: outputURL, finalGeometryURL: finalGeometryURL, directory: directory) }
}

enum JobSubmitError: LocalizedError {
    case programMissing(QCProgram)
    case io(String)
    var errorDescription: String? {
        switch self {
        case .programMissing(let p): ProgramLocator.notFoundMessage(p)
        case .io(let m): m
        }
    }
}

/// Sequential local job queue for Gaussian, ORCA, Q-Chem and xtb (one job at a time).
@MainActor
final class JobQueue: ObservableObject {
    static let shared = JobQueue()

    @Published private(set) var jobs: [JobRun] = []
    /// Located executables per program (nil = not found).
    @Published private(set) var locations: [QCProgram: URL] = [:]

    /// Test hook: use this executable instead of locating the program.
    var executableOverride: [QCProgram: URL] = [:]
    /// Test hook: polling interval for log tailing.
    var pollInterval: TimeInterval = 0.5

    private var runner: JobProcess?
    private var runningID: UUID?
    private var completions: [UUID: (JobRunResult) -> Void] = [:]
    private var externalCancels: [UUID: () -> Void] = [:]

    init() { refreshAvailability() }

    var hasActiveJobs: Bool { jobs.contains { $0.status.isActive } }

    func resolveExecutable(_ p: QCProgram) -> URL? { executableOverride[p] ?? ProgramLocator.locate(p) }

    func refreshAvailability() {
        var m: [QCProgram: URL] = [:]
        for p in QCProgram.allCases { if let u = resolveExecutable(p) { m[p] = u } }
        locations = m
    }

    func isAvailable(_ p: QCProgram) -> Bool { locations[p] != nil }

    // MARK: Submit

    /// Writes the input into a fresh job directory and queues it.
    @discardableResult
    func submit(setup: CalcSetup, molecule: Molecule, name: String, documentURL: URL?, autoOpen: Bool = true,
                iterations: CalcIterations = CalcIterations(),
                inputOverride: String? = nil, xtbArguments: [String]? = nil,
                completion: ((JobRunResult) -> Void)? = nil) throws -> UUID {
        let program = setup.program
        guard let exe = resolveExecutable(program) else { throw JobSubmitError.programMissing(program) }
        let safe = Self.safeName(name)
        let stamp = Self.stamp()
        let folder = "\(safe)-\(program.rawValue)-\(stamp)"
        let fm = FileManager.default
        let base: URL
        if let d = documentURL {
            base = d.deletingLastPathComponent()
        } else {
            base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("VibeView/Jobs", isDirectory: true)
        }
        let dir = base.appendingPathComponent(folder, isDirectory: true)
        var effective = setup
        var note: String? = nil
        if program == .orca, effective.nprocs > 1, ProgramLocator.mpirun(orca: exe) == nil {
            effective.nprocs = 1
            note = "mpirun not found \u{2014} running ORCA on 1 core."
        }
        let input = dir.appendingPathComponent("job." + program.inputExtension)
        let output = dir.appendingPathComponent("job." + program.outputExtension)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            // A hand-edited input is written exactly as typed.
            let text = inputOverride ?? iterations.apply(to: effective.inputText(molecule: molecule), program: program, jobType: effective.jobType)
            try text.write(to: input, atomically: true, encoding: .utf8)
        } catch {
            throw JobSubmitError.io("Could not write the job files: \(error.localizedDescription)")
        }
        var run = JobRun(id: UUID(), program: program, name: safe, directory: dir, inputURL: input, outputURL: output, setup: effective)
        run.message = note
        run.autoOpen = autoOpen
        run.inputEdited = inputOverride != nil
        if program == .xtb {
            let args = xtbArguments ?? effective.commandArguments(inputFileName: input.lastPathComponent)
            run.xtbArguments = args
            run.commandLine = XTBInputPreview.shellJoin(["xtb"] + args)
        }
        jobs.append(run)
        if let completion { completions[run.id] = completion }
        refreshAvailability()
        startNextIfIdle()
        return run.id
    }

    // MARK: Externally driven jobs (xtb runs started from the xtb settings sheet)

    /// Fresh job directory under the same root `submit` uses.
    static func newJobDirectory(name: String, program: QCProgram, documentURL: URL? = nil) -> URL {
        let base: URL
        if let d = documentURL {
            base = d.deletingLastPathComponent()
        } else {
            base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("VibeView/Jobs", isDirectory: true)
        }
        return base.appendingPathComponent("\(safeName(name))-\(program.rawValue)-\(stamp())", isDirectory: true)
    }

    /// Lists a job that something else is running (it shows in the queue window with its log) and returns its id.
    @discardableResult
    func registerExternal(program: QCProgram, name: String, directory: URL, outputURL: URL, setup: CalcSetup,
                          commandLine: String? = nil, message: String? = nil, cancel: @escaping () -> Void) -> UUID {
        var run = JobRun(id: UUID(), program: program, name: Self.safeName(name), directory: directory,
                         inputURL: directory.appendingPathComponent("input.xyz"), outputURL: outputURL, setup: setup)
        run.commandLine = commandLine
        run.status = .running
        run.startDate = Date()
        run.autoOpen = false
        run.message = message
        jobs.append(run)
        externalCancels[run.id] = cancel
        return run.id
    }

    func updateExternal(_ id: UUID, tail: String, energies: [Double]) {
        guard let i = index(id) else { return }
        jobs[i].liveLog = tail
        jobs[i].energies = energies
    }

    func finishExternal(_ id: UUID, status: JobStatus, message: String? = nil) {
        externalCancels[id] = nil
        guard let i = index(id) else { return }
        jobs[i].status = status
        jobs[i].endDate = Date()
        if let message { jobs[i].message = message }
    }

    static func safeName(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = String(t.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" })
        return cleaned.isEmpty ? "molecule" : cleaned
    }

    static func stamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }

    // MARK: Actions

    func cancel(_ id: UUID) {
        guard let i = index(id) else { return }
        switch jobs[i].status {
        case .queued:
            jobs[i].status = .cancelled
            jobs[i].endDate = Date()
            complete(jobs[i])
        case .running:
            if let c = externalCancels[id] { c() } else { runner?.cancel() }
        default: break
        }
    }

    func remove(_ id: UUID) {
        guard let i = index(id), !jobs[i].status.isActive else { return }
        jobs.remove(at: i)
        completions[id] = nil
        JobLogCenter.shared.forget(id)
    }

    func clearFinished() {
        for j in jobs where !j.status.isActive { completions[j.id] = nil; JobLogCenter.shared.forget(j.id) }
        jobs.removeAll { !$0.status.isActive }
    }

    func reveal(_ id: UUID) {
        guard let j = jobs.first(where: { $0.id == id }) else { return }
        let target = FileManager.default.fileExists(atPath: j.outputURL.path) ? j.outputURL : j.directory
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    func job(_ id: UUID) -> JobRun? { jobs.first { $0.id == id } }

    /// Read-only viewer (search, line numbers) for the job's input file.
    func showInput(_ id: UUID) {
        guard let j = job(id) else { return }
        FileViewerWindow.show(url: j.inputURL, title: "\(j.name) \u{2014} input (\(j.inputURL.lastPathComponent))",
                              note: j.commandLine.map { "Command: " + $0 }, live: false, jobID: id)
    }

    /// Read-only viewer for the job's main output; follows the file while the job runs.
    func showOutput(_ id: UUID) {
        guard let j = job(id) else { return }
        FileViewerWindow.show(url: j.outputURL, title: "\(j.name) \u{2014} output (\(j.outputURL.lastPathComponent))",
                              note: nil, live: j.status.isActive, jobID: id)
    }

    func openResult(_ id: UUID) {
        guard let j = jobs.first(where: { $0.id == id }) else { return }
        open(j.result)
    }

    private func open(_ r: JobRunResult) {
        let fm = FileManager.default
        func tryOpen(_ url: URL, fallback: URL?) {
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                if error != nil, let f = fallback, fm.fileExists(atPath: f.path) {
                    NSDocumentController.shared.openDocument(withContentsOf: f, display: true) { _, _, _ in }
                }
            }
        }
        if fm.fileExists(atPath: r.outputURL.path) { tryOpen(r.outputURL, fallback: r.finalGeometryURL) }
        else if let g = r.finalGeometryURL { tryOpen(g, fallback: nil) }
    }

    // MARK: Internals

    private func index(_ id: UUID) -> Int? { jobs.firstIndex { $0.id == id } }

    private func complete(_ job: JobRun) {
        if let c = completions.removeValue(forKey: job.id) { c(job.result) }
    }

    private func launch(for job: JobRun, exe: URL) -> JobLaunch {
        let dir = job.directory
        let s = job.setup
        switch job.program {
        case .gaussian:
            let scratch = UserDefaults.standard.string(forKey: AppSettings.scratchDirKey)
            return JobLaunch(program: .gaussian, executable: exe, stdinFile: job.inputURL, outputFile: job.outputURL,
                             workingDirectory: dir, environment: ProgramLocator.gaussianEnvironment(exe: exe, scratchSetting: scratch, jobDirectory: dir))
        case .orca:
            var extra = [exe.deletingLastPathComponent().path]
            if let m = ProgramLocator.mpirun(orca: exe) { extra.append(m.deletingLastPathComponent().path) }
            // ORCA must be started by absolute path so it can find its helper binaries and MPI.
            return JobLaunch(program: .orca, executable: exe, arguments: [job.inputURL.lastPathComponent], outputFile: job.outputURL,
                             workingDirectory: dir, environment: ProgramLocator.baseEnvironment(extraDirs: extra))
        case .qchem:
            var env = ProgramLocator.baseEnvironment()
            if (env["QC"] ?? "").isEmpty { env["QC"] = exe.deletingLastPathComponent().deletingLastPathComponent().path }
            return JobLaunch(program: .qchem, executable: exe,
                             arguments: ["-nt", String(max(1, s.nprocs)), job.inputURL.lastPathComponent, job.outputURL.lastPathComponent],
                             outputFile: job.outputURL, stdoutFile: dir.appendingPathComponent("job.stdout"),
                             workingDirectory: dir, environment: env)
        case .xtb:
            var env = ProgramLocator.baseEnvironment(extraDirs: [exe.deletingLastPathComponent().path])
            env["OMP_NUM_THREADS"] = String(max(1, s.nprocs))
            env["OMP_STACKSIZE"] = "1G"
            env["MKL_NUM_THREADS"] = String(max(1, s.nprocs))
            return JobLaunch(program: .xtb, executable: exe, arguments: job.xtbArguments ?? s.commandArguments(inputFileName: job.inputURL.lastPathComponent),
                             outputFile: job.outputURL, workingDirectory: dir, environment: env)
        }
    }

    private func startNextIfIdle() {
        guard runner == nil, let i = jobs.firstIndex(where: { $0.status == .queued }) else { return }
        let id = jobs[i].id
        guard let exe = resolveExecutable(jobs[i].program) else {
            jobs[i].status = .failed(ProgramLocator.notFoundMessage(jobs[i].program))
            jobs[i].endDate = Date()
            complete(jobs[i])
            startNextIfIdle()
            return
        }
        let p = JobProcess(launch: launch(for: jobs[i], exe: exe), interval: pollInterval,
                           onUpdate: { snap in Task { @MainActor [weak self] in self?.apply(snap, to: id) } },
                           onExit: { outcome, snap in Task { @MainActor [weak self] in self?.finish(id, outcome, snap) } })
        do {
            try p.start()
            runner = p; runningID = id
            jobs[i].status = .running
            jobs[i].startDate = Date()
        } catch {
            jobs[i].status = .failed("Could not launch \(jobs[i].program.title): \(error.localizedDescription)")
            jobs[i].endDate = Date()
            complete(jobs[i])
            startNextIfIdle()
        }
    }

    func apply(_ snap: JobSnapshot, to id: UUID) {
        guard let i = index(id), jobs[i].status == .running else { return }
        jobs[i].liveLog = snap.tail
        jobs[i].energies = snap.energies
    }

    func finish(_ id: UUID, _ outcome: JobOutcome, _ snap: JobSnapshot) {
        if let i = index(id) {
            jobs[i].liveLog = snap.tail
            jobs[i].energies = snap.energies
            jobs[i].endDate = Date()
            switch outcome {
            case .finished(let n): jobs[i].status = .finished(normal: n)
            case .failed(let m): jobs[i].status = .failed(m)
            case .cancelled: jobs[i].status = .cancelled
            }
            let job = jobs[i]
            if job.program == .orca, job.status != .cancelled, Self.orcaMoldenEnabled,
               OrcaMoldenConversion.hasWavefunction(baseName: job.inputURL.deletingPathExtension().lastPathComponent, in: job.directory) {
                // The next job may start meanwhile; this one is opened once its orbitals are converted.
                jobs[i].isPostProcessing = true
                Task { @MainActor in
                    await self.convertOrbitals(id)
                    self.finalize(id)
                }
            } else {
                finalize(id)
            }
        }
        if runningID == id { runner = nil; runningID = nil }
        startNextIfIdle()
    }

    private func finalize(_ id: UUID) {
        guard let i = index(id) else { return }
        jobs[i].isPostProcessing = false
        let job = jobs[i]
        if job.autoOpen, case .finished = job.status { open(job.result) }
        complete(job)
    }

    // MARK: ORCA orbitals → Molden

    /// Preference (on by default): run `orca_2mkl <base> -molden` after every ORCA job that wrote a .gbw.
    static var orcaMoldenEnabled: Bool {
        UserDefaults.standard.object(forKey: AppSettings.orcaAutoMoldenKey) as? Bool ?? true
    }

    /// Converts the job's .gbw to `<base>.molden.input` in the run directory, logging each step. Never throws:
    /// a failure is recorded in the job log and the results open without orbitals.
    func convertOrbitals(_ id: UUID) async {
        guard let j = job(id) else { return }
        let base = j.inputURL.deletingPathExtension().lastPathComponent
        let orca = resolveExecutable(.orca)
        let tool = orcaMoldenToolOverride ?? orca.flatMap(OrcaMoldenConversion.locateTool(nextTo:))
        guard let tool else {
            postStep(id, "Orbital conversion skipped: orca_2mkl not found next to \(orca?.path ?? "orca"). Run “orca_2mkl \(base) -molden” in the job folder to see orbitals.")
            return
        }
        postStep(id, "Converting orbitals: \(tool.lastPathComponent) \(base) -molden \u{2026}")
        do {
            let r = try await OrcaMoldenConversion.convert(baseName: base, in: j.directory, tool: tool)
            if let i = index(id) { jobs[i].moldenURL = r.moldenURL }
            postStep(id, "Orbitals converted: \(r.moldenURL.lastPathComponent) (loaded with the results)")
        } catch {
            postStep(id, "Orbital conversion failed: \(error.localizedDescription). The results open without orbitals.")
        }
    }

    /// Test hook: the orca_2mkl to use instead of the one next to the located orca.
    var orcaMoldenToolOverride: URL?

    private func postStep(_ id: UUID, _ line: String) {
        guard let i = index(id) else { return }
        jobs[i].postSteps.append(line)
        jobs[i].liveLog += (jobs[i].liveLog.isEmpty ? "" : "\n") + "[VibeView] " + line
        JobLogCenter.shared.existing(for: id)?.enqueue("[VibeView] " + line)
    }
}
