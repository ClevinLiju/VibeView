import SwiftUI
import SceneKit
import AppKit
import MolCore

/// SwiftUI wrapper. The renderer is owned by the caller (keep it in a @State / model object)
/// so its camera and selection survive SwiftUI view updates.
public struct MoleculeSceneView: NSViewRepresentable {
    public let renderer: MoleculeRenderer
    public init(renderer: MoleculeRenderer) { self.renderer = renderer }
    public func makeNSView(context: Context) -> MoleculeSCNView { renderer.view }
    public func updateNSView(_ nsView: MoleculeSCNView, context: Context) {}
}

/// SCNView subclass that routes mouse/trackpad input:
/// - left drag: orbit; option-drag / right-drag / middle-drag: pan; shift-drag: rubber-band select
/// - click: pick (modifiers passed through); mouse wheel: zoom; trackpad two-finger scroll: orbit
///   (shift + scroll: pan); pinch: zoom; two-finger rotate: roll
/// - keys: F = fit, 1/3/7 = front/right/top (with ctrl = opposite), O = toggle ortho/persp
public final class MoleculeSCNView: SCNView {
    weak var renderer: MoleculeRenderer?
    private var downPoint: CGPoint?
    private var dragMode: DragMode = .none
    private enum DragMode { case none, orbit, pan, box }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        renderer?.refreshOutline()
    }
    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        renderer?.refreshOutline()
    }
    private var tracking: NSTrackingArea?
    static let clickSlop: CGFloat = 3
    private var samples: [(t: TimeInterval, dx: Double, dy: Double)] = []

    private func record(_ e: NSEvent) {
        samples.append((e.timestamp, Double(e.deltaX), Double(e.deltaY)))
        if samples.count > 12 { samples.removeFirst(samples.count - 12) }
    }
    /// Release velocity (points/s) from drags in the last ~80 ms before the release; zero if the pointer paused.
    private func releaseVelocity(at t: TimeInterval) -> SIMD2<Double> {
        let recent = samples.filter { t - $0.t <= 0.08 }
        defer { samples.removeAll() }
        guard let first = recent.first, let last = recent.last, last.t > first.t, t - last.t < 0.05 else { return .zero }
        let span = max(last.t - first.t, 1.0 / 60)
        return SIMD2(recent.reduce(0) { $0 + $1.dx }, recent.reduce(0) { $0 + $1.dy }) / span
    }

    public override var acceptsFirstResponder: Bool { true }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(t); tracking = t
    }

    private func loc(_ e: NSEvent) -> CGPoint { convert(e.locationInWindow, from: nil) }

    public override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        renderer?.camera.cancelMotion(); samples.removeAll()
        downPoint = loc(e); dragMode = .none
    }
    public override func mouseDragged(with e: NSEvent) {
        guard let r = renderer, let d = downPoint else { return }
        let p = loc(e)
        if dragMode == .none {
            guard hypot(p.x - d.x, p.y - d.y) > Self.clickSlop else { return }
            if e.modifierFlags.contains(.shift) { dragMode = .box; r.picking.beginBox(at: d) }
            else if e.modifierFlags.contains(.option) { dragMode = .pan }
            else { dragMode = .orbit }
        }
        if dragMode == .orbit || dragMode == .pan { record(e) }
        switch dragMode {
        case .orbit: r.camera.orbit(dx: Double(e.deltaX), dy: Double(e.deltaY))
        case .pan: r.camera.pan(dx: Double(e.deltaX), dy: Double(e.deltaY), viewSize: bounds.size)
        case .box: r.picking.dragBox(to: p)
        case .none: break
        }
    }
    public override func mouseUp(with e: NSEvent) {
        guard let r = renderer else { return }
        let p = loc(e)
        switch dragMode {
        case .none: r.picking.click(at: p, modifiers: e.modifierFlags, clickCount: e.clickCount)
        case .box: r.picking.endBox(at: p, modifiers: e.modifierFlags)
        case .orbit: r.camera.startInertia(orbitVelocity: releaseVelocity(at: e.timestamp))
        case .pan: r.camera.startPanInertia(velocity: releaseVelocity(at: e.timestamp), viewSize: bounds.size)
        }
        dragMode = .none; downPoint = nil
    }
    public override func rightMouseDown(with e: NSEvent) { renderer?.camera.cancelMotion(); samples.removeAll() }
    public override func otherMouseDown(with e: NSEvent) { renderer?.camera.cancelMotion(); samples.removeAll() }
    public override func rightMouseDragged(with e: NSEvent) { panDrag(e) }
    public override func otherMouseDragged(with e: NSEvent) { panDrag(e) }
    public override func rightMouseUp(with e: NSEvent) { panRelease(e) }
    public override func otherMouseUp(with e: NSEvent) { panRelease(e) }
    private func panDrag(_ e: NSEvent) {
        record(e)
        renderer?.camera.pan(dx: Double(e.deltaX), dy: Double(e.deltaY), viewSize: bounds.size)
    }
    private func panRelease(_ e: NSEvent) {
        renderer?.camera.startPanInertia(velocity: releaseVelocity(at: e.timestamp), viewSize: bounds.size)
    }
    public override func mouseMoved(with e: NSEvent) { renderer?.picking.hover(at: loc(e)) }
    public override func mouseExited(with e: NSEvent) { renderer?.picking.hover(at: nil) }

    public override func scrollWheel(with e: NSEvent) {
        guard let r = renderer else { return }
        // System-provided momentum events already carry the inertia; no extra inertia here.
        if e.hasPreciseScrollingDeltas {
            if e.modifierFlags.contains(.shift) {
                r.camera.pan(dx: Double(e.scrollingDeltaX), dy: -Double(e.scrollingDeltaY), viewSize: bounds.size)
            } else if e.modifierFlags.contains(.command) {
                r.camera.zoom(by: exp(Double(e.scrollingDeltaY) * 0.01))
            } else {
                r.camera.orbit(dx: Double(e.scrollingDeltaX), dy: Double(e.scrollingDeltaY))
            }
        } else {
            r.camera.zoom(by: exp(Double(e.scrollingDeltaY) * 0.1))
        }
    }
    public override func magnify(with e: NSEvent) { renderer?.camera.zoom(by: exp(Double(e.magnification))) }
    public override func smartMagnify(with e: NSEvent) { renderer?.fitToView(animated: true) }
    public override func rotate(with e: NSEvent) { renderer?.camera.roll(radians: Double(e.rotation) * .pi / 180) }

    public override func keyDown(with e: NSEvent) {
        guard let r = renderer, let ch = e.charactersIgnoringModifiers?.lowercased() else { return super.keyDown(with: e) }
        let opp = e.modifierFlags.contains(.control)
        switch ch {
        case "f": r.fitToView()
        case "1": r.camera.setStandardView(opp ? .back : .front, animated: true)
        case "3": r.camera.setStandardView(opp ? .left : .right, animated: true)
        case "7": r.camera.setStandardView(opp ? .bottom : .top, animated: true)
        case "o": r.options.projection = r.options.projection == .perspective ? .orthographic : .perspective
        default: super.keyDown(with: e)
        }
    }
}
