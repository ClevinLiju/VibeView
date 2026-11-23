import Foundation
import simd
import MolCore

// MolRender public value types. Owned by Lead 3 (Render). Posted in docs/CONTRACTS.md.

/// Linear-ish sRGB color with alpha, 0...1 components. Sendable/Codable so the app can persist it.
public struct RGBA: Sendable, Hashable, Codable {
    public var r: Double, g: Double, b: Double, a: Double
    public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }
    public static let white = RGBA(1, 1, 1), black = RGBA(0, 0, 0), clear = RGBA(0, 0, 0, 0)
    public static let red = RGBA(1, 0, 0), green = RGBA(0, 1, 0), blue = RGBA(0, 0, 1), yellow = RGBA(1, 1, 0)
    public func withAlpha(_ a: Double) -> RGBA { RGBA(r, g, b, a) }
    /// Componentwise linear interpolation, t in 0...1.
    public func mix(_ o: RGBA, _ t: Double) -> RGBA {
        RGBA(r + (o.r - r) * t, g + (o.g - g) * t, b + (o.b - b) * t, a + (o.a - a) * t)
    }
}

public enum RenderStyle: String, Sendable, Codable, CaseIterable {
    case ballAndStick, tube, wireframe, spaceFilling
}

public enum AtomColorScheme: Sendable, Hashable, Codable {
    /// CPK-like element colors.
    case element
    /// Partial charge (Atom.charge) on a red (negative) - white (0) - blue (positive) ramp.
    /// `range` is the |q| mapped to full saturation; nil = auto (max |q| in the molecule).
    case charge(range: Double?)
    /// One color for every atom.
    case uniform(RGBA)
}

public enum LabelMode: String, Sendable, Codable, CaseIterable {
    case none, element, index, elementIndex, charge, custom   // custom = Atom.label
}

public enum ProjectionMode: String, Sendable, Codable, CaseIterable { case perspective, orthographic }

public enum MaterialPreset: String, Sendable, Codable, CaseIterable {
    case matte, glossy, metallic, flat
}

public enum RenderTheme: String, Sendable, Codable, CaseIterable {
    case light, dark, black, white
    /// Default background color for the theme.
    public var background: RGBA {
        switch self {
        case .light: return RGBA(0.93, 0.94, 0.96)
        case .dark: return RGBA(0.12, 0.13, 0.15)
        case .black: return .black
        case .white: return .white
        }
    }
    /// Text/overlay color that contrasts with `background`.
    public var foreground: RGBA {
        switch self { case .light, .white: return RGBA(0.1, 0.1, 0.12); case .dark, .black: return RGBA(0.95, 0.95, 0.95) }
    }
}

/// Periodic box given by three lattice vectors (Ångström) and an origin.
public struct UnitCell: Sendable, Hashable, Codable {
    public var origin: Vec3
    public var a: Vec3, b: Vec3, c: Vec3
    public init(origin: Vec3 = .zero, a: Vec3, b: Vec3, c: Vec3) { self.origin = origin; self.a = a; self.b = b; self.c = c }
    /// Build from lengths (Å) and angles (degrees), a along x, b in the xy plane.
    public init(a la: Double, b lb: Double, c lc: Double, alpha: Double, beta: Double, gamma: Double, origin: Vec3 = .zero) {
        let al = alpha * .pi / 180, be = beta * .pi / 180, ga = gamma * .pi / 180
        let va = Vec3(la, 0, 0)
        let vb = Vec3(lb * cos(ga), lb * sin(ga), 0)
        let cx = lc * cos(be)
        let cy = lc * (cos(al) - cos(be) * cos(ga)) / sin(ga)
        let cz = (max(0, lc * lc - cx * cx - cy * cy)).squareRoot()
        self.init(origin: origin, a: va, b: vb, c: Vec3(cx, cy, cz))
    }
    /// The 8 corners, index bits (i,j,k) -> origin + i*a + j*b + k*c, i = bit0.
    public var corners: [Vec3] {
        (0..<8).map { n in origin + Double(n & 1) * a + Double((n >> 1) & 1) * b + Double((n >> 2) & 1) * c }
    }
    /// The 12 edges as corner-index pairs.
    public static let edges: [(Int, Int)] = [(0,1),(2,3),(4,5),(6,7),(0,2),(1,3),(4,6),(5,7),(0,4),(1,5),(2,6),(3,7)]
    public var volume: Double { abs(simd_dot(a, simd_cross(b, c))) }
}

/// Unordered atom pair, used for marking partial (dashed) bonds and similar overlays.
public struct AtomPair: Sendable, Hashable, Codable {
    public let a: Int, b: Int
    public init(_ a: Int, _ b: Int) { self.a = min(a, b); self.b = max(a, b) }
}

/// A geometric measurement overlay between atoms (indices into Molecule.atoms).
public enum Measurement: Sendable, Hashable, Codable {
    case distance(Int, Int)
    case angle(Int, Int, Int)
    case dihedral(Int, Int, Int, Int)
    public var atoms: [Int] {
        switch self {
        case let .distance(a, b): return [a, b]
        case let .angle(a, b, c): return [a, b, c]
        case let .dihedral(a, b, c, d): return [a, b, c, d]
        }
    }
}

/// Everything that controls how a molecule is drawn. Value type; assign a modified copy to
/// `MoleculeRenderer.options` and the renderer rebuilds only what changed.
public struct RenderOptions: Sendable, Hashable, Codable {
    public var style: RenderStyle = .ballAndStick
    public var colorScheme: AtomColorScheme = .element
    /// Ball radius = atomScale * vdW radius (ball-and-stick). Space-filling always uses full vdW.
    public var atomScale: Double = 0.25
    /// Bond cylinder radius in Å for ball-and-stick; tube uses `tubeRadius` for atoms and bonds.
    public var bondRadius: Double = 0.12
    public var tubeRadius: Double = 0.18
    /// Wireframe line width in points (approximated with thin cylinders/lines).
    public var wireWidth: Double = 1.5
    /// Bonds colored half-and-half by the two atoms' colors; false = single `bondColor`.
    public var splitBondColors: Bool = true
    public var bondColor: RGBA = RGBA(0.6, 0.6, 0.6)
    /// Draw double/triple/aromatic bonds as multiple cylinders.
    public var showBondOrders: Bool = true
    /// Bonds drawn dashed (partial bonds, TS bonds, H-bonds).
    public var dashedBonds: Set<AtomPair> = []
    public var showHydrogens: Bool = true
    /// Quality: segment count for spheres/cylinders. Builders reduce it automatically for big molecules.
    public var geometryQuality: Int = 24

    public var labelMode: LabelMode = .none
    public var labelSize: Double = 0.35            // Å height of label text
    public var measurements: [Measurement] = []

    public var unitCell: UnitCell? = nil
    public var showUnitCell: Bool = true

    public var theme: RenderTheme = .light
    /// nil = theme background.
    public var backgroundColor: RGBA? = nil
    public var transparentBackground: Bool = false
    public var material: MaterialPreset = .glossy
    public var depthCueing: Bool = false           // fog toward the background color
    public var ambientOcclusion: Bool = false      // SceneKit SSAO
    public var projection: ProjectionMode = .perspective

    public var selectionColor: RGBA = RGBA(1.0, 0.85, 0.1, 0.55)
    public var hoverColor: RGBA = RGBA(0.3, 0.8, 1.0, 0.45)

    public init() {}

    public var resolvedBackground: RGBA { backgroundColor ?? theme.background }
}

/// What a pick (click or hover) hit.
public enum PickTarget: Sendable, Hashable {
    case atom(Int)          // index into Molecule.atoms
    case bond(Int)          // index into Molecule.bonds
    case none
}
