import SceneKit
import AppKit
import QuartzCore
import simd
import MolCore

@MainActor public final class PickingController {
    unowned let renderer: MoleculeRenderer
    private var boxStart: CGPoint?
    private var boxLayer: CAShapeLayer?
    var lassoPoints: [CGPoint] = []
    var lassoLayer: CAShapeLayer?
    var moveStart: [Vec3]?
    private var lastHover: (point: CGPoint, revision: Int)?
    private var lastHoverTime: TimeInterval = 0
    /// Seconds since the last applied hover pick (for throttling checks).
    public var timeSinceLastHover: TimeInterval { ProcessInfo.processInfo.systemUptime - lastHoverTime }
    private var pendingHoverPoint: CGPoint?
    /// Minimum interval between hover picks (s): coalesces mouse-move bursts to ~display rate.
    public static let hoverInterval: TimeInterval = 1.0 / 120

    init(renderer: MoleculeRenderer) { self.renderer = renderer }

    /// World-space pick ray for a view point (AppKit coordinates).
    func ray(at point: CGPoint) -> (origin: Vec3, dir: Vec3)? {
        let v = renderer.view
        let p0 = v.unprojectPoint(SCNVector3(point.x, point.y, 0))
        let p1 = v.unprojectPoint(SCNVector3(point.x, point.y, 1))
        let o = p0.vec3, d = p1.vec3 - o
        guard o.x.isFinite, d.x.isFinite, simd_length(d) > 1e-12 else { return nil }
        return (o, d)
    }

    func hitTest(_ point: CGPoint) -> PickTarget {
        guard let r = ray(at: point) else { return .none }
        return PickMath.pick(origin: r.origin, dir: r.dir, molecule: renderer.molecule, options: renderer.options)?.0 ?? .none
    }

    func click(at point: CGPoint, modifiers: NSEvent.ModifierFlags, clickCount: Int) {
        let target = hitTest(point)
        renderer.onPick?(PickEvent(target: target, modifiers: modifiers, clickCount: clickCount, location: point))
        guard renderer.autoSelect else { return }
        let shift = modifiers.contains(.shift), cmd = modifiers.contains(.command)
        var sel = renderer.selection
        let mol = renderer.molecule
        switch target {
        case .atom(let i):
            if clickCount >= 2 {
                if renderer.centerOnDoubleClick { renderer.centerOn(atom: i) }
                let frag = Set(mol.fragment(containing: i))
                if cmd { sel.formSymmetricDifference(frag.isSubset(of: sel) ? frag : frag.subtracting(sel)) }
                else if shift { sel.formUnion(frag) }
                else { sel = frag }
            } else if cmd {
                if sel.contains(i) { sel.remove(i) } else { sel.insert(i) }
            } else if shift { sel.insert(i) }
            else { sel = [i] }
        case .bond(let k):
            guard k < mol.bonds.count else { break }
            let pair: Set<Int> = [mol.bonds[k].a, mol.bonds[k].b]
            if cmd { if pair.isSubset(of: sel) { sel.subtract(pair) } else { sel.formUnion(pair) } }
            else if shift { sel.formUnion(pair) }
            else { sel = pair }
        case .none:
            if !shift && !cmd { sel = [] }
        }
        if sel != renderer.selection { renderer.selection = sel }
    }

    /// Hover pick, throttled to `hoverInterval` (the last point of a burst is always picked) and cached:
    /// the same point with an unchanged camera/scene (`renderer.hoverRevision`) is not re-picked.
    func hover(at point: CGPoint?, throttled: Bool = false) {
        guard let p = point else {
            pendingHoverPoint = nil; lastHover = nil
            renderer.lastHoverLocation = nil
            if renderer.hovered != .none { renderer.hovered = .none } else { renderer.pushHoverTooltip() }
            return
        }
        if let l = lastHover, l.revision == renderer.hoverRevision, abs(l.point.x - p.x) < 0.5, abs(l.point.y - p.y) < 0.5 { return }
        let now = ProcessInfo.processInfo.systemUptime
        let wait = Self.hoverInterval - (now - lastHoverTime)
        if throttled && wait > 0 {
            let first = pendingHoverPoint == nil
            pendingHoverPoint = p
            if first {
                DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, let q = self.pendingHoverPoint else { return }
                        self.pendingHoverPoint = nil
                        self.pickHover(q)
                    }
                }
            }
            return
        }
        pendingHoverPoint = nil
        pickHover(p)
    }

    private func pickHover(_ p: CGPoint) {
        lastHoverTime = ProcessInfo.processInfo.systemUptime
        lastHover = (p, renderer.hoverRevision)
        let t = hitTest(p)
        renderer.lastHoverLocation = p
        if t != renderer.hovered { renderer.hovered = t }
    }

    // MARK: Rubber band

    public func beginBox(at point: CGPoint) {
        boxStart = point
        let v = renderer.view
        if v.layer == nil { v.wantsLayer = true }
        let l = CAShapeLayer()
        l.fillColor = renderer.options.selectionColor.withAlpha(0.18).cgColor
        l.strokeColor = renderer.options.selectionColor.withAlpha(0.9).cgColor
        l.lineWidth = 1
        l.lineDashPattern = [4, 3]
        l.zPosition = 1000
        v.layer?.addSublayer(l)
        boxLayer = l
        updateBox(to: point)
    }

    private func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    private func updateBox(to p: CGPoint) {
        guard let s = boxStart, let l = boxLayer else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        l.path = CGPath(rect: rect(from: s, to: p), transform: nil)
        CATransaction.commit()
    }

    public func dragBox(to point: CGPoint) { updateBox(to: point) }

    /// True while a rubber-band overlay is shown.
    var hasBoxOverlay: Bool { boxLayer?.superlayer != nil }

    /// Pickable atoms whose projection lies in `r` and in front of the camera. Like click picking and the lasso this
    /// honours `RenderOptions.atomMask`: in the cartoon style only the residues' CA stand-ins (and atoms still drawn,
    /// e.g. ligands) are boxed, never the atoms hidden under the cartoon.
    func atoms(in r: CGRect) -> Set<Int> {
        let v = renderer.view
        let mol = renderer.molecule
        let options = renderer.options
        var proj = [CGPoint?](repeating: nil, count: mol.atoms.count)
        for (i, a) in mol.atoms.enumerated() where RenderMetrics.isAtomPickable(i, in: mol, options: options) {
            let p = v.projectPoint(SCNVector3(a.position))
            if p.z >= 0, p.z <= 1, p.x.isFinite, p.y.isFinite { proj[i] = CGPoint(x: p.x, y: p.y) }
        }
        return PickMath.atomsInRect(projected: proj, rect: r)
    }

    public func endBox(at point: CGPoint, modifiers: NSEvent.ModifierFlags) {
        defer { boxLayer?.removeFromSuperlayer(); boxLayer = nil; boxStart = nil }
        guard let s = boxStart else { return }
        let inside = atoms(in: rect(from: s, to: point))
        renderer.onBoxSelect?(inside, modifiers)
        guard renderer.autoSelect else { return }
        var sel = renderer.selection
        if modifiers.contains(.command) { sel.subtract(inside) } else { sel.formUnion(inside) }
        if sel != renderer.selection { renderer.selection = sel }
    }
}

// MARK: - Public hooks (used by the app's tests/automation and checks)

extension MoleculeRenderer {
    /// Simulate a click at a view point (same path as a real mouse click).
    public func performClick(at point: CGPoint, modifiers: NSEvent.ModifierFlags = [], clickCount: Int = 1) {
        picking.click(at: point, modifiers: modifiers, clickCount: clickCount)
    }
    /// Simulate a rubber-band drag from `from` to `to`.
    public func performBoxSelect(from: CGPoint, to: CGPoint, modifiers: NSEvent.ModifierFlags = [.shift]) {
        picking.beginBox(at: from); picking.dragBox(to: to); picking.endBox(at: to, modifiers: modifiers)
    }
    /// Visible atoms whose screen projection lies inside `rect` (view coordinates).
    public func atomsInViewRect(_ rect: CGRect) -> Set<Int> { picking.atoms(in: rect) }
    /// Simulate a mouse-move hover.
    public func performHover(at point: CGPoint?) { picking.hover(at: point) }
    /// World-space pick ray through a view point.
    public func pickRay(at point: CGPoint) -> (origin: Vec3, direction: Vec3)? {
        picking.ray(at: point).map { ($0.origin, $0.dir) }
    }
}
