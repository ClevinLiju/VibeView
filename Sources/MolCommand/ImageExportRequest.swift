import Foundation

/// What `export image` asked for, independent of the renderer. Pixel sizes are final image pixels;
/// a missing width or height follows the current view's aspect ratio, and when both are missing the
/// image is the current view at `scale` × its size on screen.
public struct ImageExportRequest: Equatable, Sendable {
    public enum Format: String, Sendable { case png, jpeg, tiff, heic }

    public var format: Format = .png
    public var width: Int?
    public var height: Int?
    public var scale: Double = 2
    public var dpi: Double = 300
    public var transparent = false
    /// Render look name: studio, whitepaper, darkstage, illustration (nil keeps the current look).
    public var look: String?
    public var supersample: Int = 2
    /// JPEG/HEIC quality, 0...1.
    public var quality: Double = 0.95
    /// Zoom so the molecule (and any orbital surface) fills the view before exporting. This also refits the
    /// on-screen view.
    public var fit = false

    public init() {}

    public static let looks = ["studio", "whitepaper", "darkstage", "illustration"]

    public static func format(forExtension ext: String) -> Format? {
        switch ext.lowercased() {
        case "png": .png
        case "jpg", "jpeg": .jpeg
        case "tif", "tiff": .tiff
        case "heic", "heif": .heic
        default: nil
        }
    }

    public static let usage = "export image <file.png|jpg|tiff|heic> [W H] [width W] [height H] [scale S] [dpi D] "
        + "[transparent] [fit] [look studio|whitepaper|darkstage|illustration] [supersample N] [quality Q] [4k|publication]"

    /// Parses the words after the file path. Accepts the older positional form `<W> <H>`.
    public static func parse(path: String, options words: [String]) throws -> ImageExportRequest {
        var r = ImageExportRequest()
        let ext = (path as NSString).pathExtension
        guard let f = format(forExtension: ext) else {
            throw CommandError(ext.isEmpty ? "give the file an extension: .png, .jpg, .tiff or .heic"
                                           : "unsupported image type '.\(ext)' (use .png, .jpg, .tiff or .heic)")
        }
        r.format = f
        func number(_ s: String, _ what: String) throws -> Double {
            guard let v = Double(s), v > 0 else { throw CommandError("'\(s)' is not a valid \(what)") }
            return v
        }
        func pixels(_ s: String) throws -> Int {
            guard let n = Int(s), n > 0, n <= 16384 else { throw CommandError("'\(s)' is not a pixel size (1–16384)") }
            return n
        }
        var i = 0
        var positional: [Int] = []
        while i < words.count {
            let w = words[i].lowercased()
            func value() throws -> String {
                guard i + 1 < words.count else { throw CommandError("'\(w)' needs a value") }
                i += 1
                return words[i]
            }
            switch w {
            case "width", "w": r.width = try pixels(try value())
            case "height", "h": r.height = try pixels(try value())
            case "scale": r.scale = try number(try value(), "scale")
            case "dpi": r.dpi = try number(try value(), "dpi")
            case "fit": r.fit = true
            case "transparent": r.transparent = true
            case "opaque": r.transparent = false
            case "look":
                let l = try value().lowercased()
                guard looks.contains(l) else { throw CommandError("unknown look '\(l)' (\(looks.joined(separator: ", ")))") }
                r.look = l
            case "supersample", "ss":
                guard let n = Int(try value()), (1...4).contains(n) else { throw CommandError("supersample must be 1–4") }
                r.supersample = n
            case "quality", "q":
                let q = try number(try value(), "quality")
                r.quality = q > 1 ? min(q / 100, 1) : q            // accepts 0.9 or 90
            case "4k": r.width = 3840; r.height = 2160
            case "publication", "pub": r.width = 4200; r.height = 3000; r.dpi = 600; r.look = r.look ?? "whitepaper"
            default:
                guard positional.count < 2, let n = Int(w) else { throw CommandError("unknown export option '\(words[i])'") }
                positional.append(try pixels(w))
            }
            i += 1
        }
        if positional.count == 1 { throw CommandError("give both width and height, or use 'width W'") }
        if positional.count == 2 { r.width = positional[0]; r.height = positional[1] }
        if r.transparent && r.format == .jpeg { throw CommandError("JPEG cannot be transparent; use .png, .tiff or .heic") }
        return r
    }
}
