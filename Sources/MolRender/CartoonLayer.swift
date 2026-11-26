import Foundation
import SceneKit
import simd
import MolCore
import MolAnalysis

/// Protein cartoon (style `.cartoon`): helices as flat ribbons, strands as arrows, loops as round tubes.
///
/// The trace is a Catmull-Rom spline through the CA atoms (strand CAs are smoothed to take out the pleat); the
/// ribbon's width direction follows the carbonyl C=O vectors, flipped to stay consistent along the chain. Every
/// cross-section is a superellipse with the same vertex count, so one continuous backbone segment is a single tube
/// whose section morphs between round (loop), flat (helix) and boxy (strand), with an arrowhead at each strand end.
/// One merged SCNGeometry per continuous segment ("cartoon:segment:<k>"), one element + material per color.
public enum CartoonLayerBuilder {
    /// Half width (along the C=O guide), half thickness and superellipse exponent of a cross-section.
    struct Profile { var w: Double, h: Double, n: Double }
    static let loop = Profile(w: 0.3, h: 0.3, n: 2)
    static let helix = Profile(w: 1.25, h: 0.28, n: 2)
    static let strand = Profile(w: 1.05, h: 0.3, n: 5)
    static let arrowHalfWidth = 1.65

    public static let helixColor = RGBA(0.88, 0.27, 0.48)
    public static let strandColor = RGBA(0.95, 0.76, 0.19)
    public static let loopColor = RGBA(0.78, 0.80, 0.82)
    public static let chainColors: [RGBA] = [
        RGBA(0.31, 0.56, 0.85), RGBA(0.36, 0.75, 0.45), RGBA(0.89, 0.54, 0.23), RGBA(0.69, 0.44, 0.82), RGBA(0.25, 0.72, 0.69),
        RGBA(0.85, 0.35, 0.35), RGBA(0.79, 0.70, 0.24), RGBA(0.48, 0.56, 0.88), RGBA(0.88, 0.48, 0.72), RGBA(0.54, 0.72, 0.31),
    ]

    /// Size of the last build (checks and the status bar).
    public struct Stats: Sendable, Equatable {
        public var segments = 0, residues = 0, vertices = 0, triangles = 0
        public var seconds = 0.0
    }

    // MARK: Visibility

    /// Residues drawn as cartoon: those in continuous segments of at least two residues.
    static func drawnResidues(_ p: ProteinStructure) -> [Bool] {
        var drawn = [Bool](repeating: false, count: p.residueCount)
        for s in p.segments where s.count >= 2 { for r in s { drawn[r] = true } }
        return drawn
    }

    /// Mask for `RenderOptions.atomMask`: polymer atoms hidden (CA of each drawn residue = pickable stand-in),
    /// backbone atoms of lone residues stay visible, water hidden when `hideWater`.
    public static func mask(_ p: ProteinStructure, atomCount n: Int, hideWater: Bool) -> AtomVisibilityMask {
        var st = [UInt8](repeating: 0, count: n)
        guard p.atomCount == n else { return AtomVisibilityMask(state: st) }
        for i in 0..<n where p.polymerAtoms[i] { st[i] = 1 }
        let drawn = drawnResidues(p)
        for (k, r) in p.residues.enumerated() {
            if drawn[k] { if r.ca >= 0 { st[r.ca] = 2 } } else { for a in [r.n, r.ca, r.c, r.o] where a >= 0 { st[a] = 0 } }
        }
        if hideWater { for i in 0..<n where p.waterAtoms[i] { st[i] = 1 } }
        return AtomVisibilityMask(state: st)
    }

    // MARK: Build

    /// Node named "vibeview.cartoon" with one child per continuous segment; empty when nothing is drawable.
    public static func build(protein p: ProteinStructure, molecule m: Molecule, options: RenderOptions,
                             materials: MaterialLibrary, stats: inout Stats) -> SCNNode {
        let t0 = CFAbsoluteTimeGetCurrent()
        let layer = SCNNode(); layer.name = NodeName.cartoon
        stats = Stats()
        guard p.atomCount == m.atoms.count, !p.isEmpty else { return layer }
        let total = p.segments.reduce(0) { $0 + ($1.count >= 2 ? $1.count : 0) }
        guard total > 0 else { return layer }
        let samplesPerResidue = total > 6000 ? 4 : total > 2000 ? 6 : 10
        let ringSize = total > 6000 ? 10 : 16
        let colors = residueColors(p, options: options)
        let P = m.atoms.map(\.position)
        var cosA = [Double](), sinA = [Double]()
        for k in 0..<ringSize { let a = Double(k) / Double(ringSize) * 2 * .pi; cosA.append(cos(a)); sinA.append(sin(a)) }

        for (si, seg) in p.segments.enumerated() where seg.count >= 2 {
            let mesh = segmentMesh(p, seg: seg, positions: P, colors: colors, S: samplesPerResidue, cosA: cosA, sinA: sinA)
            guard !mesh.verts.isEmpty else { continue }
            var groups = MergedGeometry.Groups()
            for (c, tris) in mesh.triangles {
                let g = groups.index(for: c)
                groups.indices[g] = tris
            }
            let node = MergedGeometry.assemble("cartoon:segment:\(si)", verts: mesh.verts, normals: mesh.normals, groups: groups, materials: materials)
            layer.addChildNode(node)
            stats.segments += 1
            stats.residues += seg.count
            stats.vertices += mesh.verts.count
            stats.triangles += mesh.triangles.reduce(0) { $0 + $1.1.count / 3 }
        }
        stats.seconds = CFAbsoluteTimeGetCurrent() - t0
        return layer
    }

    public static func residueColors(_ p: ProteinStructure, options: RenderOptions) -> [RGBA] {
        switch options.cartoonColoring {
        case .chain:
            let chains = p.chains
            let idx = Dictionary(uniqueKeysWithValues: chains.enumerated().map { ($0.element, $0.offset) })
            return p.residues.map { chainColors[(idx[$0.chain] ?? 0) % chainColors.count] }
        case .secondaryStructure:
            return p.ss.map { s in
                switch s.kind { case .helix: return helixColor; case .strand: return strandColor; case .loop: return loopColor }
            }
        }
    }

    struct Mesh {
        var verts: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        /// Triangles grouped by color, first-appearance order.
        var triangles: [(RGBA, [UInt32])] = []
        var slot: [RGBA: Int] = [:]
        mutating func add(_ c: RGBA, _ a: UInt32, _ b: UInt32, _ d: UInt32) {
            let s: Int
            if let x = slot[c] { s = x } else { s = triangles.count; slot[c] = s; triangles.append((c, [])) }
            triangles[s].1.append(a); triangles[s].1.append(b); triangles[s].1.append(d)
        }
    }

    struct Sample {
        var t: Double
        var p: Vec3
        var g: Vec3
        /// Ring role at an arrow base: body end, flat back face (inner/outer), or arrowhead start.
        enum Role { case normal, bodyEnd, capInner, capOuter, headStart }
        var role: Role = .normal
    }

    @inline(__always) static func norm(_ v: Vec3) -> Vec3 {
        let l = (v.x * v.x + v.y * v.y + v.z * v.z).squareRoot()
        return l > 1e-12 ? Vec3(v.x / l, v.y / l, v.z / l) : v
    }
    @inline(__always) static func dot(_ a: Vec3, _ b: Vec3) -> Double { a.x * b.x + a.y * b.y + a.z * b.z }
    @inline(__always) static func cross(_ a: Vec3, _ b: Vec3) -> Vec3 {
        Vec3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
    }
    @inline(__always) static func len2(_ v: Vec3) -> Double { v.x * v.x + v.y * v.y + v.z * v.z }

    static func catmull(_ p0: Vec3, _ p1: Vec3, _ p2: Vec3, _ p3: Vec3, _ t: Double) -> Vec3 {
        let t2 = t * t, t3 = t2 * t
        func c(_ a: Double, _ b: Double, _ cc: Double, _ d: Double) -> Double {
            0.5 * (2 * b + (-a + cc) * t + (2 * a - 5 * b + 4 * cc - d) * t2 + (-a + 3 * b - 3 * cc + d) * t3)
        }
        return Vec3(c(p0.x, p1.x, p2.x, p3.x), c(p0.y, p1.y, p2.y, p3.y), c(p0.z, p1.z, p2.z, p3.z))
    }

    static func segmentMesh(_ p: ProteinStructure, seg: Range<Int>, positions P: [Vec3], colors: [RGBA], S: Int,
                            cosA: [Double], sinA: [Double]) -> Mesh {
        let n = seg.count
        let s0 = seg.lowerBound
        let kind = seg.map { p.ss[$0].kind }
        let ca = seg.map { P[p.residues[$0].ca] }
        // Control points: interior strand CAs smoothed (the pleat would make the arrow zig-zag).
        var ctrl = ca
        for i in 1..<max(n - 1, 1) where kind[i] == .strand && kind[i - 1] == .strand && kind[i + 1] == .strand {
            ctrl[i] = ca[i] * 0.5 + ca[i - 1] * 0.25 + ca[i + 1] * 0.25
        }
        // Guides: C=O directions orthogonal to the local trace, flipped for consistency.
        var guide: [Vec3] = []
        guide.reserveCapacity(n)
        for i in 0..<n {
            let r = p.residues[s0 + i]
            let tan = norm(ctrl[min(i + 1, n - 1)] - ctrl[max(i - 1, 0)])
            var g: Vec3
            if r.o >= 0 && r.c >= 0 { g = P[r.o] - P[r.c] }
            else if i > 0 && i < n - 1 { g = cross(ca[i - 1] - ca[i], ca[i + 1] - ca[i]) }
            else { g = Vec3(0, 1, 0) }
            g = g - tan * dot(g, tan)
            if len2(g) < 1e-8 { g = cross(Vec3(1, 0, 0), tan) }
            if len2(g) < 1e-8 { g = cross(Vec3(0, 1, 0), tan) }
            g = norm(g)
            if i > 0 && dot(g, guide[i - 1]) < 0 { g = -g }
            guide.append(g)
        }
        // Strand guides smoothed (removes the residual alternation).
        var sg = guide
        for i in 0..<n where kind[i] == .strand {
            sg[i] = norm(guide[i] * 2 + guide[max(i - 1, 0)] + guide[min(i + 1, n - 1)])
        }
        func prof(_ k: SecondaryStructure.Kind) -> Profile { k == .helix ? helix : k == .strand ? strand : loop }
        func isArrowEnd(_ j: Int) -> Bool { kind[j] == .strand && j > 0 && kind[j - 1] == .strand && (j == n - 1 || kind[j + 1] != .strand) }
        let smooth: (Double) -> Double = { f in f * f * (3 - 2 * f) }

        /// Section shape and residue (for color) at spline parameter t (residue units).
        func shapeAt(_ t: Double) -> (Profile, Int) {
            let i = min(n - 1, max(0, Int(t.rounded())))
            let lo = min(n - 1, max(0, Int(t.rounded(.down)))), hi = min(n - 1, lo + 1), f = t - Double(lo)
            let jLo = max(0, Int((t - 0.6).rounded(.down))), jHi = min(n - 1, Int((t + 0.5).rounded(.up)))
            if jLo <= jHi {
                for j in jLo...jHi where isArrowEnd(j) {
                    let tj = Double(j)
                    if t >= tj - 0.5 && t <= tj + 0.6 {
                        let u = (t - (tj - 0.5)) / 1.1
                        return (Profile(w: arrowHalfWidth * (1 - u) + loop.w * u, h: strand.h * (1 - u) + loop.h * u,
                                        n: strand.n * (1 - u) + 2 * u), j)
                    }
                    if t > tj + 0.6 && t < tj + 1 { return (loop, min(n - 1, j + 1)) }
                }
            }
            let A = prof(kind[lo]), B = prof(kind[hi])
            if kind[lo] == .strand && kind[hi] != .strand { return (B, i) }
            let w = kind[lo] == kind[hi] ? 0 : smooth(f)
            return (Profile(w: A.w + (B.w - A.w) * w, h: A.h + (B.h - A.h) * w, n: A.n + (B.n - A.n) * w), i)
        }

        // Sample the spline.
        var samples: [Sample] = []
        let steps = (n - 1) * S
        samples.reserveCapacity(steps + 8)
        for k in 0...steps {
            let t = Double(k) / Double(S)
            let i = min(n - 2, Int(t.rounded(.down))), f = t - Double(i)
            let q = catmull(ctrl[max(i - 1, 0)], ctrl[i], ctrl[i + 1], ctrl[min(i + 2, n - 1)], f)
            samples.append(Sample(t: t, p: q, g: sg[i] * (1 - f) + sg[i + 1] * f))
        }
        // Arrow bases: four rings at one point (body end, flat back face inner/outer edge, arrowhead start).
        for j in 1..<n where isArrowEnd(j) {
            let tb = Double(j) - 0.5
            guard let k = samples.firstIndex(where: { $0.t > tb }), k > 0 else { continue }
            let a = samples[k - 1], b = samples[k]
            let f = (tb - a.t) / max(b.t - a.t, 1e-9)
            let q = a.p * (1 - f) + b.p * f, g = a.g * (1 - f) + b.g * f
            samples.insert(contentsOf: [Sample(t: tb, p: q, g: g, role: .bodyEnd), Sample(t: tb, p: q, g: g, role: .capInner),
                                        Sample(t: tb, p: q, g: g, role: .capOuter), Sample(t: tb, p: q, g: g, role: .headStart)], at: k)
        }

        var mesh = Mesh()
        mesh.verts.reserveCapacity(samples.count * cosA.count + 2 * (cosA.count + 1))
        mesh.normals.reserveCapacity(mesh.verts.capacity)
        let M = cosA.count
        var ringColor: [RGBA] = []
        var Ts: [Vec3] = []
        var prevW = Vec3(0, 1, 0), prevT = Vec3(1, 0, 0)
        for k in samples.indices {
            let q = samples[k]
            var T = samples[min(k + 1, samples.count - 1)].p - samples[max(k - 1, 0)].p
            // Coincident arrow-base rings: use the neighbours of the group.
            if len2(T) < 1e-10 {
                var a = k, b = k
                while a > 0 && len2(samples[a].p - q.p) < 1e-12 { a -= 1 }
                while b < samples.count - 1 && len2(samples[b].p - q.p) < 1e-12 { b += 1 }
                T = samples[b].p - samples[a].p
            }
            T = len2(T) < 1e-10 ? prevT : norm(T)
            var W = q.g - T * dot(q.g, T)
            W = len2(W) < 1e-8 ? prevW : norm(W)
            let B = cross(T, W)
            prevT = T; prevW = W; Ts.append(T)
            var (sh, res) = shapeAt(q.t)
            let tbRes = min(n - 1, Int((q.t + 0.5).rounded()))
            switch q.role {
            case .normal: break
            case .bodyEnd, .capInner: sh = strand; res = tbRes
            case .capOuter, .headStart: sh = Profile(w: arrowHalfWidth, h: strand.h, n: strand.n); res = tbRes
            }
            ringColor.append(colors[s0 + min(n - 1, max(0, res))])
            let flat = q.role == .capInner || q.role == .capOuter
            let e2 = 2 / sh.n
            for mI in 0..<M {
                let cx = cosA[mI], sy = sinA[mI]
                let x = (cx < 0 ? -1.0 : 1.0) * pow(abs(cx), e2) * sh.w
                let y = (sy < 0 ? -1.0 : 1.0) * pow(abs(sy), e2) * sh.h
                let pos = q.p + W * x + B * y
                mesh.verts.append(SIMD3<Float>(Float(pos.x), Float(pos.y), Float(pos.z)))
                let N: Vec3
                if flat { N = -T } else {
                    let nx = (cx < 0 ? -1.0 : 1.0) * pow(abs(cx), 2 - e2) / sh.w
                    let ny = (sy < 0 ? -1.0 : 1.0) * pow(abs(sy), 2 - e2) / sh.h
                    N = norm(W * nx + B * ny)
                }
                mesh.normals.append(SIMD3<Float>(Float(N.x), Float(N.y), Float(N.z)))
            }
        }
        for k in 0..<(samples.count - 1) {
            // Coincident rings except the back face (capInner→capOuter) give zero-area quads: skip them.
            if samples[k + 1].role == .capInner || samples[k + 1].role == .headStart { continue }
            let a = UInt32(k * M), b = UInt32((k + 1) * M)
            let c = ringColor[k + 1]
            for mI in 0..<M {
                let m2 = UInt32((mI + 1) % M), m1 = UInt32(mI)
                mesh.add(c, a + m1, a + m2, b + m1)
                mesh.add(c, a + m2, b + m2, b + m1)
            }
        }
        // End caps.
        for (k, sign) in [(0, -1.0), (samples.count - 1, 1.0)] {
            let base = k * M
            let T = Ts[k] * sign
            let nrm = SIMD3<Float>(Float(T.x), Float(T.y), Float(T.z))
            let center = UInt32(mesh.verts.count)
            let q = samples[k].p
            mesh.verts.append(SIMD3<Float>(Float(q.x), Float(q.y), Float(q.z))); mesh.normals.append(nrm)
            let ring = UInt32(mesh.verts.count)
            for mI in 0..<M { mesh.verts.append(mesh.verts[base + mI]); mesh.normals.append(nrm) }
            let c = ringColor[k]
            for mI in 0..<M {
                let m1 = UInt32(mI), m2 = UInt32((mI + 1) % M)
                if sign > 0 { mesh.add(c, center, ring + m1, ring + m2) } else { mesh.add(c, center, ring + m2, ring + m1) }
            }
        }
        return mesh
    }
}
