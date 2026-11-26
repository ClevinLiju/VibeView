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
        Check("command.export.kinds") {
            guard case let .image(p, r) = try ExportCommand.parse(["image", "a.png", "800", "600"]) else { throw CheckFailure(description: "image") }
            try expect(p == "a.png" && r.width == 800)
            guard case let .csv(_, t) = try ExportCommand.parse(["csv", "f.csv", "frequencies"]) else { throw CheckFailure(description: "csv") }
            try expect(t == .frequencies)
            for (w, want) in [("orbitals", CSVTableName.orbitals), ("states", .states), ("energies", .energies), ("charges", .charges), ("ir", .frequencies)] {
                guard case let .csv(_, t2) = try ExportCommand.parse(["csv", "x.csv", w]) else { throw CheckFailure(description: w) }
                try expect(t2 == want, w)
            }
            try expect(try ExportCommand.parse(["structure", "t.xyz", "all"]) == .structure(path: "t.xyz", allFrames: true, selectedOnly: false))
            try expect(try ExportCommand.parse(["structure", "t.pdb"]) == .structure(path: "t.pdb", allFrames: false, selectedOnly: false))
            try expect(try ExportCommand.parse(["structure", "t.sdf", "all", "selected"]) == .structure(path: "t.sdf", allFrames: true, selectedOnly: true))
            for bad in [["csv", "x.csv"], ["csv", "x.csv", "spectra"], ["structure", "noext"], ["structure", "a.xyz", "everything"],
                        ["video", "a.mp4"], ["gif"]] {
                do { _ = try ExportCommand.parse(bad); throw CheckFailure(description: "accepted \(bad)") } catch is CommandError {}
            }
        },
        Check("command.export.animation") {
            guard case let .animation(p, v) = try ExportCommand.parse(["gif", "m.gif", "vibration", "3", "fps", "20", "duration", "1.5", "loops", "2", "640", "480"])
            else { throw CheckFailure(description: "gif") }
            try expect(p == "m.gif" && v.format == .gif && v.source == .vibration(3) && v.fps == 20 && v.loops == 2 && v.width == 640 && v.height == 480)
            try expect(v.framesPerLoop == 30)
            guard case let .animation(_, t) = try ExportCommand.parse(["mp4", "t.mp4", "trajectory", "step", "5", "quality", "60", "look", "darkstage"])
            else { throw CheckFailure(description: "mp4") }
            try expect(t.format == .mp4 && t.source == .trajectory && t.step == 5 && abs(t.quality - 0.6) < 1e-9 && t.look == "darkstage")
            guard case let .animation(_, s) = try ExportCommand.parse(["gif", "s.gif", "spin", "axis", "x", "width", "300"]) else { throw CheckFailure(description: "spin") }
            try expect(s.source == .spin && s.axis == .x && s.width == 300 && s.height == nil && s.framesPerLoop == 96)
            let bad: [[String]] = [["gif", "a.gif"], ["gif", "a.gif", "vibration"], ["gif", "a.gif", "vibration", "0"], ["gif", "a.mp4", "spin"],
                                   ["mp4", "a.mp4", "spin", "transparent"], ["gif", "a.gif", "spin", "fps", "500"], ["gif", "a.gif", "spin", "640"],
                                   ["gif", "a.gif", "spin", "look", "neon"], ["gif", "a.gif", "dance"], ["gif", "a.gif", "spin", "loops", "0"]]
            for b in bad {
                do { _ = try ExportCommand.parse(b); throw CheckFailure(description: "accepted \(b)") } catch is CommandError {}
            }
        },
        Check("command.style.cartoon") {
            try expect(DisplayStyleName(rawValue: "cartoon") == .cartoon)
            let c = CommandCompleter.candidates(for: "style car", cwd: URL(fileURLWithPath: NSTemporaryDirectory()))
            try expect(c == ["cartoon"], "\(c)")
            let k = CommandCompleter.candidates(for: "export ", cwd: URL(fileURLWithPath: NSTemporaryDirectory()))
            try expect(Set(["image", "gif", "mp4", "csv", "structure"]).isSubset(of: Set(k)), "\(k)")
            let a = CommandCompleter.candidates(for: "export gif out.gif ", cwd: URL(fileURLWithPath: NSTemporaryDirectory()))
            try expect(a == ["spin", "trajectory", "vibration"], "\(a)")
        },
    ]
}
