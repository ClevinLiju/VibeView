import SceneKit
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
        let qy = simd_quatd(angle: -dx * orbitSensitivity, axis: Vec3(0, 1, 0))
        let qx = simd_quatd(angle: -dy * orbitSensitivity, axis: Vec3(1, 0, 0))
        orientation = simd_normalize(orientation * qy * qx)
        apply()
    }

    public func pan(dx: Double, dy: Double, viewSize: CGSize) {
        guard dx.isFinite, dy.isFinite, viewSize.height > 0 else { return }
        let halfH = projection == .orthographic ? orthoScale : distance * tanHalfFOV
        let upp = 2 * halfH / Double(viewSize.height)
        target += -rightVector * (dx * upp) + upVector * (dy * upp)
        apply()
    }

    /// factor > 1 zooms in.
    public func zoom(by factor: Double) {
        guard factor.isFinite, factor > 1e-6 else { return }
        if projection == .orthographic {
            orthoScale = min(Self.maxDistance, max(Self.minScale, orthoScale / factor))
        } else {
            distance = min(Self.maxDistance, max(Self.minDistance, distance / factor))
        }
        apply()
    }

    public func roll(radians: Double) {
        guard radians.isFinite, radians != 0 else { return }
        orientation = simd_normalize(orientation * simd_quatd(angle: -radians, axis: Vec3(0, 0, 1)))
        apply()
    }

    public func fit(center: Vec3, radius: Double, animated: Bool = false) {
        let r = max(radius, 0.1)
        let aspect = max(0.05, aspectProvider?() ?? 1)
        target = center
        sceneRadius = r
        distance = min(Self.maxDistance, CameraMath.fitDistance(radius: r, verticalFOVDegrees: fovDegrees, aspect: aspect, margin: fitMargin))
        if projection == .orthographic {
            orthoScale = max(Self.minScale, r * fitMargin * max(1, 1 / aspect))
        } else {
            orthoScale = max(Self.minScale, distance * tanHalfFOV)
        }
        apply(animated: animated)
    }

    public func setStandardView(_ v: StandardView, animated: Bool = false) {
        orientation = CameraMath.orientation(for: v)
        apply(animated: animated)
    }

    public func reset() {
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

    private func apply(animated: Bool = false) {
        guard let cam = node.camera else { return }
        let pos = eye
        let ori = orientation
        let ortho = projection == .orthographic
        let near = max(0.02, distance - sceneRadius * 3), far = distance + sceneRadius * 4 + 10
        if animated && animationDuration > 0 {
            SCNTransaction.begin()
            SCNTransaction.animationDuration = animationDuration
            SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        } else {
            SCNTransaction.begin(); SCNTransaction.animationDuration = 0
        }
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
