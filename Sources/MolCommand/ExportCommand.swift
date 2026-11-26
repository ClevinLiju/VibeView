import Foundation

/// Parsed `export …` command line (arguments after the command name).
public enum ExportCommand: Equatable, Sendable {
    case image(path: String, ImageExportRequest)
    case animation(path: String, AnimationExportRequest)
    case csv(path: String, CSVTableName)
    /// `all`: every frame (multi-frame formats); `selected`: only the selected atoms.
    case structure(path: String, allFrames: Bool, selectedOnly: Bool)

    public static let usage = """
    export image <file.png|jpg|tiff|heic> [options] | export gif|mp4|mov <path> vibration N|trajectory|spin [options] | \
    export csv <path> frequencies|orbitals|states|energies|charges | export structure <path> [all] [selected]
    """

    public static func parse(_ args: [String]) throws -> ExportCommand {
        guard args.count >= 2 else { throw CommandError("usage: " + usage) }
        let kind = args[0].lowercased(), path = args[1], rest = Array(args.dropFirst(2))
        switch kind {
        case "image", "picture", "png":
            return .image(path: path, try ImageExportRequest.parse(path: path, options: rest))
        case "gif", "mp4", "mov", "movie", "animation":
            var fmt = kind == "movie" ? "mp4" : kind
            if kind == "animation" { fmt = (path as NSString).pathExtension.lowercased() }
            return .animation(path: path, try AnimationExportRequest.parse(format: fmt, path: path, words: rest))
        case "csv", "table":
            guard let w = rest.first else { throw CommandError("export csv <path> " + CSVTableName.allCases.map(\.rawValue).joined(separator: "|")) }
            guard rest.count == 1, let t = CSVTableName.parse(w) else {
                throw CommandError("unknown table '\(rest.joined(separator: " "))'; choose " + CSVTableName.allCases.map(\.rawValue).joined(separator: ", "))
            }
            return .csv(path: path, t)
        case "structure", "molecule", "coords":
            guard !(path as NSString).pathExtension.isEmpty else { throw CommandError("give the file an extension (.xyz, .pdb, .sdf, .mol, .cml, .gjf…)") }
            var all = false, sel = false
            for w in rest {
                switch w.lowercased() {
                case "all", "frames", "allframes": all = true
                case "current": all = false
                case "selected", "selection", "sel": sel = true
                default: throw CommandError("unknown structure export option '\(w)' (all, selected)")
                }
            }
            return .structure(path: path, allFrames: all, selectedOnly: sel)
        default:
            throw CommandError("export what? image, gif, mp4, mov, csv or structure (got '\(args[0])')")
        }
    }
}
