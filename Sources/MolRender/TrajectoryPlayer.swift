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
    private var timer: Timer?
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
        let f = frames[i]
        let cur = renderer.molecule
        let same = f.atoms.count == cur.atoms.count && f.bonds == cur.bonds
            && zip(f.atoms, cur.atoms).allSatisfy { $0.atomicNumber == $1.atomicNumber }
        if same { renderer.updatePositions(f.atoms.map(\.position)) } else { renderer.setMolecule(f, fitCamera: false) }
        onFrameChange?(i)
    }

    public func step(_ delta: Int) { show(frame: currentFrame + delta) }

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
        let t = Timer(timeInterval: 1.0 / max(0.1, framesPerSecond), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advance() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
}
