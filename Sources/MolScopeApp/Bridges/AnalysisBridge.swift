import Foundation
import MolCore
import MolIO
import MolRender
import MolAnalysis

// INTEGRATION BRIDGE (Lead C): orbital surfaces via MolAnalysis (Lead D).

@MainActor
final class OrbitalSurfaceCache {
    static let shared = OrbitalSurfaceCache()
    private var grids: [String: VolumeGrid] = [:]   // key: object id + MO
    private var order: [String] = []
    var generation = 0

    func grid(_ key: String) -> VolumeGrid? { grids[key] }
    func store(_ key: String, _ g: VolumeGrid) {
        grids[key] = g; order.append(key)
        if order.count > 12 { grids[order.removeFirst()] = nil }
    }
}

extension EditorModel {
    /// Recompute (or clear) the isosurface for `activeOrbitalIndex` (1-based) at `orbitalIsovalue`.
    func refreshOrbitalSurface() {
        let r = viewport.renderer
        guard let mo = activeOrbitalIndex else {
            r.removeIsosurface(id: "orbital"); orbitalStatus = ""; return
        }
        let iso = orbitalIsovalue
        let cache = OrbitalSurfaceCache.shared
        cache.generation += 1
        let gen = cache.generation
        let spinBeta = result?.orbitals.first { $0.index == mo && $0.spin == .beta } != nil
            && result?.orbitals.first { $0.index == mo && $0.spin != .beta } == nil

        // 1. A cube file that contains this MO (or a single-grid cube).
        if let vols = result?.volumes, !vols.isEmpty {
            let g = vols["MO \(mo)"] ?? (vols.count == 1 ? vols.values.first : nil)
            if let g { show(grid: g, iso: iso, gen: gen, label: "MO \(mo)"); return }
        }
        // 2. Evaluate from the basis set + MO coefficients.
        guard let wf = wavefunction else {
            r.removeIsosurface(id: "orbital")
            orbitalStatus = "Open the formatted checkpoint (.fchk), Molden file or a cube file to draw orbital surfaces."
            return
        }
        guard mo >= 1, mo <= wf.alpha.orbitalCount else { orbitalStatus = "Orbital \(mo) is not in the wavefunction."; return }
        let key = "\(ObjectIdentifier(self).hashValue)-\(spinBeta ? "b" : "a")\(mo)"
        if let g = cache.grid(key) { show(grid: g, iso: iso, gen: gen, label: "MO \(mo)"); return }
        orbitalStatus = "Computing orbital \(mo)…"
        Task.detached(priority: .userInitiated) {
            let g = WavefunctionSurfaces.orbitalGrid(wf, mo: mo - 1, spin: spinBeta ? .beta : .alpha,
                                                     grid: WavefunctionSurfaces.defaultGrid(wf, spacing: 0.18, maxPoints: 1_500_000))
            await MainActor.run {
                cache.store(key, g)
                guard cache.generation == gen else { return }
                self.show(grid: g, iso: self.orbitalIsovalue, gen: gen, label: "MO \(mo)")
            }
        }
    }

    private func show(grid g: VolumeGrid, iso: Double, gen: Int, label: String) {
        Task.detached(priority: .userInitiated) {
            let lobes = MarchingCubes.orbitalLobes(grid: g, isovalue: iso)
            await MainActor.run {
                guard OrbitalSurfaceCache.shared.generation == gen else { return }
                var s = Isosurface(id: "orbital", meshes: lobes)
                s.opacity = 0.78
                self.viewport.renderer.setIsosurface(s)
                let tri = lobes.reduce(0) { $0 + $1.indices.count / 3 }
                self.orbitalStatus = tri == 0 ? "\(label): no surface at ±\(iso) — try a smaller isovalue"
                                              : String(format: "%@ at ±%.3g a.u.", label, iso)
            }
        }
    }
}
