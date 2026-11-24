import SwiftUI
import MolCore

/// Labelled rows describing how a calculation was set up, shared by the viewport card and the
/// Summary tab. Rows the output did not state are omitted.
struct CalculationInfoRows {
    let result: CalculationResult

    var info: CalculationInfo? { result.extras?.info }

    var rows: [(String, String)] {
        guard let i = info else { return [] }
        var r: [(String, String)] = []
        func add(_ k: String, _ v: String?) { if let v, !v.isEmpty { r.append((k, v)) } }
        add("Program", programLabel)
        add("Job", i.jobTypes.isEmpty ? nil : i.jobTypes.joined(separator: " → "))
        add("Method", methodLabel(i))
        add("Basis set", i.methodFamily == "Composite" ? "built into \(i.method ?? "method")" : i.basisSet)
        add("Auxiliary basis", i.auxiliaryBasis)
        add("Dispersion", i.dispersion)
        add("Solvation", i.solvationLabel)
        add("Reference", i.reference)
        if let c = i.charge, let m = i.multiplicity { add("Charge / mult.", "\(c) / \(m) (\(Self.spinName(m)))") }
        add("Electrons", i.electrons.map(String.init))
        add("Basis functions", i.basisFunctions.map(String.init))
        add("Approximations", i.approximations.isEmpty ? nil : i.approximations.joined(separator: ", "))
        add("Grid", i.integrationGrid)
        add("Resources", resourcesLabel(i))
        add("Wall time", i.wallTimeSeconds.map(Self.duration))
        return r
    }

    var programLabel: String? {
        guard let p = result.extras?.program else { return nil }
        let name = ["orca": "ORCA", "gaussian": "Gaussian", "qchem": "Q-Chem", "xtb": "xtb"][p] ?? p
        return [name, result.extras?.programVersion].compactMap { $0 }.joined(separator: " ")
    }

    /// One line for the collapsed card: "B3LYP/def2-SVP · SMD (water) · ORCA 6.1.1".
    var headline: String? {
        guard let i = info else { return nil }
        var parts: [String] = []
        if let lot = i.levelOfTheory { parts.append(lot) }
        if i.solvationModel != nil { parts.append(i.solvationLabel) }
        if let p = programLabel { parts.append(p) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func methodLabel(_ i: CalculationInfo) -> String? {
        guard let m = i.method else { return nil }
        var s = m
        if i.methodFamily == "DFT", let x = i.exchangeFunctional {
            let parts = [x, i.correlationFunctional].compactMap { $0 }.joined(separator: " + ")
            s += " (\(parts)"
            if let h = i.exactExchange { s += String(format: ", %.0f%% HF exchange", h * 100) }
            s += ")"
        } else if let fam = i.methodFamily, fam != "HF", fam.lowercased() != m.lowercased() {
            s += " (\(fam))"
        }
        return s
    }

    private func resourcesLabel(_ i: CalculationInfo) -> String? {
        var parts: [String] = []
        if let c = i.cores { parts.append(c == 1 ? "1 core" : "\(c) cores") }
        if let m = i.memoryPerCoreMB { parts.append("\(m) MB/core") }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    static func spinName(_ m: Int) -> String {
        ["singlet", "doublet", "triplet", "quartet", "quintet", "sextet"].indices.contains(m - 1)
            ? ["singlet", "doublet", "triplet", "quartet", "quintet", "sextet"][m - 1] : "2S+1 = \(m)"
    }

    static func duration(_ s: Double) -> String {
        if s < 60 { return String(format: "%.1f s", s) }
        let t = Int(s.rounded())
        let (h, m, sec) = (t / 3600, (t % 3600) / 60, t % 60)
        return h > 0 ? "\(h) h \(m) min" : "\(m) min \(sec) s"
    }
}

/// Floating card in the 3D viewport: one-line level of theory, expandable to the full setup.
/// Appears automatically when a loaded result carries calculation info.
struct CalculationInfoCard: View {
    let result: CalculationResult
    @AppStorage("viewport.calcInfo.expanded") private var expanded = false
    @AppStorage("viewport.calcInfo.visible") private var visible = true

    var body: some View {
        let model = CalculationInfoRows(result: result)
        if visible, let headline = model.headline {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "atom")
                        .foregroundStyle(.secondary)
                    Text(headline)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button {
                        withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
                    } label: {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    }
                    .buttonStyle(.borderless)
                    .help(expanded ? "Hide calculation details" : "Show calculation details")
                    Button { visible = false } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .help("Hide (View ▸ Calculation Info to show again)")
                }
                if expanded {
                    Divider()
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                        ForEach(Array(model.rows.enumerated()), id: \.offset) { _, row in
                            GridRow(alignment: .firstTextBaseline) {
                                Text(row.0).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                                Text(row.1).textSelection(.enabled).monospacedDigit()
                            }
                        }
                    }
                    .font(.caption)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(maxWidth: expanded ? 420 : 520, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}
