import Foundation

// `--selftest` checks for the round-3 methods: element groups, Z-matrix, export, secondary structure and the
// extended calculation catalog (calc.preview per program).

extension SelfTest {
    typealias Call = (String, JSON) async -> JSON
    typealias Report = (String, Bool, String) -> Void

    /// Ideal backbone (N, H, CA, C, O per residue) from φ/ψ by NeRF, as PDB ATOM records (glycine, no side chains).
    static func backbonePDB(residues: Int, phi: Double, psi: Double, chain: String = "A") -> String {
        typealias V = (Double, Double, Double)
        func sub(_ a: V, _ b: V) -> V { (a.0 - b.0, a.1 - b.1, a.2 - b.2) }
        func cross(_ a: V, _ b: V) -> V { (a.1 * b.2 - a.2 * b.1, a.2 * b.0 - a.0 * b.2, a.0 * b.1 - a.1 * b.0) }
        func unit(_ a: V) -> V { let l = (a.0 * a.0 + a.1 * a.1 + a.2 * a.2).squareRoot(); return (a.0 / l, a.1 / l, a.2 / l) }
        /// D with |CD| = r, angle BCD = theta, dihedral ABCD = tau (degrees).
        func place(_ a: V, _ b: V, _ c: V, _ r: Double, _ theta: Double, _ tau: Double) -> V {
            let t = theta * .pi / 180, p = tau * .pi / 180
            let d2 = (-r * cos(t), r * sin(t) * cos(p), r * sin(t) * sin(p))
            let bc = unit(sub(c, b)), n = unit(cross(sub(b, a), bc)), m = cross(n, bc)
            return (c.0 + bc.0 * d2.0 + m.0 * d2.1 + n.0 * d2.2, c.1 + bc.1 * d2.0 + m.1 * d2.1 + n.1 * d2.2,
                    c.2 + bc.2 * d2.0 + m.2 * d2.1 + n.2 * d2.2)
        }
        var N: [V] = [(0, 0, 0)], CA: [V] = [(1.458, 0, 0)]
        var C: [V] = [place((0, 1, 0), N[0], CA[0], 1.525, 111.2, -60)]
        var H: [V?] = [nil]
        for i in 1..<max(residues, 1) {
            N.append(place(N[i - 1], CA[i - 1], C[i - 1], 1.329, 116.2, psi))
            CA.append(place(CA[i - 1], C[i - 1], N[i], 1.458, 121.7, 180))
            C.append(place(C[i - 1], N[i], CA[i], 1.525, 111.2, phi))
            H.append(place(CA[i - 1], C[i - 1], N[i], 1.01, 119.5, 0))
        }
        var lines: [String] = []
        var serial = 1
        func atom(_ name: String, _ el: String, _ k: Int, _ p: V) {
            let nm = name.count < 4 ? " " + name.padding(toLength: 3, withPad: " ", startingAt: 0) : name
            let el2 = el.count < 2 ? " " + el : el
            lines.append(String(format: "ATOM  %5d ", serial) + nm + " GLY " + chain + String(format: "%4d    %8.3f%8.3f%8.3f  1.00  0.00          ",
                                k + 1, p.0, p.1, p.2) + el2)
            serial += 1
        }
        for i in 0..<N.count {
            let o = i + 1 < N.count ? place(N[i + 1], CA[i], C[i], 1.231, 120.5, 180) : place(N[i], CA[i], C[i], 1.231, 120.5, psi + 180)
            atom("N", "N", i, N[i])
            atom("CA", "C", i, CA[i])
            atom("C", "C", i, C[i])
            atom("O", "O", i, o)
            if let h = H[i] { atom("H", "H", i, h) }
        }
        return lines.joined(separator: "\n") + "\nEND\n"
    }

    static func runFeatures(call call0: Call, check check0: Report, err: (JSON) -> String, waterXYZ: String) async {
        func call(_ m: String, _ p: JSON = [:]) async -> JSON { await call0(m, p) }
        func check(_ n: String, _ ok: Bool, _ detail: String = "") { check0(n, ok, detail) }
        func newWater() async -> String {
            let o = await call("doc.openText", ["text": .string(waterXYZ), "format": "xyz", "fileName": "water.xyz"])
            return o["result"]?["docId"]?.stringValue ?? ""
        }
        func formula(_ r: JSON) -> String { r["result"]?["summary"]?["formula"]?.stringValue ?? err(r) }

        // MARK: element groups
        let g = await call("build.groups", ["element": 6])
        let gs = g["result"]?["groups"]?.arrayValue ?? []
        let ids = gs.compactMap { $0["id"]?.stringValue }
        check("build.groups carbon", ["C.sp3", "C.sp2", "C.sp", "C.methyl", "C.phenyl", "C.methylidene"].allSatisfy(ids.contains)
              && gs.allSatisfy { $0["element"]?.intValue == 6 }, ids.joined(separator: " "))
        let sp2 = gs.first { $0["id"]?.stringValue == "C.sp2" }
        check("build.groups fields", sp2?["kind"]?.stringValue == "atom" && sp2?["hybridization"]?.stringValue == "sp2"
              && sp2?["molecule"]?["atoms"]?.arrayValue != nil && sp2?["anchor"]?.intValue != nil, sp2?.serialized() ?? "")
        let all = await call("build.groups")
        check("build.groups all", (all["result"]?["groups"]?.arrayValue?.count ?? 0) > gs.count)
        let w1 = await newWater()
        let pg = await call("edit.apply", ["docId": .string(w1), "op": ["type": "placeGroup", "groupId": "C.methyl", "at": 1]])
        check("placeGroup methyl on H (methanol)", formula(pg) == "CH4O", formula(pg))
        check("placeGroup undo label", pg["result"]?["summary"]?["undoName"]?.stringValue == "Place Methyl"
              || (pg["result"]?["summary"]?["undoName"]?.stringValue ?? "").hasPrefix("Place "), pg["result"]?["summary"]?["undoName"]?.stringValue ?? "")
        let pe = await call("edit.apply", ["docId": .string(w1), "op": ["type": "placeGroup", "groupId": "C.sp3", "pos": [6, 0, 0]]])
        check("placeGroup C sp3 in empty space", formula(pe) == "C2H8O", formula(pe))
        let pu = await call("edit.apply", ["docId": .string(w1), "op": ["type": "placeGroup", "groupId": "C.nope", "pos": [0, 0, 0]]])
        check("placeGroup unknown -> not_found", pu["error"]?["code"]?.stringValue == "not_found", err(pu))

        // MARK: Z-matrix
        let w2 = await newWater()
        let zg = await call("zmatrix.get", ["docId": .string(w2)])
        let rows = zg["result"]?["rows"]?.arrayValue ?? []
        check("zmatrix.get water", rows.count == 3 && rows[1]["bond"]?.doubleValue.map { abs($0 - 0.9572) < 0.01 } == true
              && rows[2]["angle"]?.doubleValue.map { abs($0 - 104.5) < 1 } == true
              && (zg["result"]?["gaussian"]?.stringValue ?? "").split(separator: "\n").count == 3
              && (zg["result"]?["orca"]?.stringValue ?? "").hasPrefix("* int 0 1"), err(zg))
        let order = zg["result"]?["order"] ?? .null
        let r1atom = rows.count > 1 ? rows[1]["atom"]?.intValue ?? 1 : 1
        let r1ref = rows.count > 1 ? rows[1]["bondAtom"]?.intValue ?? 0 : 0
        let ze = await call("zmatrix.edit", ["docId": .string(w2), "order": order, "row": 1, "field": "bond", "value": 1.2])
        let md = await call("analysis.measure", ["docId": .string(w2), "atoms": .array([.number(Double(r1atom)), .number(Double(r1ref))])])
        check("zmatrix.edit bond", abs((md["result"]?["value"]?.doubleValue ?? 0) - 1.2) < 1e-6
              && ze["result"]?["zmatrix"]?["rows"]?.arrayValue?.count == 3, err(ze))
        let zbad = await call("zmatrix.edit", ["docId": .string(w2), "row": 1, "field": "angle", "value": 100])
        check("zmatrix.edit row without angle -> bad_request", zbad["error"]?["code"]?.stringValue == "bad_request", err(zbad))
        let text = "0 1\nO\nH 1 0.96\nH 1 0.96 2 104.5\n"
        let zp = await call("zmatrix.parse", ["text": .string(text)])
        check("zmatrix.parse", zp["result"]?["atomCount"]?.intValue == 3 && zp["result"]?["molecule"]?["bonds"]?.arrayValue?.count == 2, err(zp))
        let vtext = "C\nH 1 r\nH 1 r 2 a\nH 1 r 2 a 3 d\nH 1 r 2 a 3 -d\n\nr 1.09\na 109.4712\nd 120\n"
        let zv = await call("zmatrix.parse", ["text": .string(vtext)])
        check("zmatrix.parse variables (methane)", zv["result"]?["atomCount"]?.intValue == 4 + 1
              && zv["result"]?["variables"]?["r"]?.doubleValue == 1.09, err(zv))
        let za = await call("zmatrix.apply", ["text": .string(vtext), "title": "methane"])
        let zaId = za["result"]?["docId"]?.stringValue ?? ""
        check("zmatrix.apply new document", za["result"]?["mode"]?.stringValue == "new" && formula(za) == "CH4", err(za))
        let orcaText = "* int 0 1\nO 0 0 0 0 0 0\nH 1 0 0 0.97 0 0\nH 1 2 0 0.97 104 0\n*\n"
        let zr = await call("zmatrix.apply", ["docId": .string(w2), "text": .string(orcaText)])
        check("zmatrix.apply ORCA * int onto document", formula(zr) == "H2O"
              && ["replace", "positions"].contains(zr["result"]?["mode"]?.stringValue ?? ""), err(zr))
        let zd = await call("zmatrix.addAtom", ["docId": .string(zaId), "z": 9, "bondAtom": 0, "dryRun": true])
        check("zmatrix.addAtom dryRun", zd["result"]?["position"]?.arrayValue?.count == 3 && zd["result"]?["summary"] == nil
              && zd["result"]?["defaults"]?["bond"]?.doubleValue.map { $0 > 1.0 && $0 < 1.6 } == true, err(zd))
        let zadd = await call("zmatrix.addAtom", ["docId": .string(zaId), "z": 9, "bondAtom": 0, "bond": 1.35, "angleAtom": 1, "angle": 109.47])
        check("zmatrix.addAtom commit", formula(zadd) == "CH4F" && zadd["result"]?["atom"]?.intValue == 5, err(zadd))

        // MARK: export
        let w3 = await newWater()
        let ef = await call("doc.exportFormats", ["docId": .string(w3)])
        let fids = ef["result"]?["formats"]?.arrayValue?.compactMap { $0["id"]?.stringValue } ?? []
        check("doc.exportFormats", ["xyz", "pdb", "sdf", "molden", "cube"].allSatisfy(fids.contains), fids.joined(separator: " "))
        for (fmt, needle) in [("xyz", "water"), ("pdb", "HETATM"), ("sdf", "$$$$"), ("mol", "M  END"), ("molden", "[Atoms]"),
                              ("cml", "<molecule"), ("gaussianInput", "0 1"), ("orcaInput", "* xyz 0 1")] {
            let e = await call("doc.exportAs", ["docId": .string(w3), "format": .string(fmt)])
            let t = e["result"]?["text"]?.stringValue ?? ""
            check("doc.exportAs \(fmt)", t.contains(needle) && e["result"]?["atomCount"]?.intValue == 3, String(t.prefix(80)) + err(e))
        }
        let sub = await call("doc.exportAs", ["docId": .string(w3), "format": "xyz", "atoms": [0, 1]])
        check("doc.exportAs atom subset", (sub["result"]?["text"]?.stringValue ?? "").hasPrefix("2\n"), err(sub))
        let cube = await call("doc.exportAs", ["docId": .string(w3), "format": "cube"])
        check("doc.exportAs cube without volumes -> not_found", cube["error"]?["code"]?.stringValue == "not_found", err(cube))
        let traj = "3\nf1\nO 0 0 0.1173\nH 0 0.7572 -0.4692\nH 0 -0.7572 -0.4692\n3\nf2\nO 0 0 0.12\nH 0 0.76 -0.47\nH 0 -0.76 -0.47\n"
            + "3\nf3\nO 0 0 0.13\nH 0 0.77 -0.48\nH 0 -0.77 -0.48\n"
        let tj = await call("doc.openText", ["text": .string(traj), "format": "xyz", "fileName": "traj.xyz"])
        let tId = tj["result"]?["docId"]?.stringValue ?? ""
        let ea = await call("doc.exportAs", ["docId": .string(tId), "format": "xyz", "frames": "all"])
        check("doc.exportAs all frames (trajectory)", ea["result"]?["frameCount"]?.intValue == 3
              && (ea["result"]?["text"]?.stringValue ?? "").components(separatedBy: "\n3\n").count == 3, err(ea))
        let el = await call("doc.exportAs", ["docId": .string(tId), "format": "sdf", "frames": [0, 2]])
        check("doc.exportAs frame list sdf", el["result"]?["frameCount"]?.intValue == 2
              && (el["result"]?["text"]?.stringValue ?? "").components(separatedBy: "$$$$").count == 3, err(el))
        let eb = await call("doc.exportAs", ["docId": .string(tId), "format": "xyz", "frames": [7]])
        check("doc.exportAs bad frame -> bad_request", eb["error"]?["code"]?.stringValue == "bad_request", err(eb))
        // Trajectory player: every frame's coordinates in one reply, topology flags, comment energies.
        let fc = await call("doc.frameCoordinates", ["docId": .string(tId)])
        let fcXYZ = Binary.decodeFloat32(fc["result"]?["positionsB64"]?.stringValue ?? "") ?? []
        check("doc.frameCoordinates", fc["result"]?["count"]?.intValue == 3 && fcXYZ.count == 27
              && abs(fcXYZ[9 + 2] - 0.12) < 1e-6 && abs(fcXYZ[18 + 4] - 0.77) < 1e-6
              && fc["result"]?["sameTopology"] == [false, true, true]
              && fc["result"]?["atomCounts"] == [3, 3, 3], err(fc))
        let trajE = traj.replacingOccurrences(of: "f1", with: "energy: -5.07 gnorm: 0.04").replacingOccurrences(of: "f2", with: "E=-5.08")
        let tjE = await call("doc.openText", ["text": .string(trajE), "format": "xyz", "fileName": "trajE.xyz"])
        let tEId = tjE["result"]?["docId"]?.stringValue ?? ""
        let fr = await call("doc.frames", ["docId": .string(tEId)])
        check("doc.frames comment energies", fr["result"]?["frameEnergies"] == [-5.07, -5.08, nil]
              && fr["result"]?["steps"]?.arrayValue?.first?["gradientNorm"]?.doubleValue == 0.04 && fr["result"]?["kind"]?.stringValue == "optimization"
              && fr["result"]?["home"]?.intValue == 2, err(fr))
        let ex = await call("doc.exportAs", ["docId": .string(tId), "format": "nope"])
        check("doc.exportAs unknown format -> bad_request", ex["error"]?["code"]?.stringValue == "bad_request", err(ex))

        // MARK: secondary structure
        let helix = await call("doc.openText", ["text": .string(backbonePDB(residues: 16, phi: -57, psi: -47)), "format": "pdb",
                                                "fileName": "helix.pdb"])
        let hId = helix["result"]?["docId"]?.stringValue ?? ""
        let ss = await call("analysis.secondaryStructure", ["docId": .string(hId)])
        let s1 = ss["result"]?["ss"]?.stringValue ?? ""
        check("analysis.secondaryStructure helix", ss["result"]?["residueCount"]?.intValue == 16
              && s1.filter { $0 == "H" }.count >= 10 && ss["result"]?["helixCount"]?.intValue == 1
              && ss["result"]?["source"]?.stringValue == "computed" && ss["result"]?["ca"]?.arrayValue?.count == 16
              && ss["result"]?["segments"]?.arrayValue?.count == 1,
              "\(s1) residues \(ss["result"]?["residueCount"]?.intValue ?? -1) \(helix["result"]?["formula"]?.stringValue ?? err(helix)) bonds \(helix["result"]?["bondCount"]?.intValue ?? -1) \(err(ss))")
        let strand = await call("doc.openText", ["text": .string(backbonePDB(residues: 8, phi: -120, psi: 130)), "format": "pdb",
                                                 "fileName": "strand.pdb"])
        let sId = strand["result"]?["docId"]?.stringValue ?? ""
        let ss2 = await call("analysis.secondaryStructure", ["docId": .string(sId)])
        let s2 = ss2["result"]?["ss"]?.stringValue ?? ""
        check("analysis.secondaryStructure single extended chain has no helix", s2.count == 8 && !s2.contains("H")
              && ss2["result"]?["helixCount"]?.intValue == 0, s2 + " " + err(ss2))
        // HELIX/SHEET records of an opened file win over DSSP (source auto), and source "computed" ignores them.
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("vibeview-selftest-\(ProcessInfo.processInfo.processIdentifier).pdb")
        let rec = "HELIX    1   1 GLY A    3  GLY A    6  1                                   4\n"
            + "SHEET    1   A 2 GLY A  10  GLY A  12  0\n"
        try? (rec + backbonePDB(residues: 16, phi: -57, psi: -47)).write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let fo = await call("doc.open", ["path": .string(tmp.path)])
        let foId = fo["result"]?["docId"]?.stringValue ?? ""
        let sf = await call("analysis.secondaryStructure", ["docId": .string(foId)])
        check("analysis.secondaryStructure file records", sf["result"]?["ss"]?.stringValue == "LLHHHHLLLEEELLLL"
              && sf["result"]?["source"]?.stringValue == "file" && sf["result"]?["residueSource"]?.stringValue == "file"
              && sf["result"]?["seq"]?.arrayValue?.first?.intValue == 1 && sf["result"]?["chain"]?.arrayValue?.first?.stringValue == "A",
              (sf["result"]?["ss"]?.stringValue ?? "") + err(sf) + err(fo))
        let sc = await call("analysis.secondaryStructure", ["docId": .string(foId), "source": "computed"])
        check("analysis.secondaryStructure source computed", sc["result"]?["source"]?.stringValue == "computed"
              && (sc["result"]?["ss"]?.stringValue ?? "").filter { $0 == "H" }.count >= 10, err(sc))
        let ssw = await call("analysis.secondaryStructure", ["docId": .string(w3)])
        check("analysis.secondaryStructure small molecule", ssw["result"]?["residueCount"]?.intValue == 0
              && ssw["result"]?["source"]?.stringValue == "none", err(ssw))
        let ssb = await call("analysis.secondaryStructure", ["docId": .string(hId), "source": "dssp"])
        check("analysis.secondaryStructure bad source -> bad_request", ssb["error"]?["code"]?.stringValue == "bad_request", err(ssb))

        // MARK: extended calculation catalog (calc.preview)
        // The writer is checked as such: no adaptation to the Gaussian installed here (G09W A.02 drops def2 / GD3BJ).
        ProgramPaths.adaptToInstalledGaussian = false
        defer { ProgramPaths.adaptToInstalledGaussian = true }
        let w4 = await newWater()
        func preview(_ spec: JSON) async -> (String, String) {
            let r = await call("calc.preview", ["docId": .string(w4), "spec": spec])
            let e = r["result"]?["errors"]?.arrayValue?.compactMap(\.stringValue).joined(separator: "; ") ?? err(r)
            return (r["result"]?["input"]?.stringValue ?? "", e)
        }
        // (program, method, basis, dispersion, needles that must appear, needles that must not)
        let cases: [(String, String, String, String?, [String], [String])] = [
            ("gaussian", "PBE1PBE", "Def2TZVP", "d3bj", ["PBE1PBE/Def2TZVP", "EmpiricalDispersion=GD3BJ"], []),
            ("gaussian", "M062X", "6-311++G(d,p)", "d3zero", ["M062X/6-311++G(d,p)", "EmpiricalDispersion=GD3"], []),
            ("gaussian", "wB97XD", "aug-cc-pVTZ", nil, ["wB97XD/aug-cc-pVTZ"], ["Empirical"]),
            ("gaussian", "DSDPBEP86", "cc-pVTZ", nil, ["DSDPBEP86/cc-pVTZ"], []),
            ("gaussian", "PM7", "", nil, ["PM7"], ["PM7/"]),
            ("gaussian", "CBS-QB3", "", nil, ["CBS-QB3"], ["CBS-QB3/"]),
            ("gaussian", "CCSD(T)", "cc-pVDZ", nil, ["CCSD(T)/cc-pVDZ"], []),
            ("gaussian", "LC-wHPBE", "6-31+G(d,p)", nil, ["LC-wHPBE/6-31+G(d,p)"], []),
            ("orca", "r2SCAN-3c", "def2-SVP", nil, ["! r2SCAN-3c"], ["def2-SVP"]),
            ("orca", "wB97M-V", "def2-TZVP", nil, ["wB97M-V def2-TZVP"], ["D3BJ"]),
            ("orca", "PBE0", "def2-TZVPP", "d4", ["PBE0 def2-TZVPP D4"], []),
            ("orca", "B3LYP", "ma-def2-SVP", "d3bj", ["B3LYP ma-def2-SVP D3BJ"], []),
            ("orca", "DLPNO-CCSD(T)", "cc-pVTZ", nil, ["DLPNO-CCSD(T) cc-pVTZ"], []),
            ("orca", "revDSD-PBEP86-D4", "def2-QZVPP", nil, ["revDSD-PBEP86-D4 def2-QZVPP"], []),
            ("orca", "PM3", "", nil, ["! PM3"], []),
            ("qchem", "wB97M-V", "def2-TZVP", nil, ["wb97m-v", "def2-TZVP"], ["DFT_D"]),
            ("qchem", "B3LYP", "6-311++G**", "d4", ["b3lyp", "6-311++G**", "D4"], []),
            ("qchem", "B97-D3(0)", "pcseg-2", nil, ["b97-d3(0)", "pcseg-2"], []),
            ("qchem", "PBE0", "def2-SVP", "d3bj", ["pbe0", "D3_BJ"], []),
            ("qchem", "CCSD(T)", "aug-cc-pVDZ", nil, ["ccsd(t)", "aug-cc-pVDZ"], []),
            ("xtb", "GFN-FF", "", nil, ["O"], []),
            ("xtb", "GFN1-xTB", "", nil, ["O"], []),
        ]
        for (prog, method, basis, disp, must, mustNot) in cases {
            var spec: [String: JSON] = ["program": .string(prog), "task": "optimize", "method": .string(method), "basis": .string(basis)]
            if let d = disp { spec["dispersion"] = .string(d) }
            let (input, e) = await preview(.object(spec))
            let ok = e.isEmpty && !input.isEmpty && must.allSatisfy(input.contains) && !mustNot.contains(where: input.contains)
            check("calc.preview \(prog) \(method)/\(basis.isEmpty ? "-" : basis)\(disp.map { " " + $0 } ?? "")", ok,
                  e.isEmpty ? String(input.split(separator: "\n").prefix(3).joined(separator: " | ")) : e)
        }
        // Open shell: Gaussian composites are not U-prefixed, ORCA wavefunction methods use UHF (not UKS).
        let radical: [String: JSON] = ["charge": 1, "multiplicity": 2, "unrestricted": true, "task": "energy"]
        var cbs = radical; cbs["program"] = "gaussian"; cbs["method"] = "CBS-QB3"; cbs["basis"] = ""
        let (gi, ge) = await preview(.object(cbs))
        check("calc.preview gaussian open-shell composite", ge.isEmpty && gi.contains(" CBS-QB3") && !gi.contains("UCBS"), ge + gi.prefix(60))
        var ub = radical; ub["program"] = "gaussian"; ub["method"] = "B3LYP"; ub["basis"] = "Def2SVP"
        let (ui, ue) = await preview(.object(ub))
        check("calc.preview gaussian unrestricted DFT", ue.isEmpty && ui.contains("UB3LYP/Def2SVP"), ue)
        var mp2 = radical; mp2["program"] = "orca"; mp2["method"] = "RI-MP2"; mp2["basis"] = "def2-TZVP"; mp2["extraKeywords"] = "def2-TZVP/C"
        let (oi, oe) = await preview(.object(mp2))
        check("calc.preview orca open-shell RI-MP2", oe.isEmpty && oi.contains("UHF") && !oi.contains("UKS") && oi.contains("def2-TZVP/C"), oe + oi.prefix(80))
        var uks = radical; uks["program"] = "orca"; uks["method"] = "wB97X-D3BJ"; uks["basis"] = "def2-TZVP"
        let (ki, ke) = await preview(.object(uks))
        check("calc.preview orca open-shell DFT", ke.isEmpty && ki.contains("UKS"), ke)
        var ecp: [String: JSON] = ["program": "qchem", "method": "B3LYP", "basis": "def2-SVP", "extraKeywords": ["ECP def2-ECP"]]
        ecp["task"] = "energy"
        let (qi, qe) = await preview(.object(ecp))
        check("calc.preview qchem extra $rem lines", qe.isEmpty && qi.contains("ECP def2-ECP"), qe)
        #if os(Windows)
        let np = [ProgramPaths.nativePath("C://G09W/g09.exe"), ProgramPaths.nativePath("/C:/G09W//formchk.exe"),
                  ProgramPaths.nativePath("//server/share/g16/g16.exe"), ProgramPaths.nativePath(URL(fileURLWithPath: #"C:\G09W\g09.exe"#))]
        check("program paths are native", np == [#"C:\G09W\g09.exe"#, #"C:\G09W\formchk.exe"#, #"\\server\share\g16\g16.exe"#,
                                                 #"C:\G09W\g09.exe"#], np.joined(separator: " , "))
        #endif
        let progs = await call("calc.programs")
        let shown = progs["result"]?.objectValue?.values.compactMap(\.stringValue) ?? []
        #if os(Windows)
        check("calc.programs paths without forward or doubled slashes", shown.allSatisfy { !$0.contains("/") && !$0.dropFirst(2).contains(#"\\"#) },
              shown.joined(separator: " , "))
        #endif
        let (_, nb) = await preview(["program": "orca", "method": "B3LYP", "basis": ""])
        check("calc.preview missing basis is an error", nb.contains("basis"), nb)
    }
}
