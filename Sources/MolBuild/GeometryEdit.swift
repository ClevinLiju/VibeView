import Foundation
import MolSIMD
import MolCore

// Internal-coordinate edits (Worker A, Lead 4).

public enum GeometryEdit {
    public static func distance(_ m: Molecule, _ a: Int, _ b: Int) -> Double {
        simd_distance(m.atoms[a].position, m.atoms[b].position)
    }

    public static func angle(_ m: Molecule, _ a: Int, _ b: Int, _ c: Int) -> Double {
        let u = bUnit(m.atoms[a].position - m.atoms[b].position)
        let v = bUnit(m.atoms[c].position - m.atoms[b].position)
        return acos(max(-1, min(1, simd_dot(u, v)))) * 180 / .pi
    }

    public static func dihedral(_ m: Molecule, _ a: Int, _ b: Int, _ c: Int, _ d: Int) -> Double {
        dihedralOf(m.atoms[a].position, m.atoms[b].position, m.atoms[c].position, m.atoms[d].position)
    }

    static func dihedralOf(_ p0: Vec3, _ p1: Vec3, _ p2: Vec3, _ p3: Vec3) -> Double {
        let b1 = p1 - p0, b2 = p2 - p1, b3 = p3 - p2
        let n1 = simd_cross(b1, b2), n2 = simd_cross(b2, b3)
        // IUPAC sign: positive when the front bond turns clockwise onto the back bond, viewed along b2.
        let x = simd_dot(n1, n2), y = simd_length(b2) * simd_dot(b1, n2)
        return atan2(y, x) * 180 / .pi
    }

    public static func movingSide(_ m: Molecule, fixed a: Int, moving b: Int) -> Set<Int> {
        var adj = [[Int]](repeating: [], count: m.atoms.count)
        for bd in m.bonds where bd.a < adj.count && bd.b < adj.count { adj[bd.a].append(bd.b); adj[bd.b].append(bd.a) }
        var seen: Set<Int> = [b]
        var stack = [b]
        while let x = stack.popLast() {
            for n in adj[x] {
                if x == b && n == a { continue }
                if n == a { return [b] }          // ring: a reachable another way
                if seen.insert(n).inserted { stack.append(n) }
            }
        }
        return seen
    }

    static func rotate(_ m: inout Molecule, _ set: Set<Int>, about origin: Vec3, axis: Vec3, radians: Double) {
        guard simd_length(axis) > 1e-12 else { return }
        for i in set { m.atoms[i].position = buildRotate(m.atoms[i].position, about: origin, axis: axis, angle: radians) }
    }

    public static func setDistance(_ m: inout Molecule, _ a: Int, _ b: Int, to d: Double) {
        let pa = m.atoms[a].position, pb = m.atoms[b].position
        let v = pb - pa
        let len = simd_length(v)
        let dir = len < 1e-9 ? Vec3(1, 0, 0) : v / len
        let delta = dir * (d - len)
        for i in movingSide(m, fixed: a, moving: b) { m.atoms[i].position += delta }
    }

    public static func setAngle(_ m: inout Molecule, _ a: Int, _ b: Int, _ c: Int, to degrees: Double) {
        let cur = angle(m, a, b, c)
        let pb = m.atoms[b].position
        let u = m.atoms[a].position - pb, v = m.atoms[c].position - pb
        var axis = simd_cross(u, v)
        if simd_length(axis) < 1e-9 { axis = buildPerpendicular(u) }
        // rotating v about (u x v) by +x moves v toward u... determine sign explicitly
        let delta = (degrees - cur) * .pi / 180
        // rotation about u×v by +θ moves u toward v, i.e. increases the angle when applied to v
        rotate(&m, movingSide(m, fixed: b, moving: c), about: pb, axis: axis, radians: delta)
    }

    public static func setDihedral(_ m: inout Molecule, _ a: Int, _ b: Int, _ c: Int, _ d: Int, to degrees: Double) {
        let cur = dihedral(m, a, b, c, d)
        var delta = degrees - cur
        while delta > 180 { delta -= 360 }
        while delta < -180 { delta += 360 }
        let pb = m.atoms[b].position, pc = m.atoms[c].position
        let side = movingSide(m, fixed: c, moving: d)
        rotate(&m, side, about: pc, axis: pc - pb, radians: delta * .pi / 180)
        // The handedness of the rotation relative to the dihedral sign is checked rather than assumed.
        var err = dihedral(m, a, b, c, d) - degrees
        while err > 180 { err -= 360 }
        while err < -180 { err += 360 }
        if abs(err) > 1e-6 { rotate(&m, side, about: pc, axis: pc - pb, radians: -2 * delta * .pi / 180) }
    }
}
