import AppKit
import UniformTypeIdentifiers
import MolCore
import MolRender

/// A saved working session (`.vibeview`, JSON): the structure, a reference to the file the results came
/// from, the camera, display options, monitors and orbital/vibration choices.
struct VibeViewSession: Codable {
    var format = "vibeview-session"
    var version = 1
    var appVersion: String = AppInfo.version
    var saved = Date()
    var molecule: Molecule
    /// The document the results were read from (re-opened on restore so orbitals, modes and spectra come back).
    var sourceFile: String?
    var renderOptions: RenderOptions
    var camera: CameraState?
    var monitors: [Monitor]
    var orbitalLook: OrbitalLook?
    var activeOrbitalIndex: Int?
    var activeModeIndex: Int?
    var orbitalIsovalue: Double?
    var frameIndex: Int?
}

extension UTType {
    static let vibeViewSession = UTType(exportedAs: "io.github.clevinliju.vibeview.session", conformingTo: .json)
}

@MainActor
enum SessionStore {
    static func encode(_ e: EditorModel) throws -> Data {
        let s = VibeViewSession(molecule: e.molecule, sourceFile: e.fileURL?.path, renderOptions: e.renderOptions,
                                camera: e.viewport.renderer.camera.state, monitors: e.monitors, orbitalLook: e.orbitalLook,
                                activeOrbitalIndex: e.activeOrbitalIndex, activeModeIndex: e.activeModeIndex,
                                orbitalIsovalue: e.orbitalIsovalue, frameIndex: e.frameIndex)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return try enc.encode(s)
    }

    static func decode(_ d: Data) throws -> VibeViewSession {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try dec.decode(VibeViewSession.self, from: d)
    }

    static func save(_ e: EditorModel) {
        let p = NSSavePanel()
        p.allowedContentTypes = [.vibeViewSession]
        p.nameFieldStringValue = (e.fileURL?.deletingPathExtension().lastPathComponent ?? (e.molecule.title.isEmpty ? "Session" : e.molecule.title)) + ".vibeview"
        guard p.runModal() == .OK, let url = p.url else { return }
        do {
            try encode(e).write(to: url, options: .atomic)
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            e.statusMessage = "Session saved to \(url.lastPathComponent)"
        } catch { NSAlert(error: error).runModal() }
    }

    static func openPanel() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.vibeViewSession, .json]
        guard p.runModal() == .OK, let url = p.url else { return }
        open(url)
    }

    /// Restore a session: re-open its source document (or a copy of the saved structure), then apply the state.
    static func open(_ url: URL) {
        do {
            let s = try decode(Data(contentsOf: url))
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            let before = Set(EditorRegistry.live.map { ObjectIdentifier($0) })
            if let src = s.sourceFile, FileManager.default.fileExists(atPath: src) {
                DocumentOpener.open(URL(fileURLWithPath: src))
            } else {
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("VibeView-Sessions", isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let tmp = dir.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".mol")
                try IOBridge.write(s.molecule, ext: "mol").write(to: tmp)
                DocumentOpener.open(tmp)
            }
            apply(s, waitingFor: before, attempts: 40)
        } catch {
            let a = NSAlert(error: error); a.messageText = "“\(url.lastPathComponent)” is not a readable VibeView session."; a.runModal()
        }
    }

    /// The window opens asynchronously; poll briefly for its editor (or reuse an already-open one for the file).
    private static func apply(_ s: VibeViewSession, waitingFor before: Set<ObjectIdentifier>, attempts: Int) {
        let target = EditorRegistry.live.first { !before.contains(ObjectIdentifier($0)) }
            ?? EditorRegistry.live.first { s.sourceFile != nil && $0.fileURL?.path == s.sourceFile }
        guard let e = target else {
            if attempts > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { apply(s, waitingFor: before, attempts: attempts - 1) } }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { restore(s, into: e) }
    }

    static func restore(_ s: VibeViewSession, into e: EditorModel) {
        if s.molecule != e.molecule, s.molecule.atoms.count > 0 { e.replaceMolecule(s.molecule, actionName: "Restore Session") }
        e.renderOptions = s.renderOptions
        e.monitors = s.monitors.filter { $0.atoms.allSatisfy { $0 < e.molecule.atoms.count } }
        if let l = s.orbitalLook { e.orbitalLook = l }
        if let v = s.orbitalIsovalue { e.orbitalIsovalue = v }
        if let f = s.frameIndex, e.result?.steps.indices.contains(f) == true { e.frameIndex = f }
        e.activeOrbitalIndex = s.activeOrbitalIndex
        e.activeModeIndex = s.activeModeIndex
        if let c = s.camera { e.viewport.renderer.camera.setState(c, animated: false) }
        e.statusMessage = "Session restored"
    }
}
