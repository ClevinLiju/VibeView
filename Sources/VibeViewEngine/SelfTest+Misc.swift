import Foundation

// `--selftest` checks for the macOS ports of round 6 (agent "misc"): console exports (Methods+ConsoleExport.swift),
// bond orders on calculation-output / trajectory frames (Documents.swift), Z-matrix text through MolIO ZMatrixText.

extension SelfTest {
    /// Benzene in the xy plane, frame `k` slightly breathing (same connectivity in every frame).
    static func benzeneTrajectoryXYZ(frames: Int) -> String {
        var out = ""
        for k in 0..<frames {
            let s = 1.0 + 0.01 * Double(k)
            out += "12\nbenzene frame \(k + 1)\n"
            for i in 0..<6 {
                let t = Double(i) * .pi / 3
                out += String(format: "C %.5f %.5f 0.0\n", 1.39 * s * cos(t), 1.39 * s * sin(t))
            }
            for i in 0..<6 {
                let t = Double(i) * .pi / 3
                out += String(format: "H %.5f %.5f 0.0\n", 2.47 * s * cos(t), 2.47 * s * sin(t))
            }
        }
        return out
    }

    static func runMisc(call: Call, check: Report, err: (JSON) -> String, waterXYZ: String) async {
        // Bond orders survive on frames: a 3-frame benzene XYZ trajectory.
        let bz = await call("doc.openText", ["text": .string(benzeneTrajectoryXYZ(frames: 3)), "fileName": "benzene-traj.xyz"])
        let bId = bz["result"]?["docId"]?.stringValue ?? ""
        check("frames: opened trajectory", bz["result"]?["frameCount"]?.intValue == 3, err(bz))
        for k in [0, 1] {
            let f = await call("doc.molecule", ["docId": .string(bId), "frame": .number(Double(k))])
            let orders = (f["result"]?["bonds"]?.arrayValue ?? []).compactMap { $0["order"]?.doubleValue }
            let nonSingle = orders.filter { $0 != 1 }.count
            check("frames: frame \(k) keeps bond orders", orders.count == 12 && nonSingle >= 6, "orders \(orders); \(err(f))")
        }

        // Console exports.
        let w = await call("doc.openText", ["text": .string(waterXYZ), "fileName": "water.xyz"])
        let wId = w["result"]?["docId"]?.stringValue ?? ""
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vibeview-selftest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func line(_ s: String, _ doc: String = wId) async -> JSON {
            await call("command.execute", ["docId": .string(doc), "line": .string(s)])
        }
        func ok(_ r: JSON) -> Bool { r["result"]?["results"]?.arrayValue?.first?["success"]?.boolValue == true }
        func text(_ r: JSON) -> String {
            (r["result"]?["results"]?.arrayValue ?? []).flatMap { $0["messages"]?.arrayValue ?? [] }.compactMap { $0["text"]?.stringValue }
                .joined(separator: " | ") + err(r)
        }
        let sdf = dir.appendingPathComponent("w.sdf")
        let rs = await line("export structure \"\(sdf.path)\"")
        let sdfText = (try? String(contentsOf: sdf, encoding: .utf8)) ?? ""
        check("console export structure", ok(rs) && sdfText.contains("V2000") && sdfText.contains("$$$$"), text(rs))
        let traj = dir.appendingPathComponent("bz.xyz")
        let rt = await line("export structure \"\(traj.path)\" all", bId)
        let trajText = (try? String(contentsOf: traj, encoding: .utf8)) ?? ""
        check("console export structure all frames", ok(rt) && trajText.components(separatedBy: "benzene").count >= 4, text(rt))

        let png = dir.appendingPathComponent("w.png")
        let ri = await line("export image \"\(png.path)\" 640 480 dpi 600 transparent")
        let req = ri["result"]?["view"]?["exportImage"]
        let token = req?["token"]?.stringValue ?? ""
        check("console export image request", ok(ri) && req?["kind"]?.stringValue == "image" && req?["format"]?.stringValue == "png"
              && req?["dpi"]?.doubleValue == 600 && req?["width"]?.intValue == 640 && req?["transparent"]?.boolValue == true && !token.isEmpty,
              text(ri))
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let wr = await call("command.writeExport", ["token": .string(token), "base64": .string(bytes.base64EncodedString())])
        check("command.writeExport", wr["result"]?["bytes"]?.intValue == 8 && (try? Data(contentsOf: png)) == bytes, err(wr))
        let again = await call("command.writeExport", ["token": .string(token), "text": "x"])
        check("command.writeExport token is single-use", again["error"]?["code"]?.stringValue == "not_found", err(again))
        let tif = await line("export image \"\(dir.appendingPathComponent("w.tif").path)\" width 800")
        check("console export tiff", ok(tif) && tif["result"]?["view"]?["exportImage"]?["format"]?.stringValue == "tiff", text(tif))
        let heic = await line("export image \"\(dir.appendingPathComponent("w.heic").path)\"")
        check("console export heic refused", !ok(heic) && text(heic).contains("HEIC"), text(heic))
        let jpgT = await line("export image \"\(dir.appendingPathComponent("w.jpg").path)\" transparent")
        check("console export transparent jpeg refused", !ok(jpgT), text(jpgT))
        let gif = await line("export gif \"\(dir.appendingPathComponent("s.gif").path)\" spin fps 12 duration 2")
        let greq = gif["result"]?["view"]?["exportImage"]
        check("console export gif spin", ok(gif) && greq?["kind"]?.stringValue == "animation" && greq?["framesPerLoop"]?.intValue == 24
              && greq?["source"]?["type"]?.stringValue == "spin", text(gif))
        let vib = await line("export gif \"\(dir.appendingPathComponent("v.gif").path)\" vibration 1")
        check("console export gif without modes refused", !ok(vib) && text(vib).contains("vibrational"), text(vib))
        let mov = await line("export mov \"\(dir.appendingPathComponent("s.mov").path)\" spin")
        check("console export mov refused", !ok(mov) && text(mov).contains("MOV"), text(mov))
        let csv = await line("export csv \"\(dir.appendingPathComponent("f.csv").path)\" frequencies")
        check("console export csv without modes refused", !ok(csv), text(csv))
        let csvE = await line("export csv \"\(dir.appendingPathComponent("e.csv").path)\" energies", bId)
        check("console export csv energies (trajectory)", ok(csvE) && csvE["result"]?["view"]?["exportImage"]?["table"]?.stringValue == "energies", text(csvE))
        let noDir = await line("export image \"\(dir.appendingPathComponent("missing/x.png").path)\"")
        check("console export into a missing folder refused", !ok(noDir), text(noDir))

        // Z-matrix text through MolIO ZMatrixText (variables and source still reported).
        let zp = await call("zmatrix.parse", ["text": "O\nH 1 r\nH 1 r 2 a\n\nr = 0.97\na = 104.0\n"])
        check("zmatrix.parse shared", zp["result"]?["atomCount"]?.intValue == 3 && zp["result"]?["variables"]?["r"]?.doubleValue == 0.97
              && zp["result"]?["source"]?.stringValue == "gaussian" && zp["result"]?["rowCount"]?.intValue == 3, err(zp))
    }
}
