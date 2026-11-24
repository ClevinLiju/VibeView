import SwiftUI

/// Spotlight-style command palette. Present it as an overlay when `isPresented` is true.
struct CommandPaletteView: View {
    let commands: [PaletteCommand]
    @Binding var isPresented: Bool

    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    private static let recentKey = "palette.recentCommands"

    private struct Hit: Identifiable {
        var command: PaletteCommand
        var titleMatches: [Int]
        var id: String { command.id }
    }

    private var hits: [Hit] {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty {
            let recent = UserDefaults.standard.stringArray(forKey: Self.recentKey) ?? []
            let byID = Dictionary(commands.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let first = recent.compactMap { byID[$0] }
            let rest = commands.filter { c in !recent.contains(c.id) }
            return (first + rest).prefix(60).map { Hit(command: $0, titleMatches: []) }
        }
        var scored: [(Int, Hit)] = []
        for c in commands {
            var best: (Int, [Int])? = nil
            if let m = FuzzyMatch.score(q, c.title) { best = (m.score + 100, m.matched) }
            for k in c.keywords + [c.category] + (c.subtitle.map { [$0] } ?? []) {
                if let m = FuzzyMatch.score(q, k), best == nil || m.score < (best?.0 ?? 0) - 100 || best == nil {
                    if best == nil { best = (m.score, []) }
                }
            }
            if let b = best { scored.append((b.0 + (c.isEnabled ? 0 : -500), Hit(command: c, titleMatches: b.1))) }
        }
        return scored.sorted { $0.0 > $1.0 }.prefix(60).map(\.1)
    }

    var body: some View {
        let list = hits
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.title3)
                TextField("Type a command, element or fragment…", text: $query)
                    .textFieldStyle(.plain).font(.title3).focused($focused)
                    .onSubmit { run(list) }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            Divider()
            if list.isEmpty {
                Text("No matching commands").foregroundStyle(.secondary).padding(20)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(list.enumerated()), id: \.element.id) { i, h in
                                row(h, selected: i == selection)
                                    .id(h.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture { selection = i; run(list) }
                            }
                        }
                        .padding(6)
                    }
                    .frame(height: min(CGFloat(list.count), 10) * 40 + 12)
                    .onChange(of: selection) { _, s in
                        if list.indices.contains(s) { proxy.scrollTo(list[s].id) }
                    }
                }
            }
        }
        .frame(width: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.3), radius: 24, y: 10)
        .onAppear { focused = true; selection = 0 }
        .onChange(of: query) { _, _ in selection = 0 }
        .onKeyPress(.upArrow) { selection = max(selection - 1, 0); return .handled }
        .onKeyPress(.downArrow) { selection = min(selection + 1, max(list.count - 1, 0)); return .handled }
        .onKeyPress(.escape) { isPresented = false; return .handled }
        .onExitCommand { isPresented = false }
    }

    private func row(_ h: Hit, selected: Bool) -> some View {
        let c = h.command
        return HStack(spacing: 10) {
            Image(systemName: c.symbol).frame(width: 22).foregroundStyle(selected ? Color.white : Color.accentColor)
            VStack(alignment: .leading, spacing: 0) {
                highlighted(c.title, h.titleMatches)
                if let s = c.subtitle {
                    Text(s).font(.caption).foregroundStyle(selected ? Color.white.opacity(0.8) : .secondary)
                }
            }
            Spacer()
            if let sc = c.shortcut {
                Text(sc).font(.system(.callout, design: .rounded)).foregroundStyle(selected ? Color.white.opacity(0.8) : .secondary)
            } else {
                Text(c.category).font(.caption).foregroundStyle(selected ? Color.white.opacity(0.8) : .secondary)
            }
        }
        .padding(.horizontal, 10).frame(height: 40)
        .foregroundStyle(selected ? Color.white : Color.primary)
        .background(selected ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .opacity(c.isEnabled ? 1 : 0.45)
    }

    private func highlighted(_ title: String, _ matches: [Int]) -> Text {
        let set = Set(matches)
        var t = Text("")
        for (i, ch) in title.enumerated() {
            t = t + (set.contains(i) ? Text(String(ch)).bold() : Text(String(ch)))
        }
        return t
    }

    private func run(_ list: [Hit]) {
        guard list.indices.contains(selection) else { return }
        let c = list[selection].command
        guard c.isEnabled else { return }
        var recent = UserDefaults.standard.stringArray(forKey: Self.recentKey) ?? []
        recent.removeAll { $0 == c.id }
        recent.insert(c.id, at: 0)
        UserDefaults.standard.set(Array(recent.prefix(6)), forKey: Self.recentKey)
        isPresented = false
        DispatchQueue.main.async { c.perform() }
    }
}
