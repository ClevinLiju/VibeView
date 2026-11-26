import Foundation
import SceneKit
import Darwin
import MolRender
import AppKit
import Metal

/// Developer timing log. With `VIBEVIEW_PERF` set, milestones are written to stderr (and appended to the file named
/// by `VIBEVIEW_PERF_LOG`, if any) as "perf <seconds since process start> <event>": launch, document read, scene
/// build, first frames, orbital grid/surface times. `VIBEVIEW_PERF_SPIN=<frames>` also runs a spin benchmark
/// (model turned 1.5° per frame) a second after the first frame of a loaded structure.
@MainActor
enum PerfProbe {
    static let enabled = AppEnv.isSet("PERF")

    /// Process start (wall clock), from the kernel.
    static let processStart: Date = {
        var kp = kinfo_proc(), size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &kp, &size, nil, 0) == 0 else { return Date() }
        let tv = kp.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6)
    }()

    static func log(_ event: String, at: Date = Date()) {
        guard enabled else { return }
        let line = String(format: "perf %8.3f %@\n", at.timeIntervalSince(processStart), event)
        FileHandle.standardError.write(Data(line.utf8))
        if let path = AppEnv.value("PERF_LOG") {
            if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
            else { try? line.write(toFile: path, atomically: true, encoding: .utf8) }
        }
    }

    /// Milliseconds since `t0` (`CFAbsoluteTimeGetCurrent`).
    static func ms(_ t0: CFAbsoluteTime) -> String { String(format: "%.1f ms", (CFAbsoluteTimeGetCurrent() - t0) * 1000) }

    /// Drawable size and the Metal memory of the view's device (render targets, buffers, textures).
    static func viewReport(_ r: MoleculeRenderer) -> String {
        let v = r.view
        let scale = v.window?.backingScaleFactor ?? 0
        let mtl = (v.device?.currentAllocatedSize ?? 0) >> 20
        let views = NSApp.windows.reduce(0) { n, w in n + (w.contentView.map(countSceneViews) ?? 0) }
        return String(format: "view %.0fx%.0f pt @%.0fx, Metal allocated %d MB, %d scene views", v.bounds.width, v.bounds.height, scale, mtl, views)
    }
    private static func countSceneViews(_ v: NSView) -> Int { (v is SCNView ? 1 : 0) + v.subviews.reduce(0) { $0 + countSceneViews($1) } }

    private static var firstWindowFrame = false
    private static var spun = Set<ObjectIdentifier>()

    /// A renderer was created for a window: report its first frame (once per process).
    static func windowCreated(_ r: MoleculeRenderer) {
        guard enabled, !firstWindowFrame else { return }
        firstWindowFrame = true
        r.onNextFrame { _ in log("first window frame; \(viewReport(r))") }
        // VIBEVIEW_PERF_RESIZE=<steps>: 4 s after launch grow the window one step per 1/30 s, then report the
        // Metal memory right after and 4 s later.
        if let steps = Int(AppEnv.value("PERF_RESIZE") ?? ""), steps > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                guard let w = r.view.window else { return }
                let f0 = w.frame
                var k = 0
                Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { t in
                    MainActor.assumeIsolated {
                        k += 1
                        var f = f0; f.size.width += CGFloat(k * 7); f.size.height += CGFloat(k * 4)
                        w.setFrame(f, display: true)
                        guard k >= steps else { return }
                        t.invalidate()
                        log("resized \(steps) steps; \(viewReport(r))")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { log("4 s after resize; \(viewReport(r))") }
                    }
                }
            }
        }
    }

    /// A new structure was put into the scene: report the build time and the next frame, then maybe spin.
    static func structureShown(_ r: MoleculeRenderer, atoms: Int) {
        guard enabled, atoms > 0 else { return }
        log("scene built: \(atoms) atoms, rebuild \(String(format: "%.1f ms", r.lastRebuildSeconds * 1000))")
        r.onNextFrame { _ in
            log("first frame with \(atoms) atoms; \(viewReport(r))")
            guard let n = Int(AppEnv.value("PERF_SPIN") ?? ""), n > 0, !spun.contains(ObjectIdentifier(r)) else { return }
            spun.insert(ObjectIdentifier(r))
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let started = r.benchmarkSpin(frames: n) { s in
                    log(String(format: "spin %d frames: mean %.2f ms, p95 %.2f ms, max %.2f ms, encode %.2f ms (%.0f fps); %@",
                               s.frames, s.mean * 1000, s.p95 * 1000, s.max * 1000, s.meanEncode * 1000, s.mean > 0 ? 1 / s.mean : 0, viewReport(r)))
                }
                if !started { log("spin skipped (view busy)") }
            }
        }
    }
}
