import Foundation
import MolCommand

// `export image` option parsing (ImageExportRequest).
extension Checks {
    static let commandExport: [Check] = [
        Check("command.export.formatFromExtension") {
            try expect(try ImageExportRequest.parse(path: "a.png", options: []).format == .png)
            try expect(try ImageExportRequest.parse(path: "a.JPG", options: []).format == .jpeg)
            try expect(try ImageExportRequest.parse(path: "a.jpeg", options: []).format == .jpeg)
            try expect(try ImageExportRequest.parse(path: "a.tif", options: []).format == .tiff)
            try expect(try ImageExportRequest.parse(path: "a.heic", options: []).format == .heic)
            for bad in ["a.gif", "a"] {
                do { _ = try ImageExportRequest.parse(path: bad, options: []); throw CheckFailure(description: "\(bad) accepted") }
                catch is CommandError {}
            }
        },
        Check("command.export.options") {
            let r = try ImageExportRequest.parse(path: "fig.png", options: ["width", "2400", "dpi", "600", "transparent", "look", "whitepaper", "ss", "3"])
            try expect(r.width == 2400 && r.height == nil && r.dpi == 600 && r.transparent && r.look == "whitepaper" && r.supersample == 3)
            let p = try ImageExportRequest.parse(path: "fig.png", options: ["1920", "1080"])
            try expect(p.width == 1920 && p.height == 1080, "positional size")
            let k = try ImageExportRequest.parse(path: "fig.jpg", options: ["4k", "quality", "85"])
            try expect(k.width == 3840 && k.height == 2160, "4k preset")
            try expectClose(k.quality, 0.85)
            let pub = try ImageExportRequest.parse(path: "fig.tiff", options: ["publication"])
            try expect(pub.width == 4200 && pub.height == 3000 && pub.dpi == 600 && pub.look == "whitepaper")
            let s = try ImageExportRequest.parse(path: "fig.png", options: ["scale", "4"])
            try expect(s.width == nil && s.height == nil && s.scale == 4 && !s.fit)
            try expect(try ImageExportRequest.parse(path: "fig.png", options: ["fit"]).fit)
        },
        Check("command.export.errors") {
            let bad: [(String, [String])] = [
                ("a.jpg", ["transparent"]),          // JPEG has no alpha
                ("a.png", ["1920"]),                 // half a size
                ("a.png", ["width"]),                // missing value
                ("a.png", ["width", "0"]),
                ("a.png", ["width", "99999"]),
                ("a.png", ["look", "neon"]),
                ("a.png", ["supersample", "9"]),
                ("a.png", ["sparkles"]),
            ]
            for (path, opts) in bad {
                do { _ = try ImageExportRequest.parse(path: path, options: opts); throw CheckFailure(description: "accepted \(path) \(opts)") }
                catch is CommandError {}
            }
        },
    ]
}
