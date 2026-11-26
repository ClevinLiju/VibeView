import Foundation
import MolSIMD

// Point-group detection, symmetrization and standard orientation.
// Clean-room: generic algorithm (inertia tensor + candidate axes + atom-permutation test).

public enum SymmetryElement: Sendable, Hashable {
    case identity
    case inversion
    /// Proper rotation by 360/order degrees about `axis` (unit vector). order 0 = C-infinity (linear molecules).
    case rotation(axis: Vec3, order: Int)
    case reflection(normal: Vec3)
    /// Rotation by 360/order degrees followed by reflection in the plane perpendicular to `axis` (S_order).
    case improperRotation(axis: Vec3, order: Int)
}

public struct PointGroupResult: Sendable {
    /// "C1","Cs","Ci","C2","C3v","D6h","Td","Oh","Ih","D*h","C*v","S4","Kh" (single atom), ...
    public var schoenflies: String
    /// Identity, inversion, and one entry per distinct rotation axis (highest order), mirror plane,
    /// and improper axis (highest order). Generators of the group, not every operation.
    public var elements: [SymmetryElement]
    /// Group order; 0 for infinite groups (D*h, C*v, Kh).
    public var order: Int
    public var principalAxis: Vec3?
    public var tolerance: Double
    public init(schoenflies: String, elements: [SymmetryElement], order: Int, principalAxis: Vec3?, tolerance: Double) {
        self.schoenflies = schoenflies; self.elements = elements; self.order = order
        self.principalAxis = principalAxis; self.tolerance = tolerance
    }
}

public enum Symmetry {
    /// Detects the point group. `tolerance` (Å) is the max distance an atom may deviate from the
    /// position of a same-element atom after applying an operation. Molecules with more than 2000
    /// atoms return C1 immediately.
    public static func detect(_ m: Molecule, tolerance: Double = 0.1) -> PointGroupResult {
        let a = analyze(m, tol: tolerance)
        return PointGroupResult(schoenflies: a.name, elements: a.elements, order: a.order,
                                principalAxis: a.principal, tolerance: tolerance)
    }

    /// Averages atoms over the detected group's operations so the result is symmetric to
    /// numerical precision. Atom order, bonds and all other fields are preserved. Returns the
    /// input unchanged for C1.
    public static func symmetrize(_ m: Molecule, tolerance: Double = 0.1) -> Molecule {
        var cur = m
        for _ in 0..<6 {
            let (next, shift) = symmetrizeOnce(cur, tol: tolerance)
            cur = next
            if shift < 1e-10 { break }
        }
        return cur
    }

    /// Standard orientation (conventions documented here):
    /// - origin at the mass-weighted center; right-handed frame;
    /// - linear: axis along z; cubic groups: three perpendicular C4 (O/Oh) or C2 axes along x,y,z;
    /// - axial groups: principal axis along z; Dn: a perpendicular C2 along x; D2/D2h: z = axis of
    ///   smallest moment, x = largest (planar D2h lies in the yz plane); D2d: z = S4 axis;
    ///   C2v: the mirror plane containing most atoms is yz (planar C2v lies in yz); Cnv (n>=3): xz plane
    ///   is a mirror plane; Cs: mirror normal along z (planar Cs lies in xy);
    /// - C1/Ci: principal inertia axes, moments ascending along x, y, z (planar molecules lie in xy);
    /// - signs: the heaviest atom off the origin has z > 0 (then x > 0 where free).
    public static func standardOrientation(_ m: Molecule) -> Molecule {
        guard !m.atoms.isEmpty else { return m }
        let a = analyze(m, tol: 0.1)
        var f = orientationFrame(a)
        func coords(_ f: (x: Vec3, y: Vec3, z: Vec3)) -> [Vec3] {
            a.p.map { Vec3(simd_dot($0, f.x), simd_dot($0, f.y), simd_dot($0, f.z)) }
        }
        var q = coords(f)
        func heaviest(_ comp: (Vec3) -> Double) -> Int? {
            var best: Int? = nil
            for i in q.indices where abs(comp(q[i])) > 0.01 {
                if let b = best {
                    if m.atoms[i].atomicNumber > m.atoms[b].atomicNumber { best = i }
                } else { best = i }
            }
            return best
        }
        if let i = heaviest({ $0.z }), q[i].z < 0 { f = (f.x, -f.y, -f.z); q = coords(f) }
        if let i = heaviest({ $0.x }), q[i].x < 0 { f = (-f.x, -f.y, f.z); q = coords(f) }
        var out = m
        for i in out.atoms.indices { out.atoms[i].position = q[i] }
        return out
    }

    /// Applies a single symmetry operation (about the origin) to a point.
    /// `rotation`/`improperRotation` apply one step (360/order degrees); order 0 or 1 acts as the
    /// identity (resp. pure reflection for improper order 1).
    public static func apply(_ e: SymmetryElement, to p: Vec3) -> Vec3 {
        switch e {
        case .identity: return p
        case .inversion: return -p
        case .rotation(let axis, let order):
            guard order >= 2 else { return p }
            return VecMath.rotate(p, about: .zero, axis: axis, degrees: 360.0 / Double(order))
        case .reflection(let n):
            let l = simd_length(n)
            guard l > 1e-12 else { return p }
            let u = n / l
            return p - 2 * simd_dot(p, u) * u
        case .improperRotation(let axis, let order):
            let l = simd_length(axis)
            guard l > 1e-12 else { return p }
            let r = order >= 2 ? VecMath.rotate(p, about: .zero, axis: axis, degrees: 360.0 / Double(order)) : p
            let u = axis / l
            return r - 2 * simd_dot(r, u) * u
        }
    }
}

// MARK: - Internals

private typealias Frame = (x: Vec3, y: Vec3, z: Vec3)

private struct SymAnalysis {
    var name = "C1"
    var order = 1
    var elements: [SymmetryElement] = [.identity]
    var principal: Vec3? = nil
    var axes: [(dir: Vec3, order: Int)] = []
    var planes: [Vec3] = []
    var improper: [(dir: Vec3, n: Int)] = []
    var inversion = false
    var linear = false
    var com = Vec3.zero
    var p: [Vec3] = []
    var z: [Int] = []
    var mass: [Double] = []
    var tol = 0.1
    var inertiaValues = Vec3.zero
    var inertiaVectors = matrix_identity_double3x3
}

private struct SymCtx {
    let p: [Vec3]
    let grp: [Int]
    let groups: [[Int]]
    let order: [Int]
    let t2: Double
    let tol: Double
    /// Per group: member indices sorted by distance from the origin, and those distances. Every operation tested by
    /// `maps` is orthogonal (it preserves |p|), and |p_j - q| <= tol implies ||p_j| - |q|| <= tol, so only the members
    /// whose norm lies in [|q| - tol, |q| + tol] can match. Same answer as scanning the whole group, far fewer tests.
    let sortedGroups: [[Int]]
    let sortedNorms: [[Double]]

    init(p: [Vec3], z: [Int], tol: Double) {
        self.p = p
        var gid: [Int: Int] = [:]
        var g: [Int] = []
        var gs: [[Int]] = []
        for i in p.indices {
            if let k = gid[z[i]] { g.append(k); gs[k].append(i) }
            else { gid[z[i]] = gs.count; g.append(gs.count); gs.append([i]) }
        }
        grp = g; groups = gs
        order = p.indices.sorted {
            let ca = gs[g[$0]].count, cb = gs[g[$1]].count
            if ca != cb { return ca < cb }
            return simd_length_squared(p[$0]) > simd_length_squared(p[$1])
        }
        t2 = tol * tol
        self.tol = tol
        let norms = p.map { simd_length($0) }
        let sg = gs.map { $0.sorted { norms[$0] < norms[$1] } }
        sortedGroups = sg
        sortedNorms = sg.map { $0.map { norms[$0] } }
    }

    func maps(_ R: simd_double3x3) -> Bool {
        let slack = tol * (1 + 1e-9) + 1e-12  // a hair wider than tol, so rounding never excludes a true match
        for i in order {
            let q = R * p[i]
            let r = simd_length(q)
            let members = sortedGroups[grp[i]], ns = sortedNorms[grp[i]]
            // first member with norm >= r - slack
            var lo = 0, hi = ns.count
            while lo < hi { let mid = (lo + hi) / 2; if ns[mid] < r - slack { lo = mid + 1 } else { hi = mid } }
            var found = false
            var k = lo
            while k < ns.count, ns[k] <= r + slack {
                if simd_length_squared(p[members[k]] - q) <= t2 { found = true; break }
                k += 1
            }
            if !found { return false }
        }
        return true
    }
}

private func reflMatrix(_ n: Vec3) -> simd_double3x3 {
    let u = simd_normalize(n)
    func col(_ e: Vec3) -> Vec3 { e - 2 * simd_dot(e, u) * u }
    return simd_double3x3(columns: (col(Vec3(1, 0, 0)), col(Vec3(0, 1, 0)), col(Vec3(0, 0, 1))))
}
private func rotMatrix(_ axis: Vec3, _ n: Int) -> simd_double3x3 {
    VecMath.rotationMatrix(axis: axis, degrees: 360.0 / Double(n))
}
private func invMatrix() -> simd_double3x3 { -1.0 * matrix_identity_double3x3 }

private func par(_ a: Vec3, _ b: Vec3) -> Bool { abs(simd_dot(a, b)) > 0.995 }
private func perp(_ a: Vec3, _ b: Vec3) -> Bool { abs(simd_dot(a, b)) < 0.05 }

private func groupOrder(_ name: String) -> Int {
    switch name {
    case "C1": return 1
    case "Cs", "Ci": return 2
    case "T": return 12
    case "Td", "Th", "O": return 24
    case "Oh": return 48
    case "I": return 60
    case "Ih": return 120
    case "D*h", "C*v", "Kh": return 0
    default: break
    }
    let rest = name.dropFirst()
    let digits = rest.prefix { $0.isNumber }
    guard let n = Int(digits) else { return 1 }
    let suffix = rest.dropFirst(digits.count)
    switch name.first! {
    case "C": return suffix.isEmpty ? n : 2 * n
    case "S": return n
    case "D": return suffix.isEmpty ? 2 * n : 4 * n
    default: return 1
    }
}

private func analyze(_ mol: Molecule, tol: Double) -> SymAnalysis {
    var a = SymAnalysis()
    a.tol = tol
    let n = mol.atoms.count
    guard n > 0 else { return a }
    a.z = mol.atoms.map(\.atomicNumber)
    a.mass = a.z.map { let m = Elements.element($0).mass; return m > 0 ? m : 1.0 }
    let mt = a.mass.reduce(0, +)
    var com = Vec3.zero
    for i in 0..<n { com += a.mass[i] * mol.atoms[i].position }
    com /= mt
    a.com = com
    a.p = mol.atoms.map { $0.position - com }
    // inertia
    var I = simd_double3x3()
    for i in 0..<n {
        let r = a.p[i], m = a.mass[i], r2 = simd_length_squared(r)
        I[0][0] += m * (r2 - r.x * r.x); I[1][1] += m * (r2 - r.y * r.y); I[2][2] += m * (r2 - r.z * r.z)
        I[0][1] -= m * r.x * r.y; I[1][0] -= m * r.x * r.y
        I[0][2] -= m * r.x * r.z; I[2][0] -= m * r.x * r.z
        I[1][2] -= m * r.y * r.z; I[2][1] -= m * r.y * r.z
    }
    let eig = VecMath.symmetricEigen(I)
    a.inertiaValues = eig.values; a.inertiaVectors = eig.vectors
    if n == 1 { a.name = "Kh"; a.order = 0; a.elements = [.identity, .inversion]; a.inversion = true; return a }
    if n > 2000 { return a }
    let ctx = SymCtx(p: a.p, z: a.z, tol: tol)
    let e0 = eig.vectors.columns.0, e1 = eig.vectors.columns.1, e2 = eig.vectors.columns.2

    // Linear?
    var maxPerp = 0.0
    for r in a.p { maxPerp = max(maxPerp, simd_length(r - simd_dot(r, e0) * e0)) }
    if maxPerp < tol && simd_length(a.p.max { simd_length($0) < simd_length($1) }!) > 1e-9 {
        a.linear = true
        a.principal = e0
        let inv = ctx.maps(invMatrix())
        a.inversion = inv
        a.name = inv ? "D*h" : "C*v"
        a.order = 0
        let pn = VecMath.perpendicular(e0)
        a.elements = [.identity, .rotation(axis: e0, order: 0), .reflection(normal: pn)]
        if inv { a.elements += [.inversion, .reflection(normal: e0)] }
        a.planes = [pn]
        return a
    }

    // Candidate directions.
    var seen = Set<SIMD3<Int32>>()
    var cands: [Vec3] = []
    let cap = 20000
    func add(_ v: Vec3, minLen: Double = 1e-3) {
        let l = simd_length(v)
        guard l > minLen, cands.count < cap else { return }
        var u = v / l
        let ax = abs(u.x) >= abs(u.y) && abs(u.x) >= abs(u.z) ? u.x : (abs(u.y) >= abs(u.z) ? u.y : u.z)
        if ax < 0 { u = -u }
        let key = SIMD3<Int32>(Int32((u.x * 50).rounded()), Int32((u.y * 50).rounded()), Int32((u.z * 50).rounded()))
        if seen.insert(key).inserted { cands.append(u) }
    }
    func addCross(_ x: Vec3, _ y: Vec3) {
        let c = simd_cross(x, y)
        let lx = simd_length(x), ly = simd_length(y)
        if lx > 1e-3 && ly > 1e-3 && simd_length(c) > 0.02 * lx * ly { add(c, minLen: 1e-9) }
    }
    add(e0); add(e1); add(e2)
    for i in 0..<n { add(a.p[i]) }
    let allPairs = n <= 150
    outer: for i in 0..<n {
        for j in (i + 1)..<max(n, i + 1) {
            if cands.count >= cap { break outer }
            let same = ctx.grp[i] == ctx.grp[j]
            if same { add(a.p[i] + a.p[j]); add(a.p[i] - a.p[j]) }
            if same || allPairs { addCross(a.p[i], a.p[j]) }
        }
    }
    if n <= 400 {
        for i in 0..<n {
            let near = (0..<n).filter { $0 != i }
                .sorted { simd_length_squared(a.p[$0] - a.p[i]) < simd_length_squared(a.p[$1] - a.p[i]) }
                .prefix(6)
            let nb = Array(near)
            for x in 0..<nb.count {
                for y in (x + 1)..<max(nb.count, x + 1) {
                    let u = a.p[nb[x]] - a.p[i], v = a.p[nb[y]] - a.p[i]
                    addCross(u, v)
                    add(a.p[i] + a.p[nb[x]] + a.p[nb[y]])
                }
            }
        }
    }

    // Test candidates.
    func rotOrder(_ u: Vec3) -> Int {
        var any = false
        for pr in [2, 3, 5, 7, 11] where ctx.maps(rotMatrix(u, pr)) { any = true; break }
        if !any { return 1 }
        for k in stride(from: 12, through: 2, by: -1) where ctx.maps(rotMatrix(u, k)) { return k }
        return 1
    }
    var axes: [(dir: Vec3, order: Int)] = []
    var planes: [Vec3] = []
    for u in cands {
        let k = rotOrder(u)
        if k >= 2 {
            if let idx = axes.firstIndex(where: { par($0.dir, u) }) {
                if axes[idx].order < k { axes[idx] = (u, k) }
            } else { axes.append((u, k)) }
        }
        if ctx.maps(reflMatrix(u)), !planes.contains(where: { par($0, u) }) { planes.append(u) }
    }
    axes.sort { $0.order > $1.order }
    a.axes = axes; a.planes = planes
    a.inversion = ctx.maps(invMatrix())
    // Improper axes
    var improper: [(dir: Vec3, n: Int)] = []
    for ax in axes {
        for s in stride(from: 2 * ax.order, through: 3, by: -1) {
            let ok = s % 2 == 0 ? ax.order % (s / 2) == 0 : ax.order % s == 0
            if ok, ctx.maps(rotMatrix(ax.dir, s) * reflMatrix(ax.dir)) { improper.append((ax.dir, s)); break }
        }
    }
    a.improper = improper

    // Classification.
    let highs = axes.filter { $0.order >= 3 }
    var name = "C1"
    var principal: Vec3? = nil
    if highs.count >= 2 {
        if axes.contains(where: { $0.order % 5 == 0 }) { name = a.inversion ? "Ih" : "I" }
        else if axes.contains(where: { $0.order % 4 == 0 }) { name = a.inversion ? "Oh" : "O" }
        else if a.inversion { name = "Th" }
        else if !planes.isEmpty { name = "Td" }
        else { name = "T" }
        principal = highs[0].dir
    } else if axes.isEmpty {
        if !planes.isEmpty { name = "Cs"; principal = planes[0] }
        else if a.inversion { name = "Ci" }
        else { name = "C1" }
    } else {
        var pr = axes[0]
        let nmax = pr.order
        if nmax == 2, let s4 = improper.first(where: { $0.n == 4 }) {
            pr = axes.first(where: { par($0.dir, s4.dir) }) ?? pr
        }
        let pd = pr.dir
        let nn = pr.order
        principal = pd
        let perpC2 = axes.contains { $0.order % 2 == 0 && perp($0.dir, pd) }
        let sigmaH = planes.contains { par($0, pd) }
        let sigmaV = planes.contains { perp($0, pd) }
        if perpC2 {
            if nn == 2 {
                if improper.contains(where: { $0.n == 4 && par($0.dir, pd) }) { name = "D2d" }
                else if !planes.isEmpty { name = "D2h" } else { name = "D2" }
            } else if sigmaH { name = "D\(nn)h" }
            else if !planes.isEmpty { name = "D\(nn)d" }
            else { name = "D\(nn)" }
        } else if sigmaH { name = "C\(nn)h" }
        else if sigmaV { name = "C\(nn)v" }
        else if improper.contains(where: { $0.n == 2 * nn && par($0.dir, pd) }) { name = "S\(2 * nn)" }
        else { name = "C\(nn)" }
    }
    a.name = name
    a.principal = principal
    a.order = groupOrder(name)
    var els: [SymmetryElement] = [.identity]
    if a.inversion { els.append(.inversion) }
    for ax in axes { els.append(.rotation(axis: ax.dir, order: ax.order)) }
    for pl in planes { els.append(.reflection(normal: pl)) }
    for im in improper { els.append(.improperRotation(axis: im.dir, order: im.n)) }
    a.elements = els
    return a
}

private func matrix(for e: SymmetryElement) -> simd_double3x3? {
    switch e {
    case .identity: return matrix_identity_double3x3
    case .inversion: return invMatrix()
    case .rotation(let ax, let n): return n >= 2 ? rotMatrix(ax, n) : nil
    case .reflection(let nrm): return reflMatrix(nrm)
    case .improperRotation(let ax, let n): return n >= 2 ? rotMatrix(ax, n) * reflMatrix(ax) : reflMatrix(ax)
    }
}

private func closure(_ gens: [simd_double3x3], limit: Int) -> [simd_double3x3] {
    var list = [matrix_identity_double3x3]
    func same(_ x: simd_double3x3, _ y: simd_double3x3) -> Bool {
        for c in 0..<3 { for r in 0..<3 where abs(x[c][r] - y[c][r]) > 0.05 { return false } }
        return true
    }
    var i = 0
    while i < list.count {
        for g in gens {
            let h = g * list[i]
            if !list.contains(where: { same($0, h) }) {
                list.append(h)
                if list.count > limit { return list }
            }
        }
        i += 1
    }
    return list
}

private func symmetrizeOnce(_ m: Molecule, tol: Double) -> (Molecule, Double) {
    let n = m.atoms.count
    guard n >= 2, n <= 2000 else { return (m, 0) }
    let a = analyze(m, tol: tol)
    if a.name == "C1" { return (m, 0) }
    var out = m
    if a.linear, let ax = a.principal {
        var np = a.p.map { simd_dot($0, ax) * ax }
        if a.inversion {
            let ctx = SymCtx(p: np, z: a.z, tol: tol)
            var acc = np
            for i in 0..<n {
                for j in ctx.groups[ctx.grp[i]] where simd_length(np[j] + np[i]) <= tol {
                    acc[i] = (np[i] - np[j]) / 2; break
                }
            }
            np = acc
        }
        var shift = 0.0
        for i in 0..<n { let q = np[i] + a.com; shift = max(shift, simd_length(q - m.atoms[i].position)); out.atoms[i].position = q }
        return (out, shift)
    }
    let gens = a.elements.compactMap { matrix(for: $0) }
    let expected = max(a.order, 1)
    var ops = closure(gens, limit: expected * 2 + 4)
    if ops.count > expected * 2 { ops = [matrix_identity_double3x3] + gens }
    let ctx = SymCtx(p: a.p, z: a.z, tol: tol * 1.5)
    var acc = [Vec3](repeating: .zero, count: n)
    var used = 0
    for R in ops {
        var perm = [Int](repeating: -1, count: n)
        var taken = Set<Int>()
        var ok = true
        for i in 0..<n {
            let q = R * a.p[i]
            var best = -1, bd = Double.infinity
            for j in ctx.groups[ctx.grp[i]] {
                let d = simd_length_squared(a.p[j] - q)
                if d < bd { bd = d; best = j }
            }
            if best < 0 || bd > ctx.t2 || !taken.insert(best).inserted { ok = false; break }
            perm[i] = best
        }
        if !ok { continue }
        used += 1
        let Rt = R.transpose
        for i in 0..<n { acc[i] += Rt * a.p[perm[i]] }
    }
    guard used > 0 else { return (m, 0) }
    var shift = 0.0
    for i in 0..<n {
        let q = acc[i] / Double(used) + a.com
        shift = max(shift, simd_length(q - m.atoms[i].position))
        out.atoms[i].position = q
    }
    return (out, shift)
}

private func orientationFrame(_ a: SymAnalysis) -> Frame {
    let e0 = a.inertiaVectors.columns.0, e1 = a.inertiaVectors.columns.1, e2 = a.inertiaVectors.columns.2
    func finish(_ z0: Vec3, _ xHint: Vec3?) -> Frame {
        let z = simd_normalize(z0)
        var x = xHint ?? VecMath.perpendicular(z)
        x -= simd_dot(x, z) * z
        if simd_length(x) < 1e-6 { x = VecMath.perpendicular(z) } else { x = simd_normalize(x) }
        return (x, simd_cross(z, x), z)
    }
    let inertiaFrame: Frame = (e0, e1, e2)
    func moment(_ u: Vec3) -> Double {
        var s = 0.0
        for i in a.p.indices { s += a.mass[i] * (simd_length_squared(a.p[i]) - pow(simd_dot(a.p[i], u), 2)) }
        return s
    }
    func inPlane(_ nrm: Vec3) -> Int { a.p.filter { abs(simd_dot($0, nrm)) < a.tol }.count }
    func offAxisHint(_ pd: Vec3) -> Vec3? {
        var best: Vec3? = nil; var bz = -1
        for i in a.p.indices {
            let r = a.p[i] - simd_dot(a.p[i], pd) * pd
            if simd_length(r) > 0.05 && a.z[i] > bz { bz = a.z[i]; best = r }
        }
        return best
    }
    let name = a.name
    if name == "Kh" || name == "C1" || name == "Ci" || a.p.isEmpty { return inertiaFrame }
    if a.linear { return finish(e0, nil) }
    if name == "Cs" {
        let nrm = a.planes[0]
        for e in [e0, e1, e2] where perp(e, nrm) { return finish(nrm, e) }
        return finish(nrm, nil)
    }
    if ["T", "Td", "Th", "O", "Oh", "I", "Ih"].contains(name) {
        let wantOrder = name.hasPrefix("O") ? 4 : 2
        let sel = a.axes.filter { wantOrder == 4 ? $0.order % 4 == 0 : $0.order == 2 }
        if let zA = sel.first, let xA = sel.first(where: { perp($0.dir, zA.dir) }) {
            return finish(zA.dir, xA.dir)
        }
        return inertiaFrame
    }
    guard let pd = a.principal else { return inertiaFrame }
    if name == "D2" || name == "D2h" {
        let two = a.axes.filter { $0.order == 2 }.map(\.dir).sorted { moment($0) < moment($1) }
        if two.count >= 3 { return finish(two[0], two[2]) }
        return inertiaFrame
    }
    if name.hasPrefix("D") {
        if let c2 = a.axes.first(where: { $0.order % 2 == 0 && perp($0.dir, pd) }) { return finish(pd, c2.dir) }
        return finish(pd, nil)
    }
    if name.hasSuffix("v") {
        let vs = a.planes.filter { perp($0, pd) }
        if let best = vs.max(by: { inPlane($0) < inPlane($1) }) {
            if name == "C2v" { return finish(pd, best) }
            return finish(pd, simd_cross(best, pd))
        }
    }
    return finish(pd, offAxisHint(pd))
}
