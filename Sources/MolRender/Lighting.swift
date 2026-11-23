import SceneKit
import AppKit
import MolCore

/// Key/fill/rim lights attached to the camera (so lighting follows the view) plus ambient,
/// background, depth-cue fog and SSAO. Owned by Lead 3.
@MainActor final class LightingRig {
    let scene: SCNScene
    let key = SCNNode(), fill = SCNNode(), rim = SCNNode(), ambient = SCNNode()
    unowned let cameraNode: SCNNode

    init(scene: SCNScene, cameraNode: SCNNode) {
        self.scene = scene; self.cameraNode = cameraNode
        func light(_ n: SCNNode, _ type: SCNLight.LightType, _ intensity: CGFloat, _ name: String) {
            let l = SCNLight(); l.type = type; l.intensity = intensity; n.light = l; n.name = name
        }
        light(key, .directional, 900, "light.key")
        light(fill, .directional, 350, "light.fill")
        light(rim, .directional, 250, "light.rim")
        light(ambient, .ambient, 300, "light.ambient")
        // Directions in camera space (directional lights shine along their -z).
        key.eulerAngles = SCNVector3(-0.45, -0.55, 0)
        fill.eulerAngles = SCNVector3(0.25, 0.7, 0)
        rim.eulerAngles = SCNVector3(0.2, .pi * 0.95, 0)
        [key, fill, rim].forEach { cameraNode.addChildNode($0) }
        scene.rootNode.addChildNode(ambient)
    }

    func apply(options o: RenderOptions) {
        let bg = o.resolvedBackground
        scene.background.contents = o.transparentBackground ? NSColor.clear : bg.nsColor
        let dark = (bg.r + bg.g + bg.b) / 3 < 0.5
        ambient.light?.intensity = dark ? 260 : 340
        ambient.light?.color = NSColor(white: 1, alpha: 1)
        switch o.material {
        case .flat:
            key.light?.intensity = 0; fill.light?.intensity = 0; rim.light?.intensity = 0; ambient.light?.intensity = 1000
        case .metallic:
            key.light?.intensity = 1300; fill.light?.intensity = 500; rim.light?.intensity = 400
        default:
            key.light?.intensity = 900; fill.light?.intensity = 350; rim.light?.intensity = dark ? 350 : 220
        }
        if o.material == .metallic {
            scene.lightingEnvironment.contents = Self.environmentGradient(dark: dark)
            scene.lightingEnvironment.intensity = 1.2
        } else {
            scene.lightingEnvironment.contents = nil
        }
        depthCue = o.depthCueing
        if o.depthCueing {
            scene.fogColor = o.transparentBackground ? NSColor.clear : bg.nsColor
            scene.fogDensityExponent = 1
            updateFogRange()
        } else {
            scene.fogStartDistance = 0; scene.fogEndDistance = 0
        }
        if let cam = cameraNode.camera {
            cam.screenSpaceAmbientOcclusionIntensity = o.ambientOcclusion ? 1.4 : 0
            cam.screenSpaceAmbientOcclusionRadius = 1.2
            cam.screenSpaceAmbientOcclusionNormalThreshold = 0.3
            cam.screenSpaceAmbientOcclusionDepthThreshold = 0.2
            cam.wantsHDR = o.material == .metallic
        }
    }
    private(set) var depthCue = false
    private(set) var fogStart: Double = 0, fogEnd: Double = 0

    /// Call after camera distance/scene radius changes; fog spans the molecule's depth.
    func updateFogRange(distance: Double? = nil, radius: Double? = nil) {
        if let d = distance { lastDistance = d }
        if let r = radius { lastRadius = r }
        guard depthCue else { return }
        fogStart = max(0, lastDistance - lastRadius * 0.3); fogEnd = lastDistance + lastRadius * 1.2
        scene.fogStartDistance = CGFloat(fogStart); scene.fogEndDistance = CGFloat(fogEnd)
    }
    private var lastDistance = 20.0, lastRadius = 5.0

    static func environmentGradient(dark: Bool) -> NSImage {
        let size = NSSize(width: 64, height: 32)
        let img = NSImage(size: size)
        img.lockFocus()
        let top = dark ? NSColor(white: 0.55, alpha: 1) : NSColor(white: 1, alpha: 1)
        let bottom = dark ? NSColor(white: 0.05, alpha: 1) : NSColor(white: 0.35, alpha: 1)
        NSGradient(starting: bottom, ending: top)?.draw(in: NSRect(origin: .zero, size: size), angle: 90)
        img.unlockFocus()
        return img
    }
}
