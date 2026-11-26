import Foundation
import MolCore
import MolBuild
import MolSIMD

// GaussView-style element groups (MolBuild `GroupLibrary`): `build.groups` and the `placeGroup` edit op.

extension Engine {
    /// `build.groups {element?}` → `{groups: [...]}`: atom templates (with hybridization) and functional groups,
    /// each listed under one element.
    func buildGroups(_ p: Params) -> JSON {
        let z = p.optInt("element")
        let list = z.map { GroupLibrary.groups(forElement: $0) } ?? GroupLibrary.all
        let groups: [JSON] = list.map { g in
            obj(["id": g.id, "name": g.name, "label": g.label, "element": g.element, "kind": g.kind.rawValue,
                 "hybridization": g.hybridization.map { JSON.string($0.rawValue) } ?? .null,
                 "bondOrder": g.bondOrder.rawValue, "anchor": g.fragment.anchor, "leaving": g.fragment.leaving,
                 "molecule": JSONShapes.molecule(g.fragment.molecule)])
        }
        return ["groups": .array(groups)]
    }
}

extension EditOps {
    /// `placeGroup {groupId, at: atom|null, pos: [x,y,z]|null}` (Builder.clickGroup). Returns nil for other op types.
    static func applyGroupOp(_ type: String, _ op: Params, to m: Molecule) throws -> (String, Molecule)? {
        guard type == "placeGroup" else { return nil }
        let gid = try op.string("groupId")
        guard let g = GroupLibrary.group(id: gid) else { throw RPCError.notFound("unknown group '\(gid)'") }
        let target: BuildTarget
        if let at = op.optInt("at") {
            try checkAtoms([at], in: m, name: "at")
            target = .atom(at)
        } else {
            target = .empty(try op.optVec3("pos") ?? (m.atoms.isEmpty ? Vec3(0, 0, 0) : m.centroid + Vec3(4, 0, 0)))
        }
        return ("Place \(g.name)", try Builder.clickGroup(g, on: target, in: m))
    }
}
