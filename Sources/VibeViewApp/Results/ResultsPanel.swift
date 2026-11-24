import SwiftUI
import MolCore

enum ResultsTab: String, CaseIterable, Identifiable {
    case trajectory, vibrations, orbitals, uvvis, summary
    var id: String { rawValue }
    var title: String {
        switch self {
        case .trajectory: "Trajectory"; case .vibrations: "Vibrations"; case .orbitals: "Orbitals"
        case .uvvis: "UV-Vis"; case .summary: "Summary"
        }
    }
    static func available(for r: CalculationResult) -> [ResultsTab] {
        var t: [ResultsTab] = []
        if r.steps.count > 1 || r.energies.count > 1 { t.append(.trajectory) }
        if !r.normalModes.isEmpty { t.append(.vibrations) }
        if !r.orbitals.isEmpty { t.append(.orbitals) }
        if !r.excitedStates.isEmpty { t.append(.uvvis) }
        t.append(.summary)
        return t
    }
}

/// Tabs over a loaded calculation result. Only tabs with data are shown.
struct ResultsPanel: View {
    @ObservedObject var editor: EditorModel
    @State private var tab: ResultsTab = .trajectory

    var body: some View {
        if let r = editor.result {
            let tabs = ResultsTab.available(for: r)
            let current = tabs.contains(tab) ? tab : tabs[0]
            VStack(spacing: 0) {
                Picker("Results", selection: Binding(get: { current }, set: { tab = $0 })) {
                    ForEach(tabs) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                .padding(.horizontal, 10).padding(.vertical, 7)
                Divider()
                Group {
                    switch current {
                    case .trajectory: TrajectoryView(editor: editor, result: r)
                    case .vibrations: VibrationsView(editor: editor, result: r)
                    case .orbitals: OrbitalsView(editor: editor, result: r)
                    case .uvvis: UVVisView(result: r)
                    case .summary: SummaryView(result: r)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            Text("No results loaded. Open an output file or run a job.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
