import Foundation
import SwiftUI
import AppKit
import MolCore
import MolBuild

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
    var directory: URL
    var inputURL: URL
    var outputURL: URL
    var setup: CalcSetup
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
                .appendingPathComponent("MolScope/Jobs", isDirectory: true)
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
            try effective.inputText(molecule: molecule).write(to: input, atomically: true, encoding: .utf8)
        } catch {
            throw JobSubmitError.io("Could not write the job files: \(error.localizedDescription)")
        }
        var run = JobRun(id: UUID(), program: program, name: safe, directory: dir, inputURL: input, outputURL: output, setup: effective)
        run.message = note
        run.autoOpen = autoOpen
        jobs.append(run)
        if let completion { completions[run.id] = completion }
        refreshAvailability()
        startNextIfIdle()
        return run.id
    }

    private static func safeName(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = String(t.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" })
        return cleaned.isEmpty ? "molecule" : cleaned
    }

    private static func stamp() -> String {
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
            runner?.cancel()
        default: break
        }
    }

    func remove(_ id: UUID) {
        guard let i = index(id), !jobs[i].status.isActive else { return }
        jobs.remove(at: i)
        completions[id] = nil
    }

    func clearFinished() {
        for j in jobs where !j.status.isActive { completions[j.id] = nil }
        jobs.removeAll { !$0.status.isActive }
    }

    func reveal(_ id: UUID) {
        guard let j = jobs.first(where: { $0.id == id }) else { return }
        let target = FileManager.default.fileExists(atPath: j.outputURL.path) ? j.outputURL : j.directory
        NSWorkspace.shared.activateFileViewerSelecting([target])
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
            return JobLaunch(program: .xtb, executable: exe, arguments: s.commandArguments(inputFileName: job.inputURL.lastPathComponent),
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
            if job.autoOpen, case .finished = job.status { open(job.result) }
            complete(job)
        }
        if runningID == id { runner = nil; runningID = nil }
        startNextIfIdle()
    }
}
