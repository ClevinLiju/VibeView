import SwiftUI
import Charts
import MolCore

/// Tabs over a loaded calculation result. Only tabs with data are shown.
struct ResultsPanel: View {
    @ObservedObject var editor: EditorModel
    @StateObject private var tabBox = VMBox(ResultsTab.convergence)

    var body: some View {
        if let r = editor.result {
            let tabs = ResultsTab.available(for: r)
            if tabs.isEmpty {
                placeholder("This result has no energies, frames, modes or orbitals.")
            } else {
                VStack(spacing: 0) {
                    Picker("", selection: Binding(get: { tabs.contains(tabBox.value) ? tabBox.value : tabs[0] }, set: { tabBox.value = $0 })) {
                        ForEach(tabs) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().padding(8)
                    Divider()
                    Group {
                        switch tabs.contains(tabBox.value) ? tabBox.value : tabs[0] {
                        case .convergence: ConvergenceTab(editor: editor, result: r)
                        case .frames: FramesTab(editor: editor, result: r)
                        case .vibrations: VibrationsTab(editor: editor, result: r)
                        case .orbitals: OrbitalsTab(editor: editor, result: r)
                        case .excited: ExcitedStatesTab(result: r)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        } else {
            placeholder("No results loaded. Open a Gaussian output file or run a job.")
        }
    }

    private func placeholder(_ s: String) -> some View {
        Text(s).foregroundStyle(.secondary).multilineTextAlignment(.center).padding().frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

enum ResultsTab: String, CaseIterable, Identifiable {
    case convergence, frames, vibrations, orbitals, excited
    var id: String { rawValue }
    var title: String {
        switch self {
        case .convergence: "Convergence"; case .frames: "Frames"; case .vibrations: "Vibrations"
        case .orbitals: "Orbitals"; case .excited: "Excited States"
        }
    }
    static func available(for r: CalculationResult) -> [ResultsTab] {
        var t: [ResultsTab] = []
        if !r.energies.isEmpty { t.append(.convergence) }
        if !r.steps.isEmpty { t.append(.frames) }
        if !r.normalModes.isEmpty { t.append(.vibrations) }
        if !r.orbitals.isEmpty { t.append(.orbitals) }
        if !r.excitedStates.isEmpty { t.append(.excited) }
        return t
    }
}
