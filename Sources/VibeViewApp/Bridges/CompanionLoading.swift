import Foundation
import MolCore
import MolIO
import MolCompute

extension EditorModel {
    /// Look for same-named companion files next to `url` (MolIO `loadWithCompanions`) and merge what they add:
    /// a wavefunction (orbital surfaces), normal modes, optimization frames, orbital energies. The primary file wins.
    func loadCompanions(for url: URL, allowFormchk: Bool = true) {
        let formchkOn = allowFormchk && JobQueue.gaussianFormchkEnabled
        let gaussian = JobQueue.shared.resolveExecutable(.gaussian)
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
            // A Gaussian log with `<stem>.chk` but no up-to-date `<stem>.fchk`: convert it, then load the fchk.
            guard formchkOn, file.wavefunction == nil,
                  let chk = companions.first(where: { $0.role == .binary && $0.url.pathExtension.lowercased() == "chk" })?.url,
                  GaussianFormchk.needsConversion(chk: chk) else { return }
            guard let tool = GaussianFormchk.locate(gaussian: gaussian) else {
                await MainActor.run { self.statusMessage = "\(chk.lastPathComponent): formchk not found (set GAUSS_EXEDIR or add it to PATH) \u{2014} run formchk to view orbitals" }
                return
            }
            await MainActor.run { self.busyMessage = "formchk \(chk.lastPathComponent)\u{2026}" }
            do {
                let o = try await GaussianFormchk.convert(chk: chk, executable: tool)
                await MainActor.run {
                    self.busyMessage = nil
                    self.statusMessage = "Converted \(chk.lastPathComponent) to \(o.url.lastPathComponent)"
                    self.loadCompanions(for: url, allowFormchk: false)
                }
            } catch {
                await MainActor.run { self.busyMessage = nil; self.statusMessage = "formchk failed: \(error.localizedDescription)" }
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
                e.steps = IOBridge.preparedSteps(e.steps)
                result = e
                showResults = true
            }
            return
        }
        var changed = false
        if r.normalModes.isEmpty && !extra.normalModes.isEmpty { r.normalModes = extra.normalModes; changed = true }
        if r.orbitals.isEmpty && !extra.orbitals.isEmpty { r.orbitals = extra.orbitals; changed = true }
        if r.steps.count <= 1 && extra.steps.count > 1 { r.steps = IOBridge.preparedSteps(extra.steps); changed = true }
        if changed { result = r }
    }

    /// One-line summary for the info card ("Also loaded: job.molden.input, job.hess").
    var companionSummary: String? {
        let used = companions.filter(\.used).map(\.fileName)
        return used.isEmpty ? nil : "Also loaded: " + used.joined(separator: ", ")
    }
}
