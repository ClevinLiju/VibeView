import Foundation
import simd
import MolCore
import MolIO

/// Convenience entry points: orbital / density / spin-density grids and ESP-mapped surfaces from a `Wavefunction`.
public enum WavefunctionSurfaces {
    public enum Spin: Sendable { case alpha, beta }
    public enum DensityKind: Sendable { case total, spin, alpha, beta }

    /// Nuclear positions in Å.
    public static func atomPositions(_ wf: Wavefunction) -> [Vec3] {
        wf.nuclearPositions.map { $0 * PhysConst.bohrToAngstrom }
    }

    /// Default grid around the nuclei (Å).
    public static func defaultGrid(_ wf: Wavefunction, padding: Double = 4.0, spacing: Double = 0.2,
                                   maxPoints: Int = 2_000_000) -> GridSpec {
        GridSpec.automatic(around: atomPositions(wf), padding: padding, spacing: spacing, maxPoints: maxPoints)
    }

    /// MO `mo` (0-based) of the given spin set on a grid. Beta falls back to alpha for restricted wavefunctions.
    public static func orbitalGrid(_ wf: Wavefunction, mo: Int, spin: Spin = .alpha, grid: GridSpec? = nil,
                                   evaluator: OrbitalEvaluator? = nil) -> VolumeGrid {
        let set = spin == .beta ? (wf.beta ?? wf.alpha) : wf.alpha
        let ev = evaluator ?? OrbitalEvaluator(wavefunction: wf)
        return ev.moGrid(coefficients: Array(set.orbital(mo)), grid: grid ?? defaultGrid(wf))
    }

    /// Occupied orbitals with occupation weights for a density kind (from the MO coefficients).
    static func weightedOrbitals(_ wf: Wavefunction, _ kind: DensityKind) -> (orbs: [[Double]], w: [Double]) {
        let nA = wf.alphaElectrons, nB = wf.betaElectrons
        let a = (0..<min(nA, wf.alpha.orbitalCount)).map { Array(wf.alpha.orbital($0)) }
        let bset = wf.beta ?? wf.alpha
        let b = (0..<min(nB, bset.orbitalCount)).map { Array(bset.orbital($0)) }
        switch kind {
        case .alpha: return (a, Array(repeating: 1, count: a.count))
        case .beta: return (b, Array(repeating: 1, count: b.count))
        case .total: return (a + b, Array(repeating: 1, count: a.count + b.count))
        case .spin: return (a + b, Array(repeating: 1, count: a.count) + Array(repeating: -1, count: b.count))
        }
    }

    /// Electron density (e/Bohr³) on a grid.
    public static func densityGrid(_ wf: Wavefunction, kind: DensityKind = .total, grid: GridSpec? = nil,
                                   evaluator: OrbitalEvaluator? = nil) -> VolumeGrid {
        let ev = evaluator ?? OrbitalEvaluator(wavefunction: wf)
        let (o, w) = weightedOrbitals(wf, kind)
        return ev.evaluate(.orbitalDensity(orbitals: o, weights: w), on: grid ?? defaultGrid(wf))!
    }

    public static func spinDensityGrid(_ wf: Wavefunction, grid: GridSpec? = nil) -> VolumeGrid {
        densityGrid(wf, kind: .spin, grid: grid)
    }

    /// Full n×n AO density matrix from occupied MOs.
    public static func densityMatrix(_ wf: Wavefunction, spin kind: DensityKind = .total) -> [Double] {
        let n = wf.basis.functionCount
        var P = [Double](repeating: 0, count: n * n)
        let (orbs, w) = weightedOrbitals(wf, kind)
        for (c, wt) in zip(orbs, w) {
            for mu in 0..<n where c[mu] != 0 {
                let f = wt * c[mu]
                for nu in 0..<n { P[mu * n + nu] += f * c[nu] }
            }
        }
        return P
    }

    /// Density isosurface colored by the ESP (Hartree/e in `vertexScalars`, red negative … blue positive).
    public static func espMappedDensity(_ wf: Wavefunction, isovalue: Double = 0.0004, grid: GridSpec? = nil,
                                        colorRange: ClosedRange<Double>? = nil) -> IsoSurfaceMesh {
        let g = grid ?? defaultGrid(wf, padding: 4.5, spacing: 0.2)
        let rho = densityGrid(wf, grid: g)
        var mesh = MarchingCubes.extract(grid: rho, isovalue: isovalue)
        let esp = ElectrostaticPotential(wavefunction: wf)
        mesh.vertexScalars = esp.evaluate(atAngstrom: mesh.vertices).map(Float.init)
        ESPColorMap.colorize(&mesh, range: colorRange)
        return mesh
    }
}

extension ElectrostaticPotential {
    /// Alias matching the contract: ESP-mapped density surface.
    public static func mapOntoDensity(_ wf: Wavefunction, isovalue: Double = 0.0004, grid: GridSpec? = nil) -> IsoSurfaceMesh {
        WavefunctionSurfaces.espMappedDensity(wf, isovalue: isovalue, grid: grid)
    }

    public static func evaluate(_ wf: Wavefunction, atAngstrom points: [SIMD3<Float>]) -> [Double] {
        ElectrostaticPotential(wavefunction: wf).evaluate(atAngstrom: points)
    }
}

/// The same surfaces computed from cube files.
public enum CubeSurfaces {
    /// `[+iso, −iso]` lobes of grid `gridIndex` of a cube file (orbital cubes).
    public static func lobes(_ cube: CubeFile, gridIndex: Int = 0, isovalue: Double = 0.02) -> [IsoSurfaceMesh] {
        guard cube.grids.indices.contains(gridIndex) else { return [] }
        return MarchingCubes.orbitalLobes(grid: cube.grids[gridIndex], isovalue: isovalue)
    }

    /// Single isosurface (density cubes).
    public static func surface(_ cube: CubeFile, gridIndex: Int = 0, isovalue: Double = 0.0004) -> IsoSurfaceMesh {
        guard cube.grids.indices.contains(gridIndex) else { return IsoSurfaceMesh() }
        return MarchingCubes.extract(grid: cube.grids[gridIndex], isovalue: isovalue)
    }

    /// Isosurface of `surface` with `property` (e.g. an ESP cube) sampled trilinearly at each vertex.
    /// The two grids may have different shapes/orientations.
    public static func mapped(surface: VolumeGrid, isovalue: Double, property: VolumeGrid,
                              colorRange: ClosedRange<Double>? = nil) -> IsoSurfaceMesh {
        var mesh = MarchingCubes.extract(grid: surface, isovalue: isovalue)
        mesh.vertexScalars = mesh.vertices.map { Float(property.sample(atAngstrom: SIMD3<Double>($0))) }
        ESPColorMap.colorize(&mesh, range: colorRange)
        return mesh
    }
}
