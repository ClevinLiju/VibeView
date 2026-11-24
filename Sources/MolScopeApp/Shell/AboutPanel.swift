import AppKit

/// The standard About panel with VibeView's own credits text.
@MainActor
enum AboutPanel {
    static func show() {
        let credits = NSAttributedString(
            string: "Open-source molecular builder and viewer for the Mac.\nBuild, measure, run xtb, ORCA and Gaussian jobs, and explore orbitals and vibrations.\nMIT License.",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: AppInfo.name,
            .credits: credits,
        ])
        NSApp.activate(ignoringOtherApps: true)
    }
}
