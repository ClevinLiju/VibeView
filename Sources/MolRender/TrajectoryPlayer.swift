import SceneKit
import Foundation
import MolCore

@MainActor public final class TrajectoryPlayer {
    unowned let renderer: MoleculeRenderer
    public private(set) var frames: [Molecule] = []
    public private(set) var currentFrame = 0
    public var framesPerSecond: Double = 10 { didSet { if isPlaying { restartTimer() } } }
    public var loops = true
    public private(set) var isPlaying = false
    public var onFrameChange: ((Int) -> Void)?
    /// Smooth playback: poses are linearly interpolated between frames at display rate when the
    /// frames share topology (otherwise playback steps frame by frame).
    public var interpolates = true
    /// Fractional playhead (frame units) of the last shown pose.
    public private(set) var playhead: Double = 0
    private var timer: Timer?
    private var lastTick: TimeInterval = 0
    init(renderer: MoleculeRenderer) { self.renderer = renderer }

    public func load(_ frames: [Molecule]) {
        pause()
        self.frames = frames
        currentFrame = 0
        if !frames.isEmpty { show(frame: 0) }
    }

    public func show(frame: Int) {
        guard !frames.isEmpty else { return }
        let i = max(0, min(frames.count - 1, frame))
        currentFrame = i
        playhead = Double(i)
        let f = frames[i]
        let cur = renderer.molecule
        let same = f.atoms.count == cur.atoms.count && f.bonds == cur.bonds
            && zip(f.atoms, cur.atoms).allSatisfy { $0.atomicNumber == $1.atomicNumber }
        if same { renderer.updatePositions(f.atoms.map(\.position)) } else { renderer.setMolecule(f, fitCamera: false) }
        onFrameChange?(i)
    }

    public func step(_ delta: Int) { show(frame: currentFrame + delta) }

    /// Show an interpolated pose at fractional frame `position` (clamped). Falls back to the nearest
    /// frame when neighbouring frames differ in topology.
    public func show(position: Double) {
        guard !frames.isEmpty, position.isFinite else { return }
        let p = max(0, min(Double(frames.count - 1), position))
        let i = Int(p.rounded(.down)), j = min(frames.count - 1, i + 1), t = p - Double(i)
        let a = frames[i], b = frames[j]
        let cur = renderer.molecule
        let compatible = a.atoms.count == b.atoms.count && a.atoms.count == cur.atoms.count && a.bonds == cur.bonds
            && zip(a.atoms, cur.atoms).allSatisfy { $0.atomicNumber == $1.atomicNumber }
        guard compatible, t > 1e-9 else {
            let k = Int(p.rounded()); if k != currentFrame || !compatible { show(frame: k) }; playhead = p; return
        }
        renderer.updatePositions(zip(a.atoms, b.atoms).map { $0.position + ($1.position - $0.position) * t })
        playhead = p
        if i != currentFrame { currentFrame = i; onFrameChange?(i) }
    }

    /// Advance smooth playback by `dt` seconds (used by the display timer; callable from checks).
    public func advance(by dt: TimeInterval) {
        guard !frames.isEmpty else { return }
        var p = playhead + dt * framesPerSecond
        let last = Double(frames.count - 1)
        if p > last {
            if loops && frames.count > 1 { p = p.truncatingRemainder(dividingBy: last + 1); if p > last { p = 0 } }
            else { show(position: last); pause(); return }
        }
        show(position: p)
    }

    /// One timer tick: next frame; wraps when `loops`, otherwise pauses at the last frame.
    public func advance() {
        guard !frames.isEmpty else { return }
        if currentFrame + 1 < frames.count { show(frame: currentFrame + 1) }
        else if loops { show(frame: 0) }
        else { pause() }
    }

    public func play() {
        guard !frames.isEmpty, !isPlaying else { return }
        isPlaying = true
        restartTimer()
    }

    public func pause() {
        timer?.invalidate(); timer = nil
        isPlaying = false
    }

    private func restartTimer() {
        timer?.invalidate()
        lastTick = ProcessInfo.processInfo.systemUptime
        let smooth = interpolates && frames.count > 1
        let interval = smooth ? 1.0 / 60.0 : 1.0 / max(0.1, framesPerSecond)
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if smooth {
                    let now = ProcessInfo.processInfo.systemUptime
                    self.advance(by: min(0.1, now - self.lastTick)); self.lastTick = now
                } else { self.advance() }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
}
