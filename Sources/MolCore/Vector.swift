import Foundation
import MolSIMD

// Owned by Lead 1. Small vector / linear-algebra helpers shared by all MolCore files.
// Angles in the public API are in DEGREES unless a name says otherwise.

@inline(__always) public func degToRad(_ d: Double) -> Double { d * .pi / 180 }
@inline(__always) public func radToDeg(_ r: Double) -> Double { r * 180 / .pi }

public enum VecMath {
    /// Distance between two points (Å).
    public static func distance(_ a: Vec3, _ b: Vec3) -> Double { simd_length(a - b) }

    /// Angle a-b-c in degrees (b is the vertex). Returns 0 for degenerate input.
    public static func angle(_ a: Vec3, _ b: Vec3, _ c: Vec3) -> Double {
        let u = a - b, v = c - b
        let lu = simd_length(u), lv = simd_length(v)
        guard lu > 1e-12, lv > 1e-12 else { return 0 }
        let cosT = max(-1, min(1, simd_dot(u, v) / (lu * lv)))
        return radToDeg(acos(cosT))
    }

    /// Dihedral a-b-c-d in degrees, range (-180, 180], IUPAC sign convention.
    public static func dihedral(_ a: Vec3, _ b: Vec3, _ c: Vec3, _ d: Vec3) -> Double {
        let b0 = a - b, b1 = c - b, b2 = d - c
        let b1n = simd_length(b1) > 1e-12 ? simd_normalize(b1) : Vec3(0, 0, 1)
        let v = b0 - simd_dot(b0, b1n) * b1n
        let w = b2 - simd_dot(b2, b1n) * b1n
        let x = simd_dot(v, w)
        let y = simd_dot(simd_cross(b1n, v), w)
        if abs(x) < 1e-14 && abs(y) < 1e-14 { return 0 }
        return radToDeg(atan2(y, x))
    }

    /// Rotate point `p` about the axis through `origin` with direction `axis` by `degrees`
    /// (right-hand rule, Rodrigues formula).
    public static func rotate(_ p: Vec3, about origin: Vec3, axis: Vec3, degrees: Double) -> Vec3 {
        let len = simd_length(axis)
        guard len > 1e-12 else { return p }
        let k = axis / len
        let t = degToRad(degrees)
        let v = p - origin
        let r = v * cos(t) + simd_cross(k, v) * sin(t) + k * simd_dot(k, v) * (1 - cos(t))
        return origin + r
    }

    /// 3x3 rotation matrix for an axis/angle (degrees).
    public static func rotationMatrix(axis: Vec3, degrees: Double) -> simd_double3x3 {
        let len = simd_length(axis)
        guard len > 1e-12 else { return matrix_identity_double3x3 }
        return simd_double3x3(simd_quatd(angle: degToRad(degrees), axis: axis / len))
    }

    /// Any unit vector perpendicular to `v`.
    public static func perpendicular(_ v: Vec3) -> Vec3 {
        let a = abs(v.x) < 0.9 ? Vec3(1, 0, 0) : Vec3(0, 1, 0)
        let p = simd_cross(v, a)
        let l = simd_length(p)
        return l > 1e-12 ? p / l : Vec3(0, 0, 1)
    }

    /// Eigen-decomposition of a symmetric 3x3 matrix by cyclic Jacobi rotations.
    /// Returns eigenvalues ascending and the matching unit eigenvectors (columns of a
    /// right-handed rotation matrix: det = +1).
    public static func symmetricEigen(_ m: simd_double3x3) -> (values: Vec3, vectors: simd_double3x3) {
        var a = [[m[0][0], m[1][0], m[2][0]],
                 [m[0][1], m[1][1], m[2][1]],
                 [m[0][2], m[1][2], m[2][2]]]
        var v: [[Double]] = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
        for _ in 0..<100 {
            let off = a[0][1] * a[0][1] + a[0][2] * a[0][2] + a[1][2] * a[1][2]
            if off < 1e-30 { break }
            for (p, q) in [(0, 1), (0, 2), (1, 2)] {
                if abs(a[p][q]) < 1e-300 { continue }
                let theta = (a[q][q] - a[p][p]) / (2 * a[p][q])
                let t = (theta >= 0 ? 1.0 : -1.0) / (abs(theta) + (theta * theta + 1).squareRoot())
                let c = 1 / (t * t + 1).squareRoot(), s = t * c
                for k in 0..<3 {
                    let akp = a[k][p], akq = a[k][q]
                    a[k][p] = c * akp - s * akq
                    a[k][q] = s * akp + c * akq
                }
                for k in 0..<3 {
                    let apk = a[p][k], aqk = a[q][k]
                    a[p][k] = c * apk - s * aqk
                    a[q][k] = s * apk + c * aqk
                }
                for k in 0..<3 {
                    let vkp = v[k][p], vkq = v[k][q]
                    v[k][p] = c * vkp - s * vkq
                    v[k][q] = s * vkp + c * vkq
                }
            }
        }
        var idx = [0, 1, 2]
        idx.sort { a[$0][$0] < a[$1][$1] }
        let vals = Vec3(a[idx[0]][idx[0]], a[idx[1]][idx[1]], a[idx[2]][idx[2]])
        var c0 = Vec3(v[0][idx[0]], v[1][idx[0]], v[2][idx[0]])
        let c1 = Vec3(v[0][idx[1]], v[1][idx[1]], v[2][idx[1]])
        let c2 = Vec3(v[0][idx[2]], v[1][idx[2]], v[2][idx[2]])
        if simd_dot(simd_cross(c1, c2), c0) < 0 { c0 = -c0 }
        return (vals, simd_double3x3(columns: (c0, c1, c2)))
    }
}
