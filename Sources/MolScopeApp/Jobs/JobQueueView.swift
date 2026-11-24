import SwiftUI
import Charts
import MolBuild

/// The "Job Queue" window: sidebar of runs, detail with live log and energy chart, footer with program discovery.
struct JobQueueView: View {
    @ObservedObject private var queue = JobQueue.shared
    @State private var selection: UUID?

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                sidebar
                    .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
            } detail: {
                if let id = selection, let job = queue.jobs.first(where: { $0.id == id }) {
                    JobDetail(job: job)
                } else {
                    ContentUnavailableView("No Job Selected", systemImage: "list.bullet.rectangle",
                                           description: Text("Pick a job on the left to see its log and energies."))
                }
            }
            Divider()
            ProgramFooter(queue: queue)
        }
        .frame(minWidth: 820, minHeight: 520)
        .onAppear { queue.refreshAvailability() }
        .onChange(of: queue.jobs.count) { _, _ in
            if selection == nil || !queue.jobs.contains(where: { $0.id == selection }) { selection = queue.jobs.last?.id }
        }
    }

    private var sidebar: some View {
        Group {
            if queue.jobs.isEmpty {
                ContentUnavailableView("No Jobs", systemImage: "tray",
                                       description: Text("Calculations you run from Calculation Setup appear here."))
            } else {
                List(selection: $selection) {
                    ForEach(queue.jobs.reversed()) { job in
                        JobRow(job: job).tag(job.id)
                            .contentShape(Rectangle())
                            .simultaneousGesture(TapGesture(count: 2).onEnded { LogWindow.show(job: job) })
                            .contextMenu {
                                Button("Show Log") { LogWindow.show(job: job) }
                                Button("Reveal in Finder") { queue.reveal(job.id) }
                                if job.status.isActive { Button("Cancel") { queue.cancel(job.id) } }
                                else { Button("Remove") { queue.remove(job.id) } }
                            }
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button { queue.clearFinished() } label: { Label("Clear Finished", systemImage: "trash") }
                    .help("Remove all finished jobs from the list")
                    .disabled(!queue.jobs.contains { !$0.status.isActive })
            }
        }
    }
}

private func statusColor(_ s: JobStatus) -> Color {
    switch s {
    case .queued: .secondary
    case .running: .blue
    case .finished(let n): n ? .green : .orange
    case .failed: .red
    case .cancelled: .secondary
    }
}

private func format(_ t: TimeInterval) -> String {
    let s = Int(t)
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}

private struct JobRow: View {
    let job: JobRun
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: job.status.symbol).foregroundStyle(statusColor(job.status)).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.name).lineLimit(1)
                HStack(spacing: 6) {
                    Text(job.program.title)
                    Text("\u{00B7}")
                    if job.startDate != nil {
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in Text(format(job.elapsed(at: ctx.date))).monospacedDigit() }
                    } else { Text(job.status.label) }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct JobDetail: View {
    let job: JobRun
    @ObservedObject private var queue = JobQueue.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if job.energies.count >= 2 { chart }
            logView
        }
        .padding()
        .toolbar {
            ToolbarItemGroup {
                if job.status.isActive {
                    Button { queue.cancel(job.id) } label: { Label("Cancel", systemImage: "stop.fill") }
                }
                Button { LogWindow.show(job: job) } label: { Label("Show Log", systemImage: "text.alignleft") }
                    .help("Open the streaming log viewer in its own window")
                Button { queue.reveal(job.id) } label: { Label("Reveal in Finder", systemImage: "folder") }
                Button { queue.openResult(job.id) } label: { Label("Open Result", systemImage: "doc.text.magnifyingglass") }
                    .disabled(!FileManager.default.fileExists(atPath: job.outputURL.path))
                Button { queue.remove(job.id) } label: { Label("Remove", systemImage: "minus.circle") }
                    .disabled(job.status.isActive)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: job.status.symbol).foregroundStyle(statusColor(job.status))
                Text(job.name).font(.title2.bold())
                Spacer()
                if job.startDate != nil {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text(format(job.elapsed(at: ctx.date))).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
            Text("\(job.program.title) \u{00B7} \(job.setup.jobType.title) \u{00B7} \(job.status.label)")
                .foregroundStyle(.secondary)
            if let e = job.lastEnergy {
                Text(String(format: "Last energy: %.8f  (%d step%@)", e, job.stepCount, job.stepCount == 1 ? "" : "s"))
                    .font(.callout.monospacedDigit())
            }
            if let m = job.message { Label(m, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary) }
            Text(job.directory.path).font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
        }
    }

    private var chart: some View {
        Chart(Array(job.energies.enumerated()), id: \.offset) { item in
            LineMark(x: .value("Step", item.offset + 1), y: .value("Energy (Eh)", item.element))
            PointMark(x: .value("Step", item.offset + 1), y: .value("Energy (Eh)", item.element)).symbolSize(16)
        }
        .chartYScale(domain: .automatic(includesZero: false))
        .chartXAxisLabel("Step")
        .chartYAxisLabel("Energy (Eh)")
        .frame(height: 150)
    }

    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(job.liveLog.isEmpty ? "Waiting for output\u{2026}" : job.liveLog)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(8)
            }
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .onChange(of: job.liveLog) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            .onAppear { proxy.scrollTo("end", anchor: .bottom) }
        }
    }
}

private struct ProgramFooter: View {
    @ObservedObject var queue: JobQueue
    var body: some View {
        HStack(spacing: 14) {
            ForEach(QCProgram.allCases) { p in
                let url = queue.locations[p]
                HStack(spacing: 5) {
                    Circle().fill(url != nil ? Color.green : Color.secondary.opacity(0.5)).frame(width: 8, height: 8)
                    Text(p.title).font(.caption.bold())
                    Text(url?.path ?? "not found").font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).frame(maxWidth: 170, alignment: .leading)
                }
                .help(url?.path ?? "\(p.title) was not found. Set its path in Settings.")
            }
            Spacer()
            Button { queue.refreshAvailability() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).help("Look for programs again")
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.bar)
    }
}
