import Foundation

/// `--selftest`: drives the real request path (JSON text in → engine → JSON text out) in process.
enum SelfTest {
    static let waterXYZ = """
    3
    water
    O    0.000000    0.000000    0.117300
    H    0.000000    0.757200   -0.469200
    H    0.000000   -0.757200   -0.469200
    """

    /// Water geometry plus three harmonic modes (Molden [FREQ] sections) for the spectrum round trip.
    static let waterModesMolden = """
    [Molden Format]
    [Atoms] Angs
    O     1    8     0.000000     0.000000     0.117300
    H     2    1     0.000000     0.757200    -0.469200
    H     3    1     0.000000    -0.757200    -0.469200
    [FREQ]
    1648.5
    3832.2
    3942.5
    [FR-COORD]
    O     0.000000     0.000000     0.221665
    H     0.000000     1.430901    -0.886659
    H     0.000000    -1.430901    -0.886659
    [FR-NORM-COORD]
    vibration     1
       0.000000     0.000000    -0.068700
       0.000000    -0.428900     0.545200
       0.000000     0.428900     0.545200
    vibration     2
       0.000000     0.000000     0.047400
       0.000000     0.585600    -0.376000
       0.000000    -0.585600    -0.376000
    vibration     3
       0.000000     0.068800     0.000000
       0.000000    -0.546000     0.429600
       0.000000    -0.546000    -0.429600
    [INT]
    71.2
    5.1
    44.9
    """

    /// H2 / STO-3G (restricted): basis + two MOs, for an orbital-surface round trip.
    static let h2Molden = """
    [Molden Format]
    [Atoms] AU
    H     1    1     0.0000000000     0.0000000000    -0.6991986157
    H     2    1     0.0000000000     0.0000000000     0.6991986157
    [GTO]
      1 0
     s    3 1.00
          3.42525091             0.15432897
          0.62391373             0.53532814
          0.16885540             0.44463454

      2 0
     s    3 1.00
          3.42525091             0.15432897
          0.62391373             0.53532814
          0.16885540             0.44463454

    [MO]
     Sym=  1a
     Ene= -0.5782
     Spin= Alpha
     Occup= 2.000000
       1   0.548934
       2   0.548934
     Sym=  2a
     Ene= 0.6703
     Spin= Alpha
     Occup= 0.000000
       1   1.211463
       2  -1.211463
    """

    final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func add(_ s: String) { lock.lock(); lines.append(s); lock.unlock() }
        func all() -> [String] { lock.lock(); defer { lock.unlock() }; return lines }
    }

    static func run(dataDirectory: String?) async -> Bool {
        let collector = Collector()
        let writer = OutputWriter()
        writer.setSink { collector.add($0) }
        let engine = Engine(out: writer)
        var nextId = 1
        var passed = 0, failed = 0

        func call(_ method: String, _ params: JSON = [:]) async -> JSON {
            let id = nextId; nextId += 1
            let req: JSON = ["id": .number(Double(id)), "method": .string(method), "params": params]
            engine.handleLine(req.serialized())
            await engine.tracker.waitAll()
            for l in collector.all().reversed() {
                if let j = try? JSON.parse(l), j["id"]?.intValue == id { return j }
            }
            return ["error": ["code": "internal", "message": "no response"]]
        }
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if ok { passed += 1; print("PASS \(name)\(detail.isEmpty ? "" : "  (\(detail))")") }
            else { failed += 1; print("FAIL \(name)\(detail.isEmpty ? "" : "  (\(detail))")") }
        }
        func err(_ r: JSON) -> String { r["error"].map { $0.serialized() } ?? "" }

        // JSON codec
        let tricky = "Å µ “quotes” \\ / \n\t 😀"
        let rt = (try? JSON.parse(JSON.string(tricky).serialized()))?.stringValue
        check("json.roundtrip", rt == tricky)

        let info = await call("engine.info")
        check("engine.info", info["result"]?["protocol"]?.intValue == protocolVersion, info["result"]?["platform"]?.stringValue ?? err(info))

        // water from text
        let open = await call("doc.openText", ["text": .string(waterXYZ), "format": "xyz", "fileName": "water.xyz"])
        let docId = open["result"]?["docId"]?.stringValue ?? ""
        check("doc.openText", open["result"]?["atomCount"]?.intValue == 3 && open["result"]?["formula"]?.stringValue == "H2O",
              open["result"]?["formula"]?.stringValue ?? err(open))

        let mol = await call("doc.molecule", ["docId": .string(docId)])
        check("doc.molecule", mol["result"]?["atoms"]?.arrayValue?.count == 3 && mol["result"]?["bonds"]?.arrayValue?.count == 2,
              "bonds: \(mol["result"]?["bonds"]?.arrayValue?.count ?? -1)")

        let dist = await call("analysis.measure", ["docId": .string(docId), "atoms": [0, 1]])
        let dv = dist["result"]?["value"]?.doubleValue ?? 0
        check("analysis.measure distance", abs(dv - 0.9572) < 0.01, String(format: "%.4f Å", dv))
        let ang = await call("analysis.measure", ["docId": .string(docId), "atoms": [1, 0, 2]])
        let av = ang["result"]?["value"]?.doubleValue ?? 0
        check("analysis.measure angle", abs(av - 104.5) < 1, String(format: "%.2f°", av))

        let sym = await call("analysis.symmetry", ["docId": .string(docId)])
        check("analysis.symmetry", sym["result"]?["pointGroup"]?.stringValue == "C2v", sym["result"]?["pointGroup"]?.stringValue ?? err(sym))

        let edit = await call("edit.apply", ["docId": .string(docId), "op": ["type": "setDistance", "atoms": [0, 1], "value": 1.1]])
        let d2 = await call("analysis.measure", ["docId": .string(docId), "atoms": [0, 1]])
        check("edit.apply setDistance", abs((d2["result"]?["value"]?.doubleValue ?? 0) - 1.1) < 1e-6
              && edit["result"]?["summary"]?["canUndo"]?.boolValue == true, err(edit))
        _ = await call("doc.undo", ["docId": .string(docId)])
        let d3 = await call("analysis.measure", ["docId": .string(docId), "atoms": [0, 1]])
        check("doc.undo", abs((d3["result"]?["value"]?.doubleValue ?? 0) - dv) < 1e-6)

        let cmd = await call("command.execute", ["docId": .string(docId), "line": "measure distance 1 2; style stick; select O"])
        let cr = cmd["result"]?["results"]?.arrayValue ?? []
        check("command.execute", cr.count == 3 && cr.allSatisfy { $0["success"]?.boolValue == true }
              && cmd["result"]?["view"]?["style"]?.stringValue == "stick",
              cr.first?["messages"]?.arrayValue?.first?["text"]?.stringValue ?? err(cmd))
        let comp = await call("command.complete", ["docId": .string(docId), "line": "sty", "cursor": 3])
        check("command.complete", comp["result"]?["completions"]?.arrayValue?.contains(.string("style")) == true
              && comp["result"]?["replaceFrom"]?.intValue == 0)

        let frags = await call("build.fragments")
        check("build.fragments", (frags["result"]?["fragments"]?.arrayValue?.count ?? 0) > 5)
        let place = await call("edit.apply", ["docId": .string(docId), "op": ["type": "addAtom", "z": 6, "pos": [4, 0, 0]]])
        check("edit.apply addAtom", place["result"]?["summary"]?["formula"]?.stringValue == "CH6O", place["result"]?["summary"]?["formula"]?.stringValue ?? err(place))

        // modes + spectrum
        let mopen = await call("doc.openText", ["text": .string(waterModesMolden), "fileName": "water_modes.molden"])
        let mId = mopen["result"]?["docId"]?.stringValue ?? ""
        check("doc.openText molden", mopen["result"]?["modeCount"]?.intValue == 3, err(mopen))
        let modes = await call("analysis.modes", ["docId": .string(mId)])
        check("analysis.modes", modes["result"]?["modes"]?.arrayValue?.count == 3,
              modes["result"]?["modes"]?.arrayValue?.compactMap { $0["label"]?.stringValue }.joined(separator: ", ") ?? err(modes))
        let spec = await call("analysis.spectrum", ["docId": .string(mId), "kind": "ir", "fwhm": 20])
        let ys = spec["result"]?["yB64"]?.stringValue.flatMap(Binary.decodeFloat32) ?? []
        check("analysis.spectrum ir", ys.count == 2000 && (ys.max() ?? 0) > 50 && spec["result"]?["sticks"]?.arrayValue?.count == 3,
              "\(ys.count) points, max \(ys.max() ?? 0)")
        // line shapes + %T: every shape answers, Voigt reports its own FWHM, sticks-only has no curve, %T stays in 0…100
        for shape in ["gaussian", "lorentzian", "voigt", "pseudoVoigt"] {
            let r = await call("analysis.spectrum", ["docId": .string(mId), "kind": "ir", "shape": .string(shape), "fwhm": 20,
                                                     "gaussianFWHM": 12, "lorentzianFWHM": 10, "eta": 0.3])
            let y = r["result"]?["yB64"]?.stringValue.flatMap(Binary.decodeFloat32) ?? []
            let want = shape == "voigt" ? 0.5346 * 10 + (0.2166 * 100 + 144.0).squareRoot() : 20   // Olivero–Longbothum
            check("analysis.spectrum shape \(shape)", y.count == 2000 && r["result"]?["shape"]?.stringValue == shape
                  && abs((r["result"]?["fwhm"]?.doubleValue ?? 0) - want) < 1e-9, err(r))
        }
        let sticksOnly = await call("analysis.spectrum", ["docId": .string(mId), "kind": "ir", "shape": "sticks"])
        check("analysis.spectrum sticks only", sticksOnly["result"]?["pointCount"]?.intValue == 0
              && sticksOnly["result"]?["sticks"]?.arrayValue?.count == 3, err(sticksOnly))
        let pt = await call("analysis.spectrum", ["docId": .string(mId), "kind": "ir", "fwhm": 20, "transmittance": true])
        let ty = pt["result"]?["yB64"]?.stringValue.flatMap(Binary.decodeFloat32) ?? []
        check("analysis.spectrum transmittance", ty.count == 2000 && (ty.min() ?? 0) > 14.9 && (ty.min() ?? 0) < 16
              && (ty.max() ?? 0) <= 100 && pt["result"]?["transmittance"]?.boolValue == true
              && pt["result"]?["yLabel"]?.stringValue == "Transmittance (%)", "min \(ty.min() ?? 0); \(err(pt))")
        let badShape = await call("analysis.spectrum", ["docId": .string(mId), "kind": "ir", "shape": "triangle"])
        check("analysis.spectrum bad shape", badShape["error"] != nil)

        // orbital surface
        let h2 = await call("doc.openText", ["text": .string(h2Molden), "fileName": "h2.molden"])
        let hId = h2["result"]?["docId"]?.stringValue ?? ""
        check("doc.openText wavefunction", h2["result"]?["hasWavefunction"]?.boolValue == true, err(h2))
        let lv = await call("analysis.orbitals", ["docId": .string(hId)])
        check("analysis.orbitals", lv["result"]?["columns"]?.arrayValue?.first?["levels"]?.arrayValue?.count == 2, err(lv))
        let surf = await call("analysis.orbitalSurface", ["docId": .string(hId), "orbital": 0, "isovalue": 0.05, "quality": "draft"])
        let meshes = surf["result"]?["meshes"]?.arrayValue ?? []
        let tri = meshes.first?["triangleCount"]?.intValue ?? 0
        check("analysis.orbitalSurface", meshes.count == 2 && tri > 50 && surf["result"]?["isHOMO"]?.boolValue == true,
              "+lobe \(tri) triangles, \(meshes.first?["vertexCount"]?.intValue ?? 0) vertices; \(err(surf))")

        await runFeatures(call: call, check: check, err: err, waterXYZ: waterXYZ)
        await runProtein(call: call, check: check, err: err)
        await runMisc(call: call, check: check, err: err, waterXYZ: waterXYZ)     // SelfTest+Misc.swift
        await runJobs(call: call, check: check, err: err, waterXYZ: waterXYZ)     // SelfTest+Jobs.swift

        // errors
        let bad = await call("doc.molecule", ["docId": "nope"])
        check("error not_found", bad["error"]?["code"]?.stringValue == "not_found")
        let unk = await call("no.such.method")
        check("error bad_request", unk["error"]?["code"]?.stringValue == "bad_request")

        // optional: real sample files
        if let dir = dataDirectory {
            let base = URL(fileURLWithPath: dir)
            let orca = base.appendingPathComponent("io/orca/water_optfreq.out").path
            if FileManager.default.fileExists(atPath: orca) {
                let o = await call("doc.open", ["path": .string(orca)])
                let oid = o["result"]?["docId"]?.stringValue ?? ""
                check("data: ORCA opt+freq", (o["result"]?["modeCount"]?.intValue ?? 0) >= 3, err(o))
                let th = await call("analysis.thermo", ["docId": .string(oid)])
                check("data: thermo", (th["result"]?["rows"]?.arrayValue?.count ?? 0) >= 9, err(th))
            }
            let mold = base.appendingPathComponent("analysis/water_sto3g.molden").path
            if FileManager.default.fileExists(atPath: mold) {
                let o = await call("doc.open", ["path": .string(mold)])
                let oid = o["result"]?["docId"]?.stringValue ?? ""
                let s = await call("analysis.orbitalSurface", ["docId": .string(oid), "orbital": 4, "quality": "draft"])
                check("data: water HOMO surface", (s["result"]?["meshes"]?.arrayValue?.first?["triangleCount"]?.intValue ?? 0) > 100, err(s))
            }
        }

        print("selftest: \(passed) passed, \(failed) failed")
        return failed == 0
    }
}
