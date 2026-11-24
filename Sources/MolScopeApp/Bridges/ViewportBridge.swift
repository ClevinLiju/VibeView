import SwiftUI
import AppKit
import Combine
import SceneKit
import MolCore
import MolRender
import MolAnalysis

/// Keeps one `MoleculeRenderer` in sync with an `EditorModel` (molecule, frames, selection, measurements,
/// vibrations, render options) and routes viewport clicks to the active tool.
@MainActor
final class ViewportSync {
    let renderer: MoleculeRenderer
    private weak var editor: EditorModel?
    private var bag: Set<AnyCancellable> = []
    private var shownMolecule = Molecule()
    private var pushingSelection = false
    private var didFit = false
    private var fittedRadius = 1.0

    init(editor: EditorModel) {
        self.editor = editor
        renderer = MoleculeRenderer(molecule: Molecule(), options: editor.renderOptions)
        renderer.onSelectionChange = { [weak self] sel in
            guard let self, let ed = self.editor, !self.pushingSelection, ed.selection != sel else { return }
            ed.selection = sel
            if sel.count != 2 { ed.selectedBond = nil }
        }
        renderer.onPick = { [weak self] ev in self?.handlePick(ev) }
        renderer.onBoxSelect = { [weak self] sel, _ in self?.editor?.selection = sel }

        // Structure: either the browsed frame or the editable molecule.
        // @Published fires in willSet, so use the delivered values rather than reading the editor back.
        Publishers.CombineLatest3(editor.$molecule, editor.$frameIndex, editor.$result)
            .sink { [weak self] m, f, r in
                let shown = (f.flatMap { i in r?.steps.indices.contains(i) == true ? r?.steps[i] : nil }) ?? m
                self?.refreshStructure(shown, browsing: f != nil)
            }
            .store(in: &bag)
        editor.$selection.removeDuplicates().sink { [weak self] sel in
            guard let self else { return }
            self.pushingSelection = true
            self.renderer.selection = sel.filter { $0 < self.shownMolecule.atoms.count }
            self.pushingSelection = false
        }.store(in: &bag)
        Publishers.CombineLatest(editor.$renderOptions.removeDuplicates(), editor.$measurePicks.removeDuplicates())
            .dropFirst()
            .sink { [weak self] o, p in self?.applyOptions(o, picks: p) }
            .store(in: &bag)
        editor.$tool.sink { [weak self] t in self?.renderer.autoSelect = (t == .select || t == .rotate) }.store(in: &bag)
        Publishers.CombineLatest3(editor.$activeModeIndex, editor.$vibrationAmplitude, editor.$showDisplacementArrows)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshVibration() }
            .store(in: &bag)
        Publishers.CombineLatest(editor.$activeOrbitalIndex, editor.$orbitalIsovalue.removeDuplicates())
            .debounce(for: .milliseconds(120), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.editor?.refreshOrbitalSurface() }
            .store(in: &bag)
    }

    // MARK: Sync

    private func refreshStructure(_ m: Molecule, browsing: Bool) {
        guard let ed = editor else { return }
        let sameTopology = m.atoms.count == shownMolecule.atoms.count && m.bonds == shownMolecule.bonds
            && zip(m.atoms, shownMolecule.atoms).allSatisfy { $0.atomicNumber == $1.atomicNumber && $0.charge == $1.charge }
        if sameTopology && !m.atoms.isEmpty {
            if m.atoms.map(\.position) != shownMolecule.atoms.map(\.position) { renderer.updatePositions(m.positions) }
        } else {
            let fit = !didFit || shownMolecule.atoms.isEmpty
            renderer.setMolecule(m, fitCamera: false)
            let sphere = renderer.boundingSphere()
            // Leave room to sketch around small structures; refit once the structure outgrows the view.
            let target = m.atoms.count <= 5 ? max(sphere.radius, 3.5) : sphere.radius
            if !m.atoms.isEmpty && ((fit) || sphere.radius > fittedRadius * 1.2) {
                renderer.camera.fit(center: sphere.center, radius: target, animated: didFit)
                didFit = true; fittedRadius = target
            }
        }
        shownMolecule = m
        applyOptions(ed.renderOptions, picks: browsing ? [] : ed.measurePicks)
    }

    private func applyOptions(_ o: RenderOptions, picks: [Int]) {
        var o = o
        let p = picks.filter { $0 < shownMolecule.atoms.count }
        switch p.count {
        case 2: o.measurements = [.distance(p[0], p[1])]
        case 3: o.measurements = [.angle(p[0], p[1], p[2])]
        case 4: o.measurements = [.dihedral(p[0], p[1], p[2], p[3])]
        default: o.measurements = []
        }
        if renderer.options != o { renderer.options = o }
    }

    private func refreshVibration() {
        guard let ed = editor else { return }
        renderer.vibration.amplitude = ed.vibrationAmplitude
        if let i = ed.activeModeIndex, let modes = ed.result?.normalModes, modes.indices.contains(i),
           modes[i].displacements.count == shownMolecule.atoms.count {
            if renderer.vibration.mode != modes[i] || !renderer.vibration.isPlaying { renderer.vibration.play(modes[i]) }
            renderer.showDisplacementArrows(ed.showDisplacementArrows ? modes[i] : nil, scale: 1.2 + 2 * ed.vibrationAmplitude,
                                            color: RGBA(0.2, 0.75, 0.35))
        } else {
            if renderer.vibration.isPlaying { renderer.vibration.stop() }
            renderer.showDisplacementArrows(nil)
        }
    }

    // MARK: Picking → tools

    private func handlePick(_ ev: PickEvent) {
        guard let ed = editor else { return }
        let m = shownMolecule
        var target = ViewportPick.empty(worldPoint(at: ev.location))
        switch ev.target {
        case .atom(let i): target = .atom(i)
        case .bond(let b) where m.bonds.indices.contains(b): target = .bond(m.bonds[b].a, m.bonds[b].b)
        default: break
        }
        if ed.tool == .select || ed.tool == .rotate {
            if case .bond(let a, let b) = target { ed.selectedBond = ed.displayedMolecule.bond(between: a, and: b) }
            else if case .empty = target { ed.selectedBond = nil }
            return   // the renderer's auto-select handles atom selection
        }
        ViewportInteraction(editor: ed).handle(target, modifiers: ev.modifiers)
    }

    /// The point under the cursor at the depth of the molecule's center (or the camera target).
    func worldPoint(at p: CGPoint) -> Vec3 {
        let center = shownMolecule.atoms.isEmpty ? renderer.camera.target : renderer.boundingSphere().center
        let proj = renderer.view.projectPoint(SCNVector3(center.x, center.y, center.z))
        let w = renderer.view.unprojectPoint(SCNVector3(p.x, p.y, proj.z))
        return Vec3(Double(w.x), Double(w.y), Double(w.z))
    }
}

/// What a click in the viewport hit, in editing terms.
enum ViewportPick {
    case atom(Int)
    case bond(Int, Int)
    case empty(Vec3)
}

/// STABLE WRAPPER: the main window only ever uses `MoleculeViewport(editor:)`.
struct MoleculeViewport: View {
    @ObservedObject var editor: EditorModel

    var body: some View {
        MoleculeSceneView(renderer: editor.viewport.renderer)
            .overlay(alignment: .topTrailing) {
                if editor.tool == .measure { MeasurePanel(editor: editor) }
            }
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 8) {
                    if let r = editor.result { CalculationInfoCard(result: r) }
                    if let f = editor.frameIndex, let n = editor.result?.steps.count, n > 1 {
                        Label("Frame \(f + 1) of \(n)", systemImage: "film.stack")
                            .font(.callout.monospacedDigit())
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(.regularMaterial, in: Capsule())
                    }
                }
                .padding(10)
            }
            .overlay {
                if editor.molecule.atoms.isEmpty && editor.result == nil { EmptyCanvasHint(editor: editor) }
            }
    }
}

private struct EmptyCanvasHint: View {
    @ObservedObject var editor: EditorModel
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "atom").font(.system(size: 44, weight: .thin)).foregroundStyle(.tertiary)
            Text("Start a structure").font(.title3.weight(.medium))
            Text("Pick the Sketch tool (⌘3) and click to place atoms, press ⌘K to search fragments,\nor drop a structure file here.")
                .multilineTextAlignment(.center).font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Sketch Carbon") { editor.payload = .element(6); editor.tool = .build }
                Button("Benzene Ring") { editor.payload = .fragment("benzene"); editor.tool = .build }
            }
            .controlSize(.regular)
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}
