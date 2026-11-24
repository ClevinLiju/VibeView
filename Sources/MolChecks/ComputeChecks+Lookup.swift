import Foundation
import MolCore
import MolCompute

extension Checks {
    static let computeLookup: [Check] = [
        Check("compute.lookup.classify") {
            func k(_ s: String) -> LookupQueryKind { LookupQueryKind.classify(s) }
            try expect(k("caffeine") == .name("caffeine"))
            try expect(k("benzene") == .name("benzene") && k("water") == .name("water"))
            try expect(k("CO") == .name("CO"), "2-letter is a name")
            try expect(k("58-08-2") == .cas("58-08-2"))
            try expect(k("58-08-3") == .name("58-08-3"), "bad check digit")
            try expect(k("CCO") == .smiles("CCO") && k("c1ccccc1") == .smiles("c1ccccc1") && k("CC(=O)O") == .smiles("CC(=O)O"))
            try expect(k("CID 2519") == .cid(2519) && k("2519") == .cid(2519))
            try expect(k("1,2-dichloroethane") == .name("1,2-dichloroethane"))
        },
        Check("compute.lookup.cas") {
            for s in ["58-08-2", "50-00-0", "64-17-5", "7732-18-5", "50-78-2"] { try expect(CASNumber.isValid(s), s) }
            for s in ["58-08-3", "5808-2", "abc", "58-8-2", ""] { try expect(!CASNumber.isValid(s), s) }
        },
        Check("compute.lookup.parse") {
            let props = Data("""
            {"PropertyTable":{"Properties":[{"CID":2519,"Title":"Caffeine","IUPACName":"x","MolecularFormula":"C8H10N4O2","MolecularWeight":"194.19","ConnectivitySMILES":"CN1C=NC2=C1C(=O)N(C(=O)N2C)C","SMILES":"CN1C"},{"CID":5,"CanonicalSMILES":"CC","MolecularWeight":30.07}]}}
            """.utf8)
            let p = NameLookup.parseProperties(props)
            try expect(p.count == 2 && p[0].cid == 2519 && p[0].title == "Caffeine" && p[0].formula == "C8H10N4O2")
            try expectClose(p[0].molecularWeight ?? 0, 194.19)
            try expect(p[0].smiles?.hasPrefix("CN1C=NC2") == true && p[1].smiles == "CC")
            try expectClose(p[1].molecularWeight ?? 0, 30.07)
            let syn = NameLookup.parseSynonyms(Data(#"{"InformationList":{"Information":[{"CID":2519,"Synonym":["caffeine","58-08-2"]}]}}"#.utf8))
            try expect(syn[2519] == ["caffeine", "58-08-2"])
            let ac = NameLookup.parseAutocomplete(Data(#"{"status":{"code":0},"total":2,"dictionary_terms":{"compound":["caffeine","caffeic acid"]}}"#.utf8))
            try expect(ac == ["caffeine", "caffeic acid"])
            try expect(NameLookup.parseCIDs(Data(#"{"IdentifierList":{"CID":[2519,0,7]}}"#.utf8)) == [2519, 7])
            try expect(NameLookup.parseCIDs(Data("garbage".utf8)).isEmpty)
        },
        Check("compute.lookup.throttle") {
            let t0 = Date()
            try computeRunAsync(timeout: 20) {
                let th = PubChemThrottle()
                for _ in 0..<6 { await th.wait() }
            }
            let dt = Date().timeIntervalSince(t0)
            print("    6 waits: \(String(format: "%.2f", dt)) s")
            try expect(dt >= 0.97, "too fast: \(dt)")
        },
        Check("compute.lookup.live") {
            let lookup = NameLookup()
            let probe: Bool = try computeRunAsync(timeout: 20) {
                let r = await lookup.suggest("CID 2244", limit: 1)
                if r.isEmpty, let e = await lookup.lastError, e == .offline || e == .timeout { return false }
                return true
            }
            if !probe { print("    SKIP (offline)"); return }
            func timed(_ q: String) throws -> [LookupCandidate] {
                let t0 = Date()
                let r = try computeRunAsync(timeout: 60) { await NameLookup().suggest(q) }
                print("    \(q): \(String(format: "%.2f", Date().timeIntervalSince(t0))) s -> " +
                      r.map { "\($0.cid) \($0.title) [\($0.matchKind)]" }.joined(separator: "; "))
                return r
            }
            let caf = try timed("caffeine")
            guard let c = caf.first else { throw CheckFailure(description: "no caffeine result") }
            try expect(c.cid == 2519, "cid \(c.cid)")
            try expect(c.formula == "C8H10N4O2", "formula \(c.formula ?? "nil")")
            try expect(c.casNumber == "58-08-2", "cas \(c.casNumber ?? "nil")")
            try expect(c.synonyms.count <= 5 && c.canonicalSMILES != nil)
            let png = [UInt8](c.thumbnail ?? Data()).prefix(4)
            try expect(Array(png) == [0x89, 0x50, 0x4E, 0x47], "thumbnail not PNG")
            let xy = try timed("xylene")
            try expect(xy.count >= 3, "xylene candidates: \(xy.count)")
            try expect(Set([7237, 7929, 7809]).isSubset(of: Set(xy.map(\.cid))), "o/m/p-xylene: \(xy.map(\.cid))")
            try expect(try timed("58-08-2").first?.cid == 2519)
            try expect(try timed("aspirin").first?.cid == 2244)
            try expect(try timed("cafeine").contains { $0.cid == 2519 }, "typo not corrected")
            let mol = try computeRunAsync(timeout: 60) { try await NameLookup().structure(for: c) }
            try expect(mol.atoms.count == 24, "atoms \(mol.atoms.count)")
            let zs = mol.atoms.map { $0.position.z }
            try expect((zs.max() ?? 0) - (zs.min() ?? 0) > 0.1, "planar")
        },
    ]
}
