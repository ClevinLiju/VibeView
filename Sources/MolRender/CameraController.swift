import SceneKit
import QuartzCore
import simd
import MolCore

public enum StandardView: String, Sendable, CaseIterable { case front, back, left, right, top, bottom, alongX, alongY, alongZ }

/// Pure camera math (no SceneKit objects), testable from checks.
public enum CameraMath {
    /// Distance from the sphere center so that a sphere of `radius * margin` fits inside both the vertical
    /// FOV and the horizontal FOV implied by `aspect` (width / height).
    public static func fitDistance(radius: Double, verticalFOVDegrees: Double, aspect: Double, margin: Double = 1.12) -> Double {
        let v = degToRad(max(1, min(170, verticalFOVDegrees))) / 2
        let a = aspect.isFinite && aspect > 1e-6 ? aspect : 1
        let h = atan(tan(v) * a)
        return radius * margin / sin(min(v, h))
    }
    /// Camera orientation (camera looks along its local -z, up is +y) for a standard view.
    /// front: eye on +z; right: eye on +x; top: eye on +y (screen up = -z). alongX/Y/Z view down the
    /// axis from its positive side (identical to right/top/front).
    public static func orientation(for v: StandardView) -> simd_quatd {
        func q(_ deg: Double, _ axis: Vec3) -> simd_quatd { simd_quatd(angle: degToRad(deg), axis: axis) }
        switch v {
        case .front, .alongZ: return simd_quatd(angle: 0, axis: Vec3(0, 1, 0))
        case .back: return q(180, Vec3(0, 1, 0))
        case .right, .alongX: return q(90, Vec3(0, 1, 0))
        case .left: return q(-90, Vec3(0, 1, 0))
        case .top, .alongY: return q(-90, Vec3(1, 0, 0))
        case .bottom: return q(90, Vec3(1, 0, 0))
        }
    }
    public static func lookDirection(_ q: simd_quatd) -> Vec3 { q.act(Vec3(0, 0, -1)) }
    public static func upVector(_ q: simd_quatd) -> Vec3 { q.act(Vec3(0, 1, 0)) }
    public static func rightVector(_ q: simd_quatd) -> Vec3 { q.act(Vec3(1, 0, 0)) }
}

/// Serializable camera pose.
public struct CameraState: Codable, Equatable, Sendable {
    public var target: Vec3
    public var distance: Double
    /// Quaternion as (ix, iy, iz, r).
    public var orientation: SIMD4<Double>
    public var orthographicScale: Double
    public var sceneRadius: Double
    public var projection: ProjectionMode
}

@MainActor public final class CameraController {
    public let node: SCNNode
    public var projection: ProjectionMode = .perspective {
        didSet {
            guard projection != oldValue else { return }
            let t = tanHalfFOV
            if projection == .orthographic { orthoScale = max(Self.minScale, distance * t) }
            else { distance = min(Self.maxDistance, max(Self.minDistance, orthoScale / t)) }
            apply()
        }
    }
    /// Pivot point (Å) the camera orbits around, and eye distance from it (Å).
    public private(set) var target: Vec3 = .zero
    public private(set) var distance: Double = 20
    /// Half-height (Å) of the visible area in orthographic mode.
    public var orthographicScale: Double { orthoScale }
    /// Camera orientation (world), looking along its local -z.
    public private(set) var orientation = simd_quatd(angle: 0, axis: Vec3(0, 1, 0))
    /// Radius of the content last passed to `fit` (used for clip planes).
    public private(set) var sceneRadius: Double = 5
    /// Called after any camera move (renderer uses it to update fog / redraw).
    public var onChange: (() -> Void)?
    /// View aspect ratio (width / height) used by `fit`. Set this from the view's bounds.
    public var aspectProvider: (() -> Double)?
    public var fitMargin: Double = 1.12
    public var orbitSensitivity: Double = 0.01
    public var animationDuration: TimeInterval = 0.3

    private var orthoScale: Double = 7
    static let minDistance = 0.3, maxDistance = 1e4, minScale = 0.05

    public init(node: SCNNode) {
        self.node = node
        if node.camera == nil { node.camera = SCNCamera() }
        orthoScale = distance * tanHalfFOV
        apply()
    }

    private var fovDegrees: Double { Double(node.camera?.fieldOfView ?? 60) }
    private var tanHalfFOV: Double { tan(degToRad(max(1, min(170, fovDegrees))) / 2) }

    public var eye: Vec3 { target + orientation.act(Vec3(0, 0, distance)) }
    public var lookDirection: Vec3 { CameraMath.lookDirection(orientation) }
    public var upVector: Vec3 { CameraMath.upVector(orientation) }
    public var rightVector: Vec3 { CameraMath.rightVector(orientation) }

    // MARK: Moves

    /// Drag deltas in view points (AppKit: dy > 0 is a drag downwards).
    public func orbit(dx: Double, dy: Double) {
        guard dx.isFinite, dy.isFinite, dx != 0 || dy != 0 else { return }
        cancelMotion()
        orbitImpl(dx: dx, dy: dy)
    }
    private func orbitImpl(dx: Double, dy: Double) {
        let qy = simd_quatd(angle: -dx * orbitSensitivity, axis: Vec3(0, 1, 0))
        let qx = simd_quatd(angle: -dy * orbitSensitivity, axis: Vec3(1, 0, 0))
        orientation = simd_normalize(orientation * qy * qx)
        apply()
    }

    public func pan(dx: Double, dy: Double, viewSize: CGSize) {
        guard dx.isFinite, dy.isFinite, viewSize.height > 0 else { return }
        cancelMotion()
        panImpl(dx: dx, dy: dy, viewSize: viewSize)
    }
    private func panImpl(dx: Double, dy: Double, viewSize: CGSize) {
        let halfH = projection == .orthographic ? orthoScale : distance * tanHalfFOV
        let upp = 2 * halfH / Double(viewSize.height)
        target += -rightVector * (dx * upp) + upVector * (dy * upp)
        apply()
    }

    /// factor > 1 zooms in.
    public func zoom(by factor: Double) {
        guard factor.isFinite, factor > 1e-6 else { return }
        cancelMotion()
        if projection == .orthographic {
            orthoScale = min(Self.maxDistance, max(Self.minScale, orthoScale / factor))
        } else {
            distance = min(Self.maxDistance, max(Self.minDistance, distance / factor))
        }
        apply()
    }

    public func roll(radians: Double) {
        guard radians.isFinite, radians != 0 else { return }
        cancelMotion()
        orientation = simd_normalize(orientation * simd_quatd(angle: -radians, axis: Vec3(0, 0, 1)))
        apply()
    }

    public func fit(center: Vec3, radius: Double, animated: Bool = false) {
        cancelMotion()
        let r = max(radius, 0.1)
        let aspect = max(0.05, aspectProvider?() ?? 1)
        let from = state
        target = center
        sceneRadius = r
        distance = min(Self.maxDistance, CameraMath.fitDistance(radius: r, verticalFOVDegrees: fovDegrees, aspect: aspect, margin: fitMargin))
        if projection == .orthographic {
            orthoScale = max(Self.minScale, r * fitMargin * max(1, 1 / aspect))
        } else {
            orthoScale = max(Self.minScale, distance * tanHalfFOV)
        }
        if animated && animationDuration > 0 {
            let to = state
            state = from
            animate(to: to, duration: animationDuration)
        } else { apply() }
    }

    public func setStandardView(_ v: StandardView, animated: Bool = false) {
        var to = state
        let q = CameraMath.orientation(for: v)
        to.orientation = SIMD4(q.vector.x, q.vector.y, q.vector.z, q.vector.w)
        setState(to, animated: animated)
    }

    public func setState(_ s: CameraState, animated: Bool = false) {
        if animated && animationDuration > 0 { animate(to: s, duration: animationDuration) }
        else { cancelMotion(); state = s }
    }

    // MARK: Animation & inertia

    public var inertiaEnabled = true
    public private(set) var isAnimating = false
    public var isInertiaActive: Bool { orbitVel != .zero || panVel != .zero }
    private var animFrom: CameraState?
    private var animTo: CameraState?
    private var animElapsed = 0.0, animLength = 0.35
    private var orbitVel = SIMD2<Double>.zero   // points / second
    private var panVel = SIMD2<Double>.zero
    private var panViewSize = CGSize(width: 800, height: 600)
    static let inertiaTau = 0.3, inertiaStop = 8.0
    private var timer: Timer?
    private var lastTick: CFTimeInterval = 0

    /// Smoothly move to `s` (slerp orientation, lerp target, geometric distance / scale).
    public func animate(to s: CameraState, duration: TimeInterval = 0.35) {
        cancelMotion()
        guard duration > 0 else { state = s; return }
        animFrom = state; animTo = s
        animElapsed = 0; animLength = duration
        isAnimating = true
        startTimer()
    }

    public func startInertia(orbitVelocity v: SIMD2<Double>) {
        guard inertiaEnabled, v.x.isFinite, v.y.isFinite, simd_length(v) > Self.inertiaStop else { return }
        cancelMotion(); orbitVel = v; startTimer()
    }
    public func startPanInertia(velocity v: SIMD2<Double>, viewSize: CGSize) {
        guard inertiaEnabled, v.x.isFinite, v.y.isFinite, simd_length(v) > Self.inertiaStop, viewSize.height > 0 else { return }
        cancelMotion(); panVel = v; panViewSize = viewSize; startTimer()
    }
    public func stopInertia() { orbitVel = .zero; panVel = .zero; stopTimerIfIdle() }
    /// Cancels any in-flight animation and inertia (state stays where it is).
    public func cancelMotion() {
        isAnimating = false; animFrom = nil; animTo = nil
        orbitVel = .zero; panVel = .zero
        stopTimerIfIdle()
    }

    /// Advance animation and inertia by `dt` seconds (driven by the timer; callable directly for deterministic tests).
    public func advanceAnimation(by dt: TimeInterval) {
        guard dt > 0, dt.isFinite else { return }
        if isAnimating, let a = animFrom, let b = animTo {
            animElapsed += dt
            let u = min(1, animElapsed / animLength)
            if u >= 1 { isAnimating = false; animFrom = nil; animTo = nil; state = b }
            else {
                let e = u * u * (3 - 2 * u)
                state = Self.interpolate(a, b, e)
            }
        }
        if orbitVel != .zero {
            orbitImpl(dx: orbitVel.x * dt, dy: orbitVel.y * dt)
            orbitVel *= exp(-dt / Self.inertiaTau)
            if simd_length(orbitVel) < Self.inertiaStop { orbitVel = .zero }
        }
        if panVel != .zero {
            panImpl(dx: panVel.x * dt, dy: panVel.y * dt, viewSize: panViewSize)
            panVel *= exp(-dt / Self.inertiaTau)
            if simd_length(panVel) < Self.inertiaStop { panVel = .zero }
        }
        stopTimerIfIdle()
    }

    static func interpolate(_ a: CameraState, _ b: CameraState, _ e: Double) -> CameraState {
        var s = b
        let qa = simd_quatd(ix: a.orientation.x, iy: a.orientation.y, iz: a.orientation.z, r: a.orientation.w)
        var qb = simd_quatd(ix: b.orientation.x, iy: b.orientation.y, iz: b.orientation.z, r: b.orientation.w)
        if simd_dot(qa.vector, qb.vector) < 0 { qb = simd_quatd(vector: -qb.vector) }
        let q = simd_normalize(simd_slerp(qa, qb, e))
        s.orientation = SIMD4(q.vector.x, q.vector.y, q.vector.z, q.vector.w)
        s.target = a.target + (b.target - a.target) * e
        s.distance = a.distance * pow(b.distance / a.distance, e)
        s.orthographicScale = a.orthographicScale * pow(b.orthographicScale / a.orthographicScale, e)
        s.sceneRadius = a.sceneRadius + (b.sceneRadius - a.sceneRadius) * e
        s.projection = a.projection == b.projection ? b.projection : (e < 1 ? a.projection : b.projection)
        return s
    }

    private func startTimer() {
        guard timer == nil else { return }
        lastTick = CACurrentMediaTime()
        let t = Timer(timeInterval: 1.0 / 90, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = CACurrentMediaTime()
                let dt = min(0.1, now - self.lastTick); self.lastTick = now
                self.advanceAnimation(by: dt)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
    private func stopTimerIfIdle() {
        guard !isAnimating, orbitVel == .zero, panVel == .zero else { return }
        timer?.invalidate(); timer = nil
    }

    public func reset() {
        cancelMotion()
        orientation = CameraMath.orientation(for: .front)
        target = .zero; distance = 20; sceneRadius = 5
        orthoScale = distance * tanHalfFOV
        apply()
    }

    // MARK: State

    public var state: CameraState {
        get {
            let v = orientation.vector
            return CameraState(target: target, distance: distance, orientation: SIMD4(v.x, v.y, v.z, v.w),
                               orthographicScale: orthoScale, sceneRadius: sceneRadius, projection: projection)
        }
        set {
            let o = newValue.orientation
            var q = simd_quatd(ix: o.x, iy: o.y, iz: o.z, r: o.w)
            if simd_length(q.vector) < 1e-9 { q = simd_quatd(angle: 0, axis: Vec3(0, 1, 0)) }
            orientation = simd_normalize(q)
            target = newValue.target
            distance = min(Self.maxDistance, max(Self.minDistance, newValue.distance))
            orthoScale = max(Self.minScale, newValue.orthographicScale)
            sceneRadius = max(0.1, newValue.sceneRadius)
            let p = newValue.projection
            if p != projection { projectionSilent(p) }
            apply()
        }
    }
    private func projectionSilent(_ p: ProjectionMode) {
        // set without the didSet rescaling (state carries both distance and scale)
        let saved = (distance, orthoScale)
        projection = p
        distance = saved.0; orthoScale = saved.1
    }

    // MARK: Apply

    private func apply() {
        guard let cam = node.camera else { return }
        let pos = eye
        let ori = orientation
        let ortho = projection == .orthographic
        let near = max(0.02, distance - sceneRadius * 3), far = distance + sceneRadius * 4 + 10
        SCNTransaction.begin(); SCNTransaction.animationDuration = 0
        node.simdPosition = SIMD3<Float>(Float(pos.x), Float(pos.y), Float(pos.z))
        node.simdOrientation = simd_quatf(ix: Float(ori.imag.x), iy: Float(ori.imag.y), iz: Float(ori.imag.z), r: Float(ori.real))
        cam.usesOrthographicProjection = ortho
        cam.orthographicScale = Double(orthoScale)
        cam.zNear = near
        cam.zFar = far
        SCNTransaction.commit()
        onChange?()
    }
}
