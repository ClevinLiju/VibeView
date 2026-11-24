import Foundation
import CoreGraphics
import simd
import MolCore

// Round 3 (Lead B): pure math for lasso selection, moving a selection, hydrogen bonds and scale bars.

/// Freehand lasso helpers (view coordinates, any orientation; the polygon closes implicitly).
public enum LassoMath {
    /// Even-odd point-in-polygon test. Fewer than 3 vertices -> false. Points exactly on an edge may go either way.
    public static func contains(_ polygon: [CGPoint], _ p: CGPoint) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let a = polygon[i], b = polygon[j]
            if (a.y > p.y) != (b.y > p.y) {
                let x = a.x + (p.y - a.y) * (b.x - a.x) / (b.y - a.y)
                if p.x < x { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    /// Indices whose projected point (nil = hidden / behind the camera) lies inside the polygon.
    public static func atomsInPolygon(projected: [CGPoint?], polygon: [CGPoint]) -> Set<Int> {
        guard polygon.count >= 3 else { return [] }
        var lo = polygon[0], hi = polygon[0]
        for q in polygon { lo = CGPoint(x: min(lo.x, q.x), y: min(lo.y, q.y)); hi = CGPoint(x: max(hi.x, q.x), y: max(hi.y, q.y)) }
        var out = Set<Int>()
        for (i, p) in projected.enumerated() {
            guard let p, p.x >= lo.x, p.x <= hi.x, p.y >= lo.y, p.y <= hi.y else { continue }
            if contains(polygon, p) { out.insert(i) }
        }
        return out
    }

    /// Append a pointer sample unless it is closer than `minSpacing` points to the last one.
    public static func appendSample(_ polygon: inout [CGPoint], _ p: CGPoint, minSpacing: CGFloat = 2) {
        if let l = polygon.last, hypot(l.x - p.x, l.y - p.y) < minSpacing { return }
        polygon.append(p)
    }
}

/// How a drag-selection combines with the existing selection.
public enum SelectionCombine: Sendable, Equatable {
    case replace, add, subtract
    /// shift = add, command or option = subtract, none = replace.
    public static func from(shift: Bool, command: Bool, option: Bool) -> SelectionCombine {
        if command || option { return .subtract }
        return shift ? .add : .replace
    }
    public func apply(_ hit: Set<Int>, to sel: Set<Int>) -> Set<Int> {
        switch self { case .replace: return hit; case .add: return sel.union(hit); case .subtract: return sel.subtracting(hit) }
    }
}

/// Rigid moves of a subset of atoms; everything else stays put.
public enum SelectionMoveMath {
    /// Positions with `delta` added to the selected indices (out-of-range indices ignored).
    public static func translate(_ positions: [Vec3], selection: Set<Int>, by delta: Vec3) -> [Vec3] {
        var out = positions
        for i in selection where i >= 0 && i < out.count { out[i] += delta }
        return out
    }
    /// Centroid of the selected positions (nil when nothing valid is selected).
    public static func centroid(_ positions: [Vec3], selection: Set<Int>) -> Vec3? {
        let v = selection.filter { $0 >= 0 && $0 < positions.count }
        guard !v.isEmpty else { return nil }
        return v.reduce(Vec3.zero) { $0 + positions[$1] } / Double(v.count)
    }
    /// Rotate the selected atoms by `angle` radians about `axis` through their centroid.
    public static func rotate(_ positions: [Vec3], selection: Set<Int>, axis: Vec3, angle: Double) -> [Vec3] {
        guard let c = centroid(positions, selection: selection), simd_length(axis) > 1e-12 else { return positions }
        let q = simd_quatd(angle: angle, axis: simd_normalize(axis))
        var out = positions
        for i in selection where i >= 0 && i < out.count { out[i] = c + q.act(out[i] - c) }
        return out
    }
    /// World-space translation for a pointer drag of (dx, dy) points (AppKit: +y up) in the view plane, at a
    /// depth where one point spans `worldPerPoint` Å. `right`/`up` are the camera's unit vectors.
    public static func viewPlaneDelta(dx: Double, dy: Double, right: Vec3, up: Vec3, worldPerPoint: Double) -> Vec3 {
        (right * dx + up * dy) * worldPerPoint
    }
    /// Rotation for a modifier-drag: axis perpendicular to the drag in the view plane, 0.01 rad per point.
    public static func dragRotation(dx: Double, dy: Double, right: Vec3, up: Vec3, radiansPerPoint: Double = 0.01) -> (axis: Vec3, angle: Double) {
        let len = (dx * dx + dy * dy).squareRoot()
        guard len > 1e-9 else { return (up, 0) }
        let view = simd_cross(right, up)        // toward the viewer
        let drag = right * dx + up * dy
        return (simd_normalize(simd_cross(view, drag)), len * radiansPerPoint)
    }
    /// Å per view point at distance `depth` in front of the camera.
    public static func worldPerPoint(depth: Double, verticalFOVDegrees: Double, viewHeight: Double,
                                     projection: ProjectionMode, orthographicScale: Double) -> Double {
        guard viewHeight > 0 else { return 0 }
        switch projection {
        case .orthographic: return 2 * orthographicScale / viewHeight
        case .perspective: return 2 * max(depth, 1e-3) * tan(verticalFOVDegrees * .pi / 360) / viewHeight
        }
    }
}

/// A detected hydrogen bond D–H···A (atom indices).
public struct HydrogenBond: Sendable, Hashable {
    public var donor: Int, hydrogen: Int, acceptor: Int
    /// H···A distance (Å) and D–H···A angle (degrees).
    public var distance: Double, angle: Double
}

public enum HydrogenBonds {
    /// Elements that act as donors/acceptors: N, O, F, S, Cl.
    public static let polar: Set<Int> = [7, 8, 9, 16, 17]

    /// Geometric criteria: H covalently bonded (by `molecule.bonds`, or nearest polar atom within 1.25 Å when
    /// unbonded) to a polar donor D; acceptor A polar, not D, not bonded to H; H···A <= maxDistance; angle
    /// D–H···A >= minAngle. Sorted by (hydrogen, acceptor).
    public static func find(in m: Molecule, maxDistance: Double = 2.5, minAngle: Double = 120) -> [HydrogenBond] {
        let n = m.atoms.count
        guard n > 2 else { return [] }
        let adj = m.adjacency()
        let pos = m.atoms.map(\.position)
        let grid = NeighborGrid(positions: pos, cellSize: max(maxDistance, 1.25))
        var out: [HydrogenBond] = []
        for h in 0..<n where m.atoms[h].atomicNumber == 1 {
            var donor = adj[h].first { polar.contains(m.atoms[$0].atomicNumber) }
            if donor == nil, adj[h].isEmpty {
                donor = grid.neighbors(of: pos[h], within: 1.25)
                    .filter { $0 != h && polar.contains(m.atoms[$0].atomicNumber) }
                    .min { simd_distance(pos[$0], pos[h]) < simd_distance(pos[$1], pos[h]) }
            }
            guard let d = donor else { continue }
            for a in grid.neighbors(of: pos[h], within: maxDistance) where a != d && a != h && polar.contains(m.atoms[a].atomicNumber) {
                if adj[h].contains(a) { continue }
                let dist = simd_distance(pos[h], pos[a])
                guard dist > 1.2, dist <= maxDistance else { continue }
                let ang = VecMath.angle(pos[d], pos[h], pos[a])
                guard ang >= minAngle else { continue }
                out.append(HydrogenBond(donor: d, hydrogen: h, acceptor: a, distance: dist, angle: ang))
            }
        }
        return out.sorted { ($0.hydrogen, $0.acceptor) < ($1.hydrogen, $1.acceptor) }
    }
}

public enum ScaleBarMath {
    /// A "nice" bar length (1, 2 or 5 × 10^k Å) whose on-screen length is closest to (and not above
    /// 1.5 ×) `targetPoints` given `worldPerPoint` Å per point. Returns (Å, points).
    public static func niceLength(worldPerPoint: Double, targetPoints: Double = 100) -> (angstrom: Double, points: Double) {
        guard worldPerPoint > 0, worldPerPoint.isFinite else { return (1, 0) }
        let want = worldPerPoint * targetPoints
        let e = floor(log10(want))
        var best = (1.0, Double.infinity)
        for k in [e - 1, e, e + 1] { for m in [1.0, 2.0, 5.0] {
            let v = m * pow(10, k)
            let err = abs(log(v / want))
            if err < best.1 { best = (v, err) }
        } }
        return (best.0, best.0 / worldPerPoint)
    }
    /// Label like "5 Å", "0.5 Å", "20 Å".
    public static func label(_ a: Double) -> String {
        a >= 1 ? String(format: "%.0f Å", a) : String(format: "%g Å", a)
    }
}
