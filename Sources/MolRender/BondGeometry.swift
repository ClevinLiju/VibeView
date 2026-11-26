import Foundation
import simd
import MolCore

/// One straight piece of bond to draw (a full cylinder/line from `start` to `end`).
public struct BondSegment: Sendable, Equatable {
    public var start: Vec3, end: Vec3
    public var radius: Double
    public var color: RGBA
    /// True when this piece is (or came from) a dashed bond. `BondGeometry.segments` returns the
    /// undashed-length piece flagged `dashed`; `renderSegments` expands it into dash pieces (still flagged).
    public var dashed: Bool
    public var bondIndex: Int
    public init(start: Vec3, end: Vec3, radius: Double, color: RGBA, dashed: Bool, bondIndex: Int) {
        self.start = start; self.end = end; self.radius = radius; self.color = color; self.dashed = dashed; self.bondIndex = bondIndex
    }
    public var length: Double { simd_distance(start, end) }
}

/// Pure bond-drawing math (no SceneKit).
public enum BondGeometry {
    /// Radius factor of the individual lines of a multiple bond.
    public static let multiRadiusFactor = 0.5
    /// Center-to-center spacing of multiple-bond lines, in units of their (thin) radius.
    public static let offsetFactor = 2.6

    // MARK: Context (adjacency / rings), built lazily

    struct Context {
        let molecule: Molecule
        let adjacency: [[Int]]
        var ringCenters: [Vec3] = []
        var ringOfPair: [AtomPair: Int] = [:]
        init(_ m: Molecule) {
            molecule = m
            adjacency = m.adjacency()
            let rings = m.smallestSetOfSmallestRings().sorted { $0.count < $1.count }
            for (ri, ring) in rings.enumerated() {
                var c = Vec3.zero
                for a in ring { c += m.atoms[a].position }
                ringCenters.append(c / Double(max(ring.count, 1)))
                for k in ring.indices {
                    let p = AtomPair(ring[k], ring[(k + 1) % ring.count])
                    if ringOfPair[p] == nil { ringOfPair[p] = ri }
                }
            }
        }
        func offsetDirection(_ bi: Int) -> Vec3 {
            let b = molecule.bonds[bi]
            let pa = molecule.atoms[b.a].position, pb = molecule.atoms[b.b].position
            let axis = pb - pa
            let len = simd_length(axis)
            guard len > 1e-12 else { return Vec3(0, 0, 1) }
            let d = axis / len
            func perp(_ w: Vec3) -> Vec3 { w - simd_dot(w, d) * d }
            // 1. Smallest ring containing the bond: point to its interior.
            if let ri = ringOfPair[AtomPair(b.a, b.b)] {
                let p = perp(ringCenters[ri] - (pa + pb) / 2)
                let l = simd_length(p)
                if l > 1e-6 { return p / l }
            }
            // 2. Best-defined plane from a neighbor of either end.
            var best = Vec3.zero, bestLen = 0.05
            for (atom, other) in [(b.a, b.b), (b.b, b.a)] {
                let ref = molecule.atoms[atom].position
                for n in adjacency[atom] where n != other {
                    let p = perp(molecule.atoms[n].position - ref)
                    let l = simd_length(p)
                    if l > bestLen + 1e-9 { bestLen = l; best = p / l }
                }
            }
            if bestLen > 0.05 { return best }
            // 3. Linear: any perpendicular.
            return RenderMath.perpendicular(to: d)
        }
    }

    /// Unit vector perpendicular to bond `bondIndex`, in the plane of the bond and the best neighbor
    /// (toward the ring interior for ring bonds). Linear systems fall back to `RenderMath.perpendicular`.
    public static func offsetDirection(bondIndex: Int, in molecule: Molecule) -> Vec3 {
        guard bondIndex >= 0, bondIndex < molecule.bonds.count else { return Vec3(0, 0, 1) }
        return Context(molecule).offsetDirection(bondIndex)
    }

    /// Half-spacing of the two lines of a double bond (about the atom-atom axis), in units of the thin line radius.
    public static let doubleHalfFactor = 2.0

    /// One circle per aromatic ring (center = ring centroid, normal = ring plane normal, radius = 0.6 x mean
    /// center-to-atom distance). Empty unless the style is ball-and-stick with bond orders shown and `.circle`.
    public static func aromaticRingCircles(molecule: Molecule, options: RenderOptions) -> [(center: Vec3, normal: Vec3, radius: Double)] {
        guard options.aromaticStyle == .circle, options.showBondOrders, options.style == .ballAndStick || options.style == .cartoon else { return [] }
        var out: [(center: Vec3, normal: Vec3, radius: Double)] = []
        for ring in molecule.aromaticRings() where ring.count >= 3 {
            let pts = ring.map { molecule.atoms[$0].position }
            let c = pts.reduce(Vec3.zero, +) / Double(pts.count)
            var n = Vec3.zero   // Newell normal
            for k in pts.indices {
                let p = pts[k] - c, q = pts[(k + 1) % pts.count] - c
                n += simd_cross(p, q)
            }
            let nl = simd_length(n)
            n = nl > 1e-9 ? n / nl : Vec3(0, 0, 1)
            let mean = pts.reduce(0.0) { $0 + simd_distance($1, c) } / Double(pts.count)
            out.append((c, n, 0.6 * mean))
        }
        return out
    }

    // MARK: Segments

    /// All pieces to draw for the visible bonds. See task spec in the file header of BondLayer.
    public static func segments(molecule: Molecule, options: RenderOptions, colors: [RGBA]) -> [BondSegment] {
        let baseR = RenderMetrics.bondRadius(options: options)
        guard options.style != .spaceFilling, baseR > 0 else { return [] }
        let multi = options.showBondOrders && (options.style == .ballAndStick || options.style == .cartoon)
        var ctx: Context? = nil
        var kekule: [BondOrder]? = nil
        var out: [BondSegment] = []
        out.reserveCapacity(molecule.bonds.count * 2)
        func color(_ i: Int) -> RGBA { i < colors.count ? colors[i] : options.bondColor }

        for (bi, bond) in molecule.bonds.enumerated() {
            guard RenderMetrics.isBondVisible(bond, in: molecule, options: options) else { continue }
            let pa = molecule.atoms[bond.a].position, pb = molecule.atoms[bond.b].position
            let dashed = options.dashedBonds.contains(AtomPair(bond.a, bond.b))
            // (lateral offset, radius, dashed) per line
            var lines: [(Vec3, Double, Bool)] = [(.zero, baseR, dashed)]
            if multi, bond.order != .single, simd_distance(pa, pb) > 1e-9 {
                if ctx == nil { ctx = Context(molecule) }
                let u = ctx!.offsetDirection(bi)
                let r = baseR * multiRadiusFactor
                let s = r * offsetFactor
                let h = r * doubleHalfFactor
                switch bond.order {
                case .double: lines = [(u * (-h), r, dashed), (u * h, r, dashed)]
                case .triple: lines = [(u * (-s), r, dashed), (.zero, r, dashed), (u * s, r, dashed)]
                case .aromatic:
                    switch options.aromaticStyle {
                    case .dashed: lines = [(u * (-h), r, dashed), (u * h, r, true)]
                    case .circle: break
                    case .kekule:
                        if kekule == nil { kekule = molecule.kekuleDisplayOrders() }
                        if bi < kekule!.count, kekule![bi] == .double {
                            lines = [(u * (-h), r, dashed), (u * h, r, dashed)]
                        }
                    }
                case .single: break
                }
            }
            for (off, r, dsh) in lines {
                let a = pa + off, b = pb + off
                if options.splitBondColors {
                    let m = (a + b) / 2
                    out.append(BondSegment(start: a, end: m, radius: r, color: color(bond.a), dashed: dsh, bondIndex: bi))
                    out.append(BondSegment(start: m, end: b, radius: r, color: color(bond.b), dashed: dsh, bondIndex: bi))
                } else {
                    out.append(BondSegment(start: a, end: b, radius: r, color: options.bondColor, dashed: dsh, bondIndex: bi))
                }
            }
        }
        return out
    }

    /// Expand dashed segments into dash pieces (at least 2 per segment); solid segments pass through.
    /// Dash length is ~58 % of the period, period chosen so the piece divides evenly. Pieces stay flagged `dashed`.
    public static func expandDashes(_ segs: [BondSegment]) -> [BondSegment] {
        var out: [BondSegment] = []
        out.reserveCapacity(segs.count)
        for s in segs {
            guard s.dashed else { out.append(s); continue }
            let len = s.length
            guard len > 1e-9 else { out.append(s); continue }
            let period = max(s.radius * 3.6, 0.05)
            let n = max(2, Int((len / period).rounded()))
            let step = len / Double(n)
            let dir = (s.end - s.start) / len
            for k in 0..<n {
                let a = s.start + dir * (Double(k) * step + step * 0.1)
                let b = s.start + dir * (Double(k) * step + step * 0.68)
                var d = s; d.start = a; d.end = b
                out.append(d)
            }
        }
        return out
    }

    /// `segments` followed by `expandDashes`: exactly what the layer draws.
    public static func renderSegments(molecule: Molecule, options: RenderOptions, colors: [RGBA]) -> [BondSegment] {
        expandDashes(segments(molecule: molecule, options: options, colors: colors))
    }
}
