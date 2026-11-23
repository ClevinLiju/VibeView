import Foundation

// SHARED APP CORE (owned by Lead 4). UserDefaults keys used by Preferences (worker B) and
// the job runner (worker C). Use with @AppStorage(AppSettings.gaussianPathKey).
public enum AppSettings {
    public static let gaussianPathKey = "vibeview.gaussianExecutablePath"   // full path to g16/g09, "" = auto-detect
    public static let scratchDirKey = "vibeview.scratchDirectory"           // GAUSS_SCRDIR override, "" = default
    public static let renderStyleKey = "vibeview.renderStyle"               // "ballAndStick" | "spaceFill" | "sticks" | "wireframe"
    public static let backgroundColorKey = "vibeview.backgroundColorHex"    // e.g. "#1E1F24"
    public static let showLabelsKey = "vibeview.showAtomLabels"            // Bool
    public static let defaultMethodKey = "vibeview.defaultMethod"          // e.g. "B3LYP"
    public static let defaultBasisKey = "vibeview.defaultBasis"            // e.g. "6-31G(d)"
    public static let processorsKey = "vibeview.defaultProcessors"         // Int
    public static let memoryKey = "vibeview.defaultMemory"                 // e.g. "4GB"
}
