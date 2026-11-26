import Foundation
import MolCore
import MolIO
import MolBuild
import MolCompute

// Job files (job.files / job.readFile), the pre-run geometry check (calc.preflight) and the ORCA orbital conversion
// that runs after an ORCA calc.run (orca_2mkl -molden).

/// Lines collected from a running job (its stderr), thread-safe.
final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    private var bytes = 0
    /// At most 4 MB are kept; later lines are dropped.
    func append(_ l: String) {
        lock.lock(); defer { lock.unlock() }
        guard bytes < 4 << 20 else { return }
        lines.append(l); bytes += l.utf8.count + 1
    }
    var isEmpty: Bool { lock.lock(); defer { lock.unlock() }; return lines.isEmpty }
    /// The lines joined with "\n", or nil when nothing was collected.
    func text() -> String? {
        lock.lock(); defer { lock.unlock() }
        return lines.isEmpty ? nil : lines.joined(separator: "\n") + "\n"
    }
}

extension Engine {
    // MARK: ORCA orbitals

    /// After an ORCA `calc.run`: `orca_2mkl <base> -molden` in the job folder, logged in the job log. Never throws; a
    /// failure leaves the results without orbitals and is reported as `moldenError`.
    func moldenAfterOrcaJob(jobId: String, baseName: String, directory: URL, orca: URL) async -> (URL?, String?) {
        func log(_ line: String, _ stream: String = "stdout") {
            notify("job.log", obj(["jobId": jobId, "stream": stream, "file": JSON.null, "line": line]))
        }
        guard let tool = OrcaMoldenConversion.locateTool(nextTo: orca) ?? ProgramLocator.find("orca_2mkl") else {
            let msg = "orca_2mkl not found next to \(ProgramPaths.nativePath(orca)): run `orca_2mkl \(baseName) -molden` to view orbitals"
            log("VibeView: " + msg, "stderr")
            return (nil, msg)
        }
        await jobs.setStatus(jobId, "postprocessing")
        log("VibeView: converting orbitals: \(ProgramPaths.nativePath(tool)) \(baseName) -molden")
        do {
            let o = try await OrcaMoldenConversion.convert(baseName: baseName, in: directory, tool: tool)
            for l in o.output.split(whereSeparator: \.isNewline).suffix(20) { log(String(l)) }
            log("VibeView: wrote \(o.moldenURL.lastPathComponent)")
            await jobs.update(jobId) { $0.moldenFile = o.moldenURL.lastPathComponent }
            return (o.moldenURL, nil)
        } catch {
            let msg = "orca_2mkl failed: " + RPCError.from(error).message
            log("VibeView: " + msg, "stderr")
            return (nil, msg)
        }
    }

    // MARK: Pre-run geometry check

    /// `calc.preflight {docId}`: problems that usually make a calculation fail (an isolated atom, an over-stretched
    /// bond, disconnected fragments). `text` is the confirmation message, null when the geometry looks fine.
    func calcPreflight(_ p: Params) async throws -> JSON {
        let d = try await store.get(try p.docId())
        let ws = GeometryPreflight.check(d.molecule)
        let list: [JSON] = ws.map { w in
            switch w.kind {
            case .isolatedAtom(let a, let dist):
                return obj(["kind": "isolatedAtom", "atoms": [a], "distance": dist, "message": w.message])
            case .stretchedBond(let a, let b, let dist, let ratio):
                return obj(["kind": "stretchedBond", "atoms": [a, b], "distance": dist, "ratio": ratio, "message": w.message])
            case .fragments(let sizes):
                return obj(["kind": "fragments", "atoms": [Int](), "sizes": sizes, "message": w.message])
            }
        }
        return obj(["warnings": JSON.array(list), "text": GeometryPreflight.confirmationText(ws)])
    }

    // MARK: Job files

    /// The job folder and its known files: from the job registry (`jobId`), or a folder the front end remembers
    /// (`directory`, for jobs from before an engine restart).
    private func jobFolder(_ p: Params) async throws -> (URL, JobRegistry.Info?) {
        if let id = p.optString("jobId"), let j = await jobs.info(id) {
            return (URL(fileURLWithPath: j.directory, isDirectory: true), j)
        }
        if let dir = p.optString("directory"), !dir.isEmpty {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else {
                throw RPCError.notFound("job folder \(dir) does not exist")
            }
            return (URL(fileURLWithPath: dir, isDirectory: true), nil)
        }
        if let id = p.optString("jobId") { throw RPCError.notFound("no job '\(id)'") }
        throw RPCError.badRequest("jobId or directory is required")
    }

    /// Role of a file in a job folder, for the viewer's buttons.
    static func jobFileRole(_ name: String, info: JobRegistry.Info?) -> String {
        let l = name.lowercased()
        if let i = info {
            if i.inputFile?.lowercased() == l { return "input" }
            if i.outputFile?.lowercased() == l { return "output" }
            if i.errorFile?.lowercased() == l { return "error" }
            if i.moldenFile?.lowercased() == l { return "orbitals" }
        }
        let ext = (l as NSString).pathExtension
        if l.hasPrefix("gxx.") { return "binary" }   // Gaussian scratch (gxx.inp, gxx.rwf, …) in the job folder
        if l.hasSuffix(".stderr.txt") || ext == "err" { return "error" }
        if l.hasSuffix(".molden.input") || ext == "molden" || ext == "fchk" || ext == "fch" { return "orbitals" }
        switch ext {
        case "gjf", "com", "inp", "in": return "input"
        case "log", "out": return "output"
        case "chk", "gbw", "tmp", "densities", "rwf", "int", "d2e", "scr": return "binary"
        case "xyz": return l.hasPrefix("xtbopt") || l.hasSuffix("_trj.xyz") ? "geometry" : (info == nil ? "input" : "geometry")
        case "hess", "engrad", "cube", "cub": return "data"
        default: return "other"
        }
    }

    /// `job.files {jobId | directory}`: the files in the job folder (name, size, modified, role) plus the input, output and
    /// error file names, the command line and the job status.
    func jobFiles(_ p: Params) async throws -> JSON {
        let (dir, info) = try await jobFolder(p)
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        var files: [JSON] = []
        for n in names {
            let u = dir.appendingPathComponent(n)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: u.path, isDirectory: &isDir), !isDir.boolValue else { continue }
            let a = try? fm.attributesOfItem(atPath: u.path)
            let size = (a?[.size] as? NSNumber)?.intValue ?? 0
            let modified = (a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            files.append(obj(["name": n, "size": size, "modified": modified * 1000, "role": Engine.jobFileRole(n, info: info),
                              "path": ProgramPaths.nativePath(u)]))
        }
        // When the output was planned as job.log but G09W wrote job.out (or vice versa), point at the one that exists.
        var output = info?.outputFile
        if let o = output, !names.contains(o) {
            let stem = (o as NSString).deletingPathExtension
            output = [stem + ".log", stem + ".out"].first { names.contains($0) } ?? o
        }
        return obj([
            "directory": ProgramPaths.nativePath(dir), "files": JSON.array(files),
            "inputFile": info?.inputFile, "outputFile": output, "errorFile": info?.errorFile, "moldenFile": info?.moldenFile,
            "commandLine": info?.commandLine, "status": info?.status, "program": info?.program, "inputEdited": info?.inputEdited ?? false,
        ])
    }

    /// `job.readFile {jobId | directory, name, maxBytes?}`: a text file of the job folder (by plain name; no paths). Large
    /// files return their last `maxBytes` (default 4 MB) with `truncated: true`; binary files are refused.
    func jobReadFile(_ p: Params) async throws -> JSON {
        let (dir, _) = try await jobFolder(p)
        let name = try p.string("name")
        guard !name.isEmpty, !name.contains("/"), !name.contains("\\"), name != ".", name != "..", !name.contains(":") else {
            throw RPCError.badRequest("name must be a file name in the job folder")
        }
        let u = dir.appendingPathComponent(name)
        guard let h = try? FileHandle(forReadingFrom: u) else { throw RPCError.notFound("\(name) does not exist (yet) in \(ProgramPaths.nativePath(dir))") }
        defer { try? h.close() }
        let size = ((try? FileManager.default.attributesOfItem(atPath: u.path))?[.size] as? NSNumber)?.intValue ?? 0
        let maxBytes = max(1024, min(p.optInt("maxBytes") ?? (4 << 20), 64 << 20))
        let start = max(0, size - maxBytes)
        if start > 0 { try? h.seek(toOffset: UInt64(start)) }
        let data = (try? h.readToEnd()) ?? Data()
        if data.prefix(8192).contains(0) { throw RPCError.badRequest("\(name) is a binary file") }
        var text = String(decoding: data, as: UTF8.self)
        if start > 0, let nl = text.firstIndex(of: "\n") { text = String(text[text.index(after: nl)...]) }   // drop the partial first line
        return obj(["name": name, "path": ProgramPaths.nativePath(u), "size": size, "truncated": start > 0, "text": text])
    }
}
