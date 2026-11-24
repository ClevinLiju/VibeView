import SceneKit
import AppKit
import ImageIO
import Metal
import UniformTypeIdentifiers
import MolCore

public enum ImageFormat: String, Sendable, CaseIterable { case png, tiff }
public struct ImageExportOptions: Sendable {
    public var widthPoints: Double = 800
    public var heightPoints: Double = 600
    public var dpi: Double = 144          // 72 dpi = 1 px per point
    public var transparentBackground = false
    public var format: ImageFormat = .png
    /// Render at N x the output size and downsample (on top of 4x MSAA). 1...4; reduced automatically
    /// so the internal render stays <= 16384 px.
    public var supersampling: Int = 2
    /// Optional style override for this export only (e.g. `.whitePaper`); the live view is untouched.
    public var look: RenderLook? = nil
    public init() {}
    public var pixelSize: CGSize { CGSize(width: (widthPoints * dpi / 72).rounded(), height: (heightPoints * dpi / 72).rounded()) }

    /// Exact pixel dimensions at the given dpi (metadata only).
    public static func pixels(width: Int, height: Int, dpi: Double = 300) -> ImageExportOptions {
        var o = ImageExportOptions(); o.dpi = dpi
        o.widthPoints = Double(width) * 72 / dpi; o.heightPoints = Double(height) * 72 / dpi
        return o
    }
    /// 3840 x 2160, 300 dpi, transparent, 2x supersampled.
    public static var uhd4K: ImageExportOptions { var o = pixels(width: 3840, height: 2160); o.transparentBackground = true; return o }
    /// Journal figure: 7 in x 5 in at 600 dpi (4200 x 3000 px), white-paper look, 2x supersampled.
    public static var publication: ImageExportOptions { var o = pixels(width: 4200, height: 3000, dpi: 600); o.look = .whitePaper; return o }
}
public enum RenderExportError: Error { case renderFailed, encodeFailed, unsupported(String) }

extension MoleculeRenderer {
    /// Render the current scene offscreen (no window needed) at `opts.pixelSize`.
    ///
    /// Framing: the export shows what the view shows. When the export is narrower than the view the
    /// field of view is widened so nothing visible in the view is cropped; wider exports add margin.
    public func renderImage(_ opts: ImageExportOptions) throws -> CGImage {
        let size = opts.pixelSize
        guard size.width >= 1, size.height >= 1, size.width <= 16384, size.height <= 16384 else {
            throw RenderExportError.unsupported("invalid image size \(size)")
        }
        // Temporary look override
        let savedOptions = options
        if let look = opts.look { var o = options; o.apply(look); options = o }
        defer { if opts.look != nil { options = savedOptions } }

        let savedBackground = scene.background.contents
        let savedFog = scene.fogColor
        if opts.transparentBackground {
            scene.background.contents = NSColor.clear
            scene.fogColor = NSColor.clear
        }
        // Aspect-preserving framing
        let cam = cameraNode.camera!
        let savedFOV = cam.fieldOfView, savedScale = cam.orthographicScale, savedDir = cam.projectionDirection
        let viewAspect = view.bounds.height > 0 ? Double(view.bounds.width / view.bounds.height) : 4.0 / 3.0
        let exportAspect = Double(size.width / size.height)
        cam.projectionDirection = .vertical
        if exportAspect < viewAspect {
            let k = viewAspect / exportAspect
            let half = Double(savedFOV) * .pi / 360
            cam.fieldOfView = CGFloat(min(170, 2 * atan(tan(half) * k) * 180 / .pi))
            cam.orthographicScale = savedScale * k
        }
        defer {
            cam.fieldOfView = savedFOV; cam.orthographicScale = savedScale; cam.projectionDirection = savedDir
            if opts.transparentBackground {
                scene.background.contents = savedBackground
                scene.fogColor = savedFog
            }
        }
        guard let device = MTLCreateSystemDefaultDevice() else { throw RenderExportError.renderFailed }
        let ss = max(1, min(opts.supersampling, 4, Int(16384 / max(size.width, size.height))))
        let big = CGSize(width: size.width * CGFloat(ss), height: size.height * CGFloat(ss))
        let r = SCNRenderer(device: device, options: nil)
        r.scene = scene
        r.pointOfView = cameraNode
        r.autoenablesDefaultLighting = false
        r.technique = outlineTechnique(heightPixels: Double(big.height), pointScale: opts.dpi / 72 * Double(ss))
        let image = r.snapshot(atTime: 0, with: big, antialiasingMode: .multisampling4X)
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw RenderExportError.renderFailed
        }
        if ss == 1 && cg.width == Int(size.width) && cg.height == Int(size.height) { return cg }
        return try Self.downsample(cg, to: size)
    }

    /// High-quality box/Lanczos-style reduction through Core Graphics (premultiplied RGBA, sRGB).
    static func downsample(_ img: CGImage, to size: CGSize) throws -> CGImage {
        let w = Int(size.width), h = Int(size.height)
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw RenderExportError.renderFailed }
        ctx.interpolationQuality = .high
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = ctx.makeImage() else { throw RenderExportError.renderFailed }
        return out
    }

    public func exportImage(to url: URL, options: ImageExportOptions) throws {
        let image = try renderImage(options)
        try ImageEncoding.write(image, to: url, format: options.format, dpi: options.dpi)
    }
}

enum ImageEncoding {
    static func write(_ image: CGImage, to url: URL, format: ImageFormat, dpi: Double) throws {
        let type: UTType = format == .png ? .png : .tiff
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw RenderExportError.encodeFailed
        }
        var props: [CFString: Any] = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi]
        if format == .png {
            let ppm = dpi / 0.0254
            props[kCGImagePropertyPNGDictionary] = [kCGImagePropertyPNGXPixelsPerMeter: Int(ppm.rounded()),
                                                    kCGImagePropertyPNGYPixelsPerMeter: Int(ppm.rounded())]
        } else {
            props[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFXResolution: dpi, kCGImagePropertyTIFFYResolution: dpi,
                                                     kCGImagePropertyTIFFResolutionUnit: 2]
        }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw RenderExportError.encodeFailed }
    }
}
