import Foundation
import MolSIMD
import MolCore

/// Geometry of a regular (possibly skewed) sampling grid, in Ångström. Point (i, j, k) is
/// `origin + i·axes[0] + j·axes[1] + k·axes[2]`; values are stored x-slowest, z-fastest (cube order).
public struct GridSpec: Sendable, Equatable, Codable {
    public var origin: Vec3
    public var axes: [Vec3]
    public var counts: [Int]

    public init(origin: Vec3, axes: [Vec3], counts: [Int]) {
        self.origin = origin; self.axes = axes; self.counts = counts
    }

    public init(_ grid: VolumeGrid) { self.init(origin: grid.origin, axes: grid.axes, counts: grid.counts) }

    public var pointCount: Int { counts.reduce(1, *) }

    @inlinable public func point(_ i: Int, _ j: Int, _ k: Int) -> Vec3 {
        origin + Double(i) * axes[0] + Double(j) * axes[1] + Double(k) * axes[2]
    }

    /// Volume element of one cell in Å³.
    public var voxelVolume: Double { abs(simd_double3x3(columns: (axes[0], axes[1], axes[2])).determinant) }

    public func volumeGrid(values: [Float]) -> VolumeGrid {
        VolumeGrid(origin: origin, axes: axes, counts: counts, values: values)
    }

    /// Axis-aligned grid around `positions` (Å) with `padding` Å on every side and cubic `spacing` Å.
    /// If the grid would exceed `maxPoints`, the spacing is increased until it fits.
    public static func automatic(around positions: [Vec3], padding: Double = 4.0, spacing: Double = 0.25,
                                 maxPoints: Int = 2_000_000) -> GridSpec {
        var lo = Vec3(repeating: .infinity), hi = Vec3(repeating: -.infinity)
        for p in positions { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        if positions.isEmpty { lo = .zero; hi = .zero }
        lo -= Vec3(repeating: padding); hi += Vec3(repeating: padding)
        let ext = hi - lo
        var h = max(spacing, 1e-3)
        func counts(_ h: Double) -> [Int] { (0..<3).map { max(2, Int((ext[$0] / h).rounded(.up)) + 1) } }
        var c = counts(h)
        while c.reduce(1, *) > maxPoints { h *= 1.05; c = counts(h) }
        // Center the grid on the box.
        let span = Vec3(Double(c[0] - 1), Double(c[1] - 1), Double(c[2] - 1)) * h
        let origin = (lo + hi) / 2 - span / 2
        return GridSpec(origin: origin, axes: [Vec3(h, 0, 0), Vec3(0, h, 0), Vec3(0, 0, h)], counts: c)
    }

    public static func automatic(around molecule: Molecule, padding: Double = 4.0, spacing: Double = 0.25,
                                 maxPoints: Int = 2_000_000) -> GridSpec {
        automatic(around: molecule.atoms.map(\.position), padding: padding, spacing: spacing, maxPoints: maxPoints)
    }
}

extension VolumeGrid {
    /// Trilinear interpolation at a Cartesian point (Å); works for skewed axes. Points outside the grid are
    /// clamped to the boundary.
    public func sample(atAngstrom p: Vec3) -> Double {
        guard counts.count == 3, axes.count == 3 else { return 0 }
        let M = simd_double3x3(columns: (axes[0], axes[1], axes[2]))
        let f = M.inverse * (p - origin)
        let nx = counts[0], ny = counts[1], nz = counts[2]
        func split(_ x: Double, _ n: Int) -> (Int, Double) {
            let c = min(max(x, 0), Double(n - 1))
            let i = min(Int(c), max(n - 2, 0))
            return (i, c - Double(i))
        }
        let (i, tx) = split(f.x, nx), (j, ty) = split(f.y, ny), (k, tz) = split(f.z, nz)
        func v(_ a: Int, _ b: Int, _ c: Int) -> Double {
            Double(values[(min(a, nx - 1) * ny + min(b, ny - 1)) * nz + min(c, nz - 1)])
        }
        let c00 = v(i, j, k) * (1 - tx) + v(i + 1, j, k) * tx
        let c10 = v(i, j + 1, k) * (1 - tx) + v(i + 1, j + 1, k) * tx
        let c01 = v(i, j, k + 1) * (1 - tx) + v(i + 1, j, k + 1) * tx
        let c11 = v(i, j + 1, k + 1) * (1 - tx) + v(i + 1, j + 1, k + 1) * tx
        let c0 = c00 * (1 - ty) + c10 * ty, c1 = c01 * (1 - ty) + c11 * ty
        return c0 * (1 - tz) + c1 * tz
    }

    /// Σ value · voxel volume (Å³). Multiply by `PhysConst.angstromToBohr³` for a Bohr³ integral.
    public func integral() -> Double {
        let dv = GridSpec(self).voxelVolume
        var s = 0.0
        for v in values { s += Double(v) }
        return s * dv
    }
}
