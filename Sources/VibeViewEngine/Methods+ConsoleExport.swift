import Foundation
import MolCore
import MolIO
import MolCommand

// Console `export` (agent "misc"): the macOS command set — image (PNG, JPEG, TIFF; HEIC is macOS-only), animation
// (GIF, MP4), CSV tables and structure files.
//
// Structures are written here, from the console's snapshot (ExportWriter, same text as File > Export). Images,
// animations and tables are drawn by the front end: the command's ViewChange carries
//   exportImage: {kind: "image"|"animation"|"table", path, token, …request fields}
// and the front end sends the encoded bytes back with
//   command.writeExport {token, base64 | text}  -> {path, bytes}
// The token is a one-time grant for the path typed on the console line (the main process only writes to paths
// picked in a Save dialog), valid for 15 minutes.

/// One-time write grants for console exports.
final class ConsoleExportGrants: @unchecked Sendable {
    static let shared = ConsoleExportGrants()
    static let lifetime: TimeInterval = 15 * 60
    private let lock = NSLock()
    private var grants: [String: (url: URL, kind: String, at: Date)] = [:]

    func grant(_ url: URL, kind: String) -> String {
        let token = UUID().uuidString
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        grants = grants.filter { now.timeIntervalSince($0.value.at) < Self.lifetime }
        grants[token] = (url, kind, now)
        return token
    }

    /// Removes and returns the grant (each token writes once).
    func take(_ token: String) -> (url: URL, kind: String)? {
        lock.lock(); defer { lock.unlock() }
        guard let g = grants.removeValue(forKey: token), Date().timeIntervalSince(g.at) < Self.lifetime else { return nil }
        return (g.url, g.kind)
    }
}

extension EngineCommandContext {
    func exportImage(_ r: ImageExportRequest, to url: URL) throws {
        if r.format == .heic { throw CommandError("HEIC is not available on Windows; use .png, .jpg or .tiff") }
        guard !model.molecule.atoms.isEmpty else { throw CommandError("nothing to export: the document is empty") }
        try checkDirectory(url)
        exportRequest = obj([
            "kind": "image", "path": url.path, "token": ConsoleExportGrants.shared.grant(url, kind: "image"),
            "format": r.format.rawValue, "width": r.width, "height": r.height, "scale": r.scale, "dpi": r.dpi,
            "transparent": r.transparent, "quality": r.quality, "fit": r.fit, "look": r.look, "supersample": r.supersample,
        ])
    }

    func exportAnimation(_ r: AnimationExportRequest, to url: URL) throws -> String {
        if r.format == .mov { throw CommandError("MOV is not available on Windows; use .gif or .mp4") }
        let source: JSON
        var summary: String
        switch r.source {
        case .vibration(let n):
            let modes = doc.result?.normalModes ?? []
            guard modes.indices.contains(n - 1) else {
                throw CommandError(modes.isEmpty ? "this document has no vibrational modes" : "no vibrational mode \(n) (1–\(modes.count))")
            }
            source = obj(["type": "vibration", "mode": n - 1])
            summary = "mode \(n), \(r.framesPerLoop * r.loops) frames"
        case .trajectory:
            let n = doc.frames.count
            guard n > 1 else { throw CommandError("this document has no trajectory (one structure)") }
            source = obj(["type": "trajectory"])
            summary = "\((n + r.step - 1) / r.step) of \(n) frames"
        case .spin:
            guard !model.molecule.atoms.isEmpty else { throw CommandError("nothing to export: the document is empty") }
            source = obj(["type": "spin", "axis": r.axis.rawValue])
            summary = "\(r.framesPerLoop * r.loops) frames"
        }
        try checkDirectory(url)
        exportRequest = obj([
            "kind": "animation", "path": url.path, "token": ConsoleExportGrants.shared.grant(url, kind: "animation"),
            "format": r.format.rawValue, "source": source, "width": r.width, "height": r.height, "fps": r.fps,
            "duration": r.duration, "loops": r.loops, "loopForever": r.gifLoopCount == 0, "quality": r.quality, "look": r.look,
            "transparent": r.transparent, "amplitude": r.amplitude, "step": r.step, "framesPerLoop": r.framesPerLoop,
        ])
        summary += ", rendering in the viewer"
        return summary
    }

    func exportTable(_ t: CSVTableName, to url: URL) throws {
        let r = doc.result
        switch t {
        case .frequencies: guard !(r?.normalModes.isEmpty ?? true) else { throw CommandError("this document has no vibrational modes") }
        case .orbitals: guard doc.orbitalCount > 0 else { throw CommandError("this document has no orbitals") }
        case .states: guard !(r?.excitedStates.isEmpty ?? true) else { throw CommandError("this document has no excited states") }
        case .energies: guard doc.frames.count > 1 || !(r?.energies.isEmpty ?? true) else { throw CommandError("this document has no energies") }
        case .charges: guard !(r?.chargesByScheme.isEmpty ?? true) else { throw CommandError("this document has no atomic charges") }
        }
        try checkDirectory(url)
        exportRequest = obj(["kind": "table", "path": url.path, "token": ConsoleExportGrants.shared.grant(url, kind: "table"),
                             "table": t.rawValue])
    }

    func exportStructure(to url: URL, allFrames: Bool, selectedOnly: Bool) throws -> String {
        var d = doc
        d.model = model              // edits made earlier on the same console line
        let ext = url.pathExtension
        var p: [String: JSON] = ["format": .string(ext), "frames": .string(allFrames ? "all" : "current")]
        if selectedOnly {
            let sel = model.selection.sorted
            guard !sel.isEmpty else { throw CommandError("no atoms are selected") }
            p["atoms"] = sel.json
        }
        let out: JSON
        do { out = try ExportWriter.export(d, Params(.object(p))) } catch let e as RPCError { throw CommandError(e.message) }
        guard let text = out["text"]?.stringValue else { throw CommandError("nothing to write") }
        do { try text.write(to: url, atomically: true, encoding: .utf8) } catch {
            throw CommandError("could not write \(url.lastPathComponent): \(error.localizedDescription)")
        }
        let frames = out["frameCount"]?.intValue ?? 1, atoms = out["atomCount"]?.intValue ?? 0
        return frames > 1 ? "\(frames) frames, \(atoms) atoms each" : "\(atoms) atoms"
    }

    private func checkDirectory(_ url: URL) throws {
        var isDir: ObjCBool = false
        let dir = url.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            throw CommandError("no such folder: \(dir.path)")
        }
    }
}

extension Engine {
    /// `command.writeExport {token, base64 | text}`: writes the bytes of a console image/animation/table export.
    func commandWriteExport(_ p: Params) async throws -> JSON {
        let token = try p.string("token")
        guard let g = ConsoleExportGrants.shared.take(token) else {
            throw RPCError.notFound("unknown or expired export token (run the export command again)")
        }
        let data: Data
        if let b = p.optString("base64") {
            guard let d = Data(base64Encoded: b) else { throw RPCError.badRequest("base64 does not decode") }
            data = d
        } else if let t = p.optString("text") {
            data = Data(t.utf8)
        } else {
            throw RPCError.badRequest("give 'base64' or 'text'")
        }
        do { try data.write(to: g.url, options: .atomic) } catch {
            throw RPCError.io("could not write \(g.url.lastPathComponent): \(error.localizedDescription)")
        }
        return obj(["path": g.url.path, "bytes": data.count, "kind": g.kind])
    }
}
