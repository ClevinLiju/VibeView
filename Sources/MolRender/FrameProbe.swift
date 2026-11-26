import Foundation
import SceneKit
import simd

/// Frame-interval statistics of a spin benchmark (seconds).
public struct FrameStats: Sendable, Equatable {
    public var frames = 0
    public var mean = 0.0, p95 = 0.0, max = 0.0
    /// Mean CPU time SceneKit spent between the update and the end of the render callback (encoding), per frame.
    public var meanEncode = 0.0
    public init() {}
}

/// Developer timing aid (used behind the app's `VIBEVIEW_PERF` switch): reports the next rendered frame and runs a
/// spin benchmark that turns the model about the view's vertical axis frame by frame and records the frame
/// intervals. It installs itself as the view's delegate only while the view has no other delegate (the GPU
/// vibration clock), and removes itself when done.
final class FrameProbe: NSObject, SCNSceneRendererDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var nextFrame: [(TimeInterval) -> Void] = []
    private var spinLeft = 0
    private var spinStep: simd_quatf = simd_quatf(angle: 0, axis: SIMD3(0, 1, 0))
    private weak var spinNode: SCNNode?
    private var times: [Double] = []
    private var encode: [Double] = []
    private var updateStart = 0.0
    private var spinDone: ((FrameStats) -> Void)?

    func addNextFrame(_ f: @escaping (TimeInterval) -> Void) { lock.lock(); nextFrame.append(f); lock.unlock() }

    func startSpin(node: SCNNode, frames: Int, degreesPerFrame: Float, done: @escaping (FrameStats) -> Void) {
        lock.lock(); defer { lock.unlock() }
        spinNode = node; spinLeft = frames; times = []; encode = []; spinDone = done
        spinStep = simd_quatf(angle: degreesPerFrame * .pi / 180, axis: SIMD3(0, 1, 0))
    }

    var isIdle: Bool { lock.lock(); defer { lock.unlock() }; return nextFrame.isEmpty && spinLeft == 0 && spinDone == nil }

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        updateStart = ProcessInfo.processInfo.systemUptime
        if spinLeft > 0, let n = spinNode { n.simdOrientation = spinStep * n.simdOrientation }
    }

    func renderer(_ renderer: SCNSceneRenderer, didRenderScene scene: SCNScene, atTime time: TimeInterval) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let callbacks = nextFrame; nextFrame = []
        var finished: (FrameStats, (FrameStats) -> Void)?
        if spinLeft > 0 {
            times.append(now); encode.append(now - updateStart)
            spinLeft -= 1
            if spinLeft == 0, let done = spinDone {
                spinDone = nil
                var d: [Double] = []
                for i in 1..<max(times.count, 1) { d.append(times[i] - times[i - 1]) }
                var s = FrameStats()
                s.frames = d.count
                if !d.isEmpty {
                    let sorted = d.sorted()
                    s.mean = d.reduce(0, +) / Double(d.count)
                    s.p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
                    s.max = sorted.last!
                    s.meanEncode = encode.reduce(0, +) / Double(encode.count)
                }
                finished = (s, done)
            }
        }
        lock.unlock()
        for c in callbacks { c(now) }
        if let (s, done) = finished { done(s) }
    }
}

public extension MoleculeRenderer {
    /// Calls `f` on the main actor right after the next frame has been rendered (system uptime of that moment).
    func onNextFrame(_ f: @escaping @MainActor (TimeInterval) -> Void) {
        guard installProbe() else { return }
        // An on-demand view may not draw again by itself; keep the render loop running until the frame lands.
        let wasContinuous = view.rendersContinuously
        view.rendersContinuously = true
        frameProbe.addNextFrame { t in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if !wasContinuous && self.frameProbe.isIdle && self.vibration?.isGPUActive != true && !self.resizeSettleActive {
                        self.view.rendersContinuously = false
                    }
                    self.uninstallProbeIfIdle()
                    f(t)
                }
            }
        }
    }

    /// Turns the model `frames` times by `degreesPerFrame` about the vertical axis, rendering continuously, then
    /// restores the orientation and reports the frame intervals. Returns false if the view is busy (vibration).
    @discardableResult
    func benchmarkSpin(frames: Int = 240, degreesPerFrame: Float = 1.5, completion: @escaping @MainActor (FrameStats) -> Void) -> Bool {
        guard installProbe() else { return false }
        let saved = root.simdOrientation
        let wasContinuous = view.rendersContinuously
        view.rendersContinuously = true
        view.isPlaying = true
        frameProbe.startSpin(node: root, frames: frames + 1, degreesPerFrame: degreesPerFrame) { s in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.root.simdOrientation = saved
                    self.view.rendersContinuously = wasContinuous || self.resizeSettleActive
                    self.view.isPlaying = false
                    self.uninstallProbeIfIdle()
                    completion(s)
                }
            }
        }
        return true
    }

    private func installProbe() -> Bool {
        if view.delegate === frameProbe { return true }
        guard view.delegate == nil else { return false }
        view.delegate = frameProbe
        return true
    }

    private func uninstallProbeIfIdle() {
        if view.delegate === frameProbe, frameProbe.isIdle { view.delegate = nil }
    }
}
