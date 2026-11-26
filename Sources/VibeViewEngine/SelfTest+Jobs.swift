import Foundation

// `--selftest` checks for the job helpers: calc.preflight, the editable xtb preview (calc.preview / calc.checkInput),
// and job.files / job.readFile.

extension SelfTest {
    static func runJobs(call: Call, check: Report, err: (JSON) -> String, waterXYZ: String) async {
        let w = await call("doc.openText", ["text": .string(waterXYZ), "format": "xyz", "fileName": "water.xyz"])
        let wId = w["result"]?["docId"]?.stringValue ?? ""

        // calc.preflight: clean water, then one H dragged 5 Å away.
        let clean = await call("calc.preflight", ["docId": .string(wId)])
        check("calc.preflight clean water", clean["result"]?["warnings"]?.arrayValue?.isEmpty == true && clean["result"]?["text"]?.stringValue == nil, err(clean))
        let far = """
        3
        dragged
        O    0.000000    0.000000    0.117300
        H    0.000000    5.200000    0.117300
        H    0.000000   -0.757200   -0.469200
        """
        let f = await call("doc.openText", ["text": .string(far), "format": "xyz", "fileName": "far.xyz"])
        let fId = f["result"]?["docId"]?.stringValue ?? ""
        let pf = await call("calc.preflight", ["docId": .string(fId)])
        let kinds = pf["result"]?["warnings"]?.arrayValue?.compactMap { $0["kind"]?.stringValue } ?? []
        let text = pf["result"]?["text"]?.stringValue ?? ""
        check("calc.preflight isolated atom", kinds.contains("isolatedAtom") && text.contains("H2") && text.hasSuffix("Run anyway?"),
              "\(kinds) \(text) \(err(pf))")

        // xtb preview: command line comment + XYZ; checkInput reports a broken command line.
        let xp = await call("calc.preview", ["docId": .string(wId), "spec": ["program": "xtb", "task": "optimize", "method": "GFN2-xTB", "nprocs": 2]])
        let xin = xp["result"]?["input"]?.stringValue ?? ""
        check("calc.preview xtb command line", xin.hasPrefix("# xtb job.xyz ") && xin.contains(" --opt") && xin.contains("# job.xyz:") && xin.contains("\nO ")
              && xp["result"]?["inputFile"]?.stringValue == "job.xyz", String(xin.prefix(80)) + err(xp))
        let ok = await call("calc.checkInput", ["program": "xtb", "text": .string(xin), "inputFile": "job.xyz"])
        check("calc.checkInput xtb ok", ok["result"]?["issues"]?.arrayValue?.isEmpty == true, err(ok))
        let bad = await call("calc.checkInput", ["program": "xtb", "text": "# orca job.xyz\n3\n", "inputFile": "job.xyz"])
        check("calc.checkInput xtb not xtb", bad["result"]?["issues"]?.arrayValue?.first?["message"]?.stringValue?.contains("orca") == true, err(bad))

        // job.files / job.readFile on a folder (as for a job from before an engine restart).
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vibeview-jobfiles-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try? "%chk=job.chk\n# HF/STO-3G\n\nt\n\n0 1\nH 0 0 0\nH 0 0 0.74\n\n".write(to: dir.appendingPathComponent("job.gjf"), atomically: true, encoding: .utf8)
        try? String(repeating: " SCF Done: E(RHF) = -1.1167\n", count: 2000).write(to: dir.appendingPathComponent("job.log"), atomically: true, encoding: .utf8)
        try? Data([0, 1, 2, 0, 5]).write(to: dir.appendingPathComponent("job.chk"))
        let jf = await call("job.files", ["directory": .string(dir.path)])
        let roles = Dictionary((jf["result"]?["files"]?.arrayValue ?? []).compactMap { f -> (String, String)? in
            guard let n = f["name"]?.stringValue, let r = f["role"]?.stringValue else { return nil }
            return (n, r)
        }, uniquingKeysWith: { a, _ in a })
        check("job.files roles", roles["job.gjf"] == "input" && roles["job.log"] == "output" && roles["job.chk"] == "binary", "\(roles) \(err(jf))")
        let rf = await call("job.readFile", ["directory": .string(dir.path), "name": "job.gjf"])
        check("job.readFile input", rf["result"]?["text"]?.stringValue?.contains("# HF/STO-3G") == true && rf["result"]?["truncated"]?.boolValue == false, err(rf))
        let tail = await call("job.readFile", ["directory": .string(dir.path), "name": "job.log", "maxBytes": 2000])
        let tt = tail["result"]?["text"]?.stringValue ?? ""
        check("job.readFile tail of a large file", tail["result"]?["truncated"]?.boolValue == true && tt.utf8.count <= 2000 && tt.hasPrefix(" SCF Done"),
              "\(tt.utf8.count) bytes \(err(tail))")
        let bin = await call("job.readFile", ["directory": .string(dir.path), "name": "job.chk"])
        check("job.readFile refuses binary", bin["error"]?["code"]?.stringValue == "bad_request", err(bin))
        let esc = await call("job.readFile", ["directory": .string(dir.path), "name": "..\\secret.txt"])
        check("job.readFile refuses paths", esc["error"]?["code"]?.stringValue == "bad_request", err(esc))
        let none = await call("job.files", ["jobId": "j999999"])
        check("job.files unknown job", none["error"]?["code"]?.stringValue == "not_found", err(none))
    }
}
