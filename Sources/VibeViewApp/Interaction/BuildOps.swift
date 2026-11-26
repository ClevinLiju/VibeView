import Foundation
import simd
import MolCore
import MolBuild

// FACADE: the only file that talks to MolBuild's editing API. Temporary pure-MolCore
// implementations are used until the MolBuild Builder/Editing/Cleanup API lands.

struct PaletteFragment: Identifiable, Hashable { let id: String; let name: String }
struct PaletteCategory: Identifiable { let id: String; let title: String; let fragments: [PaletteFragment] }

enum BuildOps {
    static var categories: [PaletteCategory] {
        [FragmentCategory.rings, .groups, .aminoAcids, .nucleobases].map { c in
            PaletteCategory(id: "\(c)", title: c.title, fragments: FragmentLibrary.fragments(in: c).map { PaletteFragment(id: $0.id, name: $0.name) })
        }
    }

    private static func bondLen(_ a: Int, _ b: Int) -> Double { BuildElements.bondLength(a, b) }

    static func isHydrogen(_ m: Molecule, _ i: Int) -> Bool { m.atoms.indices.contains(i) && m.atoms[i].atomicNumber == 1 }

    static func place(_ payload: BuildPayload, in m: Molecule, at p: Vec3) -> Molecule? {
        switch payload {
        case .element(let z): return Builder.placeElement(z, in: m, at: p, addHydrogens: true)
        case .fragment(let id): return FragmentLibrary.fragment(id: id).map { Builder.place($0, in: m, at: p) }
        case .group(let id): return GroupLibrary.group(id: id).map { Builder.place($0.fragment, in: m, at: p) }
        }
    }

    static func attach(_ payload: BuildPayload, to m: Molecule, replacingHydrogen h: Int) -> Molecule? {
        switch payload {
        case .element(let z): return Builder.attachElement(z, to: m, replacingHydrogen: h, addHydrogens: true)
        case .fragment(let id): return FragmentLibrary.fragment(id: id).flatMap { Builder.attach($0, to: m, replacingHydrogen: h) }
        case .group(let id): return try? Builder.click(.group(id), on: .atom(h), in: m)
        }
    }

    static func grow(_ payload: BuildPayload, from atom: Int, in m: Molecule) -> Molecule? {
        switch payload {
        case .element(let z): return Builder.bondElement(z, to: m, atom: atom, addHydrogens: true)
        case .group(let id):
            // Bond to a free valence of the atom, else substitute one of its hydrogens.
            if let r = try? Builder.click(.group(id), on: .atom(atom), in: m), r.atoms.count > m.atoms.count { return r }
            guard let h = m.neighbors(of: atom).first(where: { isHydrogen(m, $0) }) else { return nil }
            return attach(payload, to: m, replacingHydrogen: h)
        case .fragment:
            guard let h = m.neighbors(of: atom).first(where: { isHydrogen(m, $0) }) else { return nil }
            return attach(payload, to: m, replacingHydrogen: h)
        }
    }

    static func setElement(_ m: inout Molecule, atom: Int, to z: Int) { Editing.setElement(&m, atom: atom, to: z, adjustHydrogens: true) }
    static func setBondOrder(_ m: inout Molecule, _ a: Int, _ b: Int, _ order: BondOrder) { Editing.setBondOrder(&m, a, b, order, adjustHydrogens: true) }
    static func addHydrogens(_ m: inout Molecule, atoms: Set<Int>?) { Editing.addHydrogens(&m, atoms: atoms.map { Array($0).sorted() }) }
    static func deleteAtoms(_ m: inout Molecule, _ s: Set<Int>) { Editing.deleteAtoms(&m, s) }
    static func invert(_ m: inout Molecule) { Editing.invert(&m, center: nil) }
    static func mirror(_ m: inout Molecule) { Editing.mirror(&m, planeNormal: Vec3(0, 0, 1), through: nil) }
    static func hybridization(_ m: Molecule, atom: Int) -> String { Editing.hybridization(m, atom: atom).rawValue }
}

extension BuildOps {
    static func fragmentName(_ id: String) -> String { FragmentLibrary.fragment(id: id)?.name ?? id }
    static func groupLabel(_ id: String) -> String { GroupLibrary.group(id: id)?.label ?? id }
    static func payloadName(_ p: BuildPayload) -> String {
        switch p {
        case .element(let z): ElementInfo.symbol(z)
        case .fragment(let id): fragmentName(id)
        case .group(let id): GroupLibrary.group(id: id)?.name ?? id
        }
    }
}
extension BuildOps {
    static func removeHydrogens(_ m: inout Molecule, atoms: Set<Int>?) { Editing.removeHydrogens(&m, atoms: atoms.map { Array($0).sorted() }) }
}

