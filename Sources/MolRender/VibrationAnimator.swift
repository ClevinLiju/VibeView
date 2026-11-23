import SceneKit
import Foundation
import MolCore

public enum VibrationMath {
    /// base + amplitude * sin(phase) * displacement. Returns `base` unchanged on a count mismatch.
    public static func displaced(base: [Vec3], mode: NormalMode, amplitude: Double, phase: Double) -> [Vec3] {
        guard base.count == mode.displacements.count else { return base }
        let f = amplitude * sin(phase)
        return zip(base, mode.displacements).map { $0 + f * $1 }
    }
}

@MainActor public final class VibrationAnimator {
    unowned let renderer: MoleculeRenderer
    public var amplitude: Double = 0.5
    public var cyclesPerSecond: Double = 1.0
    public private(set) var mode: NormalMode?
    public private(set) var isPlaying = false
    public var isPaused = false
    private var base: [Vec3] = []
    private var timer: Timer?
    private var startTime: TimeInterval = 0
    private var pausedAt: TimeInterval?

    init(renderer: MoleculeRenderer) { self.renderer = renderer }

    public func play(_ mode: NormalMode) {
        stop()
        guard mode.displacements.count == renderer.molecule.atoms.count else { return }
        self.mode = mode
        base = renderer.molecule.atoms.map(\.position)
        isPlaying = true; isPaused = false
        startTime = ProcessInfo.processInfo.systemUptime
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isPaused else { return }
                self.tick(time: ProcessInfo.processInfo.systemUptime - self.startTime)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    public func pause() { if isPlaying { isPaused = true } }
    public func resume() {
        guard isPlaying, isPaused else { return }
        isPaused = false
    }

    /// Apply the pose at `time` seconds since start (callable without a run loop).
    public func tick(time: TimeInterval) {
        guard isPlaying, let mode else { return }
        let phase = 2 * Double.pi * cyclesPerSecond * time
        renderer.updatePositions(VibrationMath.displaced(base: base, mode: mode, amplitude: amplitude, phase: phase))
    }

    public func stop() {
        timer?.invalidate(); timer = nil
        if isPlaying, base.count == renderer.molecule.atoms.count { renderer.updatePositions(base) }
        isPlaying = false; isPaused = false; mode = nil; base = []
    }
}
