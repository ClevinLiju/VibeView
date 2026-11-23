import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MolCore

struct MainWindowView: View {
    @Binding var document: MoleculeDocument
    let fileURL: URL?
    @StateObject private var editor: EditorModel
    @StateObject private var showCalcBox = StateBox(false)
    @StateObject private var showElementsBox = StateBox(false)
    @StateObject private var showPaletteBox = StateBox(true)
    @StateObject private var showInspectorBox = StateBox(true)
    @StateObject private var showResultsBox = StateBox(true)
    private var showCalc: Bool { get { showCalcBox.value } nonmutating set { showCalcBox.value = newValue } }
    private var showElements: Bool { get { showElementsBox.value } nonmutating set { showElementsBox.value = newValue } }
    private var showPalette: Bool { get { showPaletteBox.value } nonmutating set { showPaletteBox.value = newValue } }
    private var showInspector: Bool { get { showInspectorBox.value } nonmutating set { showInspectorBox.value = newValue } }
    private var showResults: Bool { get { showResultsBox.value } nonmutating set { showResultsBox.value = newValue } }
    @Environment(\.openWindow) private var openWindow
    @Environment(\.controlActiveState) private var activeState

    init(document: Binding<MoleculeDocument>, fileURL: URL?) {
        _document = document
        self.fileURL = fileURL
        _editor = StateObject(wrappedValue: EditorModel(molecule: document.wrappedValue.molecule, result: document.wrappedValue.result))
    }

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                if showPalette {
                    FragmentPalette(editor: editor).frame(minWidth: 170, idealWidth: 200, maxWidth: 280)
                }
                VSplitView {
                    MoleculeViewport(editor: editor)
                        .frame(minWidth: 300, minHeight: 240)
                        .onDrop(of: [.fileURL], isTargeted: nil, perform: handleDrop)
                    if editor.result != nil && showResults {
                        ResultsPanel(editor: editor).frame(minHeight: 200, idealHeight: 280)
                    }
                }
                if showInspector {
                    InspectorView(editor: editor).frame(minWidth: 210, idealWidth: 240, maxWidth: 320)
                }
            }
            Divider()
            StatusBar(editor: editor)
        }
        .toolbar { toolbarContent }
        .focusedSceneValue(\.editor, editor)
        .sheet(isPresented: $showCalcBox.value) { CalcSetupSheet(editor: editor) }
        .navigationTitle(editor.molecule.title.isEmpty ? (fileURL?.lastPathComponent ?? "Untitled") : editor.molecule.title)
        .onAppear {
            editor.fileURL = fileURL
            editor.onCommit = { m in document.molecule = m }
        }
        .onChange(of: fileURL) { editor.fileURL = $0 }
        .onReceive(NotificationCenter.default.publisher(for: .molscopeShowCalcSetup)) { _ in if isActive { showCalc = true } }
        .onReceive(NotificationCenter.default.publisher(for: .molscopeShowJobQueue)) { _ in if isActive { openWindow(id: "job-queue") } }
        .onReceive(NotificationCenter.default.publisher(for: .molscopeShowResults)) { _ in if isActive { showResults = true } }
        .onReceive(NotificationCenter.default.publisher(for: .molscopeCleanGeometry)) { _ in if isActive { editor.cleanGeometry() } }
    }

    private var isActive: Bool { activeState == .key || activeState == .active }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { showPalette.toggle() } label: { Label("Fragments", systemImage: "sidebar.left") }
                .help("Show or hide the fragment palette")
        }
        ToolbarItem(placement: .principal) {
            Picker("Tool", selection: $editor.tool) {
                ForEach(EditorTool.allCases) { t in Label(t.title, systemImage: t.symbol).tag(t) }
            }
            .pickerStyle(.segmented)
            .help("Orbit, Pick, Sketch or Gauge")
        }
        ToolbarItemGroup {
            Button { showElements.toggle() } label: {
                Text(currentElementLabel).font(.system(.body, design: .rounded).weight(.bold)).frame(minWidth: 26)
            }
            .help("Choose the element to sketch with")
            .popover(isPresented: $showElementsBox.value) { PeriodicTablePopover(editor: editor, isPresented: $showElementsBox.value) }
            Button { editor.addHydrogens() } label: { Label("Add Hydrogens", systemImage: "plus.circle") }
                .help("Add hydrogens to fill valences")
            Button { editor.cleanGeometry() } label: { Label("Clean Geometry", systemImage: "wand.and.stars") }
                .help("Relax the structure with a force field")
            Button { showCalc = true } label: { Label("Set Up Calculation", systemImage: "gearshape.2") }
                .help("Set up a Gaussian calculation")
            Button { openWindow(id: "job-queue") } label: { Label("Job Queue", systemImage: "list.bullet.rectangle") }
                .help("Open the job queue")
            Button { showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") }
                .help("Show or hide the inspector")
        }
    }

    private var currentElementLabel: String {
        switch editor.payload {
        case .element(let z): return ElementInfo.symbol(z)
        case .fragment: return "Frag"
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            accepted = true
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
                }
            }
        }
        return accepted
    }
}
