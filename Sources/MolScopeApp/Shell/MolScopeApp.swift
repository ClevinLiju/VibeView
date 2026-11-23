import SwiftUI
import AppKit

final class MolScopeAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        // Files passed on the command line (bare SwiftPM binary launch).
        let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        for a in args where FileManager.default.fileExists(atPath: a) {
            open(URL(fileURLWithPath: a))
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach(open)
    }

    private func open(_ url: URL) {
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
            if let error { NSLog("MolScope: could not open %@: %@", url.path, error.localizedDescription) }
        }
    }
}

@main
struct MolScopeMain: App {
    @NSApplicationDelegateAdaptor(MolScopeAppDelegate.self) private var delegate

    var body: some Scene {
        DocumentGroup(newDocument: MoleculeDocument()) { file in
            MainWindowView(document: file.$document, fileURL: file.fileURL)
        }
        .commands { MolScopeCommands() }

        Window("Job Queue", id: "job-queue") { JobQueueView() }

        Settings { PreferencesView() }
    }
}

struct MolScopeCommands: Commands {
    @FocusedValue(\.editor) private var editor: EditorModel?
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button("Undo" + (editor?.undoActionName.map { " " + $0 } ?? "")) { editor?.undo() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!(editor?.canUndo ?? false))
            Button("Redo" + (editor?.redoActionName.map { " " + $0 } ?? "")) { editor?.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!(editor?.canRedo ?? false))
        }
        CommandMenu("Structure") {
            Button("Delete Selection") { editor?.deleteSelection() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(editor?.selection.isEmpty ?? true)
            Button("Select All") { editor?.selectAll() }
                .keyboardShortcut("a", modifiers: [.command, .option])
            Divider()
            Button("Add Hydrogens") { editor?.addHydrogens() }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            Button("Clean Geometry") { editor?.cleanGeometry() }
                .keyboardShortcut("k", modifiers: [.command, .shift])
            Divider()
            Button("Invert") { editor?.invertStructure() }
            Button("Mirror") { editor?.mirrorStructure() }
        }
        CommandMenu("Tools") {
            ForEach(Array(EditorTool.allCases.enumerated()), id: \.element) { i, t in
                Button(t.title) { editor?.tool = t }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
            }
        }
        CommandMenu("Calculate") {
            Button("Set Up Calculation…") { NotificationCenter.default.post(name: .molscopeShowCalcSetup, object: nil) }
                .keyboardShortcut("c", modifiers: [.command, .option])
            Button("Job Queue") { openWindow(id: "job-queue") }
                .keyboardShortcut("j", modifiers: [.command, .option])
            Button("Show Results") { NotificationCenter.default.post(name: .molscopeShowResults, object: nil) }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(editor?.result == nil)
        }
    }
}
