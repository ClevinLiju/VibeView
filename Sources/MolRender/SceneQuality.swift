import Foundation

/// Automatic level-of-detail for large systems (pure, no SceneKit).
public enum SceneQuality {
    /// Sphere segment count for `count` atoms at requested quality `q`.
    public static func sphereSegments(quality q: Int, atomCount count: Int) -> Int {
        let base = max(6, q)
        if count > 20000 { return min(base, 6) }
        if count > 5000 { return min(base, 8) }
        if count > 2000 { return min(base, 12) }
        return base
    }
    /// Cylinder radial segment count for `count` cylinder nodes at quality `q`.
    public static func cylinderSegments(quality q: Int, segmentCount count: Int) -> Int {
        let base = max(6, q * 2 / 3)
        if count > 40000 { return min(base, 6) }
        if count > 10000 { return min(base, 8) }
        if count > 3000 { return min(base, 12) }
        return base
    }

    /// Longitude segment count of the template sphere used by merged atom geometry.
    public static func mergedSphereSegments(quality q: Int, atomCount count: Int) -> Int {
        let base = max(8, q)
        if count > 40000 { return min(base, 8) }
        if count > 20000 { return min(base, 10) }
        if count > 8000 { return min(base, 12) }
        return min(base, 16)
    }
    /// Radial segment count of the template open cylinder used by merged bond geometry.
    public static func mergedCylinderSegments(quality q: Int, segmentCount count: Int) -> Int {
        let base = max(6, q * 2 / 3)
        if count > 40000 { return min(base, 6) }
        if count > 10000 { return min(base, 8) }
        return min(base, 12)
    }
}
