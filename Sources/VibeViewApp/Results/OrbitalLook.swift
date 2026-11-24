import SwiftUI
import AppKit
import MolAnalysis
import MolRender

/// How orbital surfaces are drawn: colors for occupied and virtual orbitals, display mode and grid quality.
public struct OrbitalLook: Codable, Equatable, Sendable {
    public var occupied: OrbitalColorScheme = .occupied     // red (+) / blue (−)
    public var virtual: OrbitalColorScheme = .virtual       // green (+) / yellow (−)
    public var mode: SurfaceDisplayMode = .transparent
    public var quality: OrbitalGridQuality = .normal

    static let key = "vibeview.orbital.look"
    public static func load() -> OrbitalLook {
        guard let d = UserDefaults.standard.data(forKey: key), let l = try? JSONDecoder().decode(OrbitalLook.self, from: d) else { return OrbitalLook() }
        return l
    }
    func save() { if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: Self.key) } }
    func scheme(occupied o: Bool) -> OrbitalColorScheme { o ? occupied : virtual }

    /// Modes offered in the picker (`.mesh` is the same look as wireframe).
    static let modes: [SurfaceDisplayMode] = [.solid, .transparent, .wireframe, .points]
}

extension SurfaceDisplayMode {
    var title: String {
        switch self { case .solid: "Solid"; case .transparent: "Transparent"; case .wireframe, .mesh: "Wireframe"; case .points: "Points" }
    }
}

extension OrbitalGridQuality {
    var title: String { switch self { case .draft: "Draft"; case .normal: "Normal"; case .high: "High"; case .ultra: "Ultra" } }
}

extension RGBA {
    var color: Color { Color(red: r, green: g, blue: b, opacity: a) }
    init(_ c: Color) {
        let n = NSColor(c).usingColorSpace(.sRGB) ?? .gray
        self.init(Double(n.redComponent), Double(n.greenComponent), Double(n.blueComponent), Double(n.alphaComponent))
    }
}

/// Orbital appearance controls: colors (occupied / virtual), render mode, grid quality.
struct OrbitalLookControls: View {
    @ObservedObject var editor: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Mode").font(.caption).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                Picker("Mode", selection: $editor.orbitalLook.mode) {
                    ForEach(OrbitalLook.modes, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden().pickerStyle(.segmented)
            }
            HStack {
                Text("Quality").font(.caption).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                Slider(value: qualitySlider, in: 0...Double(OrbitalGridQuality.allCases.count - 1), step: 1)
                Text("\(editor.orbitalLook.quality.title) · \(String(format: "%.2f", editor.orbitalLook.quality.spacing)) Å")
                    .font(.caption).monospacedDigit().frame(width: 92, alignment: .trailing)
            }
            .help("Grid spacing used to compute the orbital: finer grids give smoother surfaces but take longer")
            // One row when the panel is wide enough, otherwise colours and Reset on two rows.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    colorPair("Occupied", \.occupied)
                    colorPair("Virtual", \.virtual)
                    Spacer(minLength: 4)
                    resetButton
                }
                VStack(alignment: .leading, spacing: 6) {
                    colorPair("Occupied", \.occupied)
                    HStack(spacing: 10) {
                        colorPair("Virtual", \.virtual)
                        Spacer(minLength: 4)
                        resetButton
                    }
                }
            }
        }
        .onChange(of: editor.orbitalLook) { _, l in l.save() }
    }

    private var qualitySlider: Binding<Double> {
        Binding(get: { Double(OrbitalGridQuality.allCases.firstIndex(of: editor.orbitalLook.quality) ?? 1) },
                set: { editor.orbitalLook.quality = OrbitalGridQuality.allCases[max(0, min(3, Int($0.rounded())))] })
    }

    private var resetButton: some View {
        Button("Reset") { let q = editor.orbitalLook.quality, m = editor.orbitalLook.mode
            editor.orbitalLook = OrbitalLook(); editor.orbitalLook.quality = q; editor.orbitalLook.mode = m }
            .controlSize(.small).fixedSize().help("Back to red/blue (occupied) and green/yellow (virtual)")
    }

    private func colorPair(_ title: String, _ kp: WritableKeyPath<OrbitalLook, OrbitalColorScheme>) -> some View {
        HStack(spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                .layoutPriority(1)
            ColorPicker("+", selection: Binding(get: { editor.orbitalLook[keyPath: kp].positive.color },
                                                set: { editor.orbitalLook[keyPath: kp].positive = RGBA($0) }), supportsOpacity: false)
                .labelsHidden().help("\(title) orbitals, positive lobe")
            ColorPicker("−", selection: Binding(get: { editor.orbitalLook[keyPath: kp].negative.color },
                                                set: { editor.orbitalLook[keyPath: kp].negative = RGBA($0) }), supportsOpacity: false)
                .labelsHidden().help("\(title) orbitals, negative lobe")
        }
    }
}
