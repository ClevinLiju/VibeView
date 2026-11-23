import SceneKit
import MolCore

/// Caches one SCNMaterial per (color, preset) so thousands of nodes share materials.
///
/// Presets: matte = blinn with faint specular; glossy = blinn with white specular and a tight highlight;
/// metallic = physically based (metalness 0.5, roughness 0.3); flat = constant (unlit) shading.
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

    /// Build an uncached material (also used by checks).
    public static func makeMaterial(color: RGBA, preset: MaterialPreset) -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = RGBA(color.r, color.g, color.b, 1).nsColor
        switch preset {
        case .matte:
            m.lightingModel = .blinn
            m.specular.contents = NSColor(white: 0.08, alpha: 1)
            m.shininess = 0.1
        case .glossy:
            m.lightingModel = .blinn
            m.specular.contents = NSColor.white
            m.shininess = 0.6
        case .metallic:
            m.lightingModel = .physicallyBased
            m.metalness.contents = 0.5
            m.roughness.contents = 0.3
        case .flat:
            m.lightingModel = .constant
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
