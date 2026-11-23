import SwiftUI
import AppKit

struct PreferencesView: View {
    var body: some View {
        TabView {
            GeneralPrefs().tabItem { Label("General", systemImage: "gearshape") }
            CalcPrefs().tabItem { Label("Calculation", systemImage: "function") }
            GaussianPrefs().tabItem { Label("Gaussian", systemImage: "terminal") }
        }
        .frame(width: 480, height: 300)
        .padding()
    }
}

private struct GeneralPrefs: View {
    @AppStorage(AppSettings.renderStyleKey) private var style = "ballAndStick"
    @AppStorage(AppSettings.backgroundColorKey) private var bgHex = "#1E1F24"
    @AppStorage(AppSettings.showLabelsKey) private var labels = false

    var body: some View {
        Form {
            Picker("Render style", selection: $style) {
                Text("Ball and stick").tag("ballAndStick")
                Text("Space filling").tag("spaceFill")
                Text("Sticks").tag("sticks")
                Text("Wireframe").tag("wireframe")
            }
            ColorPicker("Background", selection: Binding(
                get: { Color(nsColor: NSColor(hex: bgHex)) },
                set: { bgHex = NSColor($0).hexString }), supportsOpacity: false)
            Toggle("Show atom labels", isOn: $labels)
            Button("Reset Background") { bgHex = "#1E1F24" }
        }
        .padding()
    }
}

private struct CalcPrefs: View {
    @AppStorage(AppSettings.defaultMethodKey) private var method = "B3LYP"
    @AppStorage(AppSettings.defaultBasisKey) private var basis = "6-31G(d)"
    @AppStorage(AppSettings.processorsKey) private var procs = 4
    @AppStorage(AppSettings.memoryKey) private var memory = "4GB"
    var body: some View {
        Form {
            TextField("Method", text: $method)
            TextField("Basis set", text: $basis)
            Stepper("Processors: \(procs)", value: $procs, in: 1...256)
            TextField("Memory", text: $memory)
        }
        .padding()
    }
}

enum GaussianPathProbe {
    static func detect() -> String? {
        let fm = FileManager.default
        let env = ProcessInfo.processInfo.environment
        var dirs: [String] = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        for (rootVar, sub) in [("g16root", "g16"), ("g09root", "g09")] {
            if let r = env[rootVar] { dirs.append((r as NSString).appendingPathComponent(sub)) }
        }
        if let e = env["GAUSS_EXEDIR"] { dirs.append(contentsOf: e.split(separator: ":").map(String.init)) }
        dirs += ["/usr/local/g16", "/opt/g16", "/usr/local/g09", "/opt/g09"]
        for d in dirs {
            for name in ["g16", "g09"] {
                let p = (d as NSString).appendingPathComponent(name)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: p, isDirectory: &isDir), !isDir.boolValue, fm.isExecutableFile(atPath: p) { return p }
            }
        }
        return nil
    }
}

private struct GaussianPrefs: View {
    @AppStorage(AppSettings.gaussianPathKey) private var path = ""
    @AppStorage(AppSettings.scratchDirKey) private var scratch = ""
    @StateObject private var msgBox = StateBox("")

    private var found: Bool { !path.isEmpty && FileManager.default.isExecutableFile(atPath: path) }

    var body: some View {
        Form {
            HStack {
                TextField("Gaussian executable", text: $path)
                Button("Choose…") { choose(directory: false) }
                Button("Detect") { detect() }
            }
            HStack {
                Image(systemName: found ? "checkmark.circle.fill" : "xmark.circle")
                    .foregroundStyle(found ? Color.green : Color.secondary)
                Text(path.isEmpty ? "Not set. Detect searches PATH, g16root, g09root, GAUSS_EXEDIR and standard locations." : (found ? "Executable found" : "Not found at this path"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !msgBox.value.isEmpty { Text(msgBox.value).font(.caption) }
            HStack {
                TextField("Scratch directory (optional)", text: $scratch)
                Button("Choose…") { choose(directory: true) }
            }
        }
        .padding()
    }

    private func detect() {
        if let p = GaussianPathProbe.detect() { path = p; msgBox.value = "Found \(p)" } else { msgBox.value = "No Gaussian installation found." }
    }

    private func choose(directory: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = !directory
        panel.canChooseDirectories = directory
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let u = panel.url { if directory { scratch = u.path } else { path = u.path } }
    }
}
