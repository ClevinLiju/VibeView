import AppKit
import SwiftUI

/// Developer aid: with `VIBEVIEW_SNAPSHOT_DIR` and `VIBEVIEW_GALLERY=1` set, individual panels (periodic
/// table, fragment palette, console, xtb settings, log viewer…) are hosted in offscreen windows and written
/// to `<dir>/gallery-<name>.png`, so each can be reviewed without driving the UI by hand.
@MainActor
enum UIGallery {
    typealias Entry = (name: String, size: CGSize, view: AnyView)
    /// Extra entries registered by feature files.
    static var providers: [(EditorModel) -> [Entry]] = []

    static func capture(to dir: URL, editor: EditorModel) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Session round trip (encode → decode → compare) for the frontmost document.
        do {
            let data = try SessionStore.encode(editor)
            try data.write(to: dir.appendingPathComponent("session.vibeview"))
            let back = try SessionStore.decode(data)
            let ok = back.molecule == editor.molecule && back.renderOptions == editor.renderOptions && back.monitors == editor.monitors
            try "session round trip: \(ok ? "OK" : "MISMATCH") atoms=\(back.molecule.atoms.count) bytes=\(data.count) source=\(back.sourceFile ?? "-")\n"
                .write(to: dir.appendingPathComponent("session-check.txt"), atomically: true, encoding: .utf8)
        } catch {
            try? "session round trip FAILED: \(error)\n".write(to: dir.appendingPathComponent("session-check.txt"), atomically: true, encoding: .utf8)
        }
        var entries: [Entry] = [
            ("periodic-table", CGSize(width: 660, height: 400),
             AnyView(PeriodicTablePopover(editor: editor, isPresented: .constant(true)))),
        ]
        entries.append(("fragments", CGSize(width: 760, height: 640), AnyView(FragmentGalleryView())))
        let console = editor.console
        if let dir = AppEnv.value("GALLERY_CWD") { console.context.currentDirectory = URL(fileURLWithPath: dir) }
        for cmd in ["pwd", "ls", "help measure", "select all", "measure distance 1 2", "frobnicate"] { console.input = cmd; console.submit() }
        console.input = "st"; console.complete()
        entries.append(("console", CGSize(width: 900, height: 420), AnyView(ConsoleView(console: console))))
        for p in providers { entries += p(editor) }
        var pending = entries
        func next() {
            guard !pending.isEmpty else { return }
            let e = pending.removeFirst()
            render(e, to: dir) { next() }
        }
        next()
    }

    private static var hold: [NSWindow] = []

    static func render(_ e: Entry, to dir: URL, done: @escaping () -> Void) {
        let host = NSHostingView(rootView: e.view.frame(width: e.size.width, height: e.size.height)
            .background(Color(nsColor: .windowBackgroundColor)))
        host.frame = NSRect(origin: .zero, size: e.size)
        let w = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: e.size.width, height: e.size.height),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.contentView = host
        w.orderFront(nil)
        hold.append(w)
        // Give SwiftUI (and any async work such as thumbnails) a moment to lay out.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            host.layoutSubtreeIfNeeded()
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("gallery-\(e.name).png"))
            }
            w.orderOut(nil)
            done()
        }
    }
}

/// Every palette fragment with its generated thumbnail (gallery review only).
struct FragmentGalleryView: View {
    var body: some View {
        let all = BuildOps.categories.flatMap(\.fragments)
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(118), spacing: 6), count: 6), spacing: 8) {
            ForEach(all) { f in
                VStack(spacing: 2) {
                    FragmentThumbnail(id: f.id, side: 56)
                    Text(f.name).font(.caption2).lineLimit(1)
                }
            }
        }
        .padding(10)
    }
}
