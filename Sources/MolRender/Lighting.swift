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
        // SceneKit's SSAO attenuates only ambient/indirect light, so the rig keeps a strong ambient +
        // image-based term and a moderate key light; AO then reads clearly in crevices.
        ambient.light?.color = NSColor(white: 1, alpha: 1)
        switch o.material {
        case .flat:
            key.light?.intensity = 0; fill.light?.intensity = 0; rim.light?.intensity = 0; ambient.light?.intensity = 1000
        case .metallic:
            key.light?.intensity = 1100; fill.light?.intensity = 250; rim.light?.intensity = dark ? 500 : 300
            ambient.light?.intensity = dark ? 250 : 320
        default:
            key.light?.intensity = 820; fill.light?.intensity = 180; rim.light?.intensity = dark ? 420 : 160
            ambient.light?.intensity = dark ? 380 : 480
        }
        if o.material == .flat {
            scene.lightingEnvironment.contents = nil
        } else {
            scene.lightingEnvironment.contents = Self.studioEnvironment(dark: dark)
            scene.lightingEnvironment.intensity = o.material == .metallic ? 1.4 : (dark ? 0.7 : 0.9)
        }
        if let k = key.light {
            let on = o.shadows && o.material != .flat
            k.castsShadow = on
            if on {
                k.shadowMode = .deferred
                k.shadowSampleCount = 16
                k.shadowRadius = 3.5
                k.shadowColor = NSColor(white: 0, alpha: dark ? 0.6 : 0.42)
                k.shadowMapSize = CGSize(width: 2048, height: 2048)
                k.automaticallyAdjustsShadowProjection = true
                k.shadowBias = 0.05
            }
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
            let ao = o.ambientOcclusion && o.material != .flat
            cam.screenSpaceAmbientOcclusionIntensity = ao ? CGFloat(max(0, min(3, o.ambientOcclusionIntensity))) : 0
            cam.screenSpaceAmbientOcclusionRadius = CGFloat(max(0.2, o.ambientOcclusionRadius))
            cam.screenSpaceAmbientOcclusionBias = 0.03
            cam.screenSpaceAmbientOcclusionNormalThreshold = 0.3
            cam.screenSpaceAmbientOcclusionDepthThreshold = 0.25
            cam.wantsHDR = o.material == .metallic
            cam.wantsDepthOfField = o.depthOfField
            cam.fStop = CGFloat(max(0.5, o.depthOfFieldFStop))
            cam.apertureBladeCount = 6
            cam.focalBlurSampleCount = 12
        }
    }

    /// Keep the depth-of-field focus on the camera target.
    func updateFocus(distance: Double) {
        guard let cam = cameraNode.camera, cam.wantsDepthOfField else { return }
        cam.focusDistance = CGFloat(distance)
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

    private static var envCache: [Bool: NSImage] = [:]
    /// Procedural equirectangular "photo studio": bright overhead softbox, a warm key softbox on the
    /// upper left, a cool strip on the right, neutral floor. Gives PBR highlights shape without an asset.
    static func studioEnvironment(dark: Bool) -> NSImage {
        if let i = envCache[dark] { return i }
        let w = 256, h = 128
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: w * 4, bitsPerPixel: 32)!
        let p = rep.bitmapData!
        func box(_ u: Double, _ v: Double, _ cu: Double, _ cv: Double, _ su: Double, _ sv: Double) -> Double {
            let du = min(abs(u - cu), 1 - abs(u - cu)) / su, dv = (v - cv) / sv
            return exp(-pow(du * du + dv * dv, 2))
        }
        for y in 0..<h {
            let v = Double(y) / Double(h - 1)          // 0 = top (zenith), 1 = nadir
            for x in 0..<w {
                let u = Double(x) / Double(w)
                var base = dark ? (v < 0.5 ? 0.10 + 0.12 * (0.5 - v) : 0.03) : (v < 0.5 ? 0.62 + 0.3 * (0.5 - v) : 0.30 - 0.12 * (v - 0.5))
                var r = base, g = base, b = base
                let top = box(u, v, 0.5, 0.0, 2, 0.16) * (dark ? 1.6 : 1.4)
                let key = box(u, v, 0.37, 0.3, 0.07, 0.1) * 2.4
                let strip = box(u, v, 0.72, 0.42, 0.025, 0.2) * 1.4
                r += top + key * 1.0 + strip * 0.8; g += top + key * 0.96 + strip * 0.9; b += top + key * 0.9 + strip * 1.05
                base = 0
                let o = (y * w + x) * 4
                p[o] = UInt8(min(255, r * 255)); p[o + 1] = UInt8(min(255, g * 255)); p[o + 2] = UInt8(min(255, b * 255)); p[o + 3] = 255
            }
        }
        let img = NSImage(size: NSSize(width: w, height: h)); img.addRepresentation(rep)
        envCache[dark] = img
        return img
    }
}
