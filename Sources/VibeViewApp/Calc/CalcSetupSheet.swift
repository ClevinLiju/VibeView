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
    @State private var iterations = CalcIterations()
    /// The preview text: follows the form until the user edits it (then Save/Copy/Run use the edit as typed).
    @State private var draft: CalcInputDraft

    /// Self-test hook: the next sheet opens with its preview edited by this function (used once).
    static var nextInitialEdit: ((String) -> String)?

    /// `initialEdit` (gallery/self-test only) starts the sheet with the preview already edited.
    init(editor: EditorModel, initialEdit: ((String) -> String)? = nil) {
        let initialEdit = initialEdit ?? Self.nextInitialEdit
        Self.nextInitialEdit = nil
        self.editor = editor
        let d = UserDefaults.standard
        let program = d.string(forKey: AppSettings.lastProgramKey).flatMap(QCProgram.init(rawValue:)) ?? .gaussian
        var s = CalcSetup(molecule: editor.molecule, program: program)
        Self.applyStored(&s, defaults: d)
        let base = Self.baseName(editor)
        s.checkpoint = base + ".chk"
        s.title = editor.molecule.title
        _setup = State(initialValue: s)
        var dr = CalcInputDraft(generated: Self.previewText(s, molecule: editor.molecule, iterations: CalcIterations()))
        if let f = initialEdit { dr.setText(f(dr.generated)) }
        _draft = State(initialValue: dr)
    }

    private static func baseName(_ editor: EditorModel) -> String {
        editor.fileURL?.deletingPathExtension().lastPathComponent ?? "molecule"
    }

    private static func methodKey(_ p: QCProgram) -> String { "vibeview.calc.method.\(p.rawValue)" }
    private static func basisKey(_ p: QCProgram) -> String { "vibeview.calc.basis.\(p.rawValue)" }

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
    private static func inputName(_ p: QCProgram) -> String { "job." + p.inputExtension }
    private var inputName: String { Self.inputName(setup.program) }

    /// The preview generated from the form (for xtb: the command line, then the XYZ file).
    private static func previewText(_ s: CalcSetup, molecule: Molecule, iterations: CalcIterations) -> String {
        let input = iterations.apply(to: s.inputText(molecule: molecule), program: s.program, jobType: s.jobType)
        guard s.program == .xtb else { return input }
        let name = inputName(.xtb)
        return XTBInputPreview.compose(arguments: s.commandArguments(inputFileName: name), inputFileName: name, xyz: input)
    }
    private var preview: String { Self.previewText(setup, molecule: editor.molecule, iterations: iterations) }

    /// What gets written and run: the input file text plus, for xtb, the arguments from the command line.
    private struct EffectiveInput { var fileText: String; var xtbArguments: [String]? }
    private var effectiveInput: Result<EffectiveInput, Error> {
        let text = draft.isEdited ? draft.text : preview
        guard setup.program == .xtb else { return .success(EffectiveInput(fileText: text, xtbArguments: nil)) }
        do {
            let p = try XTBInputPreview.parse(text, inputFileName: inputName)
            return .success(EffectiveInput(fileText: p.xyz, xtbArguments: p.arguments))
        } catch { return .failure(error) }
    }
    private var editProblem: String? {
        if case .failure(let e) = effectiveInput { return e.localizedDescription }
        if draft.isEdited, draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "The input is empty." }
        return nil
    }
    /// Form problems block Run only while the preview follows the form; an edited input is the user's call.
    private var blockingProblems: [String] { draft.isEdited ? (editProblem.map { [$0] } ?? []) : problems + (editProblem.map { [$0] } ?? []) }
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
        .onAppear { queue.refreshAvailability(); draft.updateGenerated(preview) }
        .onChange(of: preview) { _, new in draft.updateGenerated(new) }
    }

    // MARK: Bindings

    private var programBinding: Binding<QCProgram> {
        Binding(get: { setup.program }, set: { p in
            guard p != setup.program else { return }
            if draft.isEdited {
                // An edited input is written for one program; switching would leave a mismatched file.
                let a = NSAlert()
                a.messageText = "Discard your edits to the input?"
                a.informativeText = "Switching to \(p.title) generates a new \(p.title) input from the form. Your hand edits to the \(setup.program.title) input are lost."
                a.addButton(withTitle: "Switch and Discard Edits")
                a.addButton(withTitle: "Cancel")
                guard a.runModal() == .alertFirstButtonReturn else { return }
                draft.revert()
            }
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
            if CalcIterations.supports(setup.program) {
                OptionalCountField(title: "SCF max iterations", value: $iterations.scfMaxIter, prompt: "default")
                if setup.jobType != .energy && setup.jobType != .frequency && setup.jobType != .nmr && setup.jobType != .excitedStates {
                    OptionalCountField(title: "Optimization max steps", value: $iterations.optMaxIter, prompt: "default")
                }
            }
            TextField(setup.program == .qchem ? "Extra $rem lines" : "Extra keywords", text: $setup.extraKeywords,
                      prompt: Text(extraPrompt))
                .font(.system(.body, design: .monospaced))
            TextField("Title", text: $setup.title, prompt: Text(editor.molecule.title.isEmpty ? "VibeView calculation" : editor.molecule.title))
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

    private var previewText: Binding<String> {
        Binding(get: { draft.isEdited ? draft.text : preview },
                set: { t in draft.updateGenerated(preview); draft.setText(t) })
    }

    private var previewPane: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(setup.program == .xtb ? "Command Line + \(inputName)" : "Input: \(inputName)").font(.headline)
                Spacer()
                if draft.isEdited {
                    Label("Edited", systemImage: "pencil.circle.fill")
                        .font(.callout.weight(.semibold)).foregroundStyle(.orange)
                    Button("Revert to Generated") { draft.revert() }
                        .help("Discard your edits; the preview follows the form again")
                } else {
                    Text("Editable").font(.caption).foregroundStyle(.secondary)
                        .help("Type in the preview to change the input by hand. Save and Run use exactly what is shown.")
                }
            }
            PlainTextEditor(text: previewText)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(draft.isEdited ? Color.orange.opacity(0.7) : Color.secondary.opacity(0.25)))
            if draft.isEdited {
                Label(draft.formChangedSinceEdit
                      ? "The form changed after you edited the input. Those changes are NOT in this input; Revert to Generated applies them (and discards your edits)."
                      : "Edited by hand: form changes no longer update this input. Save and Run use it exactly as shown.",
                      systemImage: draft.formChangedSinceEdit ? "exclamationmark.triangle.fill" : "info.circle")
                    .font(.callout)
                    .foregroundStyle(draft.formChangedSinceEdit ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let e = editProblem {
                Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout)
            }
            if !problems.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(problems, id: \.self) {
                        Label($0, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(draft.isEdited ? Color.orange : Color.red).font(.callout)
                    }
                }
            }
        }
        .padding()
    }

    private var runHelp: String {
        if programMissing { return "\(setup.program.title) not found \u{2014} set its path in Settings" }
        if !blockingProblems.isEmpty { return "Fix the problems listed below the preview first" }
        if draft.isEdited { return "Run \(setup.program.title) with the edited input" }
        return "Run \(setup.program.title) on this molecule"
    }

    private var footer: some View {
        HStack {
            if !message.isEmpty { Text(message).font(.callout).foregroundStyle(.secondary).lineLimit(2) }
            Spacer()
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Copy Input") {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(previewText.wrappedValue, forType: .string)
                message = "Input copied"
            }
            Button("Save Input\u{2026}") { _ = save() }
            Button("Run") { run() }
                .keyboardShortcut(.defaultAction)
                .disabled(programMissing || !blockingProblems.isEmpty)
                .help(runHelp)
        }
        .padding()
    }

    private func run() {
        guard GeometryPreflightPrompt.confirm(editor.molecule, program: setup.program.title) else { message = "Run cancelled"; return }
        do {
            let eff = try effectiveInput.get()
            try queue.submit(setup: setup, molecule: editor.molecule, name: Self.baseName(editor), documentURL: editor.fileURL, iterations: iterations,
                             inputOverride: draft.isEdited ? eff.fileText : nil, xtbArguments: draft.isEdited ? eff.xtbArguments : nil)
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
        let eff: EffectiveInput
        do { eff = try effectiveInput.get() } catch { message = error.localizedDescription; return nil }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            try eff.fileText.write(to: url, atomically: true, encoding: .utf8)
            if let a = eff.xtbArguments {
                let args = a.map { $0 == inputName ? url.lastPathComponent : $0 }
                message = "Saved \(url.lastPathComponent). Run it with: " + XTBInputPreview.shellJoin(["xtb"] + args)
            } else {
                message = "Saved \(url.lastPathComponent)"
            }
            return url
        } catch {
            message = "Could not save: \(error.localizedDescription)"
            return nil
        }
    }
}

/// Monospaced, non-wrapping plain-text editor with every automatic substitution off (smart quotes or dashes
/// would corrupt an input file).
struct PlainTextEditor: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        guard let tv = scroll.documentView as? NSTextView else { return scroll }
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.isAutomaticDataDetectionEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.textColor = .textColor
        tv.backgroundColor = .textBackgroundColor
        tv.drawsBackground = true
        tv.textContainerInset = NSSize(width: 6, height: 6)
        tv.isHorizontallyResizable = true
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.string = text
        tv.delegate = context.coordinator
        tv.setAccessibilityLabel("Input file text")
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = scroll.documentView as? NSTextView, tv.string != text else { return }
        let sel = tv.selectedRanges
        tv.string = text
        let len = (text as NSString).length
        tv.selectedRanges = sel.map { r in
            let v = r.rangeValue
            return NSValue(range: NSRange(location: min(v.location, len), length: 0))
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PlainTextEditor
        init(_ p: PlainTextEditor) { parent = p }
        func textDidChange(_ n: Notification) {
            guard let tv = n.object as? NSTextView else { return }
            parent.text = tv.string
        }
    }
}
