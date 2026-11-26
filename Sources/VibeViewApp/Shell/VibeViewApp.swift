import SwiftUI
import AppKit
import MolCore
import MolRender

final class VibeViewAppDelegate: NSObject, NSApplicationDelegate {
    /// Files named on the command line of a bare binary launch (`VibeView job.log`).
    private let argumentFiles: [URL] = LaunchFiles.fromArguments(CommandLine.arguments)
    /// Set once any document request arrives (Finder, `open -a`, argv) before the launch settles.
    private var receivedFileRequest = false
    private var launchSettled = false

    override init() {
        // AppKit would also treat command-line file arguments as open requests (without showing a window
        // reliably); with two concurrent opens a slow file can appear twice. We open argv files ourselves.
        // Launching with files shows exactly those files: no windows restored from an earlier run (File ▸ Open
        // Recent and sessions cover that).
        UserDefaults.standard.register(defaults: ["NSTreatUnknownArgumentsAsOpen": "NO", "ApplePersistenceIgnoreState": "YES",
                                                  "NSQuitAlwaysKeepsWindows": false])
        super.init()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        if !argumentFiles.isEmpty { receivedFileRequest = true }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if IconRenderer.runIfRequested() { return }
        NSApp.activate(ignoringOtherApps: true)
        Task { @MainActor in
            GalleryJobs.registerGallery()
            WindowSnapshots.scheduleIfRequested()
            GalleryJobs.runXTBSelfTestIfRequested()
            GalleryJobs.runORCASelfTestIfRequested()
        }
        for u in argumentFiles {
            Task { @MainActor in
                if u.pathExtension.lowercased() == "vibeview" { SessionStore.open(u) } else { DocumentOpener.open(u) }
            }
        }
        // SwiftUI's DocumentGroup creates a blank document at launch before the files of an `open -a` / Finder /
        // command-line launch arrive (and doesn't route those through this delegate). Remember the blank documents
        // that exist during launch; as soon as a file-backed document appears, close them if still blank and unedited.
        // Big files can take a while to load, so watch for up to 30 s.
        var launchBlank = Set<ObjectIdentifier>()
        func sweep(_ t: Double, elapsed: Double) {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in
                let now = elapsed + t
                let docs = NSDocumentController.shared.documents
                if now <= 1.5 { for d in docs where d.fileURL == nil { launchBlank.insert(ObjectIdentifier(d)) } }
                if docs.contains(where: { $0.fileURL != nil }) {
                    for d in docs where launchBlank.contains(ObjectIdentifier(d)) && d.fileURL == nil && !d.isDocumentEdited {
                        debugLog("closing blank launch document \(d.displayName ?? "?")")
                        d.close()
                    }
                    if now > 1.5 { self?.launchSettled = true; return }
                }
                if now < 30 { sweep(0.25, elapsed: now) } else { self?.launchSettled = true }
            }
        }
        sweep(0.1, elapsed: 0)
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { !receivedFileRequest }

    func application(_ application: NSApplication, open urls: [URL]) {
        if !launchSettled { receivedFileRequest = true }
        for u in urls where !argumentFiles.contains(where: { $0.standardizedFileURL == u.standardizedFileURL }) || launchSettled {
            Task { @MainActor in
                if u.pathExtension.lowercased() == "vibeview" { SessionStore.open(u) } else { DocumentOpener.open(u) }
            }
        }
    }
}

/// Launch-time document bookkeeping: argv parsing and removal of the spare "Untitled" window.
enum LaunchFiles {
    static func fromArguments(_ argv: [String]) -> [URL] {
        var out: [URL] = []
        var skipNext = false
        for a in argv.dropFirst() {
            if skipNext { skipNext = false; continue }
            if a.hasPrefix("-") { skipNext = a.hasPrefix("-NS") || a.hasPrefix("-Apple"); continue }   // `-NSFoo YES`
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: a, isDirectory: &isDir), !isDir.boolValue {
                out.append(URL(fileURLWithPath: a).standardizedFileURL)
            }
        }
        return out
    }

    /// Returns true once a real (file-backed) document exists, i.e. the sweep is finished.
    @discardableResult
    @MainActor static func closeBlankUntitledDocuments() -> Bool {
        let docs = NSDocumentController.shared.documents
        guard docs.contains(where: { $0.fileURL != nil }) else { return false }
        for d in docs where d.fileURL == nil && !d.isDocumentEdited {
            debugLog("closing blank launch document \(d.displayName ?? "?")")
            d.close()
        }
        return true
    }
}

@main
struct VibeViewMain: App {
    @NSApplicationDelegateAdaptor(VibeViewAppDelegate.self) private var delegate

    var body: some Scene {
        DocumentGroup(newDocument: MoleculeDocument()) { file in
            MainWindowView(document: file.$document, fileURL: file.fileURL)
                .frame(minWidth: 860, minHeight: 560)
        }
        .defaultSize(width: 1280, height: 820)
        .commands { VibeViewCommands() }

        Window("Job Queue", id: "job-queue") { JobQueueView() }
            .defaultSize(width: 900, height: 560)
            .keyboardShortcut("j", modifiers: [.command, .option])

        Settings { PreferencesView() }
    }
}

struct VibeViewCommands: Commands {
    @FocusedValue(\.editor) private var editor: EditorModel?
    @AppStorage("viewport.calcInfo.visible") private var showCalcInfo = true
    @Environment(\.openWindow) private var openWindow

    private var hasAtoms: Bool { !(editor?.molecule.atoms.isEmpty ?? true) }

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About \(AppInfo.name)") { AboutPanel.show() }
        }
        CommandGroup(after: .newItem) {
            Button("Find Molecule by Name…") { editor?.showPubChem = true }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(editor == nil)
        }
        CommandGroup(after: .saveItem) {
            Divider()
            Button("Save Session…") { if let e = editor { SessionStore.save(e) } }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(editor == nil)
            Button("Open Session…") { SessionStore.openPanel() }
                .keyboardShortcut("o", modifiers: [.command, .option])
            Menu("Export") {
                Button("Structure…") { editor?.exportStructureDialog() }
                    .disabled(!hasAtoms)
                Button("Image…") { editor?.exportImage() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(editor == nil)
                Button("Animation (GIF / MP4)…") { editor?.exportAnimationDialog() }
                    .disabled(!hasAtoms)
                Button("Table (CSV)…") { editor?.exportTableDialog() }
                    .disabled(editor?.result == nil)
            }
        }
        CommandGroup(replacing: .undoRedo) {
            Button("Undo" + (editor?.undoActionName.map { " " + $0 } ?? "")) { editor?.undo() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!(editor?.canUndo ?? false))
            Button("Redo" + (editor?.redoActionName.map { " " + $0 } ?? "")) { editor?.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!(editor?.canRedo ?? false))
        }
        CommandGroup(after: .pasteboard) {
            Button("Copy Image") { editor?.copyImage() }
                .keyboardShortcut("c", modifiers: [.command, .shift, .option])
                .disabled(editor == nil)
            Divider()
            Button("Select All Atoms") { editor?.selectAll() }
                .keyboardShortcut("a", modifiers: [.command, .option])
                .disabled(!hasAtoms)
            Button("Invert Selection") { editor?.invertSelection() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(!hasAtoms)
            Button("Delete Selected Atoms") { editor?.deleteSelection() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(editor?.selection.isEmpty ?? true)
        }
        CommandGroup(before: .toolbar) {
            Button("Command Palette…") { editor?.showCommandPalette.toggle() }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(editor == nil)
            Divider()
            Menu("Style") {
                ForEach(RenderStyle.allCases, id: \.self) { s in
                    Toggle(s.title, isOn: Binding(get: { editor?.renderOptions.style == s }, set: { _ in editor?.setStyle(s) }))
                        .keyboardShortcut(s.shortcut, modifiers: [.command, .control])
                }
                Divider()
                Toggle("Cartoon Colored by Chain", isOn: Binding(get: { editor?.renderOptions.cartoonColoring == .chain },
                                                                 set: { on in editor?.renderOptions.cartoonColoring = on ? .chain : .secondaryStructure }))
                Toggle("Cartoon Hides Water", isOn: Binding(get: { editor?.renderOptions.cartoonHidesWater ?? true },
                                                            set: { on in editor?.renderOptions.cartoonHidesWater = on }))
            }
            Menu("Labels") {
                ForEach(LabelMode.menuCases, id: \.self) { l in
                    Toggle(l.title, isOn: Binding(get: { editor?.renderOptions.labelMode == l }, set: { _ in editor?.setLabels(l) }))
                }
            }
            Menu("Material") {
                ForEach(MaterialPreset.allCases, id: \.self) { m in
                    Toggle(m.rawValue.capitalized, isOn: Binding(get: { editor?.renderOptions.material == m }, set: { _ in editor?.setMaterial(m) }))
                }
            }
            Toggle("Show Hydrogens", isOn: Binding(get: { editor?.renderOptions.showHydrogens ?? true }, set: { _ in editor?.toggleHydrogens() }))
                .keyboardShortcut("h", modifiers: [.command, .control])
            Toggle("Color by Charge", isOn: Binding(get: { if case .charge = editor?.renderOptions.colorScheme { return true }; return false },
                                                    set: { _ in editor?.toggleChargeColors() }))
            Toggle("Ambient Occlusion", isOn: Binding(get: { editor?.renderOptions.ambientOcclusion ?? false }, set: { _ in editor?.toggleAmbientOcclusion() }))
            Toggle("Depth Cueing", isOn: Binding(get: { editor?.renderOptions.depthCueing ?? false }, set: { _ in editor?.toggleDepthCue() }))
            Toggle("Orthographic Projection", isOn: Binding(get: { editor?.renderOptions.projection == .orthographic }, set: { _ in editor?.toggleProjection() }))
            Toggle("Calculation Info", isOn: $showCalcInfo)
            Divider()
            Button("Fit to Window") { editor?.fitView() }
                .keyboardShortcut("0", modifiers: .command)
            Menu("Look Along") {
                Button("Front") { editor?.standardView(.front) }
                Button("Back") { editor?.standardView(.back) }
                Button("Left") { editor?.standardView(.left) }
                Button("Right") { editor?.standardView(.right) }
                Button("Top") { editor?.standardView(.top) }
                Button("Bottom") { editor?.standardView(.bottom) }
                Divider()
                Button("X Axis") { editor?.standardView(.alongX) }
                Button("Y Axis") { editor?.standardView(.alongY) }
                Button("Z Axis") { editor?.standardView(.alongZ) }
            }
            Divider()
            Button((editor?.showLibrary ?? true) ? "Hide Library" : "Show Library") { editor?.showLibrary.toggle() }
                .keyboardShortcut("l", modifiers: [.command, .option])
            Button((editor?.showInspector ?? true) ? "Hide Inspector" : "Show Inspector") { editor?.showInspector.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Button((editor?.showConsole ?? false) ? "Hide Command Line" : "Show Command Line") { editor?.showConsole.toggle() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(editor == nil)
            Button((editor?.showResults ?? true) ? "Hide Results" : "Show Results") { editor?.showResults.toggle() }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(editor?.result == nil)
            Button("Show Z-Matrix") { editor?.resultsTab = .zmatrix; editor?.showResults = true }
                .keyboardShortcut("z", modifiers: [.command, .option])
                .disabled(!hasAtoms)
            Divider()
        }
        CommandMenu("Structure") {
            ForEach(EditorTool.allCases) { t in
                Toggle(t.title + " Tool", isOn: Binding(get: { editor?.tool == t }, set: { _ in editor?.tool = t }))
                    .keyboardShortcut(KeyEquivalent(Character("\(t.shortcutDigit)")), modifiers: .command)
            }
            Divider()
            Button("Add Hydrogens") { editor?.addHydrogens() }
                .keyboardShortcut("h", modifiers: [.command, .shift])
                .disabled(!hasAtoms)
            Button("Remove Hydrogens") { editor?.removeHydrogens() }
                .keyboardShortcut("h", modifiers: [.command, .option, .shift])
                .disabled(!hasAtoms)
            Button("Optimize with xtb") { editor?.optimizeWithXTB() }
                .keyboardShortcut("k", modifiers: [.command, .option])
                .disabled(!hasAtoms)
            Divider()
            Button("Invert Through Center") { editor?.invertStructure() }.disabled(!hasAtoms)
            Button("Mirror Through XY Plane") { editor?.mirrorStructure() }.disabled(!hasAtoms)
            Button("Center at Origin") { editor?.centerAtOrigin() }.disabled(!hasAtoms)
            Button("Rebuild Bonds") { editor?.rebuildBonds() }.disabled(!hasAtoms)
            Divider()
            Button("From Z-Matrix\u{2026}") { editor?.showFromZMatrix = true }.disabled(editor == nil)
        }
        CommandMenu("Calculate") {
            Button("New Calculation…") { editor?.showCalcSetup = true }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(!hasAtoms)
            Button("Optimize with xtb") { editor?.optimizeWithXTB() }
                .disabled(!hasAtoms)
            Button("xtb Settings…") { editor?.showXTBSettings = true }
                .keyboardShortcut("x", modifiers: [.command, .option])
                .disabled(editor == nil)
            Divider()
            Button("Show Job Queue") { openWindow(id: "job-queue") }
        }
    }
}

extension RenderStyle {
    var title: String {
        switch self { case .ballAndStick: "Ball and Stick"; case .tube: "Tubes"; case .wireframe: "Wireframe"; case .spaceFilling: "Space Filling"; case .cartoon: "Cartoon" }
    }
    var symbol: String {
        switch self { case .ballAndStick: "circle.hexagongrid"; case .tube: "line.3.horizontal"; case .wireframe: "skew"; case .spaceFilling: "circle.grid.3x3.fill"; case .cartoon: "scribble.variable" }
    }
    var shortcut: KeyEquivalent {
        switch self { case .ballAndStick: "1"; case .tube: "2"; case .wireframe: "3"; case .spaceFilling: "4"; case .cartoon: "5" }
    }
}

extension LabelMode {
    static let menuCases: [LabelMode] = [.none, .element, .index, .elementIndex, .charge]
    var title: String {
        switch self {
        case .none: "None"; case .element: "Element"; case .index: "Atom Number"; case .elementIndex: "Element + Number"
        case .charge: "Partial Charge"; case .custom: "Custom"
        }
    }
}
