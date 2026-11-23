import Foundation
import MolCore

/// Writer for Gaussian-style input files.
public enum GaussianInputWriter {
    /// Write jobs separated by `--Link1--`.
    public static func write(_ jobs: [GaussianJob]) -> String {
        var out = ""
        for (k, job) in jobs.enumerated() {
            if k > 0 { out += "--Link1--\n" }
            out += writeOne(job)
        }
        return out
    }

    private static func fmt(_ v: Double) -> String { String(format: "%.8f", v) }

    private static func writeOne(_ job: GaussianJob) -> String {
        var out = ""
        for l in job.link0.lines { out += l + "\n" }
        out += job.route.text + "\n\n"
        let route = job.route
        if route.readsEverythingFromCheckpoint {
            appendTail(&out, job)
            return out
        }
        var title = job.title.isEmpty ? job.molecule.title : job.title
        title = splitLines(title).filter { !$0.allSatisfy { $0 == " " || $0 == "\t" } }.joined(separator: "\n")
        out += (title.isEmpty ? "Title Card Required" : title) + "\n\n"
        let cms = job.chargeMultiplicities.isEmpty
            ? [ChargeMultiplicity(charge: job.molecule.charge, multiplicity: job.molecule.multiplicity)]
            : job.chargeMultiplicities
        out += cms.map { "\($0.charge) \($0.multiplicity)" }.joined(separator: " ") + "\n"
        if route.readsGeometryFromCheckpoint {
            out += "\n"
        } else {
            out += geometry(job)
            out += "\n"
            if route.readsConnectivity { out += connectivity(job) + "\n" }
        }
        appendTail(&out, job)
        return out
    }

    private static func appendTail(_ out: inout String, _ job: GaussianJob) {
        if !job.modRedundant.isEmpty || job.route.readsModRedundant {
            out += job.modRedundant.joined(separator: "\n")
            out += job.modRedundant.isEmpty ? "\n" : "\n\n"
        }
        for s in job.extraSections { out += s + "\n\n" }
        if out.hasSuffix("\n\n") { return }
        out += "\n"
    }

    private static func geometry(_ job: GaussianJob) -> String {
        var out = ""
        if let z = job.zMatrix {
            for e in z.entries {
                var f: [String] = [e.symbol]
                if e.isCartesian {
                    if let fr = e.freeze { f.append(String(fr)) }
                    f.append(contentsOf: e.values)
                } else {
                    for k in 0..<e.references.count {
                        f.append(e.references[k])
                        if k < e.values.count { f.append(e.values[k]) }
                    }
                }
                f.append(contentsOf: e.trailing)
                out += f.joined(separator: " ") + "\n"
            }
            func vline(_ v: GaussianZMatrix.Variable) -> String {
                ([v.name + "=" + "\(v.value)"] + v.extra).joined(separator: " ")
            }
            let vars = z.variables.filter { !$0.isConstant }, consts = z.variables.filter { $0.isConstant }
            if !vars.isEmpty {
                out += "\nVariables:\n" + vars.map(vline).joined(separator: "\n") + "\n"
            }
            if !consts.isEmpty {
                out += "\nConstants:\n" + consts.map(vline).joined(separator: "\n") + "\n"
            }
            return out
        }
        let atoms = job.molecule.atoms
        let specs = job.atomSpecs.count == atoms.count ? job.atomSpecs : []
        out.reserveCapacity(atoms.count * 64)
        for (k, a) in atoms.enumerated() {
            var label: String
            var freeze = 0
            var layerPart = ""
            if !specs.isEmpty {
                let s = specs[k]
                label = s.label.isEmpty ? (a.label ?? IOElements.symbol(a.atomicNumber)) : s.label
                if let fr = s.fragment, !label.lowercased().contains("fragment=") { label += "(Fragment=\(fr))" }
                freeze = s.freeze
                if let l = s.layer {
                    layerPart = " " + l
                    if let la = s.linkAtom { layerPart += " " + la }
                } else if !s.parameters.isEmpty { layerPart = " " + s.parameters.joined(separator: " ") }
            } else {
                label = a.label ?? IOElements.symbol(a.atomicNumber)
            }
            let showFreeze = freeze != 0 || !layerPart.isEmpty && specs[k].layer != nil
            out += label
            if showFreeze { out += " \(freeze)" }
            out += " " + fmt(a.position.x) + " " + fmt(a.position.y) + " " + fmt(a.position.z) + layerPart + "\n"
        }
        return out
    }

    private static func connectivity(_ job: GaussianJob) -> String {
        // Input numbering = Z-matrix row numbering (dummies included) or atom order.
        var rowOfAtom: [Int] = []
        var total = job.molecule.atoms.count
        if let z = job.zMatrix {
            total = z.entries.count
            for (r, e) in z.entries.enumerated() where !e.isDummy { rowOfAtom.append(r) }
        } else {
            rowOfAtom = Array(0..<job.molecule.atoms.count)
        }
        var neighbors = [[(Int, BondOrder)]](repeating: [], count: total)
        for b in job.molecule.bonds where b.a >= 0 && b.b >= 0 && b.a < rowOfAtom.count && b.b < rowOfAtom.count {
            let x = rowOfAtom[b.a], y = rowOfAtom[b.b]
            neighbors[min(x, y)].append((max(x, y), b.order))
        }
        var out = ""
        for i in 0..<total {
            out += String(i + 1)
            for (j, o) in neighbors[i].sorted(by: { $0.0 < $1.0 }) { out += " \(j + 1) \(o.rawValue)" }
            out += "\n"
        }
        return out
    }
}
