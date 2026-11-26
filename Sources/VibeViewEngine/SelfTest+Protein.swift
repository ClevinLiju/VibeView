import Foundation

// `--selftest` checks for protein display: polymer-residue classification (HETATM-flagged modified residues, lone
// ligands with backbone-like atom names, waters), alternate locations, biological assemblies and NMR models.

extension SelfTest {
    /// Moves the x coordinate of ATOM/HETATM lines by `dx` (columns 31-38).
    static func shiftPDB(_ text: String, dx: Double) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { l -> String in
            let s = String(l)
            guard s.hasPrefix("ATOM") || s.hasPrefix("HETATM"), s.count >= 54 else { return s }
            let a = Array(s)
            let x = (Double(String(a[30..<38]).trimmingCharacters(in: .whitespaces)) ?? 0) + dx
            return String(a[0..<30]) + String(format: "%8.3f", x) + String(a[38...])
        }.joined(separator: "\n")
    }

    static func runProtein(call: Call, check: Report, err: (JSON) -> String) async {
        func body(_ s: String) -> [String] { s.split(separator: "\n").map(String.init).filter { $0.hasPrefix("ATOM") } }
        var a = body(backbonePDB(residues: 12, phi: -57, psi: -47, chain: "A"))
        // Residue 6 of chain A becomes a HETATM-flagged selenomethionine (still peptide-linked: polymer).
        a = a.map { l in
            guard l.dropFirst(22).hasPrefix("   6") else { return l }
            return "HETATM" + l.dropFirst(6).replacingOccurrences(of: " GLY A", with: " MSE A")
        }
        // Residue 3's O in two alternate locations: B (occupancy 0.6) wins, A is dropped.
        if let k = a.firstIndex(where: { $0.dropFirst(12).hasPrefix(" O  ") && $0.dropFirst(22).hasPrefix("   3") }) {
            let l = a[k]
            let la = String(l.prefix(16)) + "A" + String(l.dropFirst(17).prefix(37)) + "  0.40" + String(l.dropFirst(60))
            let lb = shiftPDB(String(l.prefix(16)) + "B" + String(l.dropFirst(17).prefix(37)) + "  0.60" + String(l.dropFirst(60)), dx: 0.3)
            a.replaceSubrange(k...k, with: [la, lb])
        }
        let b = body(shiftPDB(backbonePDB(residues: 12, phi: -120, psi: 130, chain: "B"), dx: 40))
        let lig = [
            "HETATM 9001  N   LIG C 301      80.000   0.000   0.000  1.00  0.00           N",
            "HETATM 9002  CA  LIG C 301      81.458   0.000   0.000  1.00  0.00           C",
            "HETATM 9003  C   LIG C 301      82.000   1.420   0.000  1.00  0.00           C",
            "HETATM 9004  O   LIG C 301      83.200   1.600   0.000  1.00  0.00           O",
            "HETATM 9005  O   HOH W 401      60.000  10.000   0.000  1.00  0.00           O",
        ]
        let remark = """
        REMARK 350 BIOMOLECULE: 1
        REMARK 350 APPLY THE FOLLOWING TO CHAINS: A, C
        REMARK 350   BIOMT1   1  1.000000  0.000000  0.000000        0.00000
        REMARK 350   BIOMT2   1  0.000000  1.000000  0.000000        0.00000
        REMARK 350   BIOMT3   1  0.000000  0.000000  1.000000        0.00000
        REMARK 350   BIOMT1   2 -1.000000  0.000000  0.000000       10.00000
        REMARK 350   BIOMT2   2  0.000000 -1.000000  0.000000        0.00000
        REMARK 350   BIOMT3   2  0.000000  0.000000  1.000000        0.00000
        REMARK 350 BIOMOLECULE: 2
        REMARK 350 APPLY THE FOLLOWING TO CHAINS: B
        REMARK 350   BIOMT1   1  1.000000  0.000000  0.000000        0.00000
        REMARK 350   BIOMT2   1  0.000000  1.000000  0.000000        0.00000
        REMARK 350   BIOMT3   1  0.000000  0.000000  1.000000        0.00000

        """
        let text = remark + (a + ["TER"] + b + ["TER"] + lig).joined(separator: "\n") + "\nEND\n"
        let dir = FileManager.default.temporaryDirectory
        let pid = ProcessInfo.processInfo.processIdentifier
        let f1 = dir.appendingPathComponent("vibeview-selftest-protein-\(pid).pdb")
        try? text.write(to: f1, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: f1) }
        let o = await call("doc.open", ["path": .string(f1.path)])
        let id = o["result"]?["docId"]?.stringValue ?? ""
        let atomCount = o["result"]?["summary"]?["atomCount"]?.intValue ?? o["result"]?["atomCount"]?.intValue ?? -1
        check("pdb altLoc: one conformer kept", atomCount == a.count - 1 + b.count + lig.count,
              "atoms \(atomCount), expected \(a.count - 1 + b.count + lig.count) \(err(o))")
        let r = await call("analysis.secondaryStructure", ["docId": .string(id)])
        let res = r["result"]
        let names = res?["name"]?.arrayValue?.compactMap(\.stringValue) ?? []
        check("protein residues: HETATM MSE is polymer, lone LIG is not", res?["residueCount"]?.intValue == 24
              && names.contains("MSE") && !names.contains("LIG") && res?["residueSource"]?.stringValue == "file",
              "\(res?["residueCount"]?.intValue ?? -1) \(names.prefix(8)) \(err(r))")
        let polymer = Set(res?["polymerAtoms"]?.arrayValue?.compactMap(\.intValue) ?? [])
        let water = res?["waterAtoms"]?.arrayValue?.compactMap(\.intValue) ?? []
        let n = atomCount
        check("protein atoms: ligand and water outside the polymer", n > 5 && water == [n - 1]
              && !(n - 5..<n).contains(where: { polymer.contains($0) }) && polymer.count == n - 5,
              "polymer \(polymer.count) water \(water)")
        let segs = res?["segments"]?.arrayValue ?? []
        check("protein segments: one per chain", segs.count == 2, "\(segs.count) segments")
        let chains = res?["chains"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let atomChain = res?["atomChain"]?.arrayValue?.compactMap(\.intValue) ?? []
        check("protein chains per atom", chains == ["A", "B", "C", "W"] && atomChain.count == n
              && atomChain.last == 3 && atomChain.first == 0, "\(chains) \(atomChain.count)")
        let asm = res?["assembly"]
        let parts = asm?["parts"]?.arrayValue ?? []
        check("protein assembly 1 from REMARK 350", asm?["chains"]?.arrayValue?.compactMap(\.stringValue) == ["A", "C"]
              && parts.count == 1 && parts.first?["operators"]?.arrayValue?.count == 2
              && parts.first?["operators"]?.arrayValue?.last?.arrayValue?.first?.doubleValue == -1,
              asm.map { $0.serialized() } ?? "no assembly")

        // NMR ensemble: the document shows model 1 and the residues come from model 1's records.
        let m1 = backbonePDB(residues: 10, phi: -57, psi: -47).replacingOccurrences(of: "END\n", with: "")
        let nmr = "MODEL        1\n" + m1 + "ENDMDL\nMODEL        2\n" + shiftPDB(m1, dx: 25) + "ENDMDL\nEND\n"
        let f2 = dir.appendingPathComponent("vibeview-selftest-nmr-\(pid).pdb")
        try? nmr.write(to: f2, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: f2) }
        let o2 = await call("doc.open", ["path": .string(f2.path)])
        let id2 = o2["result"]?["docId"]?.stringValue ?? ""
        let mol = await call("doc.molecule", ["docId": .string(id2)])
        let x0 = (mol["result"]?["atoms"] ?? mol["result"]?["molecule"]?["atoms"])?.arrayValue?.first?["pos"]?.arrayValue?.first?.doubleValue ?? -99
        let r2 = await call("analysis.secondaryStructure", ["docId": .string(id2)])
        check("pdb models: model 1 shown, others are frames", abs(x0) < 0.01
              && (o2["result"]?["summary"]?["frameCount"]?.intValue ?? o2["result"]?["frameCount"]?.intValue) == 2
              && r2["result"]?["residueSource"]?.stringValue == "file" && r2["result"]?["residueCount"]?.intValue == 10,
              "x0 \(x0) \(err(o2)) \(r2["result"]?["residueSource"]?.stringValue ?? err(r2))")
    }
}
