import SwiftUI
import AppKit
import MolCore
import MolBuild
import MolCompute

// MARK: - Persistence and helpers

enum XTBSettingsStore {
    static let key = "vibeview.xtb.settings"

    /// Last used settings. Charge / unpaired electrons are never remembered: they come from the molecule.
    static func load(_ defaults: UserDefaults = .standard) -> XTBSettings {
        guard let data = defaults.data(forKey: key), let s = try? JSONDecoder().decode(XTBSettings.self, from: data) else {
            return XTBSettings(threads: max(1, min(8, ProcessInfo.processInfo.activeProcessorCount / 2)))
        }
        return s
    }

    static func save(_ settings: XTBSettings, _ defaults: UserDefaults = .standard) {
        var s = settings
        s.charge = nil; s.uhf = nil
        if let data = try? JSONEncoder().encode(s) { defaults.set(data, forKey: key) }
    }
}

/// Shell-like word splitting: whitespace separates words; single and double quotes group; backslash escapes.
enum ShellWords {
    static func split(_ text: String) -> (words: [String], unbalanced: Bool) {
        var words: [String] = [], cur = "", inWord = false
        var quote: Character? = nil
        var escape = false
        for ch in text {
            if escape { cur.append(ch); escape = false; inWord = true; continue }
            if ch == "\\" && quote != "'" { escape = true; continue }
            if let q = quote {
                if ch == q { quote = nil } else { cur.append(ch) }
                continue
            }
            if ch == "\"" || ch == "'" { quote = ch; inWord = true; continue }
            if ch == " " || ch == "\t" || ch == "\n" {
                if inWord { words.append(cur); cur = ""; inWord = false }
                continue
            }
            cur.append(ch); inWord = true
        }
        if inWord { words.append(cur) }
        return (words, quote != nil)
    }

    static func join(_ words: [String]) -> String {
        words.map { w in
            w.isEmpty || w.contains(where: { " \t\"'\\".contains($0) }) ? "\"" + w.replacingOccurrences(of: "\"", with: "\\\"") + "\"" : w
        }.joined(separator: " ")
    }
}

extension XTBTask {
    var sheetTitle: String {
        switch self { case .singlePoint: "Single point"; case .optimize: "Geometry optimization"; case .hessian: "Optimization + frequencies" }
    }
}

// MARK: - Running xtb through the job queue

/// One code path for "run xtb on the editor's molecule": lists the run in the Job Queue, streams its output into a
/// live log, and loads the optimized geometry back as an undoable step.
@MainActor
enum XTBJobRunner {
    struct Outcome {
        var energy: Double
        var converged: Bool?
        var cycles: Int?
        var atoms: Int
        var logLines: Int
        var geometryReplaced: Bool
        var directory: URL
    }

    /// Starts the run. Returns the queue job id, or nil (with `editor.statusMessage` set) when it could not start.
    @discardableResult
    static func run(editor: EditorModel, settings: XTBSettings, showLog: Bool = true,
                    completion: ((Result<Outcome, Error>) -> Void)? = nil) -> UUID? {
        let molecule = editor.molecule
        let problems = settings.validationErrors(molecule: molecule)
        guard problems.isEmpty else { editor.statusMessage = "xtb: " + problems[0]; return nil }
        let queue = JobQueue.shared
        queue.refreshAvailability()
        guard let exe = queue.resolveExecutable(.xtb) ?? XTBRunner.locate() else {
            editor.statusMessage = ProgramLocator.notFoundMessage(.xtb); return nil
        }
        let baseName = editor.fileURL?.deletingPathExtension().lastPathComponent
            ?? (molecule.title.isEmpty ? "molecule" : molecule.title)
        let dir = JobQueue.newJobDirectory(name: baseName, program: .xtb, documentURL: editor.fileURL)
        let handle = XTBRunner(executable: exe).stream(molecule, settings: settings, runDirectory: dir)

        let log = LogModel(title: "\(JobQueue.safeName(baseName)) \u{2014} xtb", fileURL: dir.appendingPathComponent("xtb.out"))
        log.isPushed = true
        log.isLive = true
        var setup = CalcSetup(molecule: molecule, program: .xtb)
        setup.jobType = settings.task == .singlePoint ? .energy : (settings.task == .hessian ? .optFreq : .optimize)
        setup.method = settings.method.title
        let id = queue.registerExternal(program: .xtb, name: baseName, directory: dir, outputURL: dir.appendingPathComponent("xtb.out"),
                                        setup: setup, cancel: { handle.cancel() })
        JobLogCenter.shared.register(log, for: id)
        editor.statusMessage = "Running xtb (\(settings.method.title))\u{2026}"
        if showLog { LogWindow.show(id: id, model: log) }

        let isOptimizing = settings.task != .singlePoint
        Task { @MainActor in
            var scanner = LogScanner(program: .xtb)
            var lastPush = Date.distantPast
            var cancelledByUser = false
            let eventsTask = Task { @MainActor in
                for await ev in handle.events {
                    switch ev {
                    case .started(_, let cmd): log.enqueue("$ " + cmd)
                    case .stdout(let l), .stderr(let l): log.enqueue(l); scanner.feed(l + "\n")
                    case .file(let name, let l): if name != "xtbopt.log" { log.enqueue("[\(name)] " + l) }   // trajectory frames are noise
                    case .finished(let code): log.enqueue("[xtb finished with exit code \(code)]")
                    }
                    if Date().timeIntervalSince(lastPush) > 0.4 {
                        lastPush = Date()
                        queue.updateExternal(id, tail: scanner.tailText, energies: scanner.energies)
                    }
                }
            }
            do {
                let result = try await handle.value
                await eventsTask.value
                log.flushNow(); log.isLive = false
                queue.updateExternal(id, tail: scanner.tailText, energies: scanner.energies)
                var replaced = false
                if isOptimizing {
                    if editor.molecule.atoms.count == result.molecule.atoms.count {
                        editor.replaceMolecule(result.molecule, actionName: "xtb Optimization")
                        replaced = true
                    }
                }
                let e = String(format: "%.6f Eh", result.energy)
                let conv: String
                switch result.converged {
                case .some(true): conv = ", converged" + (result.optimizationCycles.map { " in \($0) cycles" } ?? "")
                case .some(false): conv = ", NOT converged" + (result.optimizationCycles.map { " after \($0) cycles" } ?? "")
                case .none: conv = ""
                }
                let verb = isOptimizing ? (replaced ? "optimized geometry loaded" : "geometry not loaded (molecule changed)") : "single point"
                editor.statusMessage = "xtb \(settings.method.title): E = \(e)\(conv); \(verb)"
                let normal = result.exitCode == 0 && result.converged != false
                queue.finishExternal(id, status: .finished(normal: normal), message: normal ? nil : "The optimization stopped before converging.")
                completion?(.success(Outcome(energy: result.energy, converged: result.converged, cycles: result.optimizationCycles,
                                             atoms: result.molecule.atoms.count, logLines: log.totalLines, geometryReplaced: replaced,
                                             directory: result.workingDirectory)))
            } catch {
                await eventsTask.value
                log.flushNow(); log.isLive = false
                cancelledByUser = Task.isCancelled || error is CancellationError
                if cancelledByUser {
                    log.enqueue("[cancelled]"); log.flushNow()
                    queue.finishExternal(id, status: .cancelled)
                    editor.statusMessage = "xtb run cancelled"
                } else {
                    let m = error.localizedDescription
                    log.enqueue("[error] " + m); log.flushNow()
                    queue.finishExternal(id, status: .failed(m))
                    editor.statusMessage = "xtb failed: " + String(m.prefix(160))
                }
                completion?(.failure(error))
            }
        }
        return id
    }
}

// MARK: - Sheet

/// "Run xtb": every xtb option in one sheet, with a live command-line preview.
struct XTBSettingsSheet: View {
    @ObservedObject var editor: EditorModel
    @Binding var isPresented: Bool
    @State private var settings: XTBSettings
    @State private var extraText: String
    @State private var message = ""
    @ObservedObject private var queue = JobQueue.shared

    init(editor: EditorModel, isPresented: Binding<Bool>, initial: XTBSettings? = nil) {
        self.editor = editor
        _isPresented = isPresented
        let s = initial ?? XTBSettingsStore.load()
        _settings = State(initialValue: s)
        _extraText = State(initialValue: ShellWords.join(s.extraArguments))
    }

    private var molecule: Molecule { editor.molecule }
    private var errors: [String] {
        var e = settings.validationErrors(molecule: molecule)
        if ShellWords.split(extraText).unbalanced { e.append("Extra arguments have an unclosed quote.") }
        return e
    }
    private var missing: Bool { !queue.isAvailable(.xtb) && XTBRunner.locate() == nil }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "bolt.horizontal.circle").font(.title2).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Run xtb").font(.title3.bold())
                    Text("\(molecule.atoms.count) atoms \u{00B7} charge \(molecule.charge) \u{00B7} multiplicity \(molecule.multiplicity)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding([.horizontal, .top], 16).padding(.bottom, 8)
            Form {
                methodSection
                solventSection
                stateSection
                advancedSection
            }
            .formStyle(.grouped)
            previewPane
            Divider()
            footer
        }
        .frame(minWidth: 540, idealWidth: 560, minHeight: 600, idealHeight: 700)
        .onChange(of: settings) { _, new in XTBSettingsStore.save(new) }
        .onChange(of: extraText) { _, t in settings.extraArguments = ShellWords.split(t).words }
        .onAppear { queue.refreshAvailability() }
    }

    // MARK: Sections

    private var methodSection: some View {
        Section("Method") {
            Picker("GFN level", selection: $settings.method) {
                ForEach(MolCompute.XTBMethod.allCases) { Text($0.title).tag($0) }
            }
            Picker("Task", selection: $settings.task) {
                ForEach(XTBTask.allCases, id: \.self) { Text($0.sheetTitle).tag($0) }
            }
            if settings.task != .singlePoint {
                Picker("Convergence", selection: $settings.optLevel) {
                    ForEach(XTBOptLevel.allCases) { Text($0.title).tag($0) }
                }
                OptionalIntRow(title: "Limit cycles", value: $settings.maxCycles, defaultValue: 200, range: 1...10_000)
            }
        }
    }

    private var solventSection: some View {
        Section("Solvent") {
            Picker("Model", selection: Binding(get: { settings.solvationModel }, set: { m in
                settings.solvationModel = m
                let names = XTBSolvents.names(for: m)
                if m == .none { settings.solvent = nil }
                else if settings.solvent == nil || !names.contains(settings.solvent!) { settings.solvent = names.contains("water") ? "water" : names.first }
            })) {
                ForEach(XTBSolvationModel.allCases) { Text($0.title).tag($0) }
            }
            if settings.solvationModel != .none {
                Picker("Solvent", selection: Binding(get: { settings.solvent ?? "water" }, set: { settings.solvent = $0 })) {
                    ForEach(XTBSolvents.names(for: settings.solvationModel), id: \.self) { Text($0).tag($0) }
                }
            }
        }
    }

    private var stateSection: some View {
        Section("Electronic State") {
            HStack {
                Toggle("Charge from molecule (\(molecule.charge))", isOn: Binding(
                    get: { settings.charge == nil },
                    set: { settings.charge = $0 ? nil : molecule.charge }))
                if let c = settings.charge {
                    Spacer()
                    Text("\(c)").monospacedDigit().foregroundStyle(.secondary)
                    Stepper("", value: Binding(get: { c }, set: { settings.charge = $0 }), in: -10...10).labelsHidden()
                }
            }
            HStack {
                Toggle("Unpaired e\u{207B} from molecule (\(max(0, molecule.multiplicity - 1)))", isOn: Binding(
                    get: { settings.uhf == nil },
                    set: { settings.uhf = $0 ? nil : max(0, molecule.multiplicity - 1) }))
                if let u = settings.uhf {
                    Spacer()
                    Text("\(u)").monospacedDigit().foregroundStyle(.secondary)
                    Stepper("", value: Binding(get: { u }, set: { settings.uhf = $0 }), in: 0...20).labelsHidden()
                }
            }
        }
    }

    private var advancedSection: some View {
        Section("Advanced") {
            OptionalDoubleRow(title: "Electronic temperature (K)", value: $settings.electronicTemperature, defaultValue: 300)
            Stepper("Threads: \(settings.threads)", value: $settings.threads, in: 1...64)
            TextField("Extra arguments", text: $extraText, prompt: Text("e.g. --acc 0.5 --input extra.inp"))
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
        }
    }

    private var previewPane: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Command").font(.caption.bold()).foregroundStyle(.secondary)
            Text(settings.commandLine(molecule: molecule))
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            ForEach(errors, id: \.self) { Label($0, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.red) }
            if missing { Label(ProgramLocator.notFoundMessage(.xtb), systemImage: "questionmark.circle").font(.callout).foregroundStyle(.orange) }
        }
        .padding(.horizontal, 16).padding(.bottom, 10)
    }

    private var footer: some View {
        HStack {
            if !message.isEmpty { Text(message).font(.callout).foregroundStyle(.secondary).lineLimit(2) }
            Button("Reset") {
                settings = XTBSettings(threads: settings.threads); extraText = ""
            }.help("Back to the defaults (GFN2, geometry optimization)")
            Spacer()
            Button("Cancel") { isPresented = false }.keyboardShortcut(.cancelAction)
            Button("Run") { run() }
                .keyboardShortcut(.defaultAction)
                .disabled(!errors.isEmpty || missing)
        }
        .padding(12)
    }

    private func run() {
        settings.extraArguments = ShellWords.split(extraText).words
        XTBSettingsStore.save(settings)
        if XTBJobRunner.run(editor: editor, settings: settings) != nil { isPresented = false }
        else { message = editor.statusMessage }
    }
}

// MARK: - Small optional-value rows

private struct OptionalIntRow: View {
    let title: String
    @Binding var value: Int?
    let defaultValue: Int
    let range: ClosedRange<Int>
    var body: some View {
        HStack {
            Toggle(title, isOn: Binding(get: { value != nil }, set: { value = $0 ? defaultValue : nil }))
            if let v = value {
                Spacer()
                Text("\(v)").monospacedDigit().foregroundStyle(.secondary)
                Stepper("", value: Binding(get: { v }, set: { value = $0 }), in: range, step: v >= 100 ? 10 : 1).labelsHidden()
            }
        }
    }
}

private struct OptionalDoubleRow: View {
    let title: String
    @Binding var value: Double?
    let defaultValue: Double
    var body: some View {
        HStack {
            Toggle(title, isOn: Binding(get: { value != nil }, set: { value = $0 ? defaultValue : nil }))
            if let v = value {
                TextField("Kelvin", value: Binding(get: { v }, set: { value = $0 }), format: .number)
                    .textFieldStyle(.roundedBorder).frame(width: 90).multilineTextAlignment(.trailing)
            }
        }
    }
}
