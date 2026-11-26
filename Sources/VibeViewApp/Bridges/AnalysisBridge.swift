import Foundation
import MolCore
import MolIO
import MolRender
import MolAnalysis

// INTEGRATION BRIDGE (Lead C): orbital surfaces via MolAnalysis (Lead D).

@MainActor
final class OrbitalSurfaceCache {
    static let shared = OrbitalSurfaceCache()
    /// Grids kept for quick orbital switching: least recently used first out, at most `countLimit` grids and
    /// `byteBudget` bytes of values (a fine grid of a large molecule is tens of MB; small ones stay at 12).
    static let countLimit = 12
    static let byteBudget = 256 << 20
    private var grids: [String: VolumeGrid] = [:]   // key: object id + MO
    private var order: [String] = []
    private(set) var bytes = 0
    var generation = 0

    /// The orbital surface currently on screen per editor: the grid it came from and how it was drawn.
    struct Shown {
        var grid: VolumeGrid
        var iso: Double
        var look: OrbitalLook
        var occupied: Bool
        func matches(_ g: VolumeGrid, iso: Double, look: OrbitalLook, occupied: Bool) -> Bool {
            iso == self.iso && look == self.look && occupied == self.occupied && Self.sameStorage(g, grid)
        }
        /// Same grid object: equal geometry and the very same value storage (the cache keeps it alive).
        static func sameStorage(_ a: VolumeGrid, _ b: VolumeGrid) -> Bool {
            a.counts == b.counts && a.origin == b.origin && a.axes == b.axes
                && a.values.withUnsafeBufferPointer { pa in b.values.withUnsafeBufferPointer { pb in pa.baseAddress == pb.baseAddress } }
        }
    }
    var shown: [ObjectIdentifier: Shown] = [:]

    static func size(_ g: VolumeGrid) -> Int { g.values.count * MemoryLayout<Float>.size }

    func grid(_ key: String) -> VolumeGrid? {
        guard let g = grids[key] else { return nil }
        if order.last != key, let i = order.firstIndex(of: key) { order.remove(at: i); order.append(key) }
        return g
    }
    func store(_ key: String, _ g: VolumeGrid) {
        if let old = grids[key] { bytes -= Self.size(old); order.removeAll { $0 == key } }
        grids[key] = g; order.append(key); bytes += Self.size(g)
        while order.count > Self.countLimit || (bytes > Self.byteBudget && order.count > 1) {
            let k = order.removeFirst()
            if let old = grids.removeValue(forKey: k) { bytes -= Self.size(old) }
        }
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
        PerfProbe.log("orbital \(mo) requested")
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
        let quality = orbitalLook.quality
        let key = "\(ObjectIdentifier(self).hashValue)-\(spinBeta ? "b" : "a")\(mo)-\(quality.rawValue)"
        if let g = cache.grid(key) { show(grid: g, iso: iso, gen: gen, label: "MO \(mo)"); return }
        orbitalStatus = "Computing orbital \(mo) (\(quality.title.lowercased()) grid)…"
        Task.detached(priority: .userInitiated) {
            let t0 = CFAbsoluteTimeGetCurrent()
            let g = WavefunctionSurfaces.orbitalGrid(wf, mo: mo - 1, spin: spinBeta ? .beta : .alpha,
                                                     grid: GridSpec.adaptive(wf, quality: quality))
            let took = CFAbsoluteTimeGetCurrent() - t0
            await MainActor.run {
                PerfProbe.log("orbital \(mo) grid \(g.counts.map(String.init).joined(separator: "x")) in \(String(format: "%.1f ms", took * 1000))")
                cache.store(key, g)
                guard cache.generation == gen else { return }
                self.show(grid: g, iso: self.orbitalIsovalue, gen: gen, label: "MO \(mo)")
            }
        }
    }

    private func show(grid g: VolumeGrid, iso: Double, gen: Int, label: String) {
        // Re-selecting what is already drawn (same grid, isovalue and look) would only rebuild the same mesh.
        let me = ObjectIdentifier(self)
        let occupied = result?.orbitals.first { $0.index == activeOrbitalIndex }?.occupied ?? true
        if viewport.renderer.isosurfaces["orbital"] != nil,
           OrbitalSurfaceCache.shared.shown[me]?.matches(g, iso: iso, look: orbitalLook, occupied: occupied) == true {
            PerfProbe.log("\(label) surface already shown")
            return
        }
        Task.detached(priority: .userInitiated) {
            let t0 = CFAbsoluteTimeGetCurrent()
            let lobes = MarchingCubes.orbitalLobes(grid: g, isovalue: iso)
            let took = CFAbsoluteTimeGetCurrent() - t0
            await MainActor.run {
                guard OrbitalSurfaceCache.shared.generation == gen else { return }
                PerfProbe.log("\(label) surface (marching cubes + post) in \(String(format: "%.1f ms", took * 1000))")
                let occ = self.result?.orbitals.first { $0.index == self.activeOrbitalIndex }?.occupied ?? true
                var s = Isosurface(id: "orbital", meshes: lobes, colors: self.orbitalLook.scheme(occupied: occ))
                s.mode = self.orbitalLook.mode
                s.opacity = self.orbitalLook.mode == .transparent ? 1 : 0.95
                self.viewport.renderer.setIsosurface(s)
                OrbitalSurfaceCache.shared.shown[ObjectIdentifier(self)] = .init(grid: g, iso: iso, look: self.orbitalLook, occupied: occ)
                MoleculeRenderer.releaseFreedMemory()   // grid evaluation and marching-cubes temporaries
                if PerfProbe.enabled { self.viewport.renderer.onNextFrame { _ in PerfProbe.log("\(label) surface on screen") } }
                let tri = lobes.reduce(0) { $0 + $1.indices.count / 3 }
                self.orbitalStatus = tri == 0 ? "\(label): no surface at ±\(iso) — try a smaller isovalue"
                                              : String(format: "%@ at ±%.3g a.u.", label, iso)
            }
        }
    }
}
