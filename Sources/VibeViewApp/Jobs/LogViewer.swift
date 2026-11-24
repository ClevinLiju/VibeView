import SwiftUI
import AppKit

// MARK: - Model

/// A growing text log. Lines arrive in batches (pushed by a runner, or read from a file being written)
/// and only the newest `maxLines` are kept.
@MainActor
final class LogModel: ObservableObject {
    static let maxLines = 20_000
    /// When the cap is exceeded, drop this many lines at once so the view is rebuilt rarely.
    private static let trimChunk = 2_000

    @Published private(set) var lines: [String] = []
    /// Bumped whenever lines were appended.
    @Published private(set) var revision = 0
    /// Bumped whenever existing text was removed or replaced (the text view must reload everything).
    private(set) var generation = 0
    /// Lines ever received, including ones dropped by the cap.
    @Published private(set) var totalLines = 0
    @Published var isLive = false
    /// True when a runner pushes lines (no file to tail).
    var isPushed = false
    var title: String
    /// File shown by "Reveal in Finder" / "Open in Console".
    var fileURL: URL?

    private var pending: [String] = []
    private var flushScheduled = false
    private var tailTimer: DispatchSourceTimer?

    init(title: String = "Log", fileURL: URL? = nil, lines: [String] = []) {
        self.title = title
        self.fileURL = fileURL
        if !lines.isEmpty { append(lines: lines); flushNow() }
    }

    var droppedLines: Int { totalLines - lines.count }
    var joinedText: String { lines.joined(separator: "\n") }

    /// Queue lines; the view is updated at most ~8 times a second.
    func enqueue(_ new: [String]) {
        guard !new.isEmpty else { return }
        pending.append(contentsOf: new)
        if !flushScheduled {
            flushScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in self?.flushNow() }
        }
    }

    func enqueue(_ line: String) { enqueue([line]) }

    func flushNow() {
        flushScheduled = false
        guard !pending.isEmpty else { return }
        let batch = pending
        pending.removeAll(keepingCapacity: true)
        append(lines: batch)
    }

    private func append(lines new: [String]) {
        lines.append(contentsOf: new)
        totalLines += new.count
        if lines.count > Self.maxLines + Self.trimChunk {
            lines.removeFirst(lines.count - Self.maxLines)
            generation += 1
        }
        revision += 1
    }

    func clear() {
        pending.removeAll(); lines.removeAll(); totalLines = 0
        generation += 1; revision += 1
    }

    // MARK: File tailing

    /// Polls `url` every 0.5 s and appends complete new lines. Safe to call more than once.
    func startTailing(_ url: URL, interval: TimeInterval = 0.5) {
        stopTailing(flushPartial: false)
        fileURL = url
        clear()
        isLive = true
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "vibeview.logtail", qos: .utility))
        let box = TailBox(url: url)
        timer.schedule(deadline: .now(), repeating: interval)
        timer.setEventHandler { [weak self, box] in
            let (newLines, reset) = box.poll()
            guard !newLines.isEmpty || reset else { return }
            DispatchQueue.main.async { self?.applyTail(newLines, reset: reset) }
        }
        tailBox = box
        tailTimer = timer
        timer.resume()
    }

    private var tailBox: TailBox?

    private func applyTail(_ new: [String], reset: Bool) {
        if reset { clear() }
        enqueue(new)
    }

    func stopTailing(flushPartial: Bool = true) {
        tailTimer?.cancel(); tailTimer = nil
        if flushPartial, let box = tailBox {
            let (l, _) = box.poll(final: true)
            enqueue(l)
        }
        tailBox = nil
        isLive = false
        flushNow()
    }
}

/// Reads appended bytes of a file; used on a background queue only.
private final class TailBox: @unchecked Sendable {
    let url: URL
    private var offset: UInt64 = 0
    private var partial = Data()
    private let lock = NSLock()
    init(url: URL) { self.url = url }

    /// Returns complete new lines and whether the file was truncated/replaced (start over).
    func poll(final: Bool = false) -> ([String], Bool) {
        lock.lock(); defer { lock.unlock() }
        guard let h = try? FileHandle(forReadingFrom: url) else { return ([], false) }
        defer { try? h.close() }
        var reset = false
        let size = (try? h.seekToEnd()) ?? 0
        if size < offset { offset = 0; partial.removeAll(); reset = true }
        guard size > offset || final else { return ([], reset) }
        try? h.seek(toOffset: offset)
        var out: [String] = []
        // Read in 1 MB pieces so a huge file does not allocate at once.
        while let d = try? h.read(upToCount: 1 << 20), !d.isEmpty {
            offset += UInt64(d.count)
            partial.append(d)
            out.append(contentsOf: takeLines())
        }
        if final, !partial.isEmpty {
            out.append(String(decoding: partial, as: UTF8.self)); partial.removeAll()
        }
        return (out, reset)
    }

    private func takeLines() -> [String] {
        var out: [String] = []
        var start = partial.startIndex
        var i = start
        while i < partial.endIndex {
            if partial[i] == 0x0A {
                var end = i
                if end > start, partial[end - 1] == 0x0D { end -= 1 }
                out.append(String(decoding: partial[start..<end], as: UTF8.self))
                start = partial.index(after: i)
            }
            i = partial.index(after: i)
        }
        if start > partial.startIndex { partial = Data(partial[start...]) }
        return out
    }
}

// MARK: - Registry (one log per job)

@MainActor
final class JobLogCenter {
    static let shared = JobLogCenter()
    private var models: [UUID: LogModel] = [:]

    /// The log for a queued/running/finished job. Pushed logs (xtb launched from the settings sheet) are
    /// registered by their runner; everything else tails the job's output file.
    func model(for job: JobRun) -> LogModel {
        if let m = models[job.id] { return m }
        let m = LogModel(title: job.name + " \u{2014} " + job.program.title, fileURL: job.outputURL)
        models[job.id] = m
        return m
    }

    func register(_ model: LogModel, for id: UUID) { models[id] = model }
    func existing(for id: UUID) -> LogModel? { models[id] }
    func forget(_ id: UUID) { models[id] = nil }
}

// MARK: - Window

@MainActor
enum LogWindow {
    private static var windows: [UUID: NSWindow] = [:]

    /// Opens (or brings forward) the log window for a job.
    static func show(job: JobRun) {
        let model = JobLogCenter.shared.model(for: job)
        show(id: job.id, model: model, tail: model.isPushed ? nil : job.outputURL)
    }

    static func show(id: UUID, model: LogModel, tail: URL? = nil) {
        if let w = windows[id], w.isVisible { w.makeKeyAndOrderFront(nil); return }
        let view = LogViewer(model: model, tailFile: tail)
        let host = NSHostingController(rootView: view)
        let w = NSWindow(contentViewController: host)
        w.title = model.title
        w.setContentSize(NSSize(width: 820, height: 540))
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.isReleasedWhenClosed = false
        w.center()
        windows[id] = w
        w.makeKeyAndOrderFront(nil)
    }
}

// MARK: - View

/// Streaming log viewer: monospaced text that follows the end, with search, line count and file actions.
struct LogViewer: View {
    @ObservedObject var model: LogModel
    /// When set, the viewer tails this file while it is on screen.
    var tailFile: URL? = nil
    @State private var autoScroll = true
    @State private var query: String
    @State private var matchCount = 0
    @State private var matchIndex = 0
    @State private var copied = false

    init(model: LogModel, tailFile: URL? = nil, initialSearch: String = "") {
        self.model = model
        self.tailFile = tailFile
        _query = State(initialValue: initialSearch)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            LogTextView(model: model, revision: model.revision, query: query, autoScroll: autoScroll,
                        matchIndex: $matchIndex, matchCount: $matchCount)
            Divider()
            statusBar
        }
        .frame(minWidth: 560, minHeight: 300)
        .onAppear { if let t = tailFile { model.startTailing(t) } }
        .onDisappear { if tailFile != nil { model.stopTailing() } }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search log", text: $query)
                    .textFieldStyle(.plain)
                    .onSubmit { step(1) }
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.6)))
            .frame(maxWidth: 260)
            if !query.isEmpty {
                Text(matchCount == 0 ? "No matches" : "\(matchIndex + 1) of \(matchCount)")
                    .font(.caption.monospacedDigit()).foregroundStyle(matchCount == 0 ? .red : .secondary)
                Button { step(-1) } label: { Image(systemName: "chevron.up") }
                    .help("Previous match").disabled(matchCount == 0)
                Button { step(1) } label: { Image(systemName: "chevron.down") }
                    .help("Next match").disabled(matchCount == 0)
            }
            Spacer()
            Toggle(isOn: $autoScroll) { Label("Follow", systemImage: "arrow.down.to.line") }
                .toggleStyle(.button).help("Keep the newest output in view")
            Button { copyAll() } label: { Label(copied ? "Copied" : "Copy All", systemImage: "doc.on.doc") }
                .help("Copy the whole visible log")
            Button { reveal() } label: { Label("Reveal", systemImage: "folder") }
                .help("Show the log file in Finder").disabled(model.fileURL == nil)
            Button { openInConsole() } label: { Label("Console", systemImage: "terminal") }
                .help("Open the log file in the Console app").disabled(model.fileURL == nil)
        }
        .labelStyle(.titleAndIcon)
        .controlSize(.small)
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            if model.isLive { Label("Live", systemImage: "dot.radiowaves.left.and.right").foregroundStyle(.green) }
            Text("\(model.totalLines) line\(model.totalLines == 1 ? "" : "s")").monospacedDigit()
            if model.droppedLines > 0 { Text("showing the last \(model.lines.count)").foregroundStyle(.orange) }
            Spacer()
            if let u = model.fileURL { Text(u.path).lineLimit(1).truncationMode(.middle).foregroundStyle(.tertiary) }
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, 10).padding(.vertical, 5)
    }

    private func step(_ d: Int) {
        guard matchCount > 0 else { return }
        autoScroll = false
        matchIndex = (matchIndex + d + matchCount) % matchCount
    }

    private func copyAll() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.joinedText, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }

    private func reveal() {
        guard let u = model.fileURL else { return }
        let target = FileManager.default.fileExists(atPath: u.path) ? u : u.deletingLastPathComponent()
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    private func openInConsole() {
        guard let u = model.fileURL, FileManager.default.fileExists(atPath: u.path) else { return }
        let console = URL(fileURLWithPath: "/System/Applications/Utilities/Console.app")
        NSWorkspace.shared.open([u], withApplicationAt: console, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
    }
}

// MARK: - Text view

/// NSTextView host: appends batches, highlights matches via temporary attributes (no text storage edits).
struct LogTextView: NSViewRepresentable {
    let model: LogModel
    let revision: Int
    let query: String
    let autoScroll: Bool
    @Binding var matchIndex: Int
    @Binding var matchCount: Int

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        guard let tv = scroll.documentView as? NSTextView else { return scroll }
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = false
        tv.usesFindBar = false
        tv.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        tv.textColor = .labelColor
        tv.backgroundColor = .textBackgroundColor
        tv.textContainerInset = NSSize(width: 6, height: 6)
        tv.isHorizontallyResizable = true
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.layoutManager?.allowsNonContiguousLayout = true
        scroll.hasHorizontalScroller = true
        context.coordinator.textView = tv
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        guard let tv = c.textView, let storage = tv.textStorage else { return }
        let m = model
        var textChanged = false
        if c.generation != m.generation || c.appliedLines > m.lines.count {
            c.generation = m.generation
            let text = m.lines.joined(separator: "\n")
            storage.setAttributedString(NSAttributedString(string: text, attributes: c.attrs))
            c.appliedLines = m.lines.count
            textChanged = true
        } else if c.appliedLines < m.lines.count {
            let new = m.lines[c.appliedLines...]
            let prefix = c.appliedLines > 0 ? "\n" : ""
            storage.append(NSAttributedString(string: prefix + new.joined(separator: "\n"), attributes: c.attrs))
            c.appliedLines = m.lines.count
            textChanged = true
        }
        var navigated = false
        if textChanged || c.query != query {
            c.query = query
            c.recomputeMatches(in: storage.string as NSString)
            let n = c.ranges.count
            let idx = n == 0 ? 0 : min(matchIndex, n - 1)
            DispatchQueue.main.async {
                if matchCount != n { matchCount = n }
                if matchIndex != idx { matchIndex = idx }
            }
            c.shownIndex = min(matchIndex, max(0, n - 1))
            navigated = true
        } else if c.shownIndex != matchIndex {
            c.shownIndex = matchIndex
            navigated = true
        }
        if navigated || textChanged { c.paintMatches() }
        if autoScroll {
            if textChanged || !c.wasAutoScrolling {
                tv.scrollToEndOfDocument(nil)
                DispatchQueue.main.async { [weak tv] in tv?.scrollToEndOfDocument(nil) }   // again after layout
            }
        } else if navigated, !c.ranges.isEmpty, c.shownIndex < c.ranges.count, (c.query != c.lastScrolledQuery || c.shownIndex != c.lastScrolledIndex) {
            tv.scrollRangeToVisible(c.ranges[c.shownIndex])
            c.lastScrolledQuery = c.query; c.lastScrolledIndex = c.shownIndex
        }
        c.wasAutoScrolling = autoScroll
    }

    @MainActor
    final class Coordinator {
        weak var textView: NSTextView?
        var generation = -1
        var appliedLines = 0
        var query = ""
        var ranges: [NSRange] = []
        var shownIndex = 0
        var wasAutoScrolling = false
        var lastScrolledQuery = ""
        var lastScrolledIndex = -1
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ]
        private var painted: [NSRange] = []

        func recomputeMatches(in text: NSString) {
            ranges.removeAll(keepingCapacity: true)
            guard !query.isEmpty else { return }
            var from = 0
            while from < text.length, ranges.count < 5000 {
                let r = text.range(of: query, options: [.caseInsensitive], range: NSRange(location: from, length: text.length - from))
                if r.location == NSNotFound { break }
                ranges.append(r)
                from = r.location + max(1, r.length)
            }
        }

        func paintMatches() {
            guard let lm = textView?.layoutManager, let len = textView?.textStorage?.length else { return }
            for r in painted where NSMaxRange(r) <= len { lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: r) }
            painted.removeAll(keepingCapacity: true)
            for (i, r) in ranges.enumerated() where NSMaxRange(r) <= len {
                let color: NSColor = i == shownIndex ? .systemOrange : NSColor.systemYellow.withAlphaComponent(0.45)
                lm.addTemporaryAttribute(.backgroundColor, value: color, forCharacterRange: r)
                painted.append(r)
            }
        }
    }
}
