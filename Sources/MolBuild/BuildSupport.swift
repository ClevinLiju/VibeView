import Foundation
import simd
import MolCore

// Shared MolBuild support (owned by Lead 4). Self-contained element data so MolBuild
// does not depend on MolCore's element table landing first.

public struct BuildElement: Sendable {
    public let z: Int
    public let symbol: String
    public let covalentRadius: Double   // Å (single-bond)
    public let valence: Int             // typical neutral valence used for add-H
}

public enum BuildElements {
    // (symbol, covalent radius Å, typical valence)
    static let raw: [(String, Double, Int)] = [
        ("X", 0.00, 0),
        ("H", 0.31, 1), ("He", 0.28, 0),
        ("Li", 1.28, 1), ("Be", 0.96, 2), ("B", 0.84, 3), ("C", 0.76, 4), ("N", 0.71, 3), ("O", 0.66, 2), ("F", 0.57, 1), ("Ne", 0.58, 0),
        ("Na", 1.66, 1), ("Mg", 1.41, 2), ("Al", 1.21, 3), ("Si", 1.11, 4), ("P", 1.07, 3), ("S", 1.05, 2), ("Cl", 1.02, 1), ("Ar", 1.06, 0),
        ("K", 2.03, 1), ("Ca", 1.76, 2), ("Sc", 1.70, 3), ("Ti", 1.60, 4), ("V", 1.53, 5), ("Cr", 1.39, 6), ("Mn", 1.39, 2), ("Fe", 1.32, 2),
        ("Co", 1.26, 2), ("Ni", 1.24, 2), ("Cu", 1.32, 1), ("Zn", 1.22, 2), ("Ga", 1.22, 3), ("Ge", 1.20, 4), ("As", 1.19, 3), ("Se", 1.20, 2),
        ("Br", 1.20, 1), ("Kr", 1.16, 0),
        ("Rb", 2.20, 1), ("Sr", 1.95, 2), ("Y", 1.90, 3), ("Zr", 1.75, 4), ("Nb", 1.64, 5), ("Mo", 1.54, 6), ("Tc", 1.47, 7), ("Ru", 1.46, 3),
        ("Rh", 1.42, 3), ("Pd", 1.39, 2), ("Ag", 1.45, 1), ("Cd", 1.44, 2), ("In", 1.42, 3), ("Sn", 1.39, 4), ("Sb", 1.39, 3), ("Te", 1.38, 2),
        ("I", 1.39, 1), ("Xe", 1.40, 0),
        ("Cs", 2.44, 1), ("Ba", 2.15, 2), ("La", 2.07, 3), ("Ce", 2.04, 3), ("Pr", 2.03, 3), ("Nd", 2.01, 3), ("Pm", 1.99, 3), ("Sm", 1.98, 3),
        ("Eu", 1.98, 3), ("Gd", 1.96, 3), ("Tb", 1.94, 3), ("Dy", 1.92, 3), ("Ho", 1.92, 3), ("Er", 1.89, 3), ("Tm", 1.90, 3), ("Yb", 1.87, 3),
        ("Lu", 1.87, 3), ("Hf", 1.75, 4), ("Ta", 1.70, 5), ("W", 1.62, 6), ("Re", 1.51, 7), ("Os", 1.44, 4), ("Ir", 1.41, 4), ("Pt", 1.36, 2),
        ("Au", 1.36, 1), ("Hg", 1.32, 2), ("Tl", 1.45, 3), ("Pb", 1.46, 4), ("Bi", 1.48, 3), ("Po", 1.40, 2), ("At", 1.50, 1), ("Rn", 1.50, 0),
    ]

    public static let all: [BuildElement] = raw.enumerated().map { BuildElement(z: $0.offset, symbol: $0.element.0, covalentRadius: $0.element.1, valence: $0.element.2) }

    public static func element(_ z: Int) -> BuildElement { (z >= 0 && z < all.count) ? all[z] : BuildElement(z: z, symbol: "X", covalentRadius: 1.5, valence: 0) }
    public static func symbol(_ z: Int) -> String { element(z).symbol }
    public static func covalentRadius(_ z: Int) -> Double { element(z).covalentRadius }
    public static func valence(_ z: Int) -> Int { element(z).valence }
    public static func atomicNumber(_ symbol: String) -> Int? {
        let s = symbol.trimmingCharacters(in: .whitespaces).lowercased()
        return all.firstIndex { $0.symbol.lowercased() == s }
    }
    /// Ideal bond length between two elements for a given bond order (simple Pyykkö-style scaling).
    public static func bondLength(_ za: Int, _ zb: Int, order: BondOrder = .single) -> Double {
        let base = covalentRadius(za) + covalentRadius(zb)
        switch order {
        case .single: return base
        case .aromatic: return base * 0.92
        case .double: return base * 0.87
        case .triple: return base * 0.78
        }
    }
}

public extension Molecule {
    /// Indices (array positions) of atoms bonded to `i`.
    func buildNeighbors(of i: Int) -> [Int] {
        bonds.compactMap { $0.a == i ? $0.b : ($0.b == i ? $0.a : nil) }
    }
    func buildBond(_ i: Int, _ j: Int) -> Bond? {
        let a = min(i, j), b = max(i, j)
        return bonds.first { $0.a == a && $0.b == b }
    }
    /// Sum of bond orders around atom i (aromatic counts 1.5).
    func buildBondOrderSum(_ i: Int) -> Double {
        bonds.reduce(0) { ($1.a == i || $1.b == i) ? $0 + $1.order.rawValue : $0 }
    }
    /// Remove atoms, re-index remaining atoms (id == array index) and bonds.
    func buildRemovingAtoms(_ remove: Set<Int>) -> Molecule {
        var map = [Int: Int]()
        var out = self
        out.atoms = []
        for (i, var a) in atoms.enumerated() where !remove.contains(i) {
            map[i] = out.atoms.count
            a.id = out.atoms.count
            out.atoms.append(a)
        }
        out.bonds = bonds.compactMap { b in
            guard let na = map[b.a], let nb = map[b.b] else { return nil }
            return Bond(na, nb, order: b.order)
        }
        return out
    }
    /// Append an atom (id = index) and return its index.
    @discardableResult
    mutating func buildAddAtom(_ z: Int, at p: Vec3) -> Int {
        let i = atoms.count
        atoms.append(Atom(id: i, atomicNumber: z, position: p))
        return i
    }
    /// Add or replace a bond; nil order removes it.
    mutating func buildSetBond(_ i: Int, _ j: Int, _ order: BondOrder?) {
        let a = min(i, j), b = max(i, j)
        bonds.removeAll { $0.a == a && $0.b == b }
        if let order, i != j { bonds.append(Bond(a, b, order: order)) }
    }
    /// Append another molecule; returns index offset of the appended atoms.
    @discardableResult
    mutating func buildAppend(_ other: Molecule) -> Int {
        let off = atoms.count
        for var a in other.atoms { a.id = atoms.count; atoms.append(a) }
        for b in other.bonds { bonds.append(Bond(b.a + off, b.b + off, order: b.order)) }
        return off
    }
}

/// Any unit vector perpendicular to v.
public func buildPerpendicular(_ v: Vec3) -> Vec3 {
    let n = simd_normalize(v)
    let trial: Vec3 = abs(n.x) < 0.9 ? Vec3(1, 0, 0) : Vec3(0, 1, 0)
    return simd_normalize(simd_cross(n, trial))
}

/// Rotate point p about an axis through `origin` with direction `axis` by `angle` radians.
public func buildRotate(_ p: Vec3, about origin: Vec3, axis: Vec3, angle: Double) -> Vec3 {
    let q = simd_quatd(angle: angle, axis: simd_normalize(axis))
    return origin + q.act(p - origin)
}
