import SwiftUI
import Combine
import AppKit
import simd
import MolCore
import MolBuild
import MolCompute

/// Gallery entries and the headless xtb self-test for the live-log / xtb-settings features.
@MainActor
enum GalleryJobs {
    private static var registered = false

    /// Appends "xtb-settings" and "log-viewer" to `UIGallery.providers` (idempotent).
    static func registerGallery() {
        guard !registered else { return }
        registered = true
        UIGallery.providers.append { _ in
            let editor = EditorModel(molecule: Builder.placeElement(8, in: Molecule(), at: .zero))
            var s = XTBSettings(method: .gfn2, task: .optimize, optLevel: .tight, maxCycles: 250,
                                solvationModel: .alpb, solvent: "water", threads: 4)
            s.extraArguments = ["--acc", "0.5"]
            let log = LogModel(title: "water \u{2014} xtb", fileURL: URL(fileURLWithPath: "/Users/me/Library/Application Support/VibeView/Jobs/water-xtb-20260101-120000/xtb.out"),
                               lines: sampleLog())
            log.isLive = true
            return [
                (name: "xtb-settings", size: CGSize(width: 560, height: 720),
                 view: AnyView(XTBSettingsSheet(editor: editor, isPresented: .constant(true), initial: s))),
                (name: "log-viewer", size: CGSize(width: 800, height: 500),
                 view: AnyView(LogViewer(model: log, initialSearch: "energy"))),
            ]
        }
    }

    static func sampleLog() -> [String] {
        var l = ["$ OMP_NUM_THREADS=4,1 xtb input.xyz --gfn 2 --opt tight --chrg 0 --uhf 0 --alpb water -P 4",
                 "      -----------------------------------------------------------",
                 "     |                   =====================                   |",
                 "     |                           x T B                           |",
                 "     |                   =====================                   |",
                 "      -----------------------------------------------------------", ""]
        var e = -5.0703
        for c in 1...48 {
            e -= 0.012 / Double(c)
            l.append(" ......................................................................")
            l.append(" .............................. CYCLE \(String(format: "%5d", c)) ......................................")
            l.append(" ...................................................................")
            l.append("   iter      E             dE          RMSdq      gap      omega  full diag")
            l.append(String(format: "    1     %.7f   -0.5E-02    0.1E-01    9.213     0.000    -", e + 0.01))
            l.append(String(format: "    2     %.7f   -0.2E-04    0.3E-02    9.220     0.000    -", e))
            l.append(String(format: "         :: total energy           %.9f Eh    ::", e))
            l.append(String(format: "         :: gradient norm           %.6f Eh/a0 ::", 0.05 / Double(c)))
            l.append(String(format: "   * total energy  :   %.7f Eh     change       %.5fE-03 Eh", e, -0.8 / Double(c)))
            l.append("")
        }
        l.append("          *** GEOMETRY OPTIMIZATION CONVERGED AFTER 48 ITERATIONS ***")
        l.append(" normal termination of xtb")
        return l
    }

    // MARK: Self-test

    /// With `VIBEVIEW_XTB_SELFTEST=1`: runs a GFN2 optimization through the same code the "Run" button uses, shows the log
    /// window, writes `<snapshot dir>/xtb-selftest.txt` and snapshots all windows.
    static func runXTBSelfTestIfRequested() {
        guard AppEnv.isSet("XTB_SELFTEST") else { return }
        let dir = URL(fileURLWithPath: AppEnv.value("SNAPSHOT_DIR") ?? NSTemporaryDirectory())
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let report = dir.appendingPathComponent("xtb-selftest.txt")
        var text = ""
        func say(_ s: String) {
            text += s + "\n"
            try? text.write(to: report, atomically: true, encoding: .utf8)
        }
        Task { @MainActor in
            // Wait for the first editor window.
            var tries = 0
            while EditorRegistry.live.last == nil, tries < 100 { try? await Task.sleep(nanoseconds: 200_000_000); tries += 1 }
            guard let editor = EditorRegistry.live.last else { say("FAIL no editor window"); return }
            if editor.molecule.atoms.isEmpty {
                // A small alkane chain (a few seconds of xtb) so streaming is observable; water if VIBEVIEW_XTB_SELFTEST=water.
                var m = Builder.placeElement(8, in: Molecule(), at: .zero)
                if ProcessInfo.processInfo.environment["VIBEVIEW_XTB_SELFTEST"] != "water" {
                    m = Molecule()
                    for i in 0..<8 { m = Builder.placeElement(6, in: m, at: SIMD3<Double>(1.5 * Double(i), 0.3 * Double(i % 2), 0)) }
                }
                editor.replaceMolecule(m, actionName: "Build Test Molecule")
            }
            let before = editor.molecule.atoms.map(\.position)
            say("start: \(editor.molecule.atoms.count) atoms")
            var settings = XTBSettings(method: .gfn2, task: .optimize, optLevel: .tight, threads: 2)
            settings.charge = nil
            say("command: " + settings.commandLine(molecule: editor.molecule))
            var outcome: Result<XTBJobRunner.Outcome, Error>?
            guard let id = XTBJobRunner.run(editor: editor, settings: settings, completion: { outcome = $0 }) else {
                say("FAIL could not start: \(editor.statusMessage)"); return
            }
            var samples: [String] = []
            var maxWhileRunning = 0
            let t0 = Date()
            var cancellable: AnyCancellable?
            cancellable = JobLogCenter.shared.existing(for: id)?.$totalLines.sink { n in
                let running = JobQueue.shared.jobs.first(where: { $0.id == id })?.status == .running
                if running { maxWhileRunning = max(maxWhileRunning, n) }
                samples.append(String(format: "%.2fs:%d", Date().timeIntervalSince(t0), n))
            }
            while outcome == nil { try? await Task.sleep(nanoseconds: 50_000_000) }
            cancellable?.cancel()
            say(String(format: "run took %.2f s", Date().timeIntervalSince(t0)))
            say("log line count changes (time:lines) while running: \(samples)")
            say("max lines seen while job status == running: \(maxWhileRunning)")
            switch outcome! {
            case .success(let o):
                let moved = zip(before, editor.molecule.atoms.map(\.position)).map { simd_length($0 - $1) }.max() ?? 0
                say("result: SUCCESS energy=\(o.energy) Eh converged=\(String(describing: o.converged)) cycles=\(String(describing: o.cycles)) atoms=\(o.atoms)")
                say("log lines total: \(o.logLines); geometry replaced: \(o.geometryReplaced); max atom displacement: \(moved) A")
                say("run directory: \(o.directory.path)")
            case .failure(let e): say("result: FAILURE \(e.localizedDescription)")
            }
            say("status: \(editor.statusMessage)")
            say("queue: " + JobQueue.shared.jobs.map { "\($0.name) [\($0.status.label)] lastEnergy=\($0.lastEnergy.map { String($0) } ?? "-")" }.joined(separator: "; "))
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            WindowSnapshots.capture(to: dir)
            say("snapshots written to \(dir.path)")
        }
    }
}
