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

/// Plays a normal mode.
///
/// GPU path (default, `useGPU = true`): `play` builds one vibrating mesh (see `GPUVibration`) and hides
/// the atom/bond layers; vertices are displaced in a geometry shader and the per-frame scalar is written
/// on SceneKit's render thread, so there is no per-frame main-thread geometry work. `renderer.molecule`
/// keeps the base coordinates unless overlays need updating: while there are labels, measurements,
/// a selection or a hover highlight, a light main-thread timer moves just those overlays (and the model
/// coordinates, so measurement values are live) in step with the GPU clock.
///
/// CPU path (`useGPU = false`): the round-2 behaviour, `updatePositions` every 1/60 s.
///
/// `tick(time:)` poses explicitly (checks, exports): it moves the model to that pose and holds the GPU
/// mesh at the same phase until `resume()` or the next `play`.
@MainActor public final class VibrationAnimator {
    unowned let renderer: MoleculeRenderer
    public var amplitude: Double = 0.5 { didSet { if amplitude != oldValue { reclock() } } }
    public var cyclesPerSecond: Double = 1.0 { didSet { if cyclesPerSecond != oldValue { reclock() } } }
    /// Animate on the GPU (default). Takes effect at the next `play`.
    public var useGPU = true
    public private(set) var mode: NormalMode?
    public private(set) var isPlaying = false
    public var isPaused = false
    /// True while the GPU mesh is displayed (playing with `useGPU`).
    public var isGPUActive: Bool { gpuNode != nil }
    private var base: [Vec3] = []
    private var timer: Timer?
    private var startTime: TimeInterval = 0
    private var gpuNode: SCNNode?
    private var gpuMaterials: [SCNMaterial] = []
    let clock = VibrationClock()
    private var posing = false
    /// Last pose written by the overlay timer (so a rebuild doesn't mistake it for a new base pose).
    private var lastOverlayPositions: [Vec3]?
    /// Main-thread time spent in the last overlay/CPU frame update (seconds; diagnostics).
    public private(set) var lastFrameWork: TimeInterval = 0

    init(renderer: MoleculeRenderer) { self.renderer = renderer }

    public func play(_ mode: NormalMode) {
        stop()
        guard mode.displacements.count == renderer.molecule.atoms.count else { return }
        self.mode = mode
        base = renderer.molecule.atoms.map(\.position)
        isPlaying = true; isPaused = false
        startTime = ProcessInfo.processInfo.systemUptime
        if useGPU {
            installGPU(phase: 0, held: false)
        }
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.frame() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    public func pause() {
        guard isPlaying, !isPaused else { return }
        isPaused = true
        if isGPUActive { clock.configure(materials: gpuMaterials, amplitude: amplitude, cyclesPerSecond: cyclesPerSecond, phase: clock.phase(), held: true) }
    }
    public func resume() {
        guard isPlaying else { return }
        let ph = clock.phase()
        isPaused = false
        if isGPUActive {
            clock.configure(materials: gpuMaterials, amplitude: amplitude, cyclesPerSecond: cyclesPerSecond, phase: ph, held: false)
        } else {
            startTime = ProcessInfo.processInfo.systemUptime - (cyclesPerSecond > 0 ? ph / (2 * .pi * cyclesPerSecond) : 0)
        }
    }

    /// Apply the pose at `time` seconds since start (callable without a run loop). In GPU mode this also
    /// holds the GPU mesh at that phase.
    public func tick(time: TimeInterval) {
        guard isPlaying, let mode else { return }
        let phase = 2 * Double.pi * cyclesPerSecond * time
        if isGPUActive { clock.configure(materials: gpuMaterials, amplitude: amplitude, cyclesPerSecond: cyclesPerSecond, phase: phase, held: true) }
        posing = true
        renderer.updatePositions(VibrationMath.displaced(base: base, mode: mode, amplitude: amplitude, phase: phase))
        posing = false
    }

    public func stop() {
        timer?.invalidate(); timer = nil
        removeGPU()
        if isPlaying, base.count == renderer.molecule.atoms.count { renderer.updatePositions(base) }
        isPlaying = false; isPaused = false; mode = nil; base = []; lastOverlayPositions = nil
    }

    // MARK: Per-frame

    /// Whether any overlay follows atom positions (labels, measurements, highlights).
    var overlaysFollowAtoms: Bool {
        let o = renderer.options
        return o.labelMode != .none || !o.measurements.isEmpty || !renderer.selection.isEmpty || renderer.hovered != .none
            || o.showHydrogenBonds
    }

    private func frame() {
        guard isPlaying, !isPaused, let mode else { return }
        let t0 = ProcessInfo.processInfo.systemUptime
        if isGPUActive {
            guard overlaysFollowAtoms else { lastFrameWork = 0; return }
            let pos = VibrationMath.displaced(base: base, mode: mode, amplitude: clock.currentAmplitude, phase: clock.phase())
            renderer.updateOverlayPositions(pos)
            lastOverlayPositions = pos
        } else {
            tick(time: t0 - startTime)
        }
        lastFrameWork = ProcessInfo.processInfo.systemUptime - t0
    }

    // MARK: GPU layer

    private func installGPU(phase: Double, held: Bool) {
        guard let mode else { return }
        removeGPU()
        var baseMol = renderer.molecule
        if base.count == baseMol.atoms.count { for i in base.indices { baseMol.atoms[i].position = base[i] } }
        let (node, mats) = GPUVibration.build(molecule: baseMol, mode: mode, options: renderer.options,
                                              colors: renderer.currentColors, materials: renderer.materials)
        gpuNode = node; gpuMaterials = mats
        renderer.root.addChildNode(node)
        renderer.setGeometryLayersHidden(true)
        clock.configure(materials: mats, amplitude: amplitude, cyclesPerSecond: cyclesPerSecond, phase: phase, held: held)
        renderer.view.delegate = clock
        renderer.view.rendersContinuously = true
        renderer.view.isPlaying = true
    }

    private func removeGPU() {
        guard let n = gpuNode else { return }
        n.removeFromParentNode()
        gpuNode = nil; gpuMaterials = []
        clock.clear()
        if renderer.view.delegate === clock { renderer.view.delegate = nil }
        renderer.view.rendersContinuously = false
        renderer.view.isPlaying = false
        renderer.setGeometryLayersHidden(false)
    }

    private func reclock() {
        guard isGPUActive else { return }
        clock.configure(materials: gpuMaterials, amplitude: amplitude, cyclesPerSecond: cyclesPerSecond, phase: clock.phase(), held: isPaused)
    }

    /// Called by the renderer after the atom/bond layers were rebuilt (options or molecule change).
    func layersRebuilt() {
        guard isPlaying, let mode else { return }
        guard mode.displacements.count == renderer.molecule.atoms.count else { stop(); return }
        guard isGPUActive else { return }
        let cur = renderer.molecule.atoms.map(\.position)
        if !posing && cur != lastOverlayPositions { base = cur }
        let ph = clock.phase(), held = isPaused || posing
        installGPU(phase: ph, held: held)
    }

    /// Called by `updatePositions` when coordinates change from outside the animator (e.g. a trajectory):
    /// the new coordinates become the base pose of the GPU mesh.
    func positionsChangedExternally() {
        guard isGPUActive, !posing else { return }
        base = renderer.molecule.atoms.map(\.position)
        installGPU(phase: clock.phase(), held: isPaused)
    }

    /// The vibrating node (checks/introspection).
    var gpuLayer: SCNNode? { gpuNode }
    var gpuMaterialList: [SCNMaterial] { gpuMaterials }
}
