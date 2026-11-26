import Foundation
import MolCore

/// `.vibeview` sessions. The top level matches the macOS app's `VibeViewSession` (format, version, appVersion,
/// saved, molecule, sourceFile, renderOptions, monitors, …) so either app can open the other's files; the
/// Windows engine adds `documents` (one entry per saved document) and keeps each document's front-end `view` state.
extension Engine {
    func sessionSave(_ p: Params) async throws -> JSON {
        let path = try p.string("path")
        var ids: [String] = []
        if let arr = p["docs"]?.arrayValue { ids = arr.compactMap { $0.stringValue ?? $0.intValue.map(String.init) } }
        else if let one = p.optString("docId") { ids = [one] }
        if ids.isEmpty { ids = await store.all().map(\.id) }
        guard !ids.isEmpty else { throw RPCError.badRequest("no documents to save") }
        let views = p["views"]?.objectValue ?? [:]
        var docs: [JSON] = []
        var first: EngineDocument?
        for id in ids {
            let d = try await store.get(id)
            if first == nil { first = d }
            docs.append(obj([
                "title": d.displayTitle, "sourceFile": d.path, "format": d.format?.rawValue,
                "molecule": try JSON.encode(d.molecule), "view": views[id] ?? JSON.null,
            ]))
        }
        let f = ISO8601DateFormatter()
        let fv = views[first!.id]
        var session: [String: JSON] = [
            "format": "vibeview-session", "version": 1, "appVersion": .string("windows-engine \(engineVersion)"),
            "saved": .string(f.string(from: Date())),
            "molecule": try JSON.encode(first!.molecule), "sourceFile": first!.path.json,
            "renderOptions": fv?["renderOptions"] ?? [:], "monitors": fv?["monitors"] ?? [],
            "documents": .array(docs),
        ]
        for k in ["camera", "orbitalLook", "activeOrbitalIndex", "activeModeIndex", "orbitalIsovalue", "frameIndex"] {
            if let v = fv?[k] { session[k] = v }
        }
        let json = JSON.object(session)
        do { try json.serialized().write(toFile: path, atomically: true, encoding: .utf8) } catch {
            throw RPCError.io("could not write \(path): \(error.localizedDescription)")
        }
        return ["path": .string(path), "session": json]
    }

    func sessionLoad(_ p: Params) async throws -> JSON {
        let path = try p.string("path")
        let text: String
        do { text = try String(contentsOfFile: path, encoding: .utf8) } catch {
            throw RPCError.io("could not read \(path): \(error.localizedDescription)")
        }
        let s = try JSON.parse(text)
        guard s["format"]?.stringValue == "vibeview-session" else { throw RPCError.parse("\(path) is not a VibeView session") }
        var entries: [JSON] = s["documents"]?.arrayValue ?? []
        if entries.isEmpty {
            // macOS session: one structure plus its view state at the top level.
            var view: [String: JSON] = [:]
            for k in ["renderOptions", "camera", "monitors", "orbitalLook", "activeOrbitalIndex", "activeModeIndex", "orbitalIsovalue", "frameIndex"] {
                if let v = s[k] { view[k] = v }
            }
            entries = [obj(["molecule": s["molecule"] ?? JSON.null, "sourceFile": s["sourceFile"] ?? JSON.null, "view": JSON.object(view)])]
        }
        var out: [JSON] = []
        for e in entries {
            var saved: Molecule?
            if let mj = e["molecule"], !mj.isNull { saved = try? mj.decode(Molecule.self) }
            var doc: EngineDocument
            if let src = e["sourceFile"]?.stringValue, FileManager.default.fileExists(atPath: src),
               let d = try? await openDocument(url: URL(fileURLWithPath: src), companions: true) {
                doc = d
                if let m = saved, !m.atoms.isEmpty, m != d.molecule {
                    doc = try await store.commit(d.id, name: "Restore Session", molecule: m)
                }
            } else {
                guard var m = saved else { continue }
                m.renumberAtomIDs()
                let id = await store.newId()
                doc = EngineDocument(id: id, molecule: m, title: e["title"]?.stringValue ?? (m.title.isEmpty ? "Session" : m.title))
                await store.insert(doc)
            }
            out.append(obj(["docId": doc.id, "summary": doc.summary(), "view": e["view"] ?? JSON.null]))
        }
        return ["session": s, "docs": .array(out)]
    }
}
