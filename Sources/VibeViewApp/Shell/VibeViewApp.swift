import SwiftUI
import AppKit
import MolCore
import MolRender

final class VibeViewAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        // Files passed on the command line (bare SwiftPM binary launch).
        let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        for a in args where FileManager.default.fileExists(atPath: a) {
            Task { @MainActor in DocumentOpener.open(URL(fileURLWithPath: a)) }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for u in urls { Task { @MainActor in DocumentOpener.open(u) } }
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
    @Environment(\.openWindow) private var openWindow

    private var hasAtoms: Bool { !(editor?.molecule.atoms.isEmpty ?? true) }

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Open from PubChem…") { editor?.showPubChem = true }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(editor == nil)
        }
        CommandGroup(after: .saveItem) {
            Divider()
            Button("Export Image…") { editor?.exportImage() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(editor == nil)
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
                .keyboardShortcut("c", modifiers: [.command, .shift])
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
            Button((editor?.showResults ?? true) ? "Hide Results" : "Show Results") { editor?.showResults.toggle() }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(editor?.result == nil)
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
            Button("Clean Up Geometry") { editor?.cleanGeometry() }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(!hasAtoms)
            Button("Optimize with xtb") { editor?.optimizeWithXTB() }
                .keyboardShortcut("k", modifiers: [.command, .option])
                .disabled(!hasAtoms)
            Divider()
            Button("Invert Through Center") { editor?.invertStructure() }.disabled(!hasAtoms)
            Button("Mirror Through XY Plane") { editor?.mirrorStructure() }.disabled(!hasAtoms)
            Button("Center at Origin") { editor?.centerAtOrigin() }.disabled(!hasAtoms)
            Button("Rebuild Bonds") { editor?.rebuildBonds() }.disabled(!hasAtoms)
        }
        CommandMenu("Calculate") {
            Button("New Calculation…") { editor?.showCalcSetup = true }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(!hasAtoms)
            Button("Optimize with xtb") { editor?.optimizeWithXTB() }
                .disabled(!hasAtoms)
            Divider()
            Button("Show Job Queue") { openWindow(id: "job-queue") }
        }
    }
}

extension RenderStyle {
    var title: String {
        switch self { case .ballAndStick: "Ball and Stick"; case .tube: "Tubes"; case .wireframe: "Wireframe"; case .spaceFilling: "Space Filling" }
    }
    var symbol: String {
        switch self { case .ballAndStick: "circle.hexagongrid"; case .tube: "line.3.horizontal"; case .wireframe: "skew"; case .spaceFilling: "circle.grid.3x3.fill" }
    }
    var shortcut: KeyEquivalent {
        switch self { case .ballAndStick: "1"; case .tube: "2"; case .wireframe: "3"; case .spaceFilling: "4" }
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
