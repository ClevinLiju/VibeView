import Foundation
import MolSIMD

// Owned by Lead 1 (Core). Geometry utilities: centroid, inertia, alignment (Kabsch via Horn quaternion).

public enum Geometry {
    public static func centroid(_ p: [Vec3]) -> Vec3 {
        guard !p.isEmpty else { return .zero }
        var s = Vec3.zero
        for x in p { s += x }
        return s / Double(p.count)
    }

    public static func centerOfMass(_ p: [Vec3], masses: [Double]) -> Vec3 {
        var s = Vec3.zero, m = 0.0
        for i in 0..<min(p.count, masses.count) { s += p[i] * masses[i]; m += masses[i] }
        return m > 0 ? s / m : centroid(p)
    }

    /// Inertia tensor about `c` in amu·Å².
    public static func inertiaTensor(_ p: [Vec3], masses: [Double], about c: Vec3) -> simd_double3x3 {
        var xx = 0.0, yy = 0.0, zz = 0.0, xy = 0.0, xz = 0.0, yz = 0.0
        for i in 0..<min(p.count, masses.count) {
            let m = masses[i], r = p[i] - c
            xx += m * (r.y * r.y + r.z * r.z)
            yy += m * (r.x * r.x + r.z * r.z)
            zz += m * (r.x * r.x + r.y * r.y)
            xy -= m * r.x * r.y
            xz -= m * r.x * r.z
            yz -= m * r.y * r.z
        }
        return simd_double3x3(columns: (Vec3(xx, xy, xz), Vec3(xy, yy, yz), Vec3(xz, yz, zz)))
    }

    public static func principalAxes(_ p: [Vec3], masses: [Double]) -> (moments: Vec3, axes: simd_double3x3) {
        let c = centerOfMass(p, masses: masses)
        let r = VecMath.symmetricEigen(inertiaTensor(p, masses: masses, about: c))
        return (r.values, r.vectors)
    }

    /// Plain RMSD (no fitting). Returns 0 for empty input.
    public static func rmsd(_ a: [Vec3], _ b: [Vec3]) -> Double {
        let n = min(a.count, b.count)
        guard n > 0 else { return 0 }
        var s = 0.0
        for i in 0..<n { let d = a[i] - b[i]; s += simd_dot(d, d) }
        return (s / Double(n)).squareRoot()
    }

    /// Optimal proper rotation + translation (apply as R*p + t) of `moving` onto `target`.
    public static func kabsch(moving: [Vec3], target: [Vec3], weights: [Double]? = nil)
        -> (rotation: simd_double3x3, translation: Vec3, rmsd: Double) {
        let n = min(moving.count, target.count)
        guard n > 0 else { return (matrix_identity_double3x3, .zero, 0) }
        let w: [Double] = (0..<n).map { i in
            if let ws = weights, i < ws.count { return ws[i] }
            return 1
        }
        let wsum = w.reduce(0, +)
        guard wsum > 0 else { return (matrix_identity_double3x3, .zero, 0) }
        var cp = Vec3.zero, cq = Vec3.zero
        for i in 0..<n { cp += moving[i] * w[i]; cq += target[i] * w[i] }
        cp /= wsum; cq /= wsum
        var sxx = 0.0, sxy = 0.0, sxz = 0.0, syx = 0.0, syy = 0.0, syz = 0.0, szx = 0.0, szy = 0.0, szz = 0.0
        for i in 0..<n {
            let p = moving[i] - cp, q = target[i] - cq, wi = w[i]
            sxx += wi * p.x * q.x; sxy += wi * p.x * q.y; sxz += wi * p.x * q.z
            syx += wi * p.y * q.x; syy += wi * p.y * q.y; syz += wi * p.y * q.z
            szx += wi * p.z * q.x; szy += wi * p.z * q.y; szz += wi * p.z * q.z
        }
        let nm: [[Double]] = [
            [sxx + syy + szz, syz - szy, szx - sxz, sxy - syx],
            [syz - szy, sxx - syy - szz, sxy + syx, szx + sxz],
            [szx - sxz, sxy + syx, -sxx + syy - szz, syz + szy],
            [sxy - syx, szx + sxz, syz + szy, -sxx - syy + szz],
        ]
        let (vals, vecs) = jacobiEigen(nm)
        var best = 0
        for i in 1..<4 where vals[i] > vals[best] { best = i }
        let qv = (0..<4).map { vecs[$0][best] }   // w,x,y,z
        let quat = simd_quatd(ix: qv[1], iy: qv[2], iz: qv[3], r: qv[0])
        let R = simd_double3x3(simd_normalize(quat))
        let t = cq - R * cp
        var s = 0.0
        for i in 0..<n { let d = R * moving[i] + t - target[i]; s += d.x * d.x + d.y * d.y + d.z * d.z }
        return (R, t, (s / Double(n)).squareRoot())
    }

    /// Cyclic Jacobi for a small symmetric matrix. Returns eigenvalues and eigenvectors (columns).
    static func jacobiEigen(_ m: [[Double]]) -> (values: [Double], vectors: [[Double]]) {
        let n = m.count
        var a = m
        var v = (0..<n).map { i in (0..<n).map { $0 == i ? 1.0 : 0.0 } }
        for _ in 0..<100 {
            var off = 0.0
            for p in 0..<n { for q in (p + 1)..<max(n, p + 1) { off += a[p][q] * a[p][q] } }
            if off < 1e-30 { break }
            for p in 0..<n {
                for q in (p + 1)..<max(n, p + 1) {
                    if abs(a[p][q]) < 1e-300 { continue }
                    let theta = (a[q][q] - a[p][p]) / (2 * a[p][q])
                    let t = (theta >= 0 ? 1.0 : -1.0) / (abs(theta) + (theta * theta + 1).squareRoot())
                    let c = 1 / (t * t + 1).squareRoot(), s = t * c
                    for k in 0..<n {
                        let akp = a[k][p], akq = a[k][q]
                        a[k][p] = c * akp - s * akq
                        a[k][q] = s * akp + c * akq
                    }
                    for k in 0..<n {
                        let apk = a[p][k], aqk = a[q][k]
                        a[p][k] = c * apk - s * aqk
                        a[q][k] = s * apk + c * aqk
                    }
                    for k in 0..<n {
                        let vkp = v[k][p], vkq = v[k][q]
                        v[k][p] = c * vkp - s * vkq
                        v[k][q] = s * vkp + c * vkq
                    }
                }
            }
        }
        return ((0..<n).map { a[$0][$0] }, v)
    }
}

extension Molecule {
    var masses: [Double] { atoms.map { $0.atomicNumber == 0 ? 0 : Elements.element($0.atomicNumber).mass } }

    public var centroid: Vec3 { Geometry.centroid(positions) }
    public var centerOfMass: Vec3 { Geometry.centerOfMass(positions, masses: masses) }

    public func inertiaTensor() -> simd_double3x3 {
        Geometry.inertiaTensor(positions, masses: masses, about: centerOfMass)
    }
    public func principalAxes() -> (moments: Vec3, axes: simd_double3x3) {
        Geometry.principalAxes(positions, masses: masses)
    }

    public func translated(by v: Vec3) -> Molecule { var m = self; m.translate(by: v); return m }
    public mutating func translate(by v: Vec3) {
        for i in atoms.indices { atoms[i].position += v }
    }

    public func transformed(rotation: simd_double3x3, translation: Vec3) -> Molecule {
        var m = self; m.transform(rotation: rotation, translation: translation); return m
    }
    public mutating func transform(rotation: simd_double3x3, translation: Vec3) {
        for i in atoms.indices { atoms[i].position = rotation * atoms[i].position + translation }
    }

    public func rmsd(to other: Molecule) -> Double { Geometry.rmsd(positions, other.positions) }

    public func alignedRMSD(to other: Molecule) -> Double {
        Geometry.kabsch(moving: positions, target: other.positions).rmsd
    }

    public func aligned(onto other: Molecule) -> Molecule {
        let r = Geometry.kabsch(moving: positions, target: other.positions)
        return transformed(rotation: r.rotation, translation: r.translation)
    }

    public func boundingBox() -> (min: Vec3, max: Vec3) {
        guard var lo = atoms.first?.position else { return (.zero, .zero) }
        var hi = lo
        for a in atoms { lo = simd_min(lo, a.position); hi = simd_max(hi, a.position) }
        return (lo, hi)
    }

    public var radiusOfGyration: Double {
        let p = positions, m = masses
        let tot = m.reduce(0, +)
        guard !p.isEmpty else { return 0 }
        if tot > 0 {
            let c = Geometry.centerOfMass(p, masses: m)
            var s = 0.0
            for i in p.indices { let d = p[i] - c; s += m[i] * simd_dot(d, d) }
            return (s / tot).squareRoot()
        }
        let c = Geometry.centroid(p)
        var s = 0.0
        for x in p { let d = x - c; s += simd_dot(d, d) }
        return (s / Double(p.count)).squareRoot()
    }
}
