import SwiftUI
import MolCore

/// STABLE WRAPPER: the main window only ever uses `MoleculeViewport(editor:)`.
/// Lead 4 swaps the fallback SceneKit implementation for MolRender here (one file).
struct MoleculeViewport: View {
    @ObservedObject var editor: EditorModel
    @AppStorage(AppSettings.renderStyleKey) private var renderStyle = "ballAndStick"
    @AppStorage(AppSettings.backgroundColorKey) private var backgroundHex = "#1E1F24"
    @AppStorage(AppSettings.showLabelsKey) private var showLabels = false

    init(editor: EditorModel) { self.editor = editor }

    private var modeDisplacements: [Vec3]? {
        guard let i = editor.activeModeIndex, let modes = editor.result?.normalModes, modes.indices.contains(i) else { return nil }
        return modes[i].displacements
    }

    var body: some View {
        FallbackSceneView(
            molecule: editor.displayedMolecule,
            selection: editor.selection,
            selectedBond: editor.selectedBond,
            measurePicks: editor.measurePicks,
            modeDisplacements: modeDisplacements,
            amplitude: editor.vibrationAmplitude,
            style: ViewportStyle(renderStyle: renderStyle, backgroundHex: backgroundHex, showLabels: showLabels),
            onPick: { pick, mods in ViewportInteraction(editor: editor).handle(pick, modifiers: mods) }
        )
        .overlay(alignment: .topTrailing) {
            if editor.tool == .measure { MeasurePanel(editor: editor) }
        }
        .overlay {
            if editor.molecule.atoms.isEmpty && editor.result == nil {
                Text("Choose the Sketch tool and click to place atoms,\nor drop a structure file here.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary).allowsHitTesting(false)
            }
        }
    }
}
