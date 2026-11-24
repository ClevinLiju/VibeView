import SwiftUI
import AppKit
import MolBuild

struct PreferencesView: View {
    var body: some View {
        TabView {
            GeneralPrefs().tabItem { Label("General", systemImage: "gearshape") }
            CalcPrefs().tabItem { Label("Calculation", systemImage: "function") }
            ProgramsPrefs().tabItem { Label("Programs", systemImage: "terminal") }
        }
        .frame(width: 600, height: 380)
        .padding()
    }
}

private func prefsColor(hex: String) -> NSColor {
    var h = hex.trimmingCharacters(in: .whitespaces)
    if h.hasPrefix("#") { h.removeFirst() }
    guard h.count == 6, let v = UInt32(h, radix: 16) else { return NSColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1) }
    return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
}

private func prefsHex(_ c: NSColor) -> String {
    let s = c.usingColorSpace(.sRGB) ?? c
    return String(format: "#%02X%02X%02X", Int((s.redComponent * 255).rounded()), Int((s.greenComponent * 255).rounded()), Int((s.blueComponent * 255).rounded()))
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
                get: { Color(nsColor: prefsColor(hex: bgHex)) },
                set: { bgHex = prefsHex(NSColor($0)) }), supportsOpacity: false)
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

private struct ProgramRow: View {
    let program: QCProgram
    @AppStorage private var path: String
    @State private var found: URL?

    init(program: QCProgram) {
        self.program = program
        _path = AppStorage(wrappedValue: "", ProgramLocator.settingKey(program))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(program.title).frame(width: 64, alignment: .leading).font(.headline)
                TextField("Executable path (blank = auto-detect)", text: $path)
                    .textFieldStyle(.roundedBorder)
                Button("Choose\u{2026}") { choose() }
                Button("Detect") { detect() }
            }
            HStack(spacing: 6) {
                Circle().fill(found != nil ? Color.green : Color.secondary.opacity(0.5)).frame(width: 8, height: 8)
                Text(found?.path ?? "Not found").font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            .padding(.leading, 70)
        }
        .onAppear { refresh() }
        .onChange(of: path) { _, _ in refresh() }
    }

    private func refresh() {
        found = ProgramLocator.locate(program, settingsPath: path)
        Task { @MainActor in JobQueue.shared.refreshAvailability() }
    }

    private func detect() {
        if let u = ProgramLocator.locate(program, settingsPath: "") { path = u.path } else { path = ""; found = nil }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "Choose the \(program.title) executable"
        if panel.runModal() == .OK, let u = panel.url { path = u.path }
    }
}

private struct ProgramsPrefs: View {
    @AppStorage(AppSettings.scratchDirKey) private var scratch = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(QCProgram.allCases) { ProgramRow(program: $0) }
            Divider()
            HStack {
                Text("Gaussian scratch").frame(width: 100, alignment: .leading)
                TextField("Scratch directory (optional)", text: $scratch).textFieldStyle(.roundedBorder)
                Button("Choose\u{2026}") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
                    if panel.runModal() == .OK, let u = panel.url { scratch = u.path }
                }
            }
            Text("Detect looks in your settings, environment variables, PATH and the usual install folders.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding()
    }
}
