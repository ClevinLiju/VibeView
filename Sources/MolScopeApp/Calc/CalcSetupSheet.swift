import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MolCore
import MolBuild

/// "Calculation Setup": one sheet for Gaussian, ORCA, Q-Chem and xtb. Live input preview, save, or run.
struct CalcSetupSheet: View {
    @ObservedObject var editor: EditorModel
    @ObservedObject private var queue = JobQueue.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @State private var setup: CalcSetup
    @State private var message = ""

    init(editor: EditorModel) {
        self.editor = editor
        let d = UserDefaults.standard
        let program = d.string(forKey: AppSettings.lastProgramKey).flatMap(QCProgram.init(rawValue:)) ?? .gaussian
        var s = CalcSetup(molecule: editor.molecule, program: program)
        Self.applyStored(&s, defaults: d)
        let base = Self.baseName(editor)
        s.checkpoint = base + ".chk"
        s.title = editor.molecule.title
        _setup = State(initialValue: s)
    }

    private static func baseName(_ editor: EditorModel) -> String {
        editor.fileURL?.deletingPathExtension().lastPathComponent ?? "molecule"
    }

    private static func methodKey(_ p: QCProgram) -> String { "molscope.calc.method.\(p.rawValue)" }
    private static func basisKey(_ p: QCProgram) -> String { "molscope.calc.basis.\(p.rawValue)" }

    /// Last used method/basis for the program, else the Preferences defaults (Gaussian), else the catalog defaults.
    private static func applyStored(_ s: inout CalcSetup, defaults d: UserDefaults) {
        let p = s.program
        if let m = d.string(forKey: methodKey(p)), !m.isEmpty { s.method = m }
        else if p == .gaussian, let m = d.string(forKey: AppSettings.defaultMethodKey), !m.isEmpty { s.method = m }
        if p != .xtb {
            if let b = d.string(forKey: basisKey(p)), !b.isEmpty { s.basis = b }
            else if p == .gaussian, let b = d.string(forKey: AppSettings.defaultBasisKey), !b.isEmpty { s.basis = b }
        }
        if p == .xtb, let x = XTBMethod.allCases.first(where: { $0.title == s.method }) { s.xtbMethod = x }
        let np = d.integer(forKey: AppSettings.processorsKey)
        if np > 0 { s.nprocs = np }
        if let mem = d.string(forKey: AppSettings.memoryKey), let mb = CalcSetup.parseMemoryMB(mem) { s.memoryMB = mb }
    }

    private var problems: [String] { setup.validate(molecule: editor.molecule) }
    private var inputText: String { setup.inputText(molecule: editor.molecule) }
    private var inputName: String { "job." + setup.program.inputExtension }
    private var preview: String {
        guard setup.program == .xtb else { return inputText }
        return "# " + setup.commandLine(program: "xtb", inputFileName: inputName) + "\n# \(inputName):\n\n" + inputText
    }
    private var programMissing: Bool { !queue.isAvailable(setup.program) }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Program", selection: programBinding) {
                ForEach(QCProgram.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .padding([.horizontal, .top]).padding(.bottom, 8)
            Divider()
            HStack(alignment: .top, spacing: 0) {
                Form { jobSection; theorySection; stateSection; solventSection; resourcesSection; extrasSection }
                    .formStyle(.grouped)
                    .frame(minWidth: 400, idealWidth: 430)
                Divider()
                previewPane.frame(minWidth: 380)
            }
            Divider()
            footer
        }
        .frame(minWidth: 860, minHeight: 560)
        .onAppear { queue.refreshAvailability() }
    }

    // MARK: Bindings

    private var programBinding: Binding<QCProgram> {
        Binding(get: { setup.program }, set: { p in
            guard p != setup.program else { return }
            var s = setup
            s.setProgram(p)
            Self.applyStored(&s, defaults: .standard)
            if s.jobType != setup.jobType, !s.supportedJobTypes.contains(s.jobType) { s.jobType = .optimize }
            setup = s
            UserDefaults.standard.set(p.rawValue, forKey: AppSettings.lastProgramKey)
        })
    }

    private var methodBinding: Binding<String> {
        Binding(get: { setup.method }, set: { setup.method = $0; UserDefaults.standard.set($0, forKey: Self.methodKey(setup.program)) })
    }
    private var basisBinding: Binding<String> {
        Binding(get: { setup.basis }, set: { setup.basis = $0; UserDefaults.standard.set($0, forKey: Self.basisKey(setup.program)) })
    }
    private var xtbBinding: Binding<XTBMethod> {
        Binding(get: { setup.xtbMethod }, set: { setup.xtbMethod = $0; setup.method = $0.title; UserDefaults.standard.set($0.title, forKey: Self.methodKey(.xtb)) })
    }

    private var solvationKind: Binding<String> {
        Binding(get: { setup.solvation.model }, set: { k in
            let s = setup.solvation.solvent ?? "Water"
            switch k { case "PCM": setup.solvation = .pcm(s); case "SMD": setup.solvation = .smd(s); default: setup.solvation = .none }
        })
    }
    private var solventBinding: Binding<String> {
        Binding(get: { setup.solvation.solvent ?? "Water" }, set: { s in
            switch setup.solvation { case .pcm: setup.solvation = .pcm(s); case .smd: setup.solvation = .smd(s); case .none: break }
        })
    }

    private var implicitModelName: String {
        switch setup.program { case .orca: "CPCM"; case .xtb: "ALPB"; default: "PCM" }
    }

    // MARK: Sections

    private var jobSection: some View {
        Section("Job Kind") {
            Picker("Task", selection: $setup.jobType) {
                ForEach(setup.supportedJobTypes) { Text($0.title).tag($0) }
            }
            switch setup.jobType {
            case .scan:
                ScanCoordinateEditor(coordinates: $setup.scanCoordinates, picks: editor.measurePicks, atomCount: editor.molecule.atoms.count)
            case .irc:
                Picker("Direction", selection: $setup.ircDirection) { ForEach(IRCDirection.allCases) { Text($0.title).tag($0) } }
                Stepper("Max points: \(setup.ircMaxPoints)", value: $setup.ircMaxPoints, in: 1...500)
                Toggle("Compute force constants first", isOn: $setup.ircCalcFC)
            case .transitionState:
                Toggle("Compute force constants first", isOn: $setup.tsCalcFC)
                if setup.program == .gaussian { Toggle("Skip Hessian eigenvalue test", isOn: $setup.tsNoEigenTest) }
            case .excitedStates:
                Stepper("States: \(setup.tdStates)", value: $setup.tdStates, in: 1...200)
                Picker("Spin", selection: $setup.tdSpin) {
                    ForEach(TDSpinKind.allCases.filter { setup.program != .orca || $0 == .unspecified || $0 == .triplets }) { Text($0.title).tag($0) }
                }
            default: EmptyView()
            }
        }
    }

    private var theorySection: some View {
        Section("Level of Theory") {
            if setup.program == .xtb {
                Picker("Method", selection: xtbBinding) { ForEach(XTBMethod.allCases) { Text($0.title).tag($0) } }
            } else {
                ChoiceField(title: "Method", options: CalcSetup.methods(for: setup.program), value: methodBinding)
                ChoiceField(title: "Basis set", options: CalcSetup.bases(for: setup.program), value: basisBinding)
            }
        }
    }

    private var stateSection: some View {
        Section("Electronic State") {
            Stepper("Charge: \(setup.charge)", value: $setup.charge, in: -10...10)
            Stepper("Multiplicity: \(setup.multiplicity)", value: $setup.multiplicity, in: 1...12)
            Button("Use molecule's values (\(editor.molecule.charge), \(editor.molecule.multiplicity))") {
                setup.charge = editor.molecule.charge; setup.multiplicity = editor.molecule.multiplicity
            }.buttonStyle(.link)
        }
    }

    private var solventSection: some View {
        Section("Environment") {
            Picker("Solvent model", selection: solvationKind) {
                Text("Gas phase").tag("None")
                Text(implicitModelName).tag("PCM")
                if setup.program != .xtb { Text("SMD").tag("SMD") }
            }
            if !setup.solvation.isNone {
                ChoiceField(title: "Solvent", options: CalcSetup.solvents, value: solventBinding)
            }
        }
    }

    private var resourcesSection: some View {
        Section("Resources") {
            Stepper("Cores: \(setup.nprocs)", value: $setup.nprocs, in: 1...256)
            Stepper("Memory: \(memoryLabel)", value: $setup.memoryMB, in: 512...1_048_576, step: 512)
            if setup.program == .gaussian {
                TextField("Checkpoint file", text: Binding(get: { setup.checkpoint ?? "" }, set: {
                    let t = $0.trimmingCharacters(in: .whitespaces); setup.checkpoint = t.isEmpty ? nil : t
                }), prompt: Text("none"))
            }
        }
    }

    private var memoryLabel: String {
        setup.memoryMB % 1024 == 0 ? "\(setup.memoryMB / 1024) GB" : "\(setup.memoryMB) MB"
    }

    private var extrasSection: some View {
        Section("Extras") {
            if setup.program == .gaussian {
                Picker("Output detail", selection: $setup.printLevel) { ForEach(PrintLevel.allCases) { Text($0.title).tag($0) } }
            }
            TextField(setup.program == .qchem ? "Extra $rem lines" : "Extra keywords", text: $setup.extraKeywords,
                      prompt: Text(extraPrompt))
                .font(.system(.body, design: .monospaced))
            TextField("Title", text: $setup.title, prompt: Text(editor.molecule.title.isEmpty ? "MolScope calculation" : editor.molecule.title))
        }
    }

    private var extraPrompt: String {
        switch setup.program {
        case .gaussian: "e.g. Int=UltraFine"
        case .orca: "e.g. TightSCF D3BJ"
        case .qchem: "e.g. SCF_CONVERGENCE 8"
        case .xtb: "e.g. --acc 0.1"
        }
    }

    // MARK: Preview + footer

    private var previewPane: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Input Preview").font(.headline)
            ScrollView([.vertical, .horizontal]) {
                Text(preview)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(8)
            }
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            if !problems.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(problems, id: \.self) { Label($0, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout) }
                }
            }
        }
        .padding()
    }

    private var runHelp: String {
        if programMissing { return "\(setup.program.title) not found \u{2014} set its path in Settings" }
        if !problems.isEmpty { return "Fix the problems listed below the preview first" }
        return "Run \(setup.program.title) on this molecule"
    }

    private var footer: some View {
        HStack {
            if !message.isEmpty { Text(message).font(.callout).foregroundStyle(.secondary).lineLimit(2) }
            Spacer()
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Copy Input") {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(inputText, forType: .string)
                message = "Input copied"
            }
            Button("Save Input\u{2026}") { _ = save() }
            Button("Run") { run() }
                .keyboardShortcut(.defaultAction)
                .disabled(programMissing || !problems.isEmpty)
                .help(runHelp)
        }
        .padding()
    }

    private func run() {
        do {
            try queue.submit(setup: setup, molecule: editor.molecule, name: Self.baseName(editor), documentURL: editor.fileURL)
            editor.statusMessage = "Queued \(setup.program.title) job"
            openWindow(id: "job-queue")
            dismiss()
        } catch {
            message = error.localizedDescription
        }
    }

    /// Runs a save panel and writes the input file. Returns the saved URL.
    private func save() -> URL? {
        let panel = NSSavePanel()
        let ext = setup.program.inputExtension
        panel.allowedContentTypes = [UTType(filenameExtension: ext)].compactMap { $0 }
        panel.canCreateDirectories = true
        panel.title = "Save \(setup.program.title) Input"
        panel.nameFieldStringValue = Self.baseName(editor) + "." + ext
        if let dir = editor.fileURL?.deletingLastPathComponent() { panel.directoryURL = dir }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            try inputText.write(to: url, atomically: true, encoding: .utf8)
            message = "Saved \(url.lastPathComponent)"
            return url
        } catch {
            message = "Could not save: \(error.localizedDescription)"
            return nil
        }
    }
}
