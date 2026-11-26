import AppKit
import MolCore
import MolBuild

/// Asks before a job runs on a structure with an isolated atom, an over-stretched bond or several fragments.
@MainActor
enum GeometryPreflightPrompt {
    /// True when the job should run: the geometry looks fine, or the user chose Run Anyway.
    static func confirm(_ molecule: Molecule, program: String) -> Bool {
        guard let text = GeometryPreflight.confirmationText(GeometryPreflight.check(molecule)) else { return true }
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = "Check the structure before running \(program)"
        a.informativeText = text + "\n\nSuch geometries often make the SCF fail to converge."
        a.addButton(withTitle: "Run Anyway")
        a.addButton(withTitle: "Cancel")
        return a.runModal() == .alertFirstButtonReturn
    }
}
