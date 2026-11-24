import SwiftUI
import AppKit
import MolCore
import MolBuild
import MolCompute

/// Find a molecule by name, CAS number, SMILES or PubChem CID, pick one of the candidates, then sketch with it
/// (it becomes the current Sketch fragment), insert it, or open it in a new window.
/// Data come from PubChem (NIH) through MolCompute's `NameLookup`; SciFinder/CAS has no public API.
@MainActor
final class NameLookupModel: ObservableObject {
    @Published var query = ""
    @Published var candidates: [LookupCandidate] = []
    @Published var selected: LookupCandidate.ID?
    @Published var busy = false
    @Published var message: String?
    private let lookup = NameLookup()
    private var searchTask: Task<Void, Never>?

    var selectedCandidate: LookupCandidate? { candidates.first { $0.id == selected } }

    func search() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        searchTask?.cancel()
        busy = true; message = nil
        searchTask = Task { [lookup] in
            let found = await lookup.suggest(q, limit: 8)
            let err = await lookup.lastError
            guard !Task.isCancelled else { return }
            self.candidates = found
            self.selected = found.first?.id
            self.busy = false
            if found.isEmpty {
                self.message = err?.localizedDescription ?? "Nothing found for “\(q)”. Check the spelling, or try a CAS number or SMILES."
            } else if let f = found.first, f.matchKind == .spellingSuggestion {
                self.message = "Showing results for “\(f.matchedQuery)”."
            }
        }
    }

    func structure(for c: LookupCandidate) async throws -> Molecule { try await lookup.structure(for: c) }
}

struct NameLookupSheet: View {
    @ObservedObject var editor: EditorModel
    @StateObject private var model = NameLookupModel()
    @Environment(\.dismiss) private var dismiss
    @State private var working = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "text.magnifyingglass").font(.title2).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Find a Molecule").font(.headline)
                    Text("Type a name, CAS number (e.g. 58-08-2), SMILES or PubChem CID.").font(.callout).foregroundStyle(.secondary)
                }
            }
            HStack {
                TextField("caffeine, 58-08-2, c1ccccc1O, 2244…", text: $model.query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.search() }
                Button("Search") { model.search() }
                    .disabled(model.query.trimmingCharacters(in: .whitespaces).isEmpty || model.busy)
            }
            HStack(alignment: .top, spacing: 12) {
                List(model.candidates, selection: $model.selected) { c in
                    CandidateRow(candidate: c).tag(c.id)
                }
                .frame(width: 300)
                .overlay {
                    if model.busy { ProgressView("Searching PubChem…") }
                    else if model.candidates.isEmpty {
                        Text(model.message ?? "Results appear here.").foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
                    }
                }
                CandidateDetail(candidate: model.selectedCandidate)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(height: 320)
            if let m = model.message, !model.candidates.isEmpty { Text(m).font(.caption).foregroundStyle(.secondary) }
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout) }
            HStack {
                Text("Structures come from PubChem (NIH), which is free and public. SciFinder has no public interface, so it isn't searched.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Menu("Insert") {
                    Button("Into This Window") { use(.insert) }
                    Button("Open in New Window") { use(.newWindow) }
                }
                .fixedSize()
                .disabled(model.selectedCandidate == nil || working)
                Button("Sketch With It") { use(.fragment) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.selectedCandidate == nil || working)
                    .help("Make it the current fragment: click a hydrogen to attach it, an atom to replace it, or empty space to place it")
            }
        }
        .padding(18)
        .frame(width: 720)
    }

    private enum Use { case fragment, insert, newWindow }

    private func use(_ how: Use) {
        guard let c = model.selectedCandidate else { return }
        working = true; error = nil
        Task {
            defer { working = false }
            do {
                var m = try await model.structure(for: c)
                m = IOBridge.prepared(m)
                if m.title.isEmpty { m.title = c.title }
                switch how {
                case .fragment:
                    let id = "lookup:\(c.cid)"
                    if let f = FragmentLibrary.makeFragment(id: id, name: c.title, molecule: m) {
                        FragmentLibrary.register(f)
                        editor.payload = .fragment(id)
                        editor.tool = .build
                        editor.statusMessage = "Sketching with \(c.title): click a hydrogen to attach, an atom to replace, or empty space to place."
                    } else if editor.molecule.atoms.isEmpty {
                        editor.replaceMolecule(m, actionName: "Insert \(c.title)")
                    } else {
                        throw CommandFailure("\(c.title) has no hydrogen to attach through; use Insert instead.")
                    }
                case .insert:
                    if editor.molecule.atoms.isEmpty {
                        editor.replaceMolecule(m, actionName: "Insert \(c.title)")
                    } else {
                        let off = (editor.molecule.atoms.map(\.position).map { $0.x }.max() ?? 0) + 4
                        let c0 = m.centroid
                        var moved = m
                        for i in moved.atoms.indices { moved.atoms[i].position += Vec3(off, 0, 0) - c0 }
                        editor.apply("Insert \(c.title)") { $0.buildAppend(moved) }
                    }
                    editor.viewport.renderer.fitToView(animated: true)
                case .newWindow:
                    try openInNewWindow(m, name: c.title)
                }
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func openInNewWindow(_ m: Molecule, name: String) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("VibeView-Lookup", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = name.replacingOccurrences(of: "/", with: "-").prefix(60)
        let url = dir.appendingPathComponent("\(safe).mol")
        try IOBridge.write(m, ext: "mol").write(to: url)
        DocumentOpener.open(url)
    }
}

struct CommandFailure: LocalizedError { let message: String; init(_ m: String) { message = m }; var errorDescription: String? { message } }

private struct CandidateRow: View {
    let candidate: LookupCandidate
    var body: some View {
        HStack(spacing: 8) {
            Thumb(data: candidate.thumbnail, side: 44)
            VStack(alignment: .leading, spacing: 1) {
                Text(candidate.title).lineLimit(1)
                Text([candidate.formula, candidate.casNumber.map { "CAS \($0)" }].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct CandidateDetail: View {
    let candidate: LookupCandidate?
    var body: some View {
        if let c = candidate {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Thumb(data: c.thumbnail, side: 160)
                    Text(c.title).font(.title3.weight(.semibold))
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                        if let f = c.formula { row("Formula", f) }
                        if let w = c.molecularWeight { row("Mol. weight", String(format: "%.2f g/mol", w)) }
                        if let cas = c.casNumber { row("CAS", cas) }
                        row("PubChem CID", "\(c.cid)")
                        if let n = c.iupacName { row("IUPAC", n) }
                        if let s = c.canonicalSMILES { row("SMILES", s) }
                    }
                    .font(.callout)
                    if !c.synonyms.isEmpty {
                        Text("Also known as").font(.caption.weight(.semibold)).padding(.top, 4)
                        Text(c.synonyms.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .textSelection(.enabled)
            }
        } else {
            Text("Select a result to see its details.").foregroundStyle(.secondary)
        }
    }
    private func row(_ k: String, _ v: String) -> some View {
        GridRow { Text(k).foregroundStyle(.secondary); Text(v).lineLimit(3) }
    }
}

private struct Thumb: View {
    let data: Data?
    let side: CGFloat
    var body: some View {
        Group {
            if let d = data, let img = NSImage(data: d) {
                Image(nsImage: img).resizable().interpolation(.high).scaledToFit()
            } else {
                Image(systemName: "hexagon").font(.system(size: side * 0.4)).foregroundStyle(.tertiary)
            }
        }
        .frame(width: side, height: side)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 6))   // PubChem depictions are drawn on white
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
