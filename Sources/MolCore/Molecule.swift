import Foundation
import simd

// SHARED CONTRACT — owned by Lead 1 (Core). Other teams may ADD extensions in their own
// modules but must not change these signatures without coordinating via docs/CONTRACTS.md.

public typealias Vec3 = SIMD3<Double>

public struct Atom: Identifiable, Hashable, Sendable, Codable {
    public var id: Int                 // stable index within its Molecule
    public var atomicNumber: Int
    public var position: Vec3          // Ångström, Cartesian
    public var charge: Double = 0      // partial charge (e.g. Mulliken), if known
    public var label: String? = nil    // e.g. Gaussian fragment / PDB atom name

    public init(id: Int, atomicNumber: Int, position: Vec3) {
        self.id = id
        self.atomicNumber = atomicNumber
        self.position = position
    }
}

public enum BondOrder: Double, Codable, Sendable, CaseIterable {
    case single = 1, aromatic = 1.5, double = 2, triple = 3
}

public struct Bond: Hashable, Sendable, Codable {
    public var a: Int
    public var b: Int
    public var order: BondOrder

    public init(_ a: Int, _ b: Int, order: BondOrder = .single) {
        self.a = min(a, b)
        self.b = max(a, b)
        self.order = order
    }
}

public struct Molecule: Sendable, Codable, Equatable {
    public var atoms: [Atom] = []
    public var bonds: [Bond] = []
    public var charge: Int = 0
    public var multiplicity: Int = 1
    public var title: String = ""

    public init(atoms: [Atom] = [], bonds: [Bond] = [], charge: Int = 0, multiplicity: Int = 1, title: String = "") {
        self.atoms = atoms
        self.bonds = bonds
        self.charge = charge
        self.multiplicity = multiplicity
        self.title = title
    }
}
