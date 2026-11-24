import Foundation
import AppKit
import simd
import MolCore

/// Tooltip-ready description of what the pointer is over. Delivered by `MoleculeRenderer.onHoverInfo`.
public struct HoverInfo: Sendable, Equatable {
    public struct AtomDetail: Sendable, Equatable {
        public var index: Int
        public var atomicNumber: Int
        public var symbol: String
        public var elementName: String
        public var position: Vec3          // Å
        public var charge: Double
        public var label: String?
        public var neighbors: [Int]        // bonded atom indices
        /// e.g. "C3 (carbon) · q = -0.12 · 3 bonds"
        public var summary: String
    }
    public struct BondDetail: Sendable, Equatable {
        public var index: Int
        public var atoms: (Int, Int)
        public var order: BondOrder
        public var length: Double          // Å
        public var summary: String         // e.g. "C1–O2 · 1.43 Å · double"
        public static func == (l: BondDetail, r: BondDetail) -> Bool {
            l.index == r.index && l.atoms == r.atoms && l.order == r.order && l.length == r.length && l.summary == r.summary
        }
    }
    public var target: PickTarget
    public var atom: AtomDetail?
    public var bond: BondDetail?
    /// Pointer location in view coordinates (AppKit, bottom-left origin) when known.
    public var location: CGPoint?
    /// Single-line text suitable for a tooltip ("" for `.none`).
    public var text: String { atom?.summary ?? bond?.summary ?? "" }

    /// Build hover info for a target (pure; usable from checks).
    public static func make(_ target: PickTarget, molecule m: Molecule, location: CGPoint? = nil) -> HoverInfo {
        var info = HoverInfo(target: target, atom: nil, bond: nil, location: location)
        func name(_ i: Int) -> String { "\(ElementPalette.symbol(m.atoms[i].atomicNumber))\(i + 1)" }
        switch target {
        case .atom(let i) where i >= 0 && i < m.atoms.count:
            let a = m.atoms[i]
            let nb = m.bonds.compactMap { b -> Int? in b.a == i ? b.b : (b.b == i ? b.a : nil) }
            let el = Elements.element(a.atomicNumber)
            var s = "\(name(i)) (\(el.name.lowercased()))"
            if let l = a.label, !l.isEmpty { s += " [\(l)]" }
            if a.charge != 0 { s += String(format: " · q = %+.3f", a.charge) }
            s += " · \(nb.count) bond\(nb.count == 1 ? "" : "s")"
            info.atom = AtomDetail(index: i, atomicNumber: a.atomicNumber, symbol: el.symbol, elementName: el.name,
                                   position: a.position, charge: a.charge, label: a.label, neighbors: nb, summary: s)
        case .bond(let k) where k >= 0 && k < m.bonds.count:
            let b = m.bonds[k]
            guard b.a < m.atoms.count, b.b < m.atoms.count else { break }
            let len = simd_distance(m.atoms[b.a].position, m.atoms[b.b].position)
            let s = String(format: "%@–%@ · %.3f Å · %@", name(b.a), name(b.b), len, "\(b.order)")
            info.bond = BondDetail(index: k, atoms: (b.a, b.b), order: b.order, length: len, summary: s)
        default:
            info.target = .none
        }
        return info
    }
}
