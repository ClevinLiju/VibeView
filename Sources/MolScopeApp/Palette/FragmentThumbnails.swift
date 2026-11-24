import AppKit
import SwiftUI
import simd
import MolCore
import MolBuild

/// A 2-D skeletal drawing computed from a fragment's own 3-D template geometry: heavy atoms are projected onto
/// their best-fit plane (principal axes), carbons are bare vertices, heteroatoms are labelled with their
/// hydrogens, aromatic rings use one Kekulé structure, and the attachment point is drawn as an accent stub.
struct FragmentSketch: Equatable {
    struct Node: Equatable { var p: CGPoint; var label: String?; var z: Int }
    struct Edge: Equatable { var a: Int; var b: Int; var order: Int }
    var nodes: [Node] = []
    var edges: [Edge] = []
    /// Attachment stub: from the anchor node toward where the host would be.
    var stub: (anchor: Int, to: CGPoint)?

    static func == (l: FragmentSketch, r: FragmentSketch) -> Bool {
        l.nodes == r.nodes && l.edges == r.edges && l.stub?.anchor == r.stub?.anchor && l.stub?.to == r.stub?.to
    }

    /// Positions are normalised into the unit square [0,1]² (y down), aspect preserved and centred.
    static func make(_ f: Fragment) -> FragmentSketch {
        let m = f.molecule
        let heavy = m.atoms.indices.filter { m.atoms[$0].atomicNumber > 1 }
        guard !heavy.isEmpty else { return FragmentSketch() }
        let index = Dictionary(uniqueKeysWithValues: heavy.enumerated().map { ($1, $0) })

        // Best-fit plane of the heavy atoms (+ the attachment direction so the stub is not foreshortened).
        var pts = heavy.map { m.atoms[$0].position }
        pts.append(m.atoms[f.leaving].position)
        let c = pts.reduce(Vec3.zero, +) / Double(pts.count)
        var cov = simd_double3x3(0)
        for p in pts { let d = p - c; cov += simd_double3x3(columns: (d * d.x, d * d.y, d * d.z)) }
        let eig = VecMath.symmetricEigen(cov)
        let vals = [eig.values.x, eig.values.y, eig.values.z]
        let cols = [eig.vectors.columns.0, eig.vectors.columns.1, eig.vectors.columns.2]
        let order = [0, 1, 2].sorted { vals[$0] > vals[$1] }
        var u = cols[order[0]], v = cols[order[1]]
        if simd_length(u) < 1e-9 { u = Vec3(1, 0, 0) }
        if simd_length(v) < 1e-9 || pts.count < 3 { v = buildPerpendicular(u) }
        // Non-planar groups (tert-butyl, CF3…): tilt the view about both in-plane axes and keep the projection in which
        // atoms (and the stub end) overlap least.
        let w = simd_normalize(simd_cross(u, v))
        var best = (score: Double.infinity, u: u, v: v)
        for a in stride(from: -60.0, through: 60.0, by: 15.0) {
            for b in stride(from: -60.0, through: 60.0, by: 15.0) {
                let ra = a * .pi / 180, rb = b * .pi / 180
                let v1 = cos(ra) * v + sin(ra) * w
                let w1 = simd_cross(u, v1)
                let u1 = cos(rb) * u + sin(rb) * w1
                let q = pts.map { CGPoint(x: simd_dot($0 - c, u1), y: simd_dot($0 - c, v1)) }
                var sc = 0.0
                for i in q.indices { for j in q.indices where j > i {
                    let d2 = max(Double((q[i].x - q[j].x) * (q[i].x - q[j].x) + (q[i].y - q[j].y) * (q[i].y - q[j].y)), 0.01)
                    sc += 1 / d2
                } }
                sc *= 1 + 0.002 * (a * a + b * b) / 100   // prefer the principal plane when it is about as good
                if sc < best.score { best = (sc, u1, v1) }
            }
        }
        u = best.u; v = best.v
        func proj(_ p: Vec3) -> CGPoint { let d = p - c; return CGPoint(x: simd_dot(d, u), y: -simd_dot(d, v)) }

        let kek = m.kekuleDisplayOrders()
        var s = FragmentSketch()
        for i in heavy {
            let z = m.atoms[i].atomicNumber
            let hCount = m.buildNeighbors(of: i).filter { $0 != f.leaving && m.atoms[$0].atomicNumber == 1 }.count
            var label: String? = nil
            if z != 6 || heavy.count == 1 {
                let sym = Elements.symbol(z)
                label = hCount == 0 ? sym : sym + "H" + (hCount > 1 ? "\(hCount)" : "")
            }
            s.nodes.append(Node(p: proj(m.atoms[i].position), label: label, z: z))
        }
        for (k, b) in m.bonds.enumerated() {
            guard let ia = index[b.a], let ib = index[b.b] else { continue }
            let o: Int = switch kek.indices.contains(k) ? kek[k] : b.order {
            case .double: 2
            case .triple: 3
            default: 1
            }
            s.edges.append(Edge(a: ia, b: ib, order: o))
        }
        if let ai = index[f.anchor] {
            let a = proj(m.atoms[f.anchor].position), l = proj(m.atoms[f.leaving].position)
            let dx = l.x - a.x, dy = l.y - a.y, len = max(hypot(dx, dy), 1e-6)
            // A full bond length so the stub reads as "attaches here", even if the H was foreshortened.
            s.stub = (ai, CGPoint(x: a.x + dx / len * 1.0, y: a.y + dy / len * 1.0))
        }
        // Normalise.
        var all = s.nodes.map(\.p); if let st = s.stub { all.append(st.to) }
        let minX = all.map(\.x).min()!, maxX = all.map(\.x).max()!, minY = all.map(\.y).min()!, maxY = all.map(\.y).max()!
        let span = max(maxX - minX, maxY - minY, 1.2)
        func norm(_ p: CGPoint) -> CGPoint {
            CGPoint(x: 0.5 + (p.x - (minX + maxX) / 2) / span, y: 0.5 + (p.y - (minY + maxY) / 2) / span)
        }
        s.nodes = s.nodes.map { var n = $0; n.p = norm(n.p); return n }
        if let st = s.stub { s.stub = (st.anchor, norm(st.to)) }
        return s
    }

    /// Draw into `rect` (flipped coordinates, y down).
    func draw(in rect: CGRect, ink: NSColor, accent: NSColor) {
        guard !nodes.isEmpty else { return }
        let pad = rect.width * 0.12
        let box = rect.insetBy(dx: pad, dy: pad)
        func P(_ p: CGPoint) -> CGPoint { CGPoint(x: box.minX + p.x * box.width, y: box.minY + p.y * box.height) }
        let lw = max(1.0, rect.width / 26)
        let fontSize = max(7, rect.width * 0.2)
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let labelGap = fontSize * 0.55
        let center = nodes.reduce(CGPoint.zero) { CGPoint(x: $0.x + P($1.p).x, y: $0.y + P($1.p).y) }
        let cen = CGPoint(x: center.x / CGFloat(nodes.count), y: center.y / CGFloat(nodes.count))

        func trimmed(_ a: Int, _ pa: CGPoint, _ pb: CGPoint, toward b: Int?) -> (CGPoint, CGPoint) {
            let dx = pb.x - pa.x, dy = pb.y - pa.y, len = max(hypot(dx, dy), 1e-6)
            var s = pa, e = pb
            if nodes[a].label != nil { s = CGPoint(x: pa.x + dx / len * labelGap, y: pa.y + dy / len * labelGap) }
            if let b, nodes[b].label != nil { e = CGPoint(x: pb.x - dx / len * labelGap, y: pb.y - dy / len * labelGap) }
            return (s, e)
        }
        func line(_ s: CGPoint, _ e: CGPoint, _ color: NSColor, width: CGFloat) {
            let path = NSBezierPath(); path.move(to: s); path.line(to: e)
            path.lineWidth = width; path.lineCapStyle = .round
            color.setStroke(); path.stroke()
        }

        if let st = stub {
            let (s, e) = trimmed(st.anchor, P(nodes[st.anchor].p), P(st.to), toward: nil)
            line(s, e, accent, width: lw)
            accent.setFill()
            let r = lw * 1.4
            NSBezierPath(ovalIn: CGRect(x: e.x - r, y: e.y - r, width: 2 * r, height: 2 * r)).fill()
        }
        for ed in edges {
            let pa = P(nodes[ed.a].p), pb = P(nodes[ed.b].p)
            let (s, e) = trimmed(ed.a, pa, pb, toward: ed.b)
            let dx = e.x - s.x, dy = e.y - s.y, len = max(hypot(dx, dy), 1e-6)
            var nx = -dy / len, ny = dx / len
            let off = lw * 2.0
            switch ed.order {
            case 2:
                // Second line on the side facing the drawing's centre (inside rings), slightly shortened.
                let mid = CGPoint(x: (s.x + e.x) / 2, y: (s.y + e.y) / 2)
                if (cen.x - mid.x) * nx + (cen.y - mid.y) * ny < 0 { nx = -nx; ny = -ny }
                let inRingLike = nodes[ed.a].label == nil && nodes[ed.b].label == nil && edges.count >= 3
                if inRingLike {
                    line(s, e, ink, width: lw)
                    let sh = 0.16
                    let s2 = CGPoint(x: s.x + dx * sh + nx * off, y: s.y + dy * sh + ny * off)
                    let e2 = CGPoint(x: e.x - dx * sh + nx * off, y: e.y - dy * sh + ny * off)
                    line(s2, e2, ink, width: lw)
                } else {
                    let h = off / 2
                    line(CGPoint(x: s.x + nx * h, y: s.y + ny * h), CGPoint(x: e.x + nx * h, y: e.y + ny * h), ink, width: lw)
                    line(CGPoint(x: s.x - nx * h, y: s.y - ny * h), CGPoint(x: e.x - nx * h, y: e.y - ny * h), ink, width: lw)
                }
            case 3:
                line(s, e, ink, width: lw)
                line(CGPoint(x: s.x + nx * off, y: s.y + ny * off), CGPoint(x: e.x + nx * off, y: e.y + ny * off), ink, width: lw)
                line(CGPoint(x: s.x - nx * off, y: s.y - ny * off), CGPoint(x: e.x - nx * off, y: e.y - ny * off), ink, width: lw)
            default:
                line(s, e, ink, width: lw)
            }
        }
        for n in nodes {
            guard let label = n.label else { continue }
            let color = FragmentSketch.labelColor(n.z, ink: ink)
            let str = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: color])
            let sz = str.size()
            let p = P(n.p)
            // Keep the element symbol centred on the atom; trailing "H2" extends to the right.
            let symW = NSAttributedString(string: Elements.symbol(n.z), attributes: [.font: font]).size().width
            var x = p.x - symW / 2
            x = min(max(x, rect.minX + 1), rect.maxX - sz.width - 1)
            str.draw(at: CGPoint(x: x, y: p.y - sz.height / 2))
        }
    }

    static func labelColor(_ z: Int, ink: NSColor) -> NSColor {
        switch z {
        case 7: return NSColor.systemBlue
        case 8: return NSColor.systemRed
        case 9, 17: return NSColor.systemGreen
        case 16: return NSColor.systemYellow.blended(withFraction: 0.35, of: .systemOrange) ?? .systemYellow
        case 35: return NSColor.systemBrown
        case 53: return NSColor.systemPurple
        case 15: return NSColor.systemOrange
        default: return ink
        }
    }
}

/// Cached thumbnails for the fragment palette (generated once per fragment and size).
@MainActor
enum FragmentThumbnails {
    private static let cache = NSCache<NSString, NSImage>()
    private static var sketches: [String: FragmentSketch] = [:]

    static func sketch(_ id: String) -> FragmentSketch? {
        if let s = sketches[id] { return s }
        guard let f = FragmentLibrary.fragment(id: id) else { return nil }
        let s = FragmentSketch.make(f)
        sketches[id] = s
        return s
    }

    static func image(_ id: String, side: CGFloat = 30) -> NSImage {
        let key = "\(id)@\(side)" as NSString
        if let img = cache.object(forKey: key) { return img }
        let s = sketch(id) ?? FragmentSketch()
        // Drawn lazily in the current appearance (label colours adapt to light/dark).
        let img = NSImage(size: NSSize(width: side, height: side), flipped: true) { rect in
            s.draw(in: rect, ink: .labelColor, accent: .controlAccentColor)
            return true
        }
        cache.setObject(img, forKey: key)
        return img
    }
}

/// SwiftUI wrapper.
struct FragmentThumbnail: View {
    let id: String
    var side: CGFloat = 30
    var body: some View {
        Image(nsImage: FragmentThumbnails.image(id, side: side))
            .frame(width: side, height: side)
            .accessibilityHidden(true)
    }
}
