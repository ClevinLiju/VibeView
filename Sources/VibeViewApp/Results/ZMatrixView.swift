import SwiftUI
import AppKit
import MolCore
import MolIO
import MolBuild

// Z-Matrix tab (results panel, any document with atoms) and Structure ▸ From Z-Matrix….
// The table lists the atoms in a connectivity-following order (MolIO `ZMatrixTable`). Hovering a row marks the atom
// and its reference atoms in the viewport, clicking selects the atom, and editing a distance / angle / dihedral moves
// the structure as one undo step, moving the smaller side as the Gauge tool does (`GeometryEdit.set*MovingSmaller`).
// The text view shows the same Z-matrix as Gaussian (with or without variables) or ORCA `* int` input; it can be
// edited and applied (atom indices kept when the atoms match the table order) or opened as a new document.

enum ZMatrixField: String { case bond, angle, dihedral }

extension EditorModel {
    /// Set one internal coordinate of a Z-matrix row, moving the smaller side. Returns an error message or nil.
    @discardableResult
    func setZMatrixValue(_ row: ZMatrixTable.Row, _ field: ZMatrixField, to v: Double) -> String? {
        let n = molecule.atoms.count
        guard row.atoms.allSatisfy({ $0 < n }), v.isFinite else { return "That row no longer matches the structure." }
        switch field {
        case .bond:
            guard let a = row.bondAtom else { return "Row has no distance." }
            guard v > 0.3 else { return "Distance must be above 0.3 Å" }
            apply("Edit Z-Matrix Distance") { GeometryEdit.setDistanceMovingSmaller(&$0, a, row.atom, to: v) }
        case .angle:
            guard let a = row.bondAtom, let b = row.angleAtom else { return "Row has no angle." }
            guard v > 0, v <= 180 else { return "Angle must be between 0° and 180°" }
            apply("Edit Z-Matrix Angle") { GeometryEdit.setAngleMovingSmaller(&$0, b, a, row.atom, to: v) }
        case .dihedral:
            guard let a = row.bondAtom, let b = row.angleAtom, let c = row.dihedralAtom else { return "Row has no dihedral." }
            apply("Edit Z-Matrix Dihedral") { GeometryEdit.setDihedralMovingSmaller(&$0, c, b, a, row.atom, to: v) }
        }
        return nil
    }

    /// Apply Z-matrix text to this document (one undo step). Returns a status line.
    func applyZMatrixText(_ text: String, order: [Int]?) throws -> String {
        let parsed = try ZMatrixText.parse(text)
        let (m, mode) = ZMatrixText.apply(parsed, onto: molecule, order: order)
        replaceMolecule(m, actionName: mode == .positions ? "Edit Z-Matrix" : "Replace from Z-Matrix")
        return mode == .positions ? "Applied: \(m.atoms.count) atoms moved, indices kept"
                                  : "Replaced the structure: \(m.atoms.count) atoms from the Z-matrix"
    }

    static func openZMatrixAsNewDocument(_ text: String, title: String = "Z-Matrix") throws {
        var m = try ZMatrixText.parse(text).molecule
        if m.title.isEmpty { m.title = title }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("VibeView-ZMatrix", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(title.replacingOccurrences(of: "/", with: "-").prefix(60))-\(Int(Date().timeIntervalSince1970) % 100000).mol")
        try IOBridge.write(m, ext: "mol").write(to: url)
        DocumentOpener.open(url)
    }
}

struct ZMatrixView: View {
    @ObservedObject var editor: EditorModel
    @State private var showText: Bool
    @State private var style: ZMatrixTable.TextStyle

    init(editor: EditorModel, showText: Bool = false, style: ZMatrixTable.TextStyle = .gaussian) {
        self.editor = editor
        _showText = State(initialValue: showText)
        _style = State(initialValue: style)
    }
    @State private var draft: String? = nil
    @State private var message = ""
    @State private var hoveredRow: Int? = nil
    @State private var savedPicks: [Int]? = nil

    private var table: ZMatrixTable? { ZMatrixTable.make(editor.molecule) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("", selection: $showText) {
                    Text("Table").tag(false)
                    Text("Text").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 130)
                if showText {
                    Picker("Format", selection: $style) { ForEach(ZMatrixTable.TextStyle.allCases) { Text($0.title).tag($0) } }
                        .labelsHidden().frame(width: 170)
                }
                Spacer()
                if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            Divider()
            if let t = table {
                if showText { textPane(t) } else { tablePane(t) }
            } else {
                Text(editor.molecule.atoms.isEmpty ? "No atoms." : "The Z-matrix view is limited to \(ZMatrixTable.maxAtoms) atoms.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: style) { _, _ in draft = nil }
        .onDisappear { endHover() }
    }

    // MARK: table

    private func tablePane(_ t: ZMatrixTable) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                header
                ForEach(Array(t.rows.enumerated()), id: \.offset) { r, row in
                    rowView(t, r, row)
                        .background(rowBackground(r, row))
                        .contentShape(Rectangle())
                        .onHover { inside in inside ? beginHover(r, row) : (hoveredRow == r ? endHover() : ()) }
                        .onTapGesture { editor.selection = [row.atom]; editor.selectedBond = nil }
                }
            }
            .padding(.horizontal, 8).padding(.bottom, 6)
        }
    }

    private static let w = (row: CGFloat(34), atom: CGFloat(56), ref: CGFloat(52), val: CGFloat(86))

    private var header: some View {
        HStack(spacing: 4) {
            Text("#").frame(width: Self.w.row, alignment: .trailing)
            Text("Atom").frame(width: Self.w.atom, alignment: .leading)
            Text("Bond to").frame(width: Self.w.ref, alignment: .leading)
            Text("Distance Å").frame(width: Self.w.val, alignment: .trailing)
            Text("Angle to").frame(width: Self.w.ref, alignment: .leading)
            Text("Angle °").frame(width: Self.w.val, alignment: .trailing)
            Text("Dihedral to").frame(width: Self.w.ref + 10, alignment: .leading)
            Text("Dihedral °").frame(width: Self.w.val, alignment: .trailing)
        }
        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        .padding(.vertical, 4)
    }

    private func atomName(_ i: Int?) -> String {
        guard let i, editor.molecule.atoms.indices.contains(i) else { return "" }
        return Elements.symbol(editor.molecule.atoms[i].atomicNumber) + "\(i + 1)"
    }

    private func rowView(_ t: ZMatrixTable, _ r: Int, _ row: ZMatrixTable.Row) -> some View {
        HStack(spacing: 4) {
            Text("\(r + 1)").foregroundStyle(.secondary).frame(width: Self.w.row, alignment: .trailing)
            Text(atomName(row.atom)).fontWeight(.semibold).frame(width: Self.w.atom, alignment: .leading)
            Text(atomName(row.bondAtom)).foregroundStyle(row.bonded || row.bondAtom == nil ? Color.primary : Color.orange)
                .frame(width: Self.w.ref, alignment: .leading)
                .help(row.bondAtom != nil && !row.bonded ? "Not a bond: the reference atom is not bonded to this atom" : "")
            ValueCell(value: row.bond, format: "%.4f", key: "\(row.bond ?? 0)") { v in commit(row, .bond, v) }
                .frame(width: Self.w.val)
            Text(atomName(row.angleAtom)).frame(width: Self.w.ref, alignment: .leading)
            ValueCell(value: row.angle, format: "%.2f", key: "\(row.angle ?? 0)") { v in commit(row, .angle, v) }
                .frame(width: Self.w.val)
            Text(atomName(row.dihedralAtom)).frame(width: Self.w.ref + 10, alignment: .leading)
            ValueCell(value: row.dihedral, format: "%.2f", key: "\(row.dihedral ?? 0)") { v in commit(row, .dihedral, v) }
                .frame(width: Self.w.val)
        }
        .font(.system(.callout, design: .monospaced))
        .padding(.vertical, 2)
    }

    private func rowBackground(_ r: Int, _ row: ZMatrixTable.Row) -> some View {
        let sel = editor.selection.contains(row.atom)
        return Rectangle().fill(sel ? Color.accentColor.opacity(0.22) : (hoveredRow == r ? Color.accentColor.opacity(0.1) : (r % 2 == 1 ? Color.secondary.opacity(0.05) : .clear)))
    }

    private func commit(_ row: ZMatrixTable.Row, _ f: ZMatrixField, _ v: Double) {
        if let e = editor.setZMatrixValue(row, f, to: v) { message = e; NSSound.beep() } else { message = "" }
    }

    /// Marks the row's atom and its reference atoms with the Gauge pick markers while hovered.
    private func beginHover(_ r: Int, _ row: ZMatrixTable.Row) {
        if savedPicks == nil { savedPicks = editor.measurePicks }
        hoveredRow = r
        editor.measurePicks = row.atoms
    }
    private func endHover() {
        hoveredRow = nil
        if let s = savedPicks { editor.measurePicks = s.filter { $0 < editor.molecule.atoms.count }; savedPicks = nil }
    }

    // MARK: text

    private func textPane(_ t: ZMatrixTable) -> some View {
        let generated = t.text(style)
        return VStack(alignment: .leading, spacing: 6) {
            PlainTextEditor(text: Binding(get: { draft ?? generated }, set: { draft = $0 == generated ? nil : $0 }))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(draft != nil ? Color.orange.opacity(0.7) : Color.secondary.opacity(0.25)))
            HStack {
                if draft != nil {
                    Label("Edited", systemImage: "pencil.circle.fill").font(.caption).foregroundStyle(.orange)
                    Button("Revert") { draft = nil }
                }
                Spacer()
                Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(draft ?? generated, forType: .string) }
                Button("Open as New Document") {
                    do { try EditorModel.openZMatrixAsNewDocument(draft ?? generated, title: editor.molecule.title.isEmpty ? "Z-Matrix" : editor.molecule.title) }
                    catch { message = error.localizedDescription }
                }
                Button("Apply") {
                    do { message = try editor.applyZMatrixText(draft ?? generated, order: t.order); draft = nil }
                    catch { message = error.localizedDescription; NSSound.beep() }
                }
                .disabled(draft == nil)
                .help("Rebuild the structure from this Z-matrix; atom numbers are kept when the atoms match the table order")
            }
        }
        .padding(8)
    }
}

/// A number that edits in place: shows the value, commits a typed value on Return.
private struct ValueCell: View {
    let value: Double?
    let format: String
    let key: String
    let onCommit: (Double) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        if let v = value {
            TextField("", text: $text)
                .textFieldStyle(.plain).multilineTextAlignment(.trailing)
                .focused($focused)
                .onAppear { text = String(format: format, v) }
                .onChange(of: key) { _, _ in if !focused { text = String(format: format, v) } }
                .onChange(of: focused) { _, f in if !f { text = String(format: format, v) } }
                .onSubmit {
                    if let d = Double(text.trimmingCharacters(in: .whitespaces)), abs(d - v) > 1e-9 { onCommit(d) }
                    else { text = String(format: format, v) }
                }
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: .textBackgroundColor).opacity(0.6)))
                .help("Type a new value and press Return; the smaller side of the structure moves")
        } else {
            Text("").frame(maxWidth: .infinity)
        }
    }
}

/// Structure ▸ From Z-Matrix…: paste a Gaussian / ORCA Z-matrix and replace the structure or open it in a new window.
struct FromZMatrixSheet: View {
    @ObservedObject var editor: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State var text: String = FromZMatrixSheet.example
    @State private var message = ""

    static let example = """
    0 1
    O
    H  1  0.96
    H  1  0.96  2  104.5
    """

    private var preview: Result<ZMatrixText.Parsed, Error> { Result { try ZMatrixText.parse(text) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("From Z-Matrix").font(.headline)
            Text("Paste a Gaussian Z-matrix (optionally with a “charge multiplicity” line and a variables section), a whole Gaussian or ORCA input, or ORCA “* int” rows.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            PlainTextEditor(text: $text)
                .frame(minHeight: 220)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25)))
            switch preview {
            case .success(let p):
                let f = Dictionary(p.molecule.atoms.map { ($0.atomicNumber, 1) }, uniquingKeysWith: +)
                let formula = f.keys.sorted { ($0 == 6 ? 0 : $0 == 1 ? 1 : 2, $0) < ($1 == 6 ? 0 : $1 == 1 ? 1 : 2, $1) }
                    .map { Elements.symbol($0) + (f[$0]! > 1 ? "\(f[$0]!)" : "") }.joined()
                Label("\(p.molecule.atoms.count) atoms (\(formula)), charge \(p.molecule.charge), multiplicity \(p.molecule.multiplicity)"
                      + (p.dummyCount > 0 ? ", \(p.dummyCount) dummy atoms dropped" : ""), systemImage: "checkmark.circle")
                    .foregroundStyle(.green).font(.callout)
            case .failure(let e):
                Label(e.localizedDescription, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout)
            }
            HStack {
                if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Open as New Document") {
                    do { try EditorModel.openZMatrixAsNewDocument(text); dismiss() } catch { message = error.localizedDescription }
                }
                .disabled((try? preview.get()) == nil)
                Button(editor.molecule.atoms.isEmpty ? "Build" : "Replace Structure") {
                    do {
                        let p = try preview.get()
                        var m = p.molecule
                        if !p.chargeGiven { m.charge = editor.molecule.charge; m.multiplicity = editor.molecule.multiplicity }
                        m.title = editor.molecule.title
                        editor.replaceMolecule(m, actionName: "Build from Z-Matrix")
                        editor.statusMessage = "Built \(m.atoms.count) atoms from the Z-matrix"
                        dismiss()
                    } catch { message = error.localizedDescription }
                }
                .keyboardShortcut(.defaultAction)
                .disabled((try? preview.get()) == nil)
            }
        }
        .padding()
        .frame(minWidth: 560, minHeight: 380)
    }
}
