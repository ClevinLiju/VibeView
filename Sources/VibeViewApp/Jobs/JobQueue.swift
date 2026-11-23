import Foundation
import SwiftUI
import AppKit

struct GaussianJobRun: Identifiable, Equatable {
    let id = UUID()
    var inputURL: URL
    var logURL: URL
    var status: JobStatus = .queued
    var startDate: Date? = nil
    var endDate: Date? = nil
    var liveLog: String = ""
    var energies: [Double] = []
    var lastEnergy: Double? { energies.last }
    var stepCount: Int { energies.count }
    var name: String { inputURL.deletingPathExtension().lastPathComponent }

    func elapsed(at now: Date = Date()) -> TimeInterval {
        guard let s = startDate else { return 0 }
        return (endDate ?? now).timeIntervalSince(s)
    }
}

/// Sequential local Gaussian job queue (one job at a time).
@MainActor
final class JobQueue: ObservableObject {
    static let shared = JobQueue()

    @Published private(set) var jobs: [GaussianJobRun] = []
    @Published private(set) var gaussianAvailable: Bool = true

    /// Test hook: use this executable instead of locating Gaussian.
    var executableOverride: URL?
    /// Test hook: polling interval for log tailing.
    var pollInterval: TimeInterval = 0.5

    private var runner: JobProcess?
    private var runningID: UUID?

    init() { refreshAvailability() }

    var hasActiveJobs: Bool { jobs.contains { $0.status.isActive } }

    func resolveExecutable() -> URL? {
        if let o = executableOverride { return o }
        let path = UserDefaults.standard.string(forKey: AppSettings.gaussianPathKey)
        return GaussianLocator.locate(settingsPath: path)
    }

    func refreshAvailability() { gaussianAvailable = resolveExecutable() != nil }

    @discardableResult
    func enqueue(inputURL: URL) -> UUID {
        let log = inputURL.deletingPathExtension().appendingPathExtension("log")
        let job = GaussianJobRun(inputURL: inputURL, logURL: log)
        jobs.append(job)
        refreshAvailability()
        startNextIfIdle()
        return job.id
    }

    func cancel(_ id: UUID) {
        guard let i = index(id) else { return }
        switch jobs[i].status {
        case .queued:
            jobs[i].status = .cancelled
        case .running:
            runner?.cancel()
        default: break
        }
    }

    func remove(_ id: UUID) {
        guard let i = index(id), !jobs[i].status.isActive else { return }
        jobs.remove(at: i)
    }

    func clearFinished() { jobs.removeAll { !$0.status.isActive } }

    func openResult(_ id: UUID) {
        guard let j = jobs.first(where: { $0.id == id }), FileManager.default.fileExists(atPath: j.logURL.path) else { return }
        NSDocumentController.shared.openDocument(withContentsOf: j.logURL, display: true) { _, _, _ in }
    }

    // MARK: Internals

    private func index(_ id: UUID) -> Int? { jobs.firstIndex { $0.id == id } }

    private func startNextIfIdle() {
        guard runner == nil, let i = jobs.firstIndex(where: { $0.status == .queued }) else { return }
        let id = jobs[i].id
        guard let exe = resolveExecutable() else {
            jobs[i].status = .failed(GaussianLocator.notFoundMessage)
            jobs[i].endDate = Date()
            startNextIfIdle()
            return
        }
        let job = jobs[i]
        let scratch = UserDefaults.standard.string(forKey: AppSettings.scratchDirKey)
        let env = GaussianLocator.environment(exe: exe, scratchSetting: scratch, jobDirectory: job.inputURL.deletingLastPathComponent())
        let p = JobProcess(executable: exe, input: job.inputURL, log: job.logURL, environment: env, interval: pollInterval,
                           onUpdate: { snap in Task { @MainActor [weak self] in self?.apply(snap, to: id) } },
                           onExit: { outcome, snap in Task { @MainActor [weak self] in self?.finish(id, outcome, snap) } })
        do {
            try p.start()
            runner = p; runningID = id
            jobs[i].status = .running
            jobs[i].startDate = Date()
        } catch {
            jobs[i].status = .failed("Could not launch Gaussian: \(error.localizedDescription)")
            jobs[i].endDate = Date()
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
        }
        if runningID == id { runner = nil; runningID = nil }
        startNextIfIdle()
    }
}
