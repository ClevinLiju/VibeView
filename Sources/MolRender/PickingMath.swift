import Foundation
import simd
import MolCore

/// Pure ray/picking math. All rays are given as origin + t * dir (dir need not be normalized; returned t is in
/// units of the normalized direction, i.e. Å along the ray).
public enum PickMath {
    /// Minimum pick radius (Å) so thin wireframe bonds and tiny dots stay pickable.
    public static let minPickRadius = 0.15

    /// Nearest non-negative hit distance with a sphere. A ray starting inside returns 0.
    public static func raySphere(origin: Vec3, dir: Vec3, center: Vec3, radius: Double) -> Double? {
        let l = simd_length(dir)
        guard l > 1e-14, radius >= 0 else { return nil }
        let d = dir / l
        let oc = origin - center
        let b = simd_dot(oc, d)
        let c = simd_dot(oc, oc) - radius * radius
        if c <= 0 { return 0 }
        let disc = b * b - c
        guard disc >= 0 else { return nil }
        let t = -b - disc.squareRoot()
        return t >= 0 ? t : nil
    }

    /// Nearest non-negative hit with a finite cylinder from a to b with flat caps. Origin inside returns 0.
    public static func rayCylinder(origin: Vec3, dir: Vec3, a: Vec3, b: Vec3, radius: Double) -> Double? {
        let l = simd_length(dir)
        // A zero-radius cylinder is a line segment: only a measure-zero set of rays could hit it, so treat as a miss.
        guard l > 1e-14, radius > 0, radius.isFinite else { return nil }
        let d = dir / l
        let axis = b - a
        let len = simd_length(axis)
        guard len > 1e-12 else { return raySphere(origin: origin, dir: d, center: a, radius: radius) }
        let u = axis / len
        let w = origin - a
        let wu = simd_dot(w, u), du = simd_dot(d, u)
        let wp = w - wu * u, dp = d - du * u
        // inside test
        if wu >= 0, wu <= len, simd_length_squared(wp) <= radius * radius { return 0 }
        var best: Double? = nil
        func consider(_ t: Double) { if t >= 0, best == nil || t < best! { best = t } }
        // side
        let A = simd_dot(dp, dp), B = 2 * simd_dot(wp, dp), C = simd_dot(wp, wp) - radius * radius
        if A > 1e-14 {
            let disc = B * B - 4 * A * C
            if disc >= 0 {
                let sq = disc.squareRoot()
                for t in [(-B - sq) / (2 * A), (-B + sq) / (2 * A)] {
                    let s = wu + t * du
                    if t >= 0, s >= 0, s <= len { consider(t) }
                }
            }
        }
        // caps
        if abs(du) > 1e-14 {
            for cap in [0.0, len] {
                let t = (cap - wu) / du
                if t >= 0 {
                    let q = wp + t * dp
                    if simd_length_squared(q) <= radius * radius { consider(t) }
                }
            }
        }
        return best
    }

    /// Nearest atom/bond hit along the ray; atoms win near-ties (slack `atomSlack` Å in favor of atoms).
    public static func pick(origin: Vec3, dir: Vec3, molecule: Molecule, options: RenderOptions) -> (PickTarget, Double)? {
        let n = molecule.atoms.count
        var bestAtom: (Int, Double)? = nil
        for i in 0..<n {
            let a = molecule.atoms[i]
            guard RenderMetrics.isAtomPickable(i, in: molecule, options: options) else { continue }
            // A CA standing in for its cartoon residue is picked within the ribbon's width.
            let standIn = options.atomMask.isStandIn(i)
            let r = standIn ? 1.1 : max(RenderMetrics.atomRadius(atomicNumber: a.atomicNumber, options: options), minPickRadius)
            if let t = raySphere(origin: origin, dir: dir, center: a.position, radius: r), bestAtom == nil || t < bestAtom!.1 {
                bestAtom = (i, t)
            }
        }
        var bestBond: (Int, Double)? = nil
        let br = max(RenderMetrics.bondRadius(options: options), minPickRadius)
        if options.style != .spaceFilling {
            for (k, bd) in molecule.bonds.enumerated() {
                guard RenderMetrics.isBondVisible(bd, in: molecule, options: options) else { continue }
                if let t = rayCylinder(origin: origin, dir: dir, a: molecule.atoms[bd.a].position, b: molecule.atoms[bd.b].position, radius: br),
                   bestBond == nil || t < bestBond!.1 {
                    bestBond = (k, t)
                }
            }
        }
        switch (bestAtom, bestBond) {
        case (nil, nil): return nil
        case let (a?, nil): return (.atom(a.0), a.1)
        case let (nil, b?): return (.bond(b.0), b.1)
        case let (a?, b?):
            return a.1 <= b.1 + atomSlack ? (.atom(a.0), a.1) : (.bond(b.0), b.1)
        }
    }
    public static let atomSlack = 0.05

    /// Indices whose projected point lies inside `rect` (nil = not projectable / behind camera).
    public static func atomsInRect(projected: [CGPoint?], rect: CGRect) -> Set<Int> {
        var out = Set<Int>()
        for (i, p) in projected.enumerated() {
            if let p, rect.contains(p) { out.insert(i) }
        }
        return out
    }
}
