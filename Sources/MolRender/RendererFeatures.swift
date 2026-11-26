import SceneKit
import AppKit
import QuartzCore
import simd
import MolCore

/// Pointer tool for left-drags in the 3D view (round 3).
/// - rotate: drag orbits (default; shift-drag = box select, shift-option-drag = lasso).
/// - boxSelect / lasso: drag selects; none = replace, shift = add, command or option = subtract.
/// - moveSelection: drag translates the selected atoms in the view plane, option-drag rotates them about
///   their centroid; with an empty selection the drag orbits.
public enum DragTool: String, Sendable, CaseIterable { case rotate, boxSelect, lasso, moveSelection }

enum FeatureNodeName {
    static let hbonds = "vibeview.hbonds"
}

// MARK: - Hydrogen-bond layer

enum HydrogenBondLayerBuilder {
    static func build(molecule: Molecule, options: RenderOptions) -> SCNNode {
        let layer = SCNNode(); layer.name = FeatureNodeName.hbonds
        guard options.showHydrogenBonds else { return layer }
        let hb = HydrogenBonds.find(in: molecule, maxDistance: options.hydrogenBondMaxDistance, minAngle: options.hydrogenBondMinAngle)
        guard !hb.isEmpty else { return layer }
        let mat = SCNMaterial()
        mat.lightingModel = .constant
        mat.diffuse.contents = options.hydrogenBondColor.nsColor
        let unit = SCNCylinder(radius: 0.035, height: 1)
        unit.radialSegmentCount = 8
        unit.firstMaterial = mat
        for b in hb {
            let a = molecule.atoms[b.hydrogen].position, c = molecule.atoms[b.acceptor].position
            // Trim at the atom surfaces, then dash.
            let ra = RenderMetrics.atomRadius(atomicNumber: 1, options: options) * 0.9
            let rc = RenderMetrics.atomRadius(atomicNumber: molecule.atoms[b.acceptor].atomicNumber, options: options) * 0.9
            let d = c - a, len = simd_length(d)
            guard len > ra + rc + 0.1 else { continue }
            let u = d / len
            let seg = BondSegment(start: a + u * ra, end: c - u * rc, radius: 0.035, color: options.hydrogenBondColor, dashed: true, bondIndex: -1)
            var dashes = BondGeometry.expandDashes([seg])
            if dashes.count < 3 { dashes = [seg] }
            for s in dashes {
                let n = SCNNode(geometry: unit)
                BondLayerBuilder.place(n, s)
                n.name = "hbond:\(b.hydrogen):\(b.acceptor)"
                layer.addChildNode(n)
            }
        }
        return layer
    }
}

// MARK: - Renderer features

extension MoleculeRenderer {
    /// Hydrogen bonds for the current coordinates and criteria (whether or not they are shown).
    public func hydrogenBonds() -> [HydrogenBond] {
        HydrogenBonds.find(in: molecule, maxDistance: options.hydrogenBondMaxDistance, minAngle: options.hydrogenBondMinAngle)
    }

    /// Current values of `options.measurements` (Å or degrees), in order; updated live during vibration
    /// (when overlays follow) and trajectory playback. See also `onMeasurementValues`.
    public func measurementValues() -> [Double] {
        options.measurements.map { ms in
            guard ms.atoms.allSatisfy({ $0 >= 0 && $0 < molecule.atoms.count }) else { return .nan }
            switch ms {
            case let .distance(a, b): return molecule.distance(a, b)
            case let .angle(a, b, c): return molecule.angle(a, b, c)
            case let .dihedral(a, b, c, d): return molecule.dihedral(a, b, c, d)
            }
        }
    }

    /// Animate the camera target to an atom (distance and orientation kept).
    public func centerOn(atom i: Int, animated: Bool = true) {
        guard i >= 0, i < molecule.atoms.count else { return }
        var s = camera.state
        s.target = molecule.atoms[i].position
        camera.setState(s, animated: animated)
    }

    /// Å per view point at the camera target depth (for scale bars and drag mapping).
    public func worldPerPointAtTarget() -> Double {
        SelectionMoveMath.worldPerPoint(depth: camera.distance, verticalFOVDegrees: Double(cameraNode.camera?.fieldOfView ?? 60),
                                        viewHeight: Double(view.bounds.height), projection: camera.projection,
                                        orthographicScale: camera.orthographicScale)
    }

    // Slab clipping: near/far planes relative to the camera target.
    func applySlab() {
        guard let cam = cameraNode.camera else { return }
        if slabDefaults == nil {
            guard options.slabNear != nil || options.slabFar != nil else { return }
            slabDefaults = (cam.zNear, cam.zFar)
        }
        guard let d = slabDefaults else { return }
        cam.zNear = options.slabNear.map { max(0.01, camera.distance - $0) } ?? d.near
        cam.zFar = options.slabFar.map { max(cam.zNear + 0.01, camera.distance + $0) } ?? d.far
        if options.slabNear == nil && options.slabFar == nil { slabDefaults = nil }
    }

    // MARK: Axes / scale bar (CALayer overlay on the live view)

    func refreshAnnotations() {
        let v = view
        if v.layer == nil { v.wantsLayer = true }
        guard let host = v.layer else { return }
        let fg = options.theme.foreground.nsColor.cgColor
        // Axes
        let axesName = "vibeview.axes", barName = "vibeview.scalebar"
        host.sublayers?.filter { $0.name == axesName || $0.name == barName }.forEach { $0.removeFromSuperlayer() }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if options.showAxes {
            let g = CALayer(); g.name = axesName; g.zPosition = 900
            let origin = CGPoint(x: 44, y: 44), len: CGFloat = 30
            let inv = camera.orientation.inverse
            let axes: [(Vec3, NSColor, String)] = [(Vec3(1, 0, 0), .systemRed, "x"), (Vec3(0, 1, 0), .systemGreen, "y"), (Vec3(0, 0, 1), .systemBlue, "z")]
            // draw back-to-front
            for (w, c, name) in axes.sorted(by: { inv.act($0.0).z < inv.act($1.0).z }) {
                let e = inv.act(w)
                let tip = CGPoint(x: origin.x + CGFloat(e.x) * len, y: origin.y + CGFloat(e.y) * len)
                let line = CAShapeLayer()
                let path = CGMutablePath(); path.move(to: origin); path.addLine(to: tip)
                line.path = path; line.strokeColor = c.cgColor; line.lineWidth = 2.2; line.lineCap = .round
                g.addSublayer(line)
                let t = CATextLayer(); t.string = name; t.fontSize = 11; t.foregroundColor = c.cgColor
                t.contentsScale = v.window?.backingScaleFactor ?? 2; t.alignmentMode = .center
                t.frame = CGRect(x: origin.x + CGFloat(e.x) * (len + 9) - 6, y: origin.y + CGFloat(e.y) * (len + 9) - 7, width: 12, height: 14)
                g.addSublayer(t)
            }
            host.addSublayer(g)
        }
        if options.showScaleBar {
            let wpp = worldPerPointAtTarget()
            let (ang, pts) = ScaleBarMath.niceLength(worldPerPoint: wpp, targetPoints: 90)
            guard pts > 4, pts < Double(v.bounds.width) else { return }
            let g = CALayer(); g.name = barName; g.zPosition = 900
            let x0 = v.bounds.width - 24 - CGFloat(pts), y0: CGFloat = 22
            let bar = CAShapeLayer()
            let p = CGMutablePath()
            p.move(to: CGPoint(x: x0, y: y0 + 4)); p.addLine(to: CGPoint(x: x0, y: y0))
            p.addLine(to: CGPoint(x: x0 + CGFloat(pts), y: y0)); p.addLine(to: CGPoint(x: x0 + CGFloat(pts), y: y0 + 4))
            bar.path = p; bar.strokeColor = fg; bar.fillColor = nil; bar.lineWidth = 1.5
            g.addSublayer(bar)
            let t = CATextLayer(); t.string = ScaleBarMath.label(ang); t.fontSize = 10.5; t.foregroundColor = fg
            t.contentsScale = v.window?.backingScaleFactor ?? 2; t.alignmentMode = .center
            t.frame = CGRect(x: x0, y: y0 + 5, width: CGFloat(pts), height: 14)
            g.addSublayer(t)
            host.addSublayer(g)
        }
    }

    // MARK: Lasso / move selection (programmatic entry points, same paths as the mouse)

    /// Atoms (visible, in front of the camera) whose projection lies inside a view-space polygon.
    public func atomsInViewPolygon(_ polygon: [CGPoint]) -> Set<Int> {
        LassoMath.atomsInPolygon(projected: picking.projectedAtoms(), polygon: polygon)
    }
    /// Simulate a lasso drag through `points` (view coordinates).
    public func performLassoSelect(_ points: [CGPoint], modifiers: NSEvent.ModifierFlags = []) {
        guard let f = points.first else { return }
        picking.beginLasso(at: f)
        for p in points.dropFirst() { picking.dragLasso(to: p) }
        picking.endLasso(modifiers: modifiers)
    }
    /// Simulate a move-selection drag: translate by (dx, dy) points (rotate = true: rotate about the centroid).
    public func performSelectionDrag(dx: Double, dy: Double, rotate: Bool = false) {
        guard picking.beginMove() else { return }
        picking.dragMove(dx: dx, dy: dy, rotate: rotate)
        picking.endMove()
    }
}

// MARK: - Picking: lasso + move

extension PickingController {
    func projectedAtoms() -> [CGPoint?] {
        let v = renderer.view
        let mol = renderer.molecule
        var proj = [CGPoint?](repeating: nil, count: mol.atoms.count)
        for (i, a) in mol.atoms.enumerated() where RenderMetrics.isAtomPickable(i, in: mol, options: renderer.options) {
            let p = v.projectPoint(SCNVector3(a.position))
            if p.z >= 0, p.z <= 1, p.x.isFinite, p.y.isFinite { proj[i] = CGPoint(x: p.x, y: p.y) }
        }
        return proj
    }

    func beginLasso(at p: CGPoint) {
        lassoPoints = [p]
        let v = renderer.view
        if v.layer == nil { v.wantsLayer = true }
        let l = CAShapeLayer()
        l.fillColor = renderer.options.selectionColor.withAlpha(0.15).cgColor
        l.strokeColor = renderer.options.selectionColor.withAlpha(0.95).cgColor
        l.lineWidth = 1.2; l.lineDashPattern = [5, 3]; l.zPosition = 1000
        v.layer?.addSublayer(l)
        lassoLayer = l
    }
    func dragLasso(to p: CGPoint) {
        LassoMath.appendSample(&lassoPoints, p)
        guard let l = lassoLayer, let f = lassoPoints.first else { return }
        let path = CGMutablePath(); path.move(to: f)
        for q in lassoPoints.dropFirst() { path.addLine(to: q) }
        path.closeSubpath()
        CATransaction.begin(); CATransaction.setDisableActions(true); l.path = path; CATransaction.commit()
    }
    func endLasso(modifiers: NSEvent.ModifierFlags) {
        defer { lassoLayer?.removeFromSuperlayer(); lassoLayer = nil; lassoPoints = [] }
        let hit = LassoMath.atomsInPolygon(projected: projectedAtoms(), polygon: lassoPoints)
        renderer.onLassoSelect?(hit, modifiers)
        guard renderer.autoSelect else { return }
        let mode = SelectionCombine.from(shift: modifiers.contains(.shift), command: modifiers.contains(.command),
                                         option: modifiers.contains(.option) && !modifiers.contains(.shift))
        let sel = mode.apply(hit, to: renderer.selection)
        if sel != renderer.selection { renderer.selection = sel }
    }

    /// Start moving the selection; false when nothing is selected.
    func beginMove() -> Bool {
        let sel = renderer.selection.filter { $0 < renderer.molecule.atoms.count }
        guard !sel.isEmpty else { return false }
        moveStart = renderer.molecule.atoms.map(\.position)
        return true
    }
    func dragMove(dx: Double, dy: Double, rotate: Bool) {
        guard moveStart != nil else { return }
        let cam = renderer.camera!
        var pos = renderer.molecule.atoms.map(\.position)
        let sel = renderer.selection
        if rotate {
            let r = SelectionMoveMath.dragRotation(dx: dx, dy: dy, right: cam.rightVector, up: cam.upVector)
            pos = SelectionMoveMath.rotate(pos, selection: sel, axis: r.axis, angle: r.angle)
        } else {
            let c = SelectionMoveMath.centroid(pos, selection: sel) ?? cam.target
            let depth = max(0.1, simd_dot(c - cam.eye, cam.lookDirection))
            let wpp = SelectionMoveMath.worldPerPoint(depth: depth, verticalFOVDegrees: Double(renderer.cameraNode.camera?.fieldOfView ?? 60),
                                                      viewHeight: Double(renderer.view.bounds.height), projection: cam.projection,
                                                      orthographicScale: cam.orthographicScale)
            pos = SelectionMoveMath.translate(pos, selection: sel, by: SelectionMoveMath.viewPlaneDelta(dx: dx, dy: dy, right: cam.rightVector, up: cam.upVector, worldPerPoint: wpp))
        }
        renderer.updatePositions(pos)
    }
    func endMove() {
        guard let before = moveStart else { return }
        moveStart = nil
        let after = renderer.molecule.atoms.map(\.position)
        if after != before { renderer.onSelectionMoved?(before, after) }
    }
}
