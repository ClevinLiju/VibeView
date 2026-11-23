import Foundation

// SHARED APP CORE (owned by Lead 4). UserDefaults keys used by Preferences (worker B) and
// the job runner (worker C). Use with @AppStorage(AppSettings.gaussianPathKey).
public enum AppSettings {
    public static let gaussianPathKey = "molscope.gaussianExecutablePath"   // full path to g16/g09, "" = auto-detect
    public static let scratchDirKey = "molscope.scratchDirectory"           // GAUSS_SCRDIR override, "" = default
    public static let renderStyleKey = "molscope.renderStyle"               // "ballAndStick" | "spaceFill" | "sticks" | "wireframe"
    public static let backgroundColorKey = "molscope.backgroundColorHex"    // e.g. "#1E1F24"
    public static let showLabelsKey = "molscope.showAtomLabels"            // Bool
    public static let defaultMethodKey = "molscope.defaultMethod"          // e.g. "B3LYP"
    public static let defaultBasisKey = "molscope.defaultBasis"            // e.g. "6-31G(d)"
    public static let processorsKey = "molscope.defaultProcessors"         // Int
    public static let memoryKey = "molscope.defaultMemory"                 // e.g. "4GB"
}
