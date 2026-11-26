import Foundation
import MolCore
import MolBuild

// Element groups for the periodic-table picker (MolBuild/Groups.swift).

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
        Check("build.groups.libraryEntriesResolve") {
            for id in ["C.methyl", "C.phenyl", "C.carboxyl", "C.formyl", "C.cyano", "N.amino", "N.nitro", "N.cyano", "N.amide",
                       "O.hydroxyl", "O.methoxy", "S.thiol", "F.trifluoromethyl", "Cl.chloromethyl", "Br.bromomethyl", "I.iodomethyl",
                       "P.phosphonic", "B.boronic", "Si.trimethylsilyl"] {
                try expect(GroupLibrary.group(id: id) != nil, "missing \(id)")
            }
            for z in [6, 7, 8, 16, 15, 9, 17, 35, 53] { try expect(GroupLibrary.groups(forElement: z).contains { $0.kind == .group }, "groups for Z=\(z)") }
        },
        Check("build.groups.clickRoutesThroughBuildItem") {
            let w = grpWater()
            let a = try Builder.click(.group("C.methyl"), on: .atom(1), in: w)
            let b = try Builder.clickGroup(try grpGroup("C.methyl"), on: .atom(1), in: w)
            try expect(a == b, "click(.group) == clickGroup")
            do { _ = try Builder.click(.group("C.nope"), on: .atom(1), in: w); throw CheckFailure(description: "expected unknown group") }
            catch BuildError.unknownFragment {}
            // Replace a heavy atom in place with an atom template: water O -> N sp3 gives ammonia.
            let n = try Builder.click(.group("N.sp3"), on: .atom(0), in: w)
            try expect(grpCounts(n) == [7: 1, 1: 3], "NH3 \(grpCounts(n))")
            // Two sp2 carbons joined through a hydrogen click become ethylene.
            let ch3 = try grpGroup("C.sp2").fragment.molecule
            let h = ch3.atoms.firstIndex { $0.atomicNumber == 1 }!
            let e = try Builder.click(.group("C.sp2"), on: .atom(h), in: ch3)
            try expect(grpCounts(e) == [6: 2, 1: 4] && e.bonds.contains { $0.order == .double }, "ethylene \(grpCounts(e))")
        },
    ]
}
