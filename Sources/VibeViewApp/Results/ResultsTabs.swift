import SwiftUI
import MolCore

/// Always-present overview of a result.
struct SummaryView: View {
    let result: CalculationResult

    var body: some View {
        ScrollView {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                row("Route", result.routeSection.isEmpty ? "–" : result.routeSection)
                row("Termination") {
                    TerminationBadge(normal: result.normalTermination)
                }
                if let e = result.energies.last {
                    row("Final energy", String(format: "%.8f Ha", e))
                    row("", String(format: "%.2f kcal/mol", e * SpectrumMath.hartreeToKcal))
                }
                if let d = result.dipole {
                    row("Dipole", String(format: "%.3f D", (d.x * d.x + d.y * d.y + d.z * d.z).squareRoot()))
                }
                row("Steps", "\(max(result.steps.count, result.energies.count))")
                row("Normal modes", "\(result.normalModes.count)")
                row("Orbitals", "\(result.orbitals.count)")
                row("Excited states", "\(result.excitedStates.count)")
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        row(k) { Text(v).textSelection(.enabled).monospacedDigit() }
    }

    private func row<V: View>(_ k: String, @ViewBuilder _ v: () -> V) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(k).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            v()
        }
    }
}

struct TerminationBadge: View {
    let normal: Bool
    var body: some View {
        Label(normal ? "Normal termination" : "Not terminated normally",
              systemImage: normal ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .font(.caption.weight(.medium))
            .foregroundStyle(normal ? Color.green : Color.orange)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background((normal ? Color.green : Color.orange).opacity(0.12), in: Capsule())
    }
}
