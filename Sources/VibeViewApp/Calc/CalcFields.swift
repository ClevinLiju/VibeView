import SwiftUI
import MolBuild

/// Picker over preset strings with a trailing "Custom…" entry that reveals a text field.
struct ChoiceField: View {
    let title: String
    let options: [String]
    @Binding var value: String
    @State private var forceCustom = false

    var body: some View {
        let isCustom = forceCustom || !options.contains(value)
        VStack(alignment: .leading, spacing: 4) {
            Picker(title, selection: Binding(
                get: { isCustom ? "\u{0}custom" : value },
                set: { new in
                    if new == "\u{0}custom" { forceCustom = true } else { forceCustom = false; value = new }
                })) {
                ForEach(options, id: \.self) { Text($0).tag($0) }
                Divider()
                Text("Custom\u{2026}").tag("\u{0}custom")
            }
            if isCustom {
                TextField("\(title) keyword", text: $value)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }
        }
    }
}

/// Editor for relaxed-scan coordinates.
struct ScanCoordinateEditor: View {
    @Binding var coordinates: [ScanCoordinate]
    let picks: [Int]            // 0-based atom indices from the viewport
    let atomCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach($coordinates) { $c in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Picker("Kind", selection: Binding(get: { c.kind }, set: { k in
                            c.kind = k
                            c.atoms = Array((c.atoms + [1, 2, 3, 4]).prefix(k.atomCount))
                            c.stepSize = k == .bond ? 0.1 : 10
                        })) { ForEach(ScanKind.allCases) { Text($0.title).tag($0) } }
                            .labelsHidden().frame(width: 100)
                        ForEach(0..<c.kind.atomCount, id: \.self) { i in
                            TextField("#", value: Binding(get: { i < c.atoms.count ? c.atoms[i] : 1 },
                                                          set: { v in while c.atoms.count <= i { c.atoms.append(1) }; c.atoms[i] = v }),
                                      format: .number)
                                .frame(width: 44).textFieldStyle(.roundedBorder)
                        }
                        Spacer()
                        Button { coordinates.removeAll { $0.id == c.id } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).help("Remove this coordinate")
                    }
                    HStack {
                        Stepper("Steps: \(c.steps)", value: $c.steps, in: 1...500)
                        TextField("Increment", value: $c.stepSize, format: .number)
                            .frame(width: 70).textFieldStyle(.roundedBorder)
                        Text(c.kind == .bond ? "\u{00C5}" : "\u{00B0}").foregroundStyle(.secondary)
                    }
                    Button("Use picked atoms") { if let a = Self.atoms(from: picks, kind: c.kind) { c.atoms = a } }
                        .buttonStyle(.link).disabled(Self.atoms(from: picks, kind: c.kind) == nil)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))
            }
            Button {
                let kind: ScanKind = [2: .bond, 3: .angle, 4: .dihedral][picks.count] ?? .bond
                let atoms = Self.atoms(from: picks, kind: kind) ?? Array([1, 2, 3, 4].prefix(kind.atomCount))
                coordinates.append(ScanCoordinate(kind: kind, atoms: atoms, steps: 10, stepSize: kind == .bond ? 0.1 : 10))
            } label: { Label("Add Coordinate", systemImage: "plus") }
        }
    }

    static func atoms(from picks: [Int], kind: ScanKind) -> [Int]? {
        picks.count == kind.atomCount ? picks.map { $0 + 1 } : nil
    }
}

/// Optional positive integer: blank means "use the program default".
struct OptionalCountField: View {
    let title: String
    @Binding var value: Int?
    var prompt = "default"

    var body: some View {
        TextField(title, text: Binding(
            get: { value.map(String.init) ?? "" },
            set: { t in
                let digits = t.filter(\.isNumber)
                if let n = Int(digits), n > 0 { value = min(n, 100_000) } else { value = nil }
            }), prompt: Text(prompt))
            .multilineTextAlignment(.trailing)
    }
}

/// Like `ChoiceField`, with the presets grouped into sections (catalog groups) and shown by label.
struct GroupedChoiceField: View {
    struct Option: Hashable { var value: String; var label: String }
    let title: String
    let groups: [(title: String, options: [Option])]
    @Binding var value: String
    @State private var forceCustom = false

    var body: some View {
        let all = groups.flatMap(\.options).map(\.value)
        let isCustom = forceCustom || !all.contains(value)
        VStack(alignment: .leading, spacing: 4) {
            Picker(title, selection: Binding(
                get: { isCustom ? "\u{0}custom" : value },
                set: { new in
                    if new == "\u{0}custom" { forceCustom = true } else { forceCustom = false; value = new }
                })) {
                ForEach(groups, id: \.title) { g in
                    Section(g.title) {
                        ForEach(g.options, id: \.self) { o in
                            Text(o.label == o.value ? o.label : "\(o.label)  (\(o.value))").tag(o.value)
                        }
                    }
                }
                Divider()
                Text("Custom\u{2026}").tag("\u{0}custom")
            }
            if isCustom {
                TextField("\(title) keyword", text: $value)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }
        }
    }

    /// Groups in first-appearance order.
    static func grouped<T>(_ items: [T], group: (T) -> String, option: (T) -> Option?) -> [(title: String, options: [Option])] {
        var out: [(title: String, options: [Option])] = []
        for it in items {
            guard let o = option(it) else { continue }
            let g = group(it)
            if let k = out.firstIndex(where: { $0.title == g }) { out[k].options.append(o) } else { out.append((g, [o])) }
        }
        return out
    }
}
