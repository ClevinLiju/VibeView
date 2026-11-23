import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MolCore
import MolBuild

/// "Calculation Setup": build a Gaussian input for the current molecule, save it, or queue it.
struct CalcSetupSheet: View {
    @ObservedObject var editor: EditorModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @StateObject private var model: CalcModel

    init(editor: EditorModel) {
        self.editor = editor
        let d = UserDefaults.standard
        var s = CalcSpec(molecule: editor.molecule)
        if let m = d.string(forKey: AppSettings.defaultMethodKey), !m.isEmpty { s.method = m }
        if let b = d.string(forKey: AppSettings.defaultBasisKey), !b.isEmpty { s.basis = b }
        let np = d.integer(forKey: AppSettings.processorsKey)
        if np > 0 { s.nprocShared = np }
        if let mem = d.string(forKey: AppSettings.memoryKey), !mem.isEmpty { s.memory = mem }
        let base = editor.fileURL?.deletingPathExtension().lastPathComponent ?? "molecule"
        s.checkpoint = base + ".chk"
        s.title = editor.molecule.title
        _model = StateObject(wrappedValue: CalcModel(spec: s, checkpointName: base + ".chk"))
    }

    private var problems: [String] { model.spec.validate(molecule: editor.molecule) }
    private var preview: String { model.spec.inputText(molecule: editor.molecule) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                Form { jobSection; theorySection; chargeSection; environmentSection; resourcesSection; extrasSection }
                    .formStyle(.grouped)
                    .frame(minWidth: 400, idealWidth: 430)
                Divider()
                previewPane.frame(minWidth: 360)
            }
            Divider()
            footer
        }
        .frame(minWidth: 840, minHeight: 640)
        .navigationTitle("Calculation Setup")
    }

    // MARK: Sections

    private var jobSection: some View {
        Section("Job Kind") {
            Picker("Task", selection: $model.spec.jobType) {
                ForEach(JobType.allCases) { Text($0.title).tag($0) }
            }
            switch model.spec.jobType {
            case .scan:
                ScanCoordinateEditor(coordinates: $model.spec.scanCoordinates, picks: editor.measurePicks, atomCount: editor.molecule.atoms.count)
            case .irc:
                Picker("Direction", selection: $model.spec.ircDirection) { ForEach(IRCDirection.allCases) { Text($0.title).tag($0) } }
                Stepper("Max points: \(model.spec.ircMaxPoints)", value: $model.spec.ircMaxPoints, in: 1...500)
                Toggle("Compute force constants first", isOn: $model.spec.ircCalcFC)
            case .transitionState:
                Toggle("Compute force constants first", isOn: $model.spec.tsCalcFC)
                Toggle("Skip Hessian eigenvalue test", isOn: $model.spec.tsNoEigenTest)
            case .excitedStates:
                Stepper("States: \(model.spec.tdStates)", value: $model.spec.tdStates, in: 1...200)
                Picker("Spin", selection: $model.spec.tdSpin) { ForEach(TDSpinKind.allCases) { Text($0.title).tag($0) } }
            default: EmptyView()
            }
        }
    }

    private var theorySection: some View {
        Section("Level of Theory") {
            ChoiceField(title: "Method", options: CalcSpec.methods, value: $model.spec.method)
            ChoiceField(title: "Basis set", options: CalcSpec.bases, value: $model.spec.basis)
        }
    }

    private var chargeSection: some View {
        Section("Electronic State") {
            Stepper("Charge: \(model.spec.charge)", value: $model.spec.charge, in: -10...10)
            Stepper("Multiplicity: \(model.spec.multiplicity)", value: $model.spec.multiplicity, in: 1...12)
            Button("Use molecule's values (\(editor.molecule.charge), \(editor.molecule.multiplicity))") {
                model.spec.charge = editor.molecule.charge; model.spec.multiplicity = editor.molecule.multiplicity
            }.buttonStyle(.link)
            if !problems.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(problems, id: \.self) { Label($0, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout) }
                }
            }
        }
    }

    private var solvationKind: Binding<String> {
        Binding(get: { model.spec.solvation.model }, set: { k in
            let s = model.spec.solvation.solvent ?? "Water"
            switch k { case "PCM": model.spec.solvation = .pcm(s); case "SMD": model.spec.solvation = .smd(s); default: model.spec.solvation = .none }
        })
    }
    private var solventBinding: Binding<String> {
        Binding(get: { model.spec.solvation.solvent ?? "Water" }, set: { s in
            switch model.spec.solvation { case .pcm: model.spec.solvation = .pcm(s); case .smd: model.spec.solvation = .smd(s); case .none: break }
        })
    }

    private var environmentSection: some View {
        Section("Environment") {
            Picker("Solvent model", selection: solvationKind) {
                Text("Gas phase").tag("None"); Text("PCM").tag("PCM"); Text("SMD").tag("SMD")
            }
            if model.spec.solvation != .none {
                ChoiceField(title: "Solvent", options: CalcSpec.solvents, value: solventBinding)
            }
        }
    }

    private var resourcesSection: some View {
        Section("Resources") {
            Stepper("Processors: \(model.spec.nprocShared)", value: $model.spec.nprocShared, in: 1...256)
            TextField("Memory", text: $model.spec.memory, prompt: Text("4GB"))
            TextField("Checkpoint file", text: $model.checkpointName, prompt: Text("none"))
                .onChange(of: model.checkpointName) { _, v in
                    let t = v.trimmingCharacters(in: .whitespaces)
                    model.spec.checkpoint = t.isEmpty ? nil : t
                }
        }
    }

    private var extrasSection: some View {
        Section("Extras") {
            Picker("Output detail", selection: $model.spec.printLevel) { ForEach(PrintLevel.allCases) { Text($0.title).tag($0) } }
            TextField("Extra keywords", text: $model.spec.extraKeywords, prompt: Text("e.g. Int=UltraFine"))
                .font(.system(.body, design: .monospaced))
            TextField("Title", text: $model.spec.title, prompt: Text(editor.molecule.title.isEmpty ? "VibeView calculation" : editor.molecule.title))
        }
    }

    // MARK: Preview + footer

    private var previewPane: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Input Preview").font(.headline)
                Spacer()
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(preview, forType: .string) } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
            }
            ScrollView([.vertical, .horizontal]) {
                Text(preview)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(8)
            }
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
        }
        .padding()
    }

    private var footer: some View {
        HStack {
            if !model.message.isEmpty { Text(model.message).font(.callout).foregroundStyle(.secondary).lineLimit(2) }
            Spacer()
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Save Input\u{2026}") { _ = save() }
            Button("Save & Run") {
                if let url = save() {
                    JobQueue.shared.enqueue(inputURL: url)
                    openWindow(id: "job-queue")
                    dismiss()
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!problems.isEmpty)
        }
        .padding()
    }

    /// Runs a save panel and writes the input file. Returns the saved URL.
    private func save() -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = ["gjf", "com"].compactMap { UTType(filenameExtension: $0) }
        panel.canCreateDirectories = true
        panel.title = "Save Gaussian Input"
        let base = editor.fileURL?.deletingPathExtension().lastPathComponent ?? "molecule"
        panel.nameFieldStringValue = base + ".gjf"
        if let dir = editor.fileURL?.deletingLastPathComponent() { panel.directoryURL = dir }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            try preview.write(to: url, atomically: true, encoding: .utf8)
            model.message = "Saved \(url.lastPathComponent)"
            return url
        } catch {
            model.message = "Could not save: \(error.localizedDescription)"
            return nil
        }
    }
}

@MainActor
final class CalcModel: ObservableObject {
    @Published var spec: CalcSpec
    @Published var checkpointName: String
    @Published var message: String = ""
    init(spec: CalcSpec, checkpointName: String) { self.spec = spec; self.checkpointName = checkpointName }
}
