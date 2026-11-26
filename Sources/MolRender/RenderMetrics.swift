import Foundation
import simd
import SceneKit
import MolCore

// Owned by Lead 3. Shared sizing/color helpers used by every layer builder and by picking.

public enum RenderMetrics {
    /// Displayed sphere radius (Å) of an atom for the given options.
    public static func atomRadius(atomicNumber z: Int, options: RenderOptions) -> Double {
        switch options.style {
        case .spaceFilling: return ElementPalette.vdwRadius(z)
        case .ballAndStick, .cartoon: return max(options.atomScale * ElementPalette.vdwRadius(z), options.bondRadius * 1.15)
        case .tube: return options.tubeRadius
        case .wireframe: return 0.06          // small pickable dot
        }
    }
    /// Displayed bond cylinder radius (Å); 0 for space-filling (bonds hidden).
    public static func bondRadius(options: RenderOptions) -> Double {
        switch options.style {
        case .ballAndStick, .cartoon: return options.bondRadius
        case .tube: return options.tubeRadius
        case .wireframe: return 0.02 * options.wireWidth
        case .spaceFilling: return 0
        }
    }
    public static func isAtomVisible(_ atom: Atom, options: RenderOptions) -> Bool {
        options.showHydrogens || atom.atomicNumber != 1
    }
    /// Index-aware visibility: also honours the renderer's `atomMask` (cartoon residues, hidden water).
    public static func isAtomVisible(_ i: Int, in molecule: Molecule, options: RenderOptions) -> Bool {
        guard i >= 0, i < molecule.atoms.count else { return false }
        if options.atomMask.isHidden(i) { return false }
        return isAtomVisible(molecule.atoms[i], options: options)
    }
    /// Visible, or a CA atom standing in for its cartoon residue (picking and highlights).
    public static func isAtomPickable(_ i: Int, in molecule: Molecule, options: RenderOptions) -> Bool {
        guard i >= 0, i < molecule.atoms.count else { return false }
        if options.atomMask.isHidden(i) { return options.atomMask.isStandIn(i) }
        return isAtomVisible(molecule.atoms[i], options: options)
    }
    public static func isBondVisible(_ bond: Bond, in molecule: Molecule, options: RenderOptions) -> Bool {
        guard options.style != .spaceFilling, bond.a < molecule.atoms.count, bond.b < molecule.atoms.count else { return false }
        return isAtomVisible(bond.a, in: molecule, options: options) && isAtomVisible(bond.b, in: molecule, options: options)
    }
    /// Per-atom display colors for the current color scheme.
    public static func atomColors(for molecule: Molecule, options: RenderOptions) -> [RGBA] {
        switch options.colorScheme {
        case .element: return molecule.atoms.map { ElementPalette.color($0.atomicNumber) }
        case .uniform(let c): return Array(repeating: c, count: molecule.atoms.count)
        case .charge(let range):
            let r = range ?? (molecule.atoms.map { abs($0.charge) }.max() ?? 0)
            return molecule.atoms.map { ColorMap.charge($0.charge, range: r) }
        }
    }
}

public enum ColorMap {
    public static let negative = RGBA(0.84, 0.10, 0.11)
    public static let neutral = RGBA(1, 1, 1)
    public static let positive = RGBA(0.13, 0.30, 0.86)
    /// Red (q = -range) through white (0) to blue (q = +range); clamped outside.
    public static func charge(_ q: Double, range: Double) -> RGBA {
        guard range > 1e-12, q.isFinite else { return neutral }
        let t = max(-1, min(1, q / range))
        return t < 0 ? neutral.mix(negative, -t) : neutral.mix(positive, t)
    }
}

/// Element colors and radii, delegated to MolCore's `Elements` table (Lead 1). Every builder
/// goes through these functions so a render-specific override stays a one-place change.
public enum ElementPalette {
    public static func color(_ z: Int) -> RGBA {
        guard z >= 0, z <= Elements.maxAtomicNumber else { return RGBA(1, 0.08, 0.58) }
        let c = Elements.element(z).color
        return RGBA(c.x, c.y, c.z)
    }
    public static func vdwRadius(_ z: Int) -> Double {
        let r = Elements.element(z).vdwRadius
        return r > 0 ? r : 1.5
    }
    public static func covalentRadius(_ z: Int) -> Double {
        let r = Elements.element(z).covalentRadius
        return r > 0 ? r : 0.75
    }
    public static func symbol(_ z: Int) -> String { Elements.element(z).symbol }
}

// MARK: - SceneKit conversion helpers (internal, shared by all builders)

extension SCNVector3 {
    init(_ v: Vec3) { self.init(CGFloat(v.x), CGFloat(v.y), CGFloat(v.z)) }
    init(_ v: SIMD3<Float>) { self.init(CGFloat(v.x), CGFloat(v.y), CGFloat(v.z)) }
    var vec3: Vec3 { Vec3(Double(x), Double(y), Double(z)) }
}

extension RGBA {
    public var nsColor: NSColor { NSColor(srgbRed: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: CGFloat(a)) }
    public var cgColor: CGColor { nsColor.cgColor }
}

/// Node-name scheme used across layers (pick by name is a fallback; picking is analytic).
enum NodeName {
    static let root = "vibeview.root"
    static let atoms = "vibeview.atoms"
    static let bonds = "vibeview.bonds"
    static let highlight = "vibeview.highlight"
    static let labels = "vibeview.labels"
    static let measurements = "vibeview.measurements"
    static let surfaces = "vibeview.surfaces"
    static let cell = "vibeview.cell"
    static let vectors = "vibeview.vectors"
    static let cartoon = "vibeview.cartoon"
    static let camera = "vibeview.camera"
    static func atom(_ i: Int) -> String { "atom:\(i)" }
    static func bond(_ i: Int) -> String { "bond:\(i)" }
}

// MARK: - Shared geometry math (internal, pure)

public enum RenderMath {
    /// Rotation taking +Y (SCNCylinder/SCNCone axis) onto `dir` (need not be normalized).
    /// Robust for dir parallel or antiparallel to +Y.
    public static func orientationFromY(to dir: Vec3) -> simd_quatf {
        let len = simd_length(dir)
        guard len > 1e-12 else { return simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0)) }
        let d = dir / len
        let y = Vec3(0, 1, 0)
        let c = simd_dot(y, d)
        if c > 1 - 1e-9 { return simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0)) }
        if c < -1 + 1e-9 { return simd_quatf(angle: .pi, axis: SIMD3<Float>(1, 0, 0)) }
        let axis = simd_normalize(simd_cross(y, d))
        return simd_quatf(angle: Float(acos(c)), axis: SIMD3<Float>(axis))
    }
    /// Any unit vector perpendicular to v.
    public static func perpendicular(to v: Vec3) -> Vec3 {
        let a = abs(v.x) < 0.9 ? Vec3(1, 0, 0) : Vec3(0, 1, 0)
        let p = simd_cross(v, a); let l = simd_length(p)
        return l > 1e-12 ? p / l : Vec3(0, 0, 1)
    }
}
