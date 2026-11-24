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
        RGBA(r * (1 - t) + o.r * t, g * (1 - t) + o.g * t, b * (1 - t) + o.b * t, a * (1 - t) + o.a * t)
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

/// How aromatic bonds (BondOrder.aromatic) are drawn when `showBondOrders` is on.
/// kekule = alternating single/double from a Kekulé structure, inner line offset toward the ring center (default);
/// dashed = one solid line plus a dashed inner line; circle = single bonds plus a ring circle inside each aromatic ring.
public enum AromaticBondStyle: String, Sendable, Codable, CaseIterable { case kekule, dashed, circle }

public enum ProjectionMode: String, Sendable, Codable, CaseIterable { case perspective, orthographic }

/// Surface look. All presets except `.flat` are physically based (energy-conserving, work with
/// the image-based environment light and SSAO).
/// matte = rough diffuse; glossy = polished plastic (default); satin = soft sheen;
/// ceramic = glazed, bright clearcoat-like highlight; metallic = brushed metal; flat = unlit.
public enum MaterialPreset: String, Sendable, Codable, CaseIterable {
    case matte, glossy, metallic, flat, satin, ceramic
}

/// One-shot style bundles applied with `RenderOptions.apply(_:)` / `RenderOptions(look:)`.
public enum RenderLook: String, Sendable, Codable, CaseIterable {
    /// Light theme, glossy PBR, SSAO and soft shadows (the default).
    case studio
    /// Publication figure: pure white background, satin materials, strong AO, thin dark outlines, no fog.
    case whitePaper
    /// Dark stage: near-black background, glossy materials, rim light, AO.
    case darkStage
    /// Flat illustration: unlit colors with bold outlines (good for schematics).
    case illustration
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
    /// Aromatic bond drawing (round 3). Default `.kekule`.
    public var aromaticStyle: AromaticBondStyle = .kekule
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
    public var ambientOcclusion: Bool = true       // SceneKit screen-space AO (darkens crevices)
    /// SSAO strength (0...3) and sampling radius in Å.
    public var ambientOcclusionIntensity: Double = 1.6
    public var ambientOcclusionRadius: Double = 1.4
    /// Soft shadows cast by the key light (atoms shadow each other).
    public var shadows: Bool = true
    /// Screen-space silhouette/crease outlines (depth discontinuities).
    public var outline: Bool = false
    /// Outline width in points (scaled with export resolution) and color (nil = auto from the theme).
    public var outlineWidth: Double = 1.2
    public var outlineColor: RGBA? = nil
    /// Depth of field around the camera target (off by default). `fStop` controls blur strength.
    public var depthOfField: Bool = false
    public var depthOfFieldFStop: Double = 2.8
    public var projection: ProjectionMode = .perspective

    // Round 3 overlays
    /// Dashed hydrogen-bond lines D-H...A (A, D in N/O/F/S/Cl) with H...A <= `hydrogenBondMaxDistance` Å
    /// and angle D-H...A >= `hydrogenBondMinAngle` degrees. Computed, not stored as bonds.
    public var showHydrogenBonds: Bool = false
    public var hydrogenBondMaxDistance: Double = 2.5
    public var hydrogenBondMinAngle: Double = 120
    public var hydrogenBondColor: RGBA = RGBA(0.25, 0.65, 1.0)
    /// Slab clipping relative to the camera target, in Å along the view direction: geometry nearer than
    /// `target - slabNear` (toward the camera) or farther than `target + slabFar` is cut. nil = no clip.
    public var slabNear: Double? = nil
    public var slabFar: Double? = nil
    /// Corner axis triad (x red, y green, z blue) following the camera orientation.
    public var showAxes: Bool = false
    /// Scale bar in Å (length chosen automatically) at the bottom of the view; valid in both projections
    /// at the camera-target depth.
    public var showScaleBar: Bool = false

    public var selectionColor: RGBA = RGBA(1.0, 0.85, 0.1, 0.55)
    public var hoverColor: RGBA = RGBA(0.3, 0.8, 1.0, 0.45)

    public init() {}
    public init(look: RenderLook) { self.init(); apply(look) }

    public var resolvedBackground: RGBA { backgroundColor ?? theme.background }
    /// Outline color actually used.
    public var resolvedOutlineColor: RGBA {
        if let c = outlineColor { return c }
        let bg = resolvedBackground
        return (bg.r + bg.g + bg.b) / 3 < 0.5 ? RGBA(0.02, 0.02, 0.03) : RGBA(0.08, 0.08, 0.10)
    }

    /// Apply a style bundle (only look-related fields change; style, labels, measurements etc. are kept).
    public mutating func apply(_ look: RenderLook) {
        backgroundColor = nil; transparentBackground = false; depthCueing = false; depthOfField = false
        outlineColor = nil
        switch look {
        case .studio:
            theme = .light; material = .glossy; ambientOcclusion = true; ambientOcclusionIntensity = 1.6
            shadows = true; outline = false
        case .whitePaper:
            theme = .white; material = .satin; ambientOcclusion = true; ambientOcclusionIntensity = 2.0
            shadows = true; outline = true; outlineWidth = 1.2
        case .darkStage:
            theme = .black; material = .glossy; ambientOcclusion = true; ambientOcclusionIntensity = 1.4
            shadows = true; outline = false
        case .illustration:
            theme = .white; material = .flat; ambientOcclusion = false; shadows = false
            outline = true; outlineWidth = 2.0
        }
    }
}

/// What a pick (click or hover) hit.
public enum PickTarget: Sendable, Hashable {
    case atom(Int)          // index into Molecule.atoms
    case bond(Int)          // index into Molecule.bonds
    case none
}

// Lenient decoding: every key is optional so options saved by older builds (or with fields added
// later) still load; missing keys keep their defaults. Encoding stays synthesized.
extension RenderOptions {
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func d<T: Decodable>(_ k: CodingKeys, _ v: inout T) { if let x = try? c.decodeIfPresent(T.self, forKey: k) { v = x } }
        d(.style, &style); d(.colorScheme, &colorScheme); d(.atomScale, &atomScale); d(.bondRadius, &bondRadius)
        d(.tubeRadius, &tubeRadius); d(.wireWidth, &wireWidth); d(.splitBondColors, &splitBondColors); d(.bondColor, &bondColor)
        d(.showBondOrders, &showBondOrders); d(.aromaticStyle, &aromaticStyle); d(.dashedBonds, &dashedBonds); d(.showHydrogens, &showHydrogens)
        d(.geometryQuality, &geometryQuality); d(.labelMode, &labelMode); d(.labelSize, &labelSize); d(.measurements, &measurements)
        if c.contains(.unitCell) { unitCell = try? c.decodeIfPresent(UnitCell.self, forKey: .unitCell) }
        d(.showUnitCell, &showUnitCell); d(.theme, &theme)
        if c.contains(.backgroundColor) { backgroundColor = try? c.decodeIfPresent(RGBA.self, forKey: .backgroundColor) }
        d(.transparentBackground, &transparentBackground); d(.material, &material); d(.depthCueing, &depthCueing)
        d(.ambientOcclusion, &ambientOcclusion); d(.ambientOcclusionIntensity, &ambientOcclusionIntensity)
        d(.ambientOcclusionRadius, &ambientOcclusionRadius); d(.shadows, &shadows); d(.outline, &outline)
        d(.outlineWidth, &outlineWidth)
        if c.contains(.outlineColor) { outlineColor = try? c.decodeIfPresent(RGBA.self, forKey: .outlineColor) }
        d(.depthOfField, &depthOfField); d(.depthOfFieldFStop, &depthOfFieldFStop); d(.projection, &projection)
        d(.selectionColor, &selectionColor); d(.hoverColor, &hoverColor)
        d(.showHydrogenBonds, &showHydrogenBonds); d(.hydrogenBondMaxDistance, &hydrogenBondMaxDistance)
        d(.hydrogenBondMinAngle, &hydrogenBondMinAngle); d(.hydrogenBondColor, &hydrogenBondColor)
        if c.contains(.slabNear) { slabNear = try? c.decodeIfPresent(Double.self, forKey: .slabNear) }
        if c.contains(.slabFar) { slabFar = try? c.decodeIfPresent(Double.self, forKey: .slabFar) }
        d(.showAxes, &showAxes); d(.showScaleBar, &showScaleBar)
    }
}
