import SceneKit
import MolCore

/// Caches one SCNMaterial per (color, preset) so thousands of nodes share materials.
///
/// Presets: all physically based except flat (constant/unlit); see `pbrParameters` for the values.
/// Colors with alpha < 1 get `transparency = alpha`, dual-layer transparency and depth writes on,
/// so overlapping translucent shells (space-filling) sort acceptably.
public final class MaterialLibrary {
    public var preset: MaterialPreset { didSet { if oldValue != preset { cache.removeAll(); lineMat = nil } } }
    private var cache: [RGBA: SCNMaterial] = [:]
    private var lineMat: SCNMaterial?
    public init(preset: MaterialPreset = .glossy) { self.preset = preset }

    public func material(for color: RGBA) -> SCNMaterial {
        if let m = cache[color] { return m }
        let m = Self.makeMaterial(color: color, preset: preset)
        cache[color] = m
        return m
    }
    public var cachedCount: Int { cache.count }

    /// Unlit material for vertex-colored line geometry (wireframe bonds). Shared; per-vertex colors drive the look.
    public func lineMaterial() -> SCNMaterial {
        if let m = lineMat { return m }
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = NSColor.white
        m.isDoubleSided = true
        m.name = "vibeview.line"
        lineMat = m
        return m
    }

    /// PBR parameters per preset (roughness, metalness, clear coat, clear-coat roughness).
    public static func pbrParameters(_ p: MaterialPreset) -> (roughness: Double, metalness: Double, clearCoat: Double, clearCoatRoughness: Double) {
        switch p {
        case .matte: return (0.82, 0, 0, 0)
        case .glossy: return (0.34, 0, 0.55, 0.07)
        case .satin: return (0.5, 0, 0.2, 0.28)
        case .ceramic: return (0.42, 0, 1.0, 0.03)
        case .metallic: return (0.3, 0.5, 0.3, 0.1)
        case .flat: return (1, 0, 0, 0)
        }
    }

    /// Build an uncached material (also used by checks).
    public static func makeMaterial(color: RGBA, preset: MaterialPreset) -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = RGBA(color.r, color.g, color.b, 1).nsColor
        if preset == .flat {
            m.lightingModel = .constant
        } else {
            let p = pbrParameters(preset)
            m.lightingModel = .physicallyBased
            m.roughness.contents = NSNumber(value: p.roughness)
            m.metalness.contents = NSNumber(value: p.metalness)
            if p.clearCoat > 0 {
                m.clearCoat.contents = NSNumber(value: p.clearCoat)
                m.clearCoatRoughness.contents = NSNumber(value: p.clearCoatRoughness)
            }
        }
        if color.a < 1 {
            m.transparency = CGFloat(max(0, color.a))
            m.transparencyMode = .dualLayer
            m.writesToDepthBuffer = true
            m.blendMode = .alpha
        }
        m.isDoubleSided = false
        m.name = "vibeview.mat"
        return m
    }
}
