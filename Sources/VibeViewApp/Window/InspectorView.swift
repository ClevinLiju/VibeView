import SwiftUI
import MolCore
import MolRender

struct InspectorView: View {
    @ObservedObject var editor: EditorModel

    var body: some View {
        let m = editor.molecule
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let b = editor.selectedBond, m.bond(between: b.a, and: b.b) != nil {
                    BondSection(editor: editor, a: b.a, b: b.b)
                } else if editor.selection.count == 1, let i = editor.selection.first, m.atoms.indices.contains(i) {
                    AtomSection(editor: editor, index: i)
                } else if editor.selection.count == 2, let a = editor.selection.min(), let b = editor.selection.max(),
                          m.atoms.indices.contains(b), m.bond(between: a, and: b) != nil {
                    BondSection(editor: editor, a: a, b: b)
                } else if editor.selection.count > 1 {
                    MultiSection(editor: editor)
                } else {
                    SummarySection(editor: editor)
                }
                if !m.atoms.isEmpty {
                    Divider().padding(.vertical, 4)
                    SymmetrySection(editor: editor)
                }
                Divider().padding(.vertical, 4)
                DisplaySection(editor: editor)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct NumberField: View {
    let label: String
    let value: Double
    var format = "%.5f"
    let commit: (Double) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool
    var body: some View {
        HStack {
            Text(label).frame(width: 24, alignment: .leading)
            TextField("", text: $text).textFieldStyle(.roundedBorder).focused($focused)
                .onSubmit { if let v = Double(text) { commit(v) }; text = String(format: format, value) }
        }
        .onAppear { text = String(format: format, value) }
        .onChange(of: value) { _, v in if !focused { text = String(format: format, v) } }
    }
}

private struct AtomSection: View {
    @ObservedObject var editor: EditorModel
    let index: Int
    var body: some View {
        let m = editor.molecule
        let a = m.atoms[index]
        Text("Atom \(index + 1)").font(.headline)
        Picker("Element", selection: Binding(get: { a.atomicNumber }, set: { z in
            editor.apply("Change Element") { BuildOps.setElement(&$0, atom: index, to: z) }
        })) {
            ForEach(1...118, id: \.self) { z in Text("\(ElementInfo.symbol(z))  \(z)").tag(z) }
            if a.atomicNumber == 0 { Text("X").tag(0) }
        }
        GroupBox("Position (Å)") {
            VStack {
                ForEach(0..<3, id: \.self) { k in
                    NumberField(label: ["x", "y", "z"][k], value: a.position[k]) { v in
                        editor.apply("Move Atom") { $0.atoms[index].position[k] = v }
                    }
                }
            }.padding(4)
        }
        LabeledContent("Hybridization", value: BuildOps.hybridization(m, atom: index))
        LabeledContent("Neighbours", value: "\(m.neighbors(of: index).count)")
        LabeledContent("Partial charge", value: String(format: "%+.4f", a.charge))
    }
}

private struct BondSection: View {
    @ObservedObject var editor: EditorModel
    let a: Int, b: Int
    var body: some View {
        let m = editor.molecule
        let order = m.bond(between: a, and: b)?.order ?? .single
        Text("Bond \(a + 1) – \(b + 1)").font(.headline)
        NumberField(label: "d", value: m.distance(a, b), format: "%.4f") { v in
            guard v > 0.2 else { return }
            editor.apply("Set Distance") { $0.setDistance(a, b, to: v) }
        }
        Text("Length in Å").font(.caption).foregroundStyle(.secondary)
        Picker("Order", selection: Binding(get: { order }, set: { o in
            editor.apply("Change Bond Order") { BuildOps.setBondOrder(&$0, a, b, o) }
            editor.selectedBond = editor.molecule.bond(between: a, and: b)
        })) {
            Text("Single").tag(BondOrder.single)
            Text("Aromatic").tag(BondOrder.aromatic)
            Text("Double").tag(BondOrder.double)
            Text("Triple").tag(BondOrder.triple)
        }
    }
}

private struct MultiSection: View {
    @ObservedObject var editor: EditorModel
    var body: some View {
        let m = editor.molecule
        let pts = editor.selection.filter { m.atoms.indices.contains($0) }.map { m.atoms[$0].position }
        let c = Geometry.centroid(pts)
        Text("\(editor.selection.count) atoms selected").font(.headline)
        LabeledContent("Centroid x", value: String(format: "%.4f", c.x))
        LabeledContent("Centroid y", value: String(format: "%.4f", c.y))
        LabeledContent("Centroid z", value: String(format: "%.4f", c.z))
        Button("Delete Selection") { editor.deleteSelection() }
    }
}

private struct SummarySection: View {
    @ObservedObject var editor: EditorModel
    var body: some View {
        let m = editor.molecule
        Text("Molecule").font(.headline)
        TextField("Title", text: Binding(get: { m.title }, set: { t in editor.apply("Edit Title") { $0.title = t } }))
            .textFieldStyle(.roundedBorder)
        LabeledContent("Formula", value: hillFormula(m))
        LabeledContent("Atoms", value: "\(m.atoms.count)")
        LabeledContent("Bonds", value: "\(m.bonds.count)")
        Stepper("Charge: \(m.charge)", value: Binding(get: { m.charge }, set: { v in editor.apply("Set Charge") { $0.charge = v } }), in: -10...10)
        Stepper("Multiplicity: \(m.multiplicity)", value: Binding(get: { m.multiplicity }, set: { v in editor.apply("Set Multiplicity") { $0.multiplicity = v } }), in: 1...10)
    }
}

private struct DisplaySection: View {
    @ObservedObject var editor: EditorModel
    var body: some View {
        Text("Display").font(.headline)
        Picker("Style", selection: Binding(get: { editor.renderOptions.style }, set: { editor.setStyle($0) })) {
            ForEach(RenderStyle.allCases, id: \.self) { s in Image(systemName: s.symbol).help(s.title).tag(s) }
        }
        .pickerStyle(.segmented)
        Picker("Labels", selection: Binding(get: { editor.renderOptions.labelMode }, set: { editor.setLabels($0) })) {
            ForEach(LabelMode.menuCases, id: \.self) { Text($0.title).tag($0) }
        }
        Picker("Material", selection: Binding(get: { editor.renderOptions.material }, set: { editor.setMaterial($0) })) {
            ForEach(MaterialPreset.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
        }
        Toggle("Hydrogens", isOn: Binding(get: { editor.renderOptions.showHydrogens }, set: { _ in editor.toggleHydrogens() }))
        Toggle("Bond orders", isOn: $editor.renderOptions.showBondOrders)
        Toggle("Ambient occlusion", isOn: Binding(get: { editor.renderOptions.ambientOcclusion }, set: { _ in editor.toggleAmbientOcclusion() }))
        Toggle("Depth cueing", isOn: Binding(get: { editor.renderOptions.depthCueing }, set: { _ in editor.toggleDepthCue() }))
        Toggle("Orthographic", isOn: Binding(get: { editor.renderOptions.projection == .orthographic }, set: { _ in editor.toggleProjection() }))
        LabeledContent("Atom size") {
            Slider(value: $editor.renderOptions.atomScale, in: 0.12...0.5)
        }
        Picker("Aromatic", selection: $editor.renderOptions.aromaticStyle) {
            Text("Kekulé").tag(AromaticBondStyle.kekule)
            Text("Dashed").tag(AromaticBondStyle.dashed)
            Text("Ring").tag(AromaticBondStyle.circle)
        }
        .help("How aromatic bonds are drawn")
        Toggle("Axes", isOn: $editor.renderOptions.showAxes)
        Toggle("Scale bar", isOn: $editor.renderOptions.showScaleBar)
        Toggle("Hydrogen bonds", isOn: $editor.renderOptions.showHydrogenBonds)
            .help("Dashed lines for X–H···Y contacts (H···Y up to \(String(format: "%.1f", editor.renderOptions.hydrogenBondMaxDistance)) Å)")
        Toggle("Clipping slab", isOn: Binding(get: { editor.renderOptions.slabNear != nil },
                                              set: { on in
                                                  let r = max(editor.viewport.renderer.boundingSphere().radius, 2)
                                                  editor.renderOptions.slabNear = on ? r * 0.5 : nil
                                                  editor.renderOptions.slabFar = on ? r * 0.5 : nil }))
            .help("Hide everything outside a slab around the view center")
        if let near = editor.renderOptions.slabNear {
            let r = max(editor.viewport.renderer.boundingSphere().radius, 2) * 1.2
            LabeledContent("Slab") {
                Slider(value: Binding(get: { near }, set: { editor.renderOptions.slabNear = $0; editor.renderOptions.slabFar = $0 }),
                       in: 0.3...max(r, 0.6))
            }
            .help(String(format: "Half-thickness %.1f Å in front of and behind the view center", near))
        }
    }
}

/// Point group of the current structure, with a one-click symmetrize.
private struct SymmetrySection: View {
    @ObservedObject var editor: EditorModel
    @StateObject private var state = StateBox<(group: String, order: Int, atoms: Int)?>(nil)
    @AppStorage("vibeview.symmetry.tolerance") private var tolerance = 0.1

    var body: some View {
        Text("Symmetry").font(.headline)
        LabeledContent("Point group") {
            if let g = state.value { Text(g.group).font(.body.weight(.semibold)) + Text("  order \(g.order)").foregroundStyle(.secondary) }
            else { Text(editor.molecule.atoms.count > 400 ? "large structure" : "…").foregroundStyle(.secondary) }
        }
        Picker("Tolerance", selection: $tolerance) {
            Text("Tight 0.01 Å").tag(0.01); Text("Normal 0.1 Å").tag(0.1); Text("Loose 0.3 Å").tag(0.3)
        }
        Button("Symmetrize") {
            let t = tolerance
            editor.apply("Symmetrize") { $0 = Symmetry.symmetrize($0, tolerance: t) }
            editor.statusMessage = "Symmetrized to \(Symmetry.detect(editor.molecule, tolerance: 0.01).schoenflies)"
        }
        .help("Snap the coordinates to the exact point group found at this tolerance")
        .task(id: TaskKey(molecule: editor.molecule, tolerance: tolerance)) {
            let m = editor.molecule, t = tolerance
            guard m.atoms.count <= 400 else { state.value = nil; return }
            try? await Task.sleep(for: .milliseconds(150))
            if Task.isCancelled { return }
            let r = await Task.detached(priority: .utility) { Symmetry.detect(m, tolerance: t) }.value
            state.value = (r.schoenflies, r.order, m.atoms.count)
        }
    }

    private struct TaskKey: Equatable { let molecule: Molecule; let tolerance: Double }
}
