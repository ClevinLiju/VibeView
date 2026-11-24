import AppKit

/// Developer aid for documentation screenshots. With `VIBEVIEW_SNAPSHOT_DIR` and
/// `VIBEVIEW_README_SHOTS="name@tab[@option],..."` set, the frontmost document window is resized to
/// `VIBEVIEW_README_SIZE` (default 1440x900) and, for each step, the results panel is switched to `tab`
/// (trajectory, vibrations, orbitals, uvvis, summary), the option applied, and the composited window
/// written to `<dir>/<name>.png`.
///
/// Options: `homo`, `lumo`, `homo-N`, `lumo+N`, `mode=N` (1-based normal mode), `hideresults`,
/// `look=solid|transparent|wireframe|points` (orbital surface style, not saved to preferences),
/// `cmd=<console command>` (run once per step, e.g. `cmd=turn y 70`; applied on the first pass only).
@MainActor
enum ReadmeShots {
    static func runIfRequested(dir: URL) -> Bool {
        guard let plan = AppEnv.value("README_SHOTS"), !plan.isEmpty else { return false }
        let steps = plan.split(separator: ",").map { $0.split(separator: "@").map(String.init) }
        guard let editor = EditorRegistry.live.last,
              let window = NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) && $0.contentView != nil }) else { return true }
        let size = (AppEnv.value("README_SIZE") ?? "1440x900").split(separator: "x").compactMap { Double($0) }
        if size.count == 2 {
            window.setContentSize(NSSize(width: size[0], height: size[1]))
            window.center()
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let originalLook = editor.orbitalLook     // `look=` overrides are put back afterwards
        var pending = steps
        func next() {
            guard !pending.isEmpty else {
                editor.orbitalLook = originalLook
                originalLook.save()
                try? "done\n".write(to: dir.appendingPathComponent("readme-shots-done.txt"), atomically: true, encoding: .utf8)
                return
            }
            let step = pending.removeFirst()
            guard step.count >= 2 else { next(); return }
            apply(step, to: editor)
            for opt in step.dropFirst(2) where opt.hasPrefix("cmd=") {
                editor.console.input = String(opt.dropFirst(4))
                editor.console.submit()
            }
            // Orbital surfaces are computed asynchronously; give them (and SwiftUI layout) time to land.
            // Re-apply once in case a late companion-file merge or list update changed the selection.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { apply(step, to: editor) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                if let rep = WindowSnapshots.composite(window), let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: dir.appendingPathComponent("\(step[0]).png"))
                }
                next()
            }
        }
        next()
        return true
    }

    private static func apply(_ step: [String], to e: EditorModel) {
        e.activeModeIndex = nil
        e.showResults = true
        if let tab = ResultsTab(rawValue: step[1]) { e.resultsTab = tab }
        for opt in step.dropFirst(2) {
            if opt.hasPrefix("cmd=") { continue }
            if opt == "hideresults" { e.showResults = false; continue }
            if opt.hasPrefix("look="), let m = OrbitalLook.modes.first(where: { "\($0)" == opt.dropFirst(5) }) {
                if e.orbitalLook.mode != m { e.orbitalLook.mode = m }
                continue
            }
            if opt.hasPrefix("mode="), let n = Int(opt.dropFirst(5)), n > 0 { e.activeModeIndex = n - 1; continue }
            let alpha = (e.result?.orbitals ?? []).filter { $0.spin != .beta }
            guard let homo = alpha.filter(\.occupied).map(\.index).max() else { continue }
            if opt == "homo" { e.activeOrbitalIndex = homo }
            else if opt == "lumo" { e.activeOrbitalIndex = homo + 1 }
            else if opt.hasPrefix("homo-"), let k = Int(opt.dropFirst(5)) { e.activeOrbitalIndex = homo - k }
            else if opt.hasPrefix("lumo+"), let k = Int(opt.dropFirst(5)) { e.activeOrbitalIndex = homo + 1 + k }
        }
    }
}
