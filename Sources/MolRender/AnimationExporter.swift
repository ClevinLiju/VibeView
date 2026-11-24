import SceneKit
import AppKit
import ImageIO
import AVFoundation
import CoreVideo
import UniformTypeIdentifiers
import MolCore

public enum AnimationFormat: String, Sendable, CaseIterable { case gif, mov, mp4 }

public enum AnimationExporter {
    /// Animated GIF. `prepareFrame(i)` poses the renderer for frame i (0..<frameCount) before it is rendered.
    /// loopCount 0 = forever.
    @MainActor public static func exportGIF(renderer: MoleculeRenderer, url: URL, frameCount: Int, fps: Double, loopCount: Int = 0,
                                            options: ImageExportOptions, prepareFrame: (Int) -> Void) throws {
        guard frameCount > 0, fps > 0 else { throw RenderExportError.unsupported("frameCount and fps must be positive") }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frameCount, nil) else {
            throw RenderExportError.encodeFailed
        }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: loopCount]] as CFDictionary)
        let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / fps]] as CFDictionary
        for i in 0..<frameCount {
            prepareFrame(i)
            let img = try renderer.renderImage(options)
            CGImageDestinationAddImage(dest, img, frameProps)
        }
        guard CGImageDestinationFinalize(dest) else { throw RenderExportError.encodeFailed }
    }

    /// H.264 movie (.mov or .mp4 by extension). Pixel dimensions are rounded down to even numbers.
    @MainActor public static func exportMovie(renderer: MoleculeRenderer, url: URL, frameCount: Int, fps: Double,
                                              options: ImageExportOptions, prepareFrame: (Int) -> Void) throws {
        guard frameCount > 0, fps > 0 else { throw RenderExportError.unsupported("frameCount and fps must be positive") }
        var opts = options
        opts.transparentBackground = false   // H.264 has no alpha
        let px = opts.pixelSize
        let w = max(2, Int(px.width) & ~1), h = max(2, Int(px.height) & ~1)
        // Render at an exact even pixel size (dpi scale 1 => points == pixels).
        opts.widthPoints = Double(w); opts.heightPoints = Double(h); opts.dpi = 72

        try? FileManager.default.removeItem(at: url)
        let fileType: AVFileType = url.pathExtension.lowercased() == "mp4" ? .mp4 : .mov
        let writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
        guard writer.canAdd(input) else { throw RenderExportError.unsupported("cannot add video input") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? RenderExportError.encodeFailed }
        writer.startSession(atSourceTime: .zero)
        let timescale: Int32 = 6000
        let frameDur = Int64((Double(timescale) / fps).rounded())
        for i in 0..<frameCount {
            prepareFrame(i)
            let img = try renderer.renderImage(opts)
            // Wait (pumping nothing; the writer is non-realtime so this settles quickly).
            var spins = 0
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed { throw writer.error ?? RenderExportError.encodeFailed }
                Thread.sleep(forTimeInterval: 0.005); spins += 1
                if spins > 4000 { throw RenderExportError.encodeFailed }
            }
            guard let pool = adaptor.pixelBufferPool else { throw RenderExportError.encodeFailed }
            var pbOut: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOut)
            guard let pb = pbOut else { throw RenderExportError.encodeFailed }
            CVPixelBufferLockBaseAddress(pb, [])
            let ok: Bool = {
                guard let base = CVPixelBufferGetBaseAddress(pb),
                      let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
                else { return false }
                ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
                return true
            }()
            CVPixelBufferUnlockBaseAddress(pb, [])
            guard ok else { throw RenderExportError.encodeFailed }
            guard adaptor.append(pb, withPresentationTime: CMTime(value: Int64(i) * frameDur, timescale: timescale)) else {
                throw writer.error ?? RenderExportError.encodeFailed
            }
        }
        input.markAsFinished()
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        sem.wait()
        guard writer.status == .completed else { throw writer.error ?? RenderExportError.encodeFailed }
    }

    /// Export one vibration cycle(s) of `mode`. Positions are restored afterwards.
    @MainActor public static func exportVibration(renderer: MoleculeRenderer, mode: NormalMode, url: URL, framesPerCycle: Int = 24,
                                                  cycles: Int = 1, amplitude: Double = 0.5, format: AnimationFormat = .gif,
                                                  options: ImageExportOptions = ImageExportOptions()) throws {
        // A live (GPU) vibration would fight the exported poses: suspend it and resume afterwards.
        let live = renderer.vibration.isPlaying ? renderer.vibration.mode : nil
        renderer.vibration.stop()
        defer { if let live { renderer.vibration.play(live) } }
        let base = renderer.molecule.atoms.map(\.position)
        guard mode.displacements.count == base.count else { throw RenderExportError.unsupported("mode/atom count mismatch") }
        let fpc = max(2, framesPerCycle)
        let total = fpc * max(1, cycles)
        defer { renderer.updatePositions(base) }
        let prepare: (Int) -> Void = { i in
            let phase = 2 * Double.pi * Double(i) / Double(fpc)
            renderer.updatePositions(VibrationMath.displaced(base: base, mode: mode, amplitude: amplitude, phase: phase))
        }
        let fps = 24.0
        switch format {
        case .gif: try exportGIF(renderer: renderer, url: url, frameCount: total, fps: fps, options: options, prepareFrame: prepare)
        case .mov, .mp4: try exportMovie(renderer: renderer, url: url, frameCount: total, fps: fps, options: options, prepareFrame: prepare)
        }
    }

    @MainActor public static func exportTrajectory(renderer: MoleculeRenderer, frames: [Molecule], url: URL, fps: Double = 10,
                                                   format: AnimationFormat = .gif,
                                                   options: ImageExportOptions = ImageExportOptions()) throws {
        guard !frames.isEmpty else { throw RenderExportError.unsupported("no frames") }
        let saved = renderer.molecule
        defer { renderer.setMolecule(saved, fitCamera: false) }
        let prepare: (Int) -> Void = { i in
            let f = frames[i]
            let cur = renderer.molecule
            if f.atoms.count == cur.atoms.count && f.bonds == cur.bonds
                && zip(f.atoms, cur.atoms).allSatisfy({ $0.atomicNumber == $1.atomicNumber }) {
                renderer.updatePositions(f.atoms.map(\.position))
            } else { renderer.setMolecule(f, fitCamera: false) }
        }
        switch format {
        case .gif: try exportGIF(renderer: renderer, url: url, frameCount: frames.count, fps: fps, options: options, prepareFrame: prepare)
        case .mov, .mp4: try exportMovie(renderer: renderer, url: url, frameCount: frames.count, fps: fps, options: options, prepareFrame: prepare)
        }
    }
}
