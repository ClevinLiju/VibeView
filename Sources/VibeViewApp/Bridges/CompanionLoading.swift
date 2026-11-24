import Foundation
import MolCore
import MolIO

extension EditorModel {
    /// Look for same-named companion files next to `url` (MolIO `loadWithCompanions`) and merge what they add:
    /// a wavefunction (orbital surfaces), normal modes, optimization frames, orbital energies. The primary file wins.
    func loadCompanions(for url: URL) {
        Task.detached(priority: .utility) {
            guard let (file, companions) = try? MolecularFileLoader.loadWithCompanions(url: url) else { return }
            let used = companions.filter(\.used)
            await MainActor.run {
                self.companions = companions
                guard !used.isEmpty || companions.contains(where: { $0.role == .binary }) else { return }
                self.mergeCompanionData(file)
                if used.isEmpty, let tip = companions.first(where: { $0.role == .binary }) {
                    self.statusMessage = "\(tip.fileName): \(tip.note)"
                }
            }
        }
    }

    private func mergeCompanionData(_ file: LoadedMolecularFile) {
        if wavefunction == nil, let wf = file.wavefunction { wavefunction = wf }
        guard let extra = file.result else { return }
        guard var r = result else {
            // Only adopt a result whose geometry matches the open structure.
            if extra.steps.last.map({ $0.atoms.count == molecule.atoms.count }) ?? true {
                var e = extra
                e.steps = e.steps.map { IOBridge.prepared($0, perceiveOrders: false) }
                result = e
                showResults = true
            }
            return
        }
        var changed = false
        if r.normalModes.isEmpty && !extra.normalModes.isEmpty { r.normalModes = extra.normalModes; changed = true }
        if r.orbitals.isEmpty && !extra.orbitals.isEmpty { r.orbitals = extra.orbitals; changed = true }
        if r.steps.count <= 1 && extra.steps.count > 1 { r.steps = extra.steps.map { IOBridge.prepared($0, perceiveOrders: false) }; changed = true }
        if changed { result = r }
    }

    /// One-line summary for the info card ("Also loaded: job.molden.input, job.hess").
    var companionSummary: String? {
        let used = companions.filter(\.used).map(\.fileName)
        return used.isEmpty ? nil : "Also loaded: " + used.joined(separator: ", ")
    }
}
