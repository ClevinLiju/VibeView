import SwiftUI
import AppKit
import MolCore
import MolCommand

/// One line of console output.
struct ConsoleLine: Identifiable, Equatable {
    enum Kind { case input, info, warning, error }
    let id: Int
    let kind: Kind
    let text: String
}

/// Per-window command console state: executor, persisted history, output and completion.
@MainActor
final class ConsoleModel: ObservableObject {
    @Published var lines: [ConsoleLine] = []
    @Published var input = ""
    @Published var completions: [String] = []
    let context: AppCommandContext
    private(set) lazy var executor = CommandExecutor(context: context, registry: .app())
    private var history = CommandHistory(maxCount: 1000)
    private var nextID = 0

    static var historyURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppInfo.name, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("command-history.txt")
    }

    init(editor: EditorModel) {
        context = AppCommandContext(editor: editor)
        try? history.load(from: Self.historyURL)
        append(.info, "\(AppInfo.name) command line. Type “help” for the list of commands; Tab completes, ↑/↓ recall history.")
        append(.info, "Working folder: \(context.currentDirectory.path)")
    }

    func append(_ kind: ConsoleLine.Kind, _ text: String) {
        for l in text.split(separator: "\n", omittingEmptySubsequences: false) {
            lines.append(ConsoleLine(id: nextID, kind: kind, text: String(l))); nextID += 1
        }
        if lines.count > 5000 { lines.removeFirst(lines.count - 5000) }
    }

    func submit() {
        let line = input.trimmingCharacters(in: .whitespaces)
        input = ""; completions = []
        guard !line.isEmpty else { return }
        append(.input, "› " + line)
        history.add(line)
        try? history.save(to: Self.historyURL)
        if line == "clear" { lines = []; return }
        for r in executor.execute(line) {
            for m in r.messages {
                append(m.level == .error ? .error : m.level == .warning ? .warning : .info, m.text)
            }
        }
    }

    func recall(previous: Bool) {
        if let s = previous ? history.previous() : history.next() { input = s }
        else if !previous { input = "" }
    }

    /// Complete the last word; a unique candidate is inserted, several are listed.
    func complete() {
        let cands = CommandCompleter.candidates(for: input, cwd: context.currentDirectory, molecule: context.molecule,
                                                registry: executor.registry)
        guard !cands.isEmpty else { completions = []; NSSound.beep(); return }
        let words = input.split(separator: " ", omittingEmptySubsequences: false)
        let partial = input.last == " " ? "" : String(words.last ?? "")
        // Path candidates may include the directory part already; replace only the word being typed.
        let common = cands.dropFirst().reduce(cands[0]) { a, b in String(zip(a, b).prefix { $0 == $1 }.map(\.0)) }
        let base = input.dropLast(partial.count)
        let pick = cands.count == 1 ? cands[0] : common
        let name = partial.contains("/") && !pick.contains("/") ? String(partial[...partial.lastIndex(of: "/")!]) + pick : pick
        if name.count >= partial.count { input = base + name + (cands.count == 1 && !name.hasSuffix("/") ? " " : "") }
        completions = cands.count > 1 ? Array(cands.prefix(40)) : []
    }
}

extension EditorModel {
    private static var consoles: [ObjectIdentifier: ConsoleModel] = [:]
    /// The console of this window (created on first use).
    var console: ConsoleModel {
        if let c = Self.consoles[ObjectIdentifier(self)] { return c }
        let c = ConsoleModel(editor: self)
        Self.consoles[ObjectIdentifier(self)] = c
        return c
    }
}

/// Bottom console panel: coloured scrollback, completion strip and a prompt line.
struct ConsoleView: View {
    @ObservedObject var console: ConsoleModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(console.lines) { l in
                            Text(l.text)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(color(l.kind))
                                .fontWeight(l.kind == .input ? .semibold : .regular)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(l.id)
                        }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                }
                .onChange(of: console.lines.last?.id) { _, id in if let id { proxy.scrollTo(id, anchor: .bottom) } }
                .onAppear { if let id = console.lines.last?.id { proxy.scrollTo(id, anchor: .bottom) } }
            }
            if !console.completions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(console.completions, id: \.self) { Text($0).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary) }
                    }.padding(.horizontal, 8)
                }
                .frame(height: 18)
            }
            Divider()
            HStack(spacing: 6) {
                Text("›").font(.system(size: 13, weight: .bold, design: .monospaced)).foregroundStyle(Color.accentColor)
                TextField("command (help, open, cd, ls, select, style, measure, xtb opt…)", text: $console.input)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .focused($focused)
                    .onSubmit { console.submit(); focused = true }
                    .onKeyPress(.upArrow) { console.recall(previous: true); return .handled }
                    .onKeyPress(.downArrow) { console.recall(previous: false); return .handled }
                    .onKeyPress(.tab) { console.complete(); return .handled }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear { focused = true }
    }

    private func color(_ k: ConsoleLine.Kind) -> Color {
        switch k {
        case .input: .primary
        case .info: .secondary
        case .warning: .orange
        case .error: .red
        }
    }
}
