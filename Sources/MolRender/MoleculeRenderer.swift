import Foundation
import SceneKit
import AppKit
import simd
import MolCore
import MolAnalysis

/// Result of a click on the 3D view.
public struct PickEvent: Sendable {
    public var target: PickTarget
    public var modifiers: NSEvent.ModifierFlags
    public var clickCount: Int
    /// View coordinates (points, origin bottom-left as in AppKit).
    public var location: CGPoint
    public init(target: PickTarget, modifiers: NSEvent.ModifierFlags, clickCount: Int, location: CGPoint) {
        self.target = target; self.modifiers = modifiers; self.clickCount = clickCount; self.location = location
    }
}

/// Owns the SceneKit scene for one molecule and its interactive view. Main-actor only.
///
/// Typical use from the app:
///   let r = MoleculeRenderer(); r.setMolecule(mol, fitCamera: true)
///   r.onPick = { ev in ... }; r.options.style = .spaceFilling
///   MoleculeSceneView(renderer: r)            // SwiftUI
@MainActor public final class MoleculeRenderer: NSObject {
    public let scene = SCNScene()
    public let view: MoleculeSCNView
    public let cameraNode = SCNNode()
    public private(set) var camera: CameraController!
    public let materials = MaterialLibrary()

    public private(set) var molecule = Molecule()
    public var options: RenderOptions { didSet { refreshAtomMask(); optionsChanged(from: oldValue) } }

    /// PDB records of the file the molecule came from (residue names, chains, HELIX/SHEET). Optional: without them
    /// the cartoon perceives the backbone from bonds and computes the secondary structure (simplified DSSP).
    public var proteinRecords: PDBProteinRecords? {
        didSet { protein = nil; if options.style == .cartoon { refreshAtomMask(); rebuildAll() } }
    }
    /// Protein analysis of the current molecule (computed when the cartoon style is first needed).
    public private(set) var protein: ProteinStructure?
    /// Size and build time of the last cartoon mesh.
    public private(set) var cartoonStats = CartoonLayerBuilder.Stats()
    var cartoonLayer = SCNNode()

    /// Selected atom indices. Highlighted; set by built-in click/box handling when `autoSelect`.
    public var selection: Set<Int> = [] { didSet { if selection != oldValue { rebuildHighlight(); onSelectionChange?(selection) } } }
    public internal(set) var hovered: PickTarget = .none {
        didSet {
            guard hovered != oldValue else { return }
            rebuildHighlight(); onHover?(hovered)
            if let cb = onHoverInfo { cb(HoverInfo.make(hovered, molecule: molecule, location: lastHoverLocation)) }
            pushHoverTooltip()
        }
    }
    /// Tooltip-ready hover callback (atom element/charge/neighbors, bond length/order, pointer location).
    /// Fires whenever `hovered` changes, including to `.none` (empty `text`).
    public var onHoverInfo: ((HoverInfo) -> Void)?
    var lastHoverLocation: CGPoint?
    /// Observable tooltip state for `HoverTooltipOverlay` / `HoverTooltipView` (round 3).
    public private(set) lazy var hoverTooltipModel = HoverTooltipModel()
    /// Bumped when the camera or coordinates change; hover picks are cached per revision.
    var hoverRevision = 0
    var slabDefaults: (near: Double, far: Double)?
    var hbondLayer = SCNNode()
    var annotationsShown = false
    var surfaceBounds: [String: (lo: Vec3, hi: Vec3)] = [:]

    /// Left-drag tool (see `DragTool`). Default `.rotate` keeps the round-2 behaviour.
    public var dragTool: DragTool = .rotate
    /// Double-clicking an atom also animates the camera target onto it (default true).
    public var centerOnDoubleClick = true
    /// Atoms inside a lasso, with the modifiers at mouse-up (fires before built-in selection handling).
    public var onLassoSelect: ((Set<Int>, NSEvent.ModifierFlags) -> Void)?
    /// A move-selection drag finished: all atom positions before and after. The renderer already shows
    /// `after`; commit it to the document (with undo) and call `setMolecule`/`updatePositions` as usual.
    public var onSelectionMoved: ((_ before: [Vec3], _ after: [Vec3]) -> Void)?
    /// Fired with `measurementValues()` whenever measurement overlays are rebuilt (live monitors).
    public var onMeasurementValues: (([Double]) -> Void)?

    /// Push the current hover target into `hoverTooltipModel`.
    func pushHoverTooltip() {
        let info = HoverInfo.make(hovered, molecule: molecule, location: lastHoverLocation)
        hoverTooltipModel.update(HoverTooltip.make(info, molecule: molecule, measurements: options.measurements), at: lastHoverLocation)
    }

    /// Built-in selection semantics: click = select atom, shift = add, cmd = toggle,
    /// double-click = whole fragment, click on empty = clear. Box (shift-drag) adds atoms inside.
    public var autoSelect = true
    public var onPick: ((PickEvent) -> Void)?
    public var onHover: ((PickTarget) -> Void)?
    public var onSelectionChange: ((Set<Int>) -> Void)?
    /// Atoms inside a rubber-band rectangle, with the modifiers at mouse-up.
    public var onBoxSelect: ((Set<Int>, NSEvent.ModifierFlags) -> Void)?

    public private(set) var isosurfaces: [String: Isosurface] = [:]
    public private(set) var vibration: VibrationAnimator!
    public private(set) var trajectory: TrajectoryPlayer!
    public internal(set) var picking: PickingController!

    // Layer containers (children rebuilt on change)
    let root = SCNNode()
    var atomLayer = SCNNode(), bondLayer = SCNNode(), highlightLayer = SCNNode()
    var labelLayer = SCNNode(), measurementLayer = SCNNode(), cellLayer = SCNNode()
    var vectorLayer = SCNNode()
    let surfaceLayer = SCNNode()
    private(set) var lighting: LightingRig!
    /// Developer frame timing (`onNextFrame`, `benchmarkSpin`); idle unless used.
    let frameProbe = FrameProbe()
    /// True while the view renders continuously after a size change.
    private(set) var resizeSettleActive = false
    private var resizeSettleDeadline = 0.0
    /// Seconds the last full scene rebuild (`setMolecule` / geometry option change) took on the main thread.
    public private(set) var lastRebuildSeconds = 0.0
    private(set) var cachedBounds: (center: Vec3, radius: Double) = (.zero, 5)

    public init(molecule: Molecule = Molecule(), options: RenderOptions = RenderOptions()) {
        self.options = options
        self.view = MoleculeSCNView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        super.init()
        root.name = NodeName.root
        surfaceLayer.name = NodeName.surfaces
        scene.rootNode.addChildNode(root)
        cameraNode.name = NodeName.camera
        cameraNode.camera = SCNCamera()
        scene.rootNode.addChildNode(cameraNode)
        camera = CameraController(node: cameraNode)
        lighting = LightingRig(scene: scene, cameraNode: cameraNode)
        camera.onChange = { [weak self] in
            guard let self else { return }
            self.lighting.updateFogRange(distance: self.camera.distance, radius: self.cachedBounds.radius)
            self.lighting.updateFocus(distance: self.camera.distance)
            self.hoverRevision &+= 1
            self.applySlab()
            if self.options.showAxes || self.options.showScaleBar || self.annotationsShown { self.refreshAnnotations(); self.annotationsShown = self.options.showAxes || self.options.showScaleBar }
        }
        picking = PickingController(renderer: self)
        vibration = VibrationAnimator(renderer: self)
        trajectory = TrajectoryPlayer(renderer: self)
        view.scene = scene
        view.pointOfView = cameraNode
        view.renderer = self
        view.antialiasingMode = .multisampling4X
        view.allowsCameraControl = false
        view.rendersContinuously = false
        applyEnvironment()
        setMolecule(molecule, fitCamera: true)
    }

    // MARK: Molecule

    /// Replace the molecule and rebuild every layer. Selection indices beyond the new atom count are dropped.
    public func setMolecule(_ m: Molecule, fitCamera: Bool = false) {
        molecule = m
        protein = nil
        selection = selection.filter { $0 < m.atoms.count }
        if case .atom(let i) = hovered, i >= m.atoms.count { hovered = .none }
        if case .bond(let i) = hovered, i >= m.bonds.count { hovered = .none }
        rebuildAll()
        if fitCamera { fitToView(animated: false) }
    }

    /// Fast path for animation: same atoms/bonds, new coordinates (count must match).
    public func updatePositions(_ positions: [Vec3]) {
        guard positions.count == molecule.atoms.count else { return }
        for i in positions.indices { molecule.atoms[i].position = positions[i] }
        hoverRevision &+= 1
        vibration?.positionsChangedExternally()
        if options.style == .cartoon, protein != nil { rebuildCartoon() }
        let okA = AtomLayerBuilder.updatePositions(atomLayer, molecule: molecule, options: options)
        let okB = BondLayerBuilder.updatePositions(bondLayer, molecule: molecule, options: options)
        if !okA { replace(&atomLayer, with: AtomLayerBuilder.build(molecule: molecule, options: options, colors: currentColors, materials: materials)) }
        if !okB { replace(&bondLayer, with: BondLayerBuilder.build(molecule: molecule, options: options, colors: currentColors, materials: materials)) }
        rebuildOverlays()
    }

    /// Move only the position-following overlays (highlights, labels, measurements, H-bonds) and the model
    /// coordinates; the atom/bond layers are untouched (used while the GPU vibration mesh is shown).
    func updateOverlayPositions(_ positions: [Vec3]) {
        guard positions.count == molecule.atoms.count else { return }
        for i in positions.indices { molecule.atoms[i].position = positions[i] }
        hoverRevision &+= 1
        rebuildOverlays()
    }

    /// Hide/show the CPU atom and bond layers (the GPU vibration mesh replaces them while playing).
    func setGeometryLayersHidden(_ hidden: Bool) {
        atomLayer.isHidden = hidden; bondLayer.isHidden = hidden
    }

    /// Display colors per atom for the current options.
    public var currentColors: [RGBA] { RenderMetrics.atomColors(for: molecule, options: options) }

    /// Bounding sphere of visible atoms (center, radius incl. display radii); radius >= 1.
    public func boundingSphere() -> (center: Vec3, radius: Double) {
        let atoms = molecule.atoms.indices.filter { RenderMetrics.isAtomVisible($0, in: molecule, options: options) }.map { molecule.atoms[$0] }
        var pts = atoms.map(\.position)
        if let cell = options.unitCell, options.showUnitCell { pts += cell.corners }
        // Visible isosurfaces (orbital lobes extend well past the atoms): their bounding-box corners.
        var surf: [Vec3] = []
        for (id, b) in surfaceBounds where isosurfaces[id]?.visible == true {
            for n in 0..<8 { surf.append(Vec3(n & 1 == 0 ? b.lo.x : b.hi.x, n & 2 == 0 ? b.lo.y : b.hi.y, n & 4 == 0 ? b.lo.z : b.hi.z)) }
        }
        pts += surf
        guard !pts.isEmpty else { return (.zero, 5) }
        var lo = pts[0], hi = pts[0]
        for p in pts { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        let c = (lo + hi) / 2
        var r = 0.0
        for a in atoms { r = max(r, simd_distance(a.position, c) + RenderMetrics.atomRadius(atomicNumber: a.atomicNumber, options: options)) }
        if let cell = options.unitCell, options.showUnitCell { for p in cell.corners { r = max(r, simd_distance(p, c)) } }
        // Box corners overestimate a lobe's extent; use 85 % of the corner distance.
        for p in surf { r = max(r, 0.85 * simd_distance(p, c)) }
        return (c, max(r, 1))
    }

    public func fitToView(animated: Bool = true) {
        let s = boundingSphere()
        camera.fit(center: s.center, radius: s.radius, animated: animated)
    }

    /// Analytic hit-test at a view point (AppKit coordinates).
    public func pick(at point: CGPoint) -> PickTarget { picking.hitTest(point) }

    // MARK: Isosurfaces

    public func setIsosurface(_ s: Isosurface) {
        isosurfaces[s.id] = s
        var lo = SIMD3<Float>(repeating: .infinity), hi = -lo
        for m in s.meshes { for v in m.vertices where v.x.isFinite && v.y.isFinite && v.z.isFinite { lo = simd_min(lo, v); hi = simd_max(hi, v) } }
        surfaceBounds[s.id] = lo.x <= hi.x ? (Vec3(lo), Vec3(hi)) : nil
        surfaceLayer.childNode(withName: "surface:\(s.id)", recursively: false)?.removeFromParentNode()
        if s.visible { surfaceLayer.addChildNode(IsosurfaceNodeBuilder.build(s)) }
    }
    public func removeIsosurface(id: String) {
        isosurfaces[id] = nil; surfaceBounds[id] = nil
        surfaceLayer.childNode(withName: "surface:\(id)", recursively: false)?.removeFromParentNode()
    }
    public func removeAllIsosurfaces() {
        isosurfaces.removeAll(); surfaceBounds.removeAll(); surfaceLayer.childNodes.forEach { $0.removeFromParentNode() }
    }

    // MARK: Displacement vectors

    /// Show per-atom displacement arrows for a normal mode (nil hides them).
    public func showDisplacementArrows(_ mode: NormalMode?, scale: Double = 1.5, color: RGBA = RGBA(0.1, 0.7, 0.2)) {
        let n = mode.map { DisplacementArrowBuilder.build(molecule: molecule, mode: $0, scale: scale, color: color) } ?? emptyNode(NodeName.vectors)
        replace(&vectorLayer, with: n)
    }

    // MARK: Building

    func rebuildAll() {
        let t0 = CFAbsoluteTimeGetCurrent()
        defer {
            lastRebuildSeconds = CFAbsoluteTimeGetCurrent() - t0
            // Building merged geometry for a big structure frees tens of MB of temporaries (and the previous
            // scene's buffers); hand those pages back to the system instead of keeping them dirty in the process.
            if molecule.atoms.count > AtomLayerBuilder.mergeThreshold { Self.releaseFreedMemory() }
        }
        hoverRevision &+= 1
        refreshAtomMask()
        cachedBounds = boundingSphere()
        let colors = currentColors
        materials.preset = options.material
        replace(&atomLayer, with: AtomLayerBuilder.build(molecule: molecule, options: options, colors: colors, materials: materials))
        replace(&bondLayer, with: BondLayerBuilder.build(molecule: molecule, options: options, colors: colors, materials: materials))
        rebuildCartoon()
        rebuildCell()
        rebuildOverlays()
        if surfaceLayer.parent == nil { root.addChildNode(surfaceLayer) }
        if vectorLayer.parent == nil { vectorLayer.name = NodeName.vectors; root.addChildNode(vectorLayer) }
        vibration?.layersRebuilt()
    }

    func rebuildOverlays() {
        rebuildHighlight()
        replace(&labelLayer, with: LabelLayerBuilder.build(molecule: molecule, options: options))
        replace(&measurementLayer, with: MeasurementLayerBuilder.build(molecule: molecule, options: options))
        if options.showHydrogenBonds || hbondLayer.childNodes.count > 0 {
            replace(&hbondLayer, with: HydrogenBondLayerBuilder.build(molecule: molecule, options: options))
        }
        if !options.measurements.isEmpty, let cb = onMeasurementValues { cb(measurementValues()) }
    }

    func rebuildHighlight() {
        replace(&highlightLayer, with: HighlightLayerBuilder.build(molecule: molecule, options: options, selection: selection, hovered: hovered))
    }

    func rebuildCell() {
        let n = (options.showUnitCell ? options.unitCell : nil).map { UnitCellLayerBuilder.build(cell: $0, options: options) } ?? emptyNode(NodeName.cell)
        replace(&cellLayer, with: n)
    }

    private func optionsChanged(from old: RenderOptions) {
        if old == options { return }
        var geometryChanged = old.style != options.style || old.colorScheme != options.colorScheme
            || old.atomScale != options.atomScale || old.bondRadius != options.bondRadius || old.tubeRadius != options.tubeRadius
            || old.wireWidth != options.wireWidth || old.splitBondColors != options.splitBondColors || old.bondColor != options.bondColor
            || old.showBondOrders != options.showBondOrders || old.aromaticStyle != options.aromaticStyle || old.dashedBonds != options.dashedBonds
            || old.showHydrogens != options.showHydrogens || old.geometryQuality != options.geometryQuality
            || old.cartoonColoring != options.cartoonColoring || old.cartoonHidesWater != options.cartoonHidesWater
        if old.material != options.material { geometryChanged = true }
        if geometryChanged {
            rebuildAll()
        } else {
            if old.unitCell != options.unitCell || old.showUnitCell != options.showUnitCell { rebuildCell() }
            if old.labelMode != options.labelMode || old.labelSize != options.labelSize || old.measurements != options.measurements
                || old.showHydrogenBonds != options.showHydrogenBonds || old.hydrogenBondMaxDistance != options.hydrogenBondMaxDistance
                || old.hydrogenBondMinAngle != options.hydrogenBondMinAngle || old.hydrogenBondColor != options.hydrogenBondColor
                || old.selectionColor != options.selectionColor || old.hoverColor != options.hoverColor || old.theme != options.theme {
                rebuildOverlays()
            }
        }
        if old.projection != options.projection { camera.projection = options.projection }
        if old.slabNear != options.slabNear || old.slabFar != options.slabFar { applySlab() }
        if old.showAxes != options.showAxes || old.showScaleBar != options.showScaleBar || (annotationsShown && old.theme != options.theme) {
            refreshAnnotations(); annotationsShown = options.showAxes || options.showScaleBar
        }
        applyEnvironment()
    }

    func applyEnvironment() {
        lighting.apply(options: options)
        lighting.updateFocus(distance: camera.distance)
        refreshOutline()
        view.backgroundColor = options.transparentBackground ? .clear : options.resolvedBackground.nsColor
        if camera.projection != options.projection { camera.projection = options.projection }
    }

    /// Outline post-process for the live view (recomputed on resize and option changes).
    func refreshOutline() {
        view.technique = outlineTechnique(heightPixels: Double(view.bounds.height) * Double(view.window?.backingScaleFactor ?? 2),
                                          pointScale: Double(view.window?.backingScaleFactor ?? 2))
    }
    /// Technique for a target of `heightPixels` device pixels, outline width scaled by `pointScale` px/pt.
    func outlineTechnique(heightPixels: Double, pointScale: Double) -> SCNTechnique? {
        guard options.outline, heightPixels > 1 else { return nil }
        let fov = Double(cameraNode.camera?.fieldOfView ?? 60) * .pi / 180
        return OutlineTechnique.technique(color: options.resolvedOutlineColor, widthPixels: options.outlineWidth * pointScale,
                                          pixelAngle: 2 * tan(fov / 2) / heightPixels)
    }

    // MARK: Cartoon

    /// Puts the cartoon visibility mask on `options` (or removes it when the style is not `.cartoon`).
    func refreshAtomMask() {
        guard options.style == .cartoon else {
            if !options.atomMask.state.isEmpty { options.atomMask = .none }
            return
        }
        let p = proteinStructure()
        let mask = CartoonLayerBuilder.mask(p, atomCount: molecule.atoms.count, hideWater: options.cartoonHidesWater)
        if options.atomMask.state != mask.state { options.atomMask = mask }
    }

    /// The protein analysis of the current molecule, computed on first use.
    @discardableResult public func proteinStructure() -> ProteinStructure {
        if let p = protein, p.atomCount == molecule.atoms.count { return p }
        let p = ProteinAnalysis.looksLikeProtein(molecule) ? ProteinAnalysis.analyze(molecule, records: proteinRecords) : {
            var e = ProteinStructure.empty
            e.atomCount = molecule.atoms.count
            e.polymerAtoms = [Bool](repeating: false, count: molecule.atoms.count); e.waterAtoms = e.polymerAtoms
            return e
        }()
        protein = p
        return p
    }

    func rebuildCartoon() {
        guard options.style == .cartoon else {
            if cartoonLayer.parent != nil || !cartoonLayer.childNodes.isEmpty { replace(&cartoonLayer, with: emptyNode(NodeName.cartoon)) }
            return
        }
        var st = CartoonLayerBuilder.Stats()
        let node = CartoonLayerBuilder.build(protein: proteinStructure(), molecule: molecule, options: options, materials: materials, stats: &st)
        cartoonStats = st
        replace(&cartoonLayer, with: node)
    }

    func replace(_ layer: inout SCNNode, with new: SCNNode) {
        if vibration?.isGPUActive == true, new.name == NodeName.atoms || new.name == NodeName.bonds { new.isHidden = true }
        layer.removeFromParentNode()
        layer = new
        root.addChildNode(new)
    }

    /// Seconds of continuous rendering after the last view size change (see `keepRenderingAfterResize`).
    static let resizeSettleSeconds = 2.5

    /// SceneKit allocates the HDR and deferred-shadow render targets for every drawable size it is given and evicts
    /// unused ones only while it keeps rendering frames. An on-demand view stops drawing as soon as a resize (or the
    /// launch layout) ends, so every intermediate size stayed resident: a 60-step window resize grew the process by
    /// ~7 GB of GPU memory. Rendering the unchanged scene for a moment after the last size change lets SceneKit
    /// release them (the picture is identical; the view returns to on-demand drawing afterwards).
    func keepRenderingAfterResize() {
        resizeSettleDeadline = ProcessInfo.processInfo.systemUptime + Self.resizeSettleSeconds
        guard !resizeSettleActive else { return }
        resizeSettleActive = true
        view.rendersContinuously = true
        scheduleResizeSettleCheck(after: Self.resizeSettleSeconds)
    }
    private func scheduleResizeSettleCheck(after t: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.resizeSettleActive else { return }
                let left = self.resizeSettleDeadline - ProcessInfo.processInfo.systemUptime
                if left > 0.01 { self.scheduleResizeSettleCheck(after: left); return }
                self.resizeSettleActive = false
                if self.vibration?.isGPUActive != true && self.frameProbe.isIdle { self.view.rendersContinuously = false }
            }
        }
    }

    /// Returns free malloc pages to the system (off the main thread; coalesced while one is pending).
    public nonisolated static func releaseFreedMemory() {
        guard reliefPending.testAndSet() else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
            reliefPending.clear()
            malloc_zone_pressure_relief(nil, 0)
        }
    }
    private nonisolated static let reliefPending = AtomicFlag()

    func emptyNode(_ name: String) -> SCNNode { let n = SCNNode(); n.name = name; return n }

    // MARK: Introspection (used by checks and the app's status bar)

    /// Number of SCNGeometry-bearing nodes in a layer (recursive).
    public func geometryNodeCount(layer: String) -> Int {
        guard let n = root.childNode(withName: layer, recursively: false) else { return 0 }
        var c = 0
        n.enumerateHierarchy { node, _ in if node.geometry != nil { c += 1 } }
        return c
    }
    /// Layer names usable with `geometryNodeCount`.
    public static let layerNames = (atoms: NodeName.atoms, bonds: NodeName.bonds, highlight: NodeName.highlight,
                                    labels: NodeName.labels, measurements: NodeName.measurements,
                                    surfaces: NodeName.surfaces, cell: NodeName.cell, vectors: NodeName.vectors,
                                    cartoon: NodeName.cartoon)
}

/// Minimal lock-protected flag.
final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var set = false
    /// Sets the flag; true if it was clear.
    func testAndSet() -> Bool { lock.lock(); defer { lock.unlock() }; if set { return false }; set = true; return true }
    func clear() { lock.lock(); set = false; lock.unlock() }
}
