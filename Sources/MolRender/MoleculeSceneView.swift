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
    private var tracking: NSTrackingArea?
    static let clickSlop: CGFloat = 3

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
        default: break
        }
        dragMode = .none; downPoint = nil
    }
    public override func rightMouseDragged(with e: NSEvent) {
        renderer?.camera.pan(dx: Double(e.deltaX), dy: Double(e.deltaY), viewSize: bounds.size)
    }
    public override func otherMouseDragged(with e: NSEvent) {
        renderer?.camera.pan(dx: Double(e.deltaX), dy: Double(e.deltaY), viewSize: bounds.size)
    }
    public override func mouseMoved(with e: NSEvent) { renderer?.picking.hover(at: loc(e)) }
    public override func mouseExited(with e: NSEvent) { renderer?.picking.hover(at: nil) }

    public override func scrollWheel(with e: NSEvent) {
        guard let r = renderer else { return }
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
    public override func magnify(with e: NSEvent) { renderer?.camera.zoom(by: 1 + Double(e.magnification)) }
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
