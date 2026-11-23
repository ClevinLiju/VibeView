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
    public init() {}
    public var pixelSize: CGSize { CGSize(width: (widthPoints * dpi / 72).rounded(), height: (heightPoints * dpi / 72).rounded()) }
}
public enum RenderExportError: Error { case renderFailed, encodeFailed, unsupported(String) }

extension MoleculeRenderer {
    /// Render the current scene offscreen (no window needed) at `opts.pixelSize`.
    public func renderImage(_ opts: ImageExportOptions) throws -> CGImage {
        let size = opts.pixelSize
        guard size.width >= 1, size.height >= 1, size.width <= 16384, size.height <= 16384 else {
            throw RenderExportError.unsupported("invalid image size \(size)")
        }
        let savedBackground = scene.background.contents
        let savedFog = scene.fogColor
        if opts.transparentBackground {
            scene.background.contents = NSColor.clear
            scene.fogColor = NSColor.clear
        }
        defer {
            if opts.transparentBackground {
                scene.background.contents = savedBackground
                scene.fogColor = savedFog
            }
        }
        guard let device = MTLCreateSystemDefaultDevice() else { throw RenderExportError.renderFailed }
        let r = SCNRenderer(device: device, options: nil)
        r.scene = scene
        r.pointOfView = cameraNode
        r.autoenablesDefaultLighting = false
        let image = r.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw RenderExportError.renderFailed
        }
        return cg
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
