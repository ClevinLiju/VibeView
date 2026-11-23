import SwiftUI
import Charts
import AppKit

/// Local job queue window: list of runs, SCF energy trace and live log of the selected run.
struct JobQueueView: View {
    @ObservedObject private var queue = JobQueue.shared
    @StateObject private var selBox = VMBox<UUID?>(nil)

    private var selected: GaussianJobRun? {
        queue.jobs.first { $0.id == selBox.value } ?? queue.jobs.last
    }

    var body: some View {
        VStack(spacing: 0) {
            if !queue.gaussianAvailable { banner }
            if queue.jobs.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray").font(.largeTitle).foregroundStyle(.secondary)
                    Text("No jobs yet").font(.headline)
                    Text("Use Calculation Setup \u{2192} Save & Run to queue a Gaussian job.").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    jobList.frame(minWidth: 260, idealWidth: 300)
                    detail.frame(minWidth: 380)
                }
            }
        }
        .frame(minWidth: 720, minHeight: 420)
        .onAppear { queue.refreshAvailability() }
    }

    private var banner: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(GaussianLocator.notFoundMessage).font(.callout)
            Spacer()
            Button("Open Settings\u{2026}") { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
            Button("Recheck") { queue.refreshAvailability() }
        }
        .padding(8)
        .background(Color.orange.opacity(0.15))
    }

    private var jobList: some View {
        VStack(spacing: 0) {
            List(selection: $selBox.value) {
                ForEach(queue.jobs) { job in
                    JobRow(job: job).tag(job.id)
                }
            }
            Divider()
            HStack {
                Button("Clear Finished") { queue.clearFinished() }
                    .disabled(!queue.jobs.contains { !$0.status.isActive })
                Spacer()
            }.padding(8)
        }
    }

    @ViewBuilder private var detail: some View {
        if let job = selected {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading) {
                        Text(job.name).font(.title3.bold())
                        Text(job.status.label).foregroundStyle(statusColor(job.status))
                    }
                    Spacer()
                    if job.status.isActive {
                        Button("Cancel") { queue.cancel(job.id) }
                    } else {
                        Button("Remove") { queue.remove(job.id) }
                    }
                    Button("Open Result") { queue.openResult(job.id) }
                        .disabled(job.status.isActive && job.status != .running || !FileManager.default.fileExists(atPath: job.logURL.path))
                }
                if job.energies.count >= 2 {
                    GroupBox("SCF energy (Hartree)") {
                        Chart(Array(job.energies.enumerated()), id: \.offset) { i, e in
                            LineMark(x: .value("SCF", i + 1), y: .value("E", e))
                            PointMark(x: .value("SCF", i + 1), y: .value("E", e)).symbolSize(14)
                        }
                        .chartYScale(domain: .automatic(includesZero: false))
                        .frame(height: 110)
                    }
                } else if let e = job.lastEnergy {
                    Text(String(format: "Last SCF energy: %.8f Eh", e)).font(.system(.body, design: .monospaced))
                }
                LiveLogView(text: job.liveLog)
            }
            .padding()
        }
    }

    private func statusColor(_ s: JobStatus) -> Color {
        switch s {
        case .queued: .secondary
        case .running: .blue
        case .finished(let n): n ? .green : .red
        case .failed: .red
        case .cancelled: .orange
        }
    }
}

private struct JobRow: View {
    let job: GaussianJobRun
    var body: some View {
        HStack(spacing: 8) {
            icon.frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.name).lineLimit(1)
                HStack(spacing: 6) {
                    if job.startDate != nil {
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            Text(Self.format(job.elapsed(at: ctx.date)))
                        }
                    }
                    if let e = job.lastEnergy { Text(String(format: "%.6f", e)) }
                    if job.stepCount > 0 { Text("\(job.stepCount) SCF") }
                }
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }

    @ViewBuilder private var icon: some View {
        switch job.status {
        case .queued: Image(systemName: "clock").foregroundStyle(.secondary)
        case .running: ProgressView().controlSize(.small)
        case .finished(let n): Image(systemName: n ? "checkmark.circle.fill" : "xmark.octagon.fill").foregroundStyle(n ? .green : .red)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        case .cancelled: Image(systemName: "stop.circle").foregroundStyle(.orange)
        }
    }

    static func format(_ t: TimeInterval) -> String {
        let s = Int(t)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Monospaced text that keeps scrolled to the bottom as new output arrives.
private struct LiveLogView: View {
    let text: String
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(text.isEmpty ? "(no output yet)" : text)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                Color.clear.frame(height: 1).id("bottom")
            }
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .onChange(of: text) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }
}
