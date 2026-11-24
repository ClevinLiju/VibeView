import SwiftUI
import AppKit
import MolCore
import MolCompute

// Lead C: "Optimize with xtb" and "Open from PubChem…", built on Lead D's MolCompute.

enum XTBAvailability {
    static var executable: URL? { ProgramLocator.locate(.xtb) ?? XTBRunner.locate() }
    static var helpText: String {
        executable == nil ? "Optimize with GFN2-xTB — xtb was not found; set its path in Settings ▸ Programs"
                          : "Optimize the structure with GFN2-xTB (⌥⌘K)"
    }
}

extension EditorModel {
    /// Fast semi-empirical optimization; degrades to an explanatory alert when xtb is missing.
    func optimizeWithXTB() {
        guard !molecule.atoms.isEmpty, busyMessage == nil else { return }
        guard let exe = XTBAvailability.executable else {
            let a = NSAlert()
            a.messageText = "xtb is not installed"
            a.informativeText = "MolScope uses the free xtb program (GFN2-xTB) for fast optimizations. Install it (for example with “brew install xtb” or conda-forge) or set its location in Settings ▸ Programs. Meanwhile you can use Clean Up Geometry (⇧⌘K), which runs the built-in force field."
            a.addButton(withTitle: "Clean Up Instead")
            a.addButton(withTitle: "Cancel")
            if a.runModal() == .alertFirstButtonReturn { cleanGeometry() }
            return
        }
        let start = molecule
        busyMessage = "Optimizing with GFN2-xTB…"
        let threads = max(1, min(8, ProcessInfo.processInfo.activeProcessorCount))
        Task { @MainActor in
            defer { busyMessage = nil }
            do {
                let r = try await XTBRunner(executable: exe).run(start, task: .optimize, method: MolCompute.XTBMethod.gfn2, threads: threads)
                guard molecule == start else { statusMessage = "xtb finished, but the structure changed meanwhile — result discarded"; return }
                var m = start
                if r.molecule.atoms.count == m.atoms.count {
                    for i in m.atoms.indices { m.atoms[i].position = r.molecule.atoms[i].position }
                }
                replaceMolecule(m, actionName: "Optimize with xtb")
                statusMessage = String(format: "xtb: E = %.6f Eh", r.energy) + (r.homoLumoGap.map { String(format: ", gap %.2f eV", $0) } ?? "")
            } catch {
                statusMessage = "xtb failed: \(error.localizedDescription)"
            }
        }
    }
}

/// "Open from PubChem…": name, CID or SMILES → a new document window.
struct PubChemSheet: View {
    @ObservedObject var editor: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var kind: Kind = .auto
    @State private var busy = false
    @State private var error: String?
    @State private var replaceCurrent = false

    enum Kind: String, CaseIterable, Identifiable { case auto = "Automatic", name = "Name", cid = "CID", smiles = "SMILES"; var id: String { rawValue } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "globe").font(.title2).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Open from PubChem").font(.headline)
                    Text("Download a 3-D structure by compound name, CID or SMILES.").font(.callout).foregroundStyle(.secondary)
                }
            }
            TextField("e.g. caffeine, 2519, or CC(=O)Oc1ccccc1C(=O)O", text: $query)
                .textFieldStyle(.roundedBorder)
                .onSubmit(fetch)
            Picker("Search by", selection: $kind) { ForEach(Kind.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented)
            if !editor.molecule.atoms.isEmpty {
                Toggle("Replace the structure in this window", isOn: $replaceCurrent)
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout) }
            HStack {
                if busy { ProgressView().controlSize(.small); Text("Contacting PubChem…").foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Open", action: fetch).keyboardShortcut(.defaultAction)
                    .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || busy)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func resolvedKind(_ q: String) -> Kind {
        if kind != .auto { return kind }
        if Int(q) != nil { return .cid }
        let smilesChars = CharacterSet(charactersIn: "=#()[]@+\\/%")
        if q.rangeOfCharacter(from: smilesChars) != nil && !q.contains(" ") { return .smiles }
        return .name
    }

    private func fetch() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, !busy else { return }
        busy = true; error = nil
        let k = resolvedKind(q)
        Task { @MainActor in
            defer { busy = false }
            do {
                let client = PubChemClient()
                let c: PubChemCompound
                switch k {
                case .cid: c = try await client.fetch(cid: Int(q) ?? 0)
                case .smiles: c = try await client.fetch(smiles: q)
                default: c = try await client.fetch(name: q)
                }
                var m = IOBridge.prepared(c.molecule)
                if m.title.isEmpty { m.title = c.title }
                if replaceCurrent || editor.molecule.atoms.isEmpty {
                    editor.replaceMolecule(m, actionName: "Open from PubChem")
                    editor.statusMessage = "Loaded \(c.title)" + (c.cid.map { " (CID \($0))" } ?? "") + (c.is3D ? "" : " — 2-D record, embedded locally")
                    editor.viewport.renderer.fitToView(animated: true)
                } else {
                    try openInNewWindow(m, name: c.title)
                }
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func openInNewWindow(_ m: Molecule, name: String) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("MolScope-PubChem", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = name.replacingOccurrences(of: "/", with: "-").prefix(60)
        let url = dir.appendingPathComponent("\(safe).mol")
        try IOBridge.write(m, ext: "mol").write(to: url)
        DocumentOpener.open(url)
    }
}
