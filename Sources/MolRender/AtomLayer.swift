import SceneKit
import simd
import MolCore

/// Builds the atom layer: one SCNNode per displayed atom ("atom:<i>"), sharing one SCNSphere per
/// distinct (radius, color) and one SCNMaterial per color.
///
/// Wireframe choice: bonded atoms get no node (the bond lines carry the picture); only isolated atoms
/// (no visible bond) get a small marker sphere (radius 0.1 Å) so they do not vanish.
/// Children are ordered by ascending atom index, which `updatePositions` relies on.
public enum AtomLayerBuilder {
    static let isolatedMarkerRadius = 0.1
    /// Above this many displayed atoms (and the same atom-count criterion for bonds) the layers use merged
    /// chunked geometry ("atoms:merged:<n>" / "bonds:merged:<n>") instead of one node per atom/bond.
    nonisolated(unsafe) public static var mergeThreshold = 1200

    /// Atom indices that get a node, ascending.
    static func displayedAtoms(molecule: Molecule, options: RenderOptions) -> [Int] {
        var idx: [Int] = []
        idx.reserveCapacity(molecule.atoms.count)
        if options.style == .wireframe {
            var hasBond = [Bool](repeating: false, count: molecule.atoms.count)
            for b in molecule.bonds where RenderMetrics.isBondVisible(b, in: molecule, options: options) {
                hasBond[b.a] = true; hasBond[b.b] = true
            }
            for i in molecule.atoms.indices where RenderMetrics.isAtomVisible(i, in: molecule, options: options) && !hasBond[i] { idx.append(i) }
        } else {
            for i in molecule.atoms.indices where RenderMetrics.isAtomVisible(i, in: molecule, options: options) { idx.append(i) }
        }
        return idx
    }

    static func radius(of atom: Atom, options: RenderOptions) -> Double {
        options.style == .wireframe ? isolatedMarkerRadius : RenderMetrics.atomRadius(atomicNumber: atom.atomicNumber, options: options)
    }

    private struct Key: Hashable { let r: Double; let c: RGBA }

    /// Returns a node named NodeName.atoms containing all visible atoms.
    public static func build(molecule: Molecule, options: RenderOptions, colors: [RGBA], materials: MaterialLibrary) -> SCNNode {
        let layer = SCNNode(); layer.name = NodeName.atoms
        let idx = displayedAtoms(molecule: molecule, options: options)
        if idx.count > mergeThreshold {
            MergedGeometry.buildAtoms(layer, idx: idx, molecule: molecule, options: options, colors: colors, materials: materials)
            return layer
        }
        let seg = SceneQuality.sphereSegments(quality: options.geometryQuality, atomCount: idx.count)
        var cache: [Key: SCNSphere] = [:]
        var nodes: [SCNNode] = []
        nodes.reserveCapacity(idx.count)
        for i in idx {
            let atom = molecule.atoms[i]
            let color = i < colors.count ? colors[i] : ElementPalette.color(atom.atomicNumber)
            let r = radius(of: atom, options: options)
            let key = Key(r: r, c: color)
            let sphere: SCNSphere
            if let s = cache[key] { sphere = s } else {
                sphere = SCNSphere(radius: CGFloat(r))
                sphere.segmentCount = seg
                sphere.firstMaterial = materials.material(for: color)
                cache[key] = sphere
            }
            let node = SCNNode(geometry: sphere)
            node.name = NodeName.atom(i)
            node.simdPosition = SIMD3<Float>(atom.position)
            nodes.append(node)
        }
        for n in nodes { layer.addChildNode(n) }
        return layer
    }

    /// Move existing atom nodes to new positions. Return false if the layer can't be updated in place.
    public static func updatePositions(_ layer: SCNNode, molecule: Molecule, options: RenderOptions) -> Bool {
        guard layer.name == NodeName.atoms else { return false }
        let idx = displayedAtoms(molecule: molecule, options: options)
        if idx.count > mergeThreshold { return MergedGeometry.updateAtoms(layer, idx: idx, molecule: molecule, options: options) }
        let children = layer.childNodes
        guard children.count == idx.count else { return false }
        for (node, i) in zip(children, idx) {
            guard node.name == NodeName.atom(i) else { return false }
            node.simdPosition = SIMD3<Float>(molecule.atoms[i].position)
        }
        return true
    }
}
