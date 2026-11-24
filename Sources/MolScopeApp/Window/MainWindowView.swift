import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MolCore
import MolRender

struct MainWindowView: View {
    @Binding var document: MoleculeDocument
    let fileURL: URL?
    @StateObject private var editor: EditorModel
    @State private var showElements = false
    @State private var columns: NavigationSplitViewVisibility = .all
    @State private var dropTargeted = false
    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorScheme) private var colorScheme

    init(document: Binding<MoleculeDocument>, fileURL: URL?) {
        _document = document
        self.fileURL = fileURL
        let d = document.wrappedValue
        _editor = StateObject(wrappedValue: EditorModel(molecule: d.molecule, result: d.result, wavefunction: d.wavefunction))
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            LibrarySidebar(editor: editor)
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
        } detail: {
            VStack(spacing: 0) {
                VSplitView {
                    MoleculeViewport(editor: editor)
                        .frame(minWidth: 360, minHeight: 260)
                        .overlay { if dropTargeted { DropHighlight() } }
                        .onDrop(of: [.fileURL], isTargeted: $dropTargeted, perform: handleDrop)
                    if editor.result != nil && editor.showResults {
                        ResultsPanel(editor: editor).frame(minHeight: 220, idealHeight: 300)
                    }
                }
                StatusBar(editor: editor)
            }
        }
        .inspector(isPresented: $editor.showInspector) {
            InspectorView(editor: editor).inspectorColumnWidth(min: 230, ideal: 260, max: 360)
        }
        .toolbar { toolbarContent }
        .focusedSceneValue(\.editor, editor)
        .sheet(isPresented: $editor.showCalcSetup) { CalcSetupSheet(editor: editor) }
        .sheet(isPresented: $editor.showPubChem) { PubChemSheet(editor: editor) }
        .overlay(alignment: .top) {
            if editor.showCommandPalette {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.12).ignoresSafeArea().onTapGesture { editor.showCommandPalette = false }
                    CommandPaletteView(commands: AppCommandCatalog.commands(editor: editor, openWindow: openWindow),
                                       isPresented: $editor.showCommandPalette)
                        .padding(.top, 70)
                }
            }
        }
        .navigationTitle(fileURL?.deletingPathExtension().lastPathComponent ?? (editor.molecule.title.isEmpty ? "Untitled" : editor.molecule.title))
        .navigationSubtitle(subtitle)
        .onAppear {
            editor.fileURL = fileURL
            editor.onCommit = { m in document.molecule = m }
            syncTheme()
        }
        .onChange(of: fileURL) { _, u in editor.fileURL = u }
        .onChange(of: colorScheme) { _, _ in syncTheme() }
        .onChange(of: columns) { _, c in editor.showLibrary = c != .detailOnly }
        .onChange(of: editor.showLibrary) { _, s in columns = s ? .all : .detailOnly }
    }

    private var subtitle: String {
        let m = editor.molecule
        guard !m.atoms.isEmpty else { return "" }
        return "\(m.formula) · \(m.atoms.count) atoms"
    }

    private func syncTheme() {
        let want: RenderThemeChoice = colorScheme == .dark ? .dark : .light
        want.apply(to: editor)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("Tool", selection: $editor.tool) {
                ForEach(EditorTool.allCases) { t in
                    Label(t.title, systemImage: t.symbol).tag(t).help("\(t.title) (⌘\(t.shortcutDigit))")
                }
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
            .help("Orbit, Pick, Sketch or Gauge")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { showElements.toggle() } label: {
                Text(currentElementLabel)
                    .font(.system(.body, design: .rounded).weight(.bold))
                    .frame(minWidth: 30)
            }
            .help("Element or fragment to sketch with")
            .popover(isPresented: $showElements, arrowEdge: .bottom) { PeriodicTablePopover(editor: editor, isPresented: $showElements) }

            Button { editor.addHydrogens() } label: { Label("Add Hydrogens", systemImage: "h.circle") }
                .help("Fill open valences with hydrogens (⌘⇧H)")
            Button { editor.cleanGeometry() } label: { Label("Clean Up", systemImage: "wand.and.stars") }
                .help("Relax the geometry with the built-in force field (⌘⇧K)")
            Button { editor.optimizeWithXTB() } label: { Label("Optimize with xtb", systemImage: "bolt.badge.automatic") }
                .help(XTBAvailability.helpText)
                .disabled(editor.molecule.atoms.isEmpty || editor.busyMessage != nil)
            Button { editor.showCalcSetup = true } label: { Label("Calculation", systemImage: "function") }
                .help("Set up a Gaussian, ORCA, Q-Chem or xtb calculation (⌥⌘C)")
            Button { openWindow(id: "job-queue") } label: { Label("Jobs", systemImage: "tray.full") }
                .help("Show the job queue (⌥⌘J)")
            Button { editor.showCommandPalette.toggle() } label: { Label("Commands", systemImage: "command") }
                .help("Search every command, element and fragment (⌘K)")
            Button { editor.showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") }
                .help("Show or hide the inspector (⌥⌘I)")
        }
    }

    private var currentElementLabel: String {
        switch editor.payload {
        case .element(let z): return ElementInfo.symbol(z)
        case .fragment(let id): return FragmentNames.short(id)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            accepted = true
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in DocumentOpener.open(url) }
            }
        }
        return accepted
    }
}

private struct DropHighlight: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            .padding(8)
            .allowsHitTesting(false)
    }
}

/// Opens files as documents, reporting failures in an alert instead of failing silently.
@MainActor
enum DocumentOpener {
    static func open(_ url: URL) {
        debugLog("open \(url.path)")
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { doc, _, error in
            debugLog("opened doc=\(doc.map { String(describing: type(of: $0)) } ?? "nil") error=\(error.map { "\($0)" } ?? "none")")
            if let error {
                let alert = NSAlert(error: error)
                alert.messageText = "“\(url.lastPathComponent)” could not be opened."
                alert.runModal()
            }
        }
    }
}

enum RenderThemeChoice {
    case light, dark
    @MainActor func apply(to editor: EditorModel) {
        var o = editor.renderOptions
        let t: RenderTheme = self == .dark ? .dark : .light
        guard o.theme != t, o.theme == .light || o.theme == .dark else { return }
        o.theme = t
        editor.renderOptions = o
    }
}

enum FragmentNames {
    static func short(_ id: String) -> String {
        let n = BuildOps.fragmentName(id)
        return n.count <= 8 ? n : String(n.prefix(7)) + "…"
    }
}

func debugLog(_ s: String) {
    if ProcessInfo.processInfo.environment["MOLSCOPE_DEBUG_IO"] != nil { FileHandle.standardError.write(Data((s + "\n").utf8)) }
}
