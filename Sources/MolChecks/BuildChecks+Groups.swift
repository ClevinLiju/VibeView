import Foundation
import MolSIMD
import MolCore
import MolBuild

// Element groups (GaussView-style picker; MolBuild/Groups.swift) and the extended Calculation Setup catalog.

fileprivate func grpCounts(_ m: Molecule) -> [Int: Int] {
    var c: [Int: Int] = [:]
    for a in m.atoms { c[a.atomicNumber, default: 0] += 1 }
    return c
}

fileprivate func grpGroup(_ id: String) throws -> BuildGroup {
    guard let g = GroupLibrary.group(id: id) else { throw CheckFailure(description: "no group \(id)") }
    return g
}

fileprivate func grpWater() -> Molecule {
    var m = Molecule(atoms: [Atom(id: 0, atomicNumber: 8, position: Vec3(0, 0, 0.1173)),
                             Atom(id: 1, atomicNumber: 1, position: Vec3(0, 0.7572, -0.4692)),
                             Atom(id: 2, atomicNumber: 1, position: Vec3(0, -0.7572, -0.4692))], title: "water")
    m.addBond(0, 1, order: .single); m.addBond(0, 2, order: .single)
    return m
}

extension Checks {
    static let buildGroups: [Check] = [
        Check("build.groups.library") {
            let all = GroupLibrary.all
            try expect(all.count >= 40, "\(all.count) groups")
            try expect(Set(all.map(\.id)).count == all.count, "ids are unique")
            for g in all {
                let m = g.fragment.molecule
                try expect(m.atoms.indices.contains(g.fragment.anchor), "\(g.id) anchor")
                try expect(m.atoms.indices.contains(g.fragment.leaving) && m.atoms[g.fragment.leaving].atomicNumber == 1, "\(g.id) leaving H")
                try expect(m.areBonded(g.fragment.anchor, g.fragment.leaving), "\(g.id) leaving H on the anchor")
                try expect(g.id.hasPrefix(BuildElements.symbol(g.element) + "."), "\(g.id) prefix")
                if g.kind == .atom {
                    try expect(g.hybridization != nil && m.atoms[g.fragment.anchor].atomicNumber == g.element, "\(g.id) atom template")
                }
            }
            for z in [5, 6, 7, 8, 14, 15, 16] {
                try expect(GroupLibrary.groups(forElement: z).contains { $0.kind == .atom }, "element \(z) has atom templates")
            }
            try expect(GroupLibrary.groups(forElement: 6).map(\.id).starts(with: ["C.sp3", "C.sp2", "C.sp"]), "carbon order")
            try expect(GroupLibrary.group(id: "C.nope") == nil)
        },
        Check("build.groups.templatesHaveHybridizationHydrogens") {
            try expect(grpCounts(try grpGroup("C.sp3").fragment.molecule) == [6: 1, 1: 4], "CH4")
            try expect(grpCounts(try grpGroup("N.sp3").fragment.molecule) == [7: 1, 1: 3], "NH3")
            try expect(grpCounts(try grpGroup("O.sp3").fragment.molecule) == [8: 1, 1: 2], "H2O")
        },
        Check("build.groups.placeOnHydrogenAndEmptySpace") {
            let w = grpWater()
            let meoh = try Builder.clickGroup(try grpGroup("C.methyl"), on: .atom(1), in: w)
            try expect(grpCounts(meoh) == [8: 1, 6: 1, 1: 4], "methanol \(grpCounts(meoh))")
            let c = meoh.atoms.firstIndex { $0.atomicNumber == 6 }!
            try expect(meoh.areBonded(0, c))
            try expectClose(VecMath.distance(meoh.atoms[0].position, meoh.atoms[c].position), 1.43, tol: 0.08)
            let two = try Builder.clickGroup(try grpGroup("C.sp3"), on: .empty(Vec3(6, 0, 0)), in: w)
            try expect(grpCounts(two) == [8: 1, 6: 1, 1: 6] && two.bonds.count == 6, "water + methane")
        },
        Check("build.groups.doubleBondGroupTakesHostHydrogens") {
            let methane = try grpGroup("C.sp3").fragment.molecule
            let h = methane.atoms.firstIndex { $0.atomicNumber == 1 }!
            let f = try Builder.clickGroup(try grpGroup("O.carbonyl"), on: .atom(h), in: methane)
            try expect(grpCounts(f) == [6: 1, 8: 1, 1: 2], "formaldehyde \(grpCounts(f))")
            let c = f.atoms.firstIndex { $0.atomicNumber == 6 }!, o = f.atoms.firstIndex { $0.atomicNumber == 8 }!
            try expect(f.bonds.contains { Set([$0.a, $0.b]) == Set([c, o]) && $0.order == .double }, "C=O")
            try expectClose(VecMath.distance(f.atoms[c].position, f.atoms[o].position), 1.22, tol: 0.08)
        },
        Check("build.calcsetup.extendedCatalog") {
            for p in MolBuild.QCProgram.allCases where p != .xtb {
                let ms = CalcSetup.methods(for: p), bs = CalcSetup.bases(for: p)
                try expect(ms.count >= 25 && bs.count >= 25, "\(p): \(ms.count) methods, \(bs.count) bases")
                try expect(Set(ms).count == ms.count && Set(bs).count == bs.count, "\(p) catalog has duplicates")
                try expect(ms.contains("CAM-B3LYP") && bs.contains("def2-SVP") && bs.contains("def2-TZVP"), "\(p) basics")
                try expect(ms.contains(CalcSetup.defaultMethod(for: p)) && bs.contains(CalcSetup.defaultBasis(for: p)), "\(p) defaults listed")
            }
            try expect(CalcSetup.methods(for: .orca).contains("r2SCAN-3c") && CalcSetup.methods(for: .gaussian).contains("PM7"))
            var s = CalcSetup(molecule: grpWater(), program: .gaussian)
            s.method = "PM7"; s.basis = "6-31G(d)"
            try expect(s.routeLine().contains("PM7 ") && !s.routeLine().contains("PM7/"), s.routeLine())
            s.method = "CBS-QB3"; s.basis = ""
            try expect(s.validate(molecule: grpWater()).isEmpty, "composite needs no basis")
            s.setProgram(.orca); s.method = "r2SCAN-3c"; s.basis = "def2-SVP"
            let orca = s.inputText(molecule: grpWater())
            try expect(orca.contains("r2SCAN-3c") && !orca.contains("def2-SVP"), orca)
        },
    ]
}
